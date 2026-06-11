#!/usr/bin/env bash
# Diagnose (and optionally recover) the local observability stack when the
# Grafana dashboards go blank. The recurring failure mode is a single-binary
# Loki ring flap: when the workstation sleeps and wakes, Loki's heartbeat goes
# stale, the ring marks its only member unhealthy ("could only find 0 healthy
# instances ... auto-forgetting instance 127.0.0.1:9096"), and the query path
# is down until the ~10-minute auto-forget elapses — so the dashboards, which
# read history from Loki, show nothing. It self-heals, but this recurs on every
# sleep/wake, so this script makes the diagnosis one command and `--fix` skips
# the wait by restarting Loki and re-running the sync.
#
# The load-bearing logic is distinguishing a real flap from GENUINE IDLENESS: a
# blank "last 1 hour" panel may just mean no recent delegations. We judge that
# against the metrics FILE — if the file itself has nothing recent, an empty
# panel is expected and nothing is wrong, so the doctor does not cry wolf.
#
# Read-only by default (like audit-metrics.sh): it only restarts/re-syncs under
# --fix. The Tempo trace path is independent of Loki's ring and is reported but
# never touched.
#
# Usage:
#   observability-doctor.sh [--fix] [--loki-url URL] [--metrics-file PATH]
#                           [--compose-file PATH]
#
# Env (shared names with sync-metrics-to-loki.sh so one tuning applies to both):
#   DELEGATE_LOKI_URL              Loki base URL. Default http://localhost:3100.
#   DELEGATE_METRICS_FILE          metrics JSONL. Default
#                                  ~/.claude/skills/delegate-local/metrics.jsonl.
#   DELEGATE_GRAFANA_URL           Grafana base URL. Default http://localhost:3001.
#   DELEGATE_TEMPO_URL             Tempo query API.  Default http://localhost:3200.
#   DELEGATE_COMPOSE_FILE          compose file. Default <repo>/observability/docker-compose.yml.
#   DELEGATE_DOCTOR_STALE_SECONDS  recency threshold (default 1800 = 30 min):
#                                  how old the newest metrics row may be before
#                                  the dashboards count as legitimately idle.
#
# Exit: 0 healthy OR genuinely idle; 1 ring flapped / Loki behind (recoverable,
#       --fix restarts+resyncs); 2 stack/Loki not running, usage error, missing
#       dependency, or unreadable metrics file (operator action, not a flap).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

loki_url="${DELEGATE_LOKI_URL:-http://localhost:3100}"
metrics_file="${DELEGATE_METRICS_FILE:-$HOME/.claude/skills/delegate-local/metrics.jsonl}"
grafana_url="${DELEGATE_GRAFANA_URL:-http://localhost:3001}"
tempo_url="${DELEGATE_TEMPO_URL:-http://localhost:3200}"
compose_file="${DELEGATE_COMPOSE_FILE:-$REPO/observability/docker-compose.yml}"
stale_seconds="${DELEGATE_DOCTOR_STALE_SECONDS:-1800}"
fix=0

usage() {
  cat >&2 <<'EOF'
usage: observability-doctor.sh [--fix] [--loki-url URL] [--metrics-file PATH] [--compose-file PATH]
  Diagnoses the local Grafana/Tempo/Loki stack when the dashboards go blank.
  Read-only by default; --fix restarts Loki and re-runs the metrics sync when
  the Loki ring has flapped (the sleep/wake failure mode). Exit 0 healthy/idle,
  1 recoverable flap, 2 stack down / usage / missing dep.
EOF
  exit 2
}

while (($# > 0)); do
  case "$1" in
    --fix) fix=1; shift;;
    --loki-url)
      [[ $# -lt 2 || -z "${2:-}" ]] && { echo 'observability-doctor: --loki-url requires a value' >&2; exit 2; }
      loki_url="$2"; shift 2;;
    --loki-url=*) loki_url="${1#--loki-url=}"; shift;;
    --metrics-file)
      [[ $# -lt 2 || -z "${2:-}" ]] && { echo 'observability-doctor: --metrics-file requires a path' >&2; exit 2; }
      metrics_file="$2"; shift 2;;
    --metrics-file=*) metrics_file="${1#--metrics-file=}"; shift;;
    --compose-file)
      [[ $# -lt 2 || -z "${2:-}" ]] && { echo 'observability-doctor: --compose-file requires a path' >&2; exit 2; }
      compose_file="$2"; shift 2;;
    --compose-file=*) compose_file="${1#--compose-file=}"; shift;;
    -h|--help) usage;;
    *) echo "observability-doctor: unknown arg '$1'" >&2; usage;;
  esac
done

command -v jq     >/dev/null || { echo "observability-doctor: jq not on PATH"     >&2; exit 2; }
command -v curl   >/dev/null || { echo "observability-doctor: curl not on PATH"   >&2; exit 2; }
command -v docker >/dev/null || { echo "observability-doctor: docker not on PATH" >&2; exit 2; }

now=$(date +%s)

# --- 1. Is the stack (specifically Loki) up? -------------------------------
running=$(docker compose -f "$compose_file" ps --status running --format '{{.Service}}' 2>/dev/null)
if ! printf '%s\n' "$running" | grep -qx 'loki'; then
  echo "observability-doctor: the Loki container is not running." >&2
  echo "  Running services: ${running:-(none)}" >&2
  echo "  Bring the stack up: docker compose -f $compose_file up -d" >&2
  echo "DOCTOR_SUMMARY: stack=down loki=absent verdict=stack-down"
  exit 2
fi

# --- 2. Loki HTTP readiness ------------------------------------------------
ready_code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "${loki_url%/}/ready" 2>/dev/null || echo "000")

# --- 3. Ring health from recent Loki logs ----------------------------------
# The sleep/wake signature the maintainer observed. Plain grep -E (no -P) for
# portability. A match within the recent window means the ring flapped.
ring_logsig=0
if docker compose -f "$compose_file" logs --since 15m loki 2>/dev/null \
     | grep -E -i 'could only find 0|unhealthy instances|auto-forgetting instance' >/dev/null 2>&1; then
  ring_logsig=1
fi

wedged=0
[[ "$ready_code" != "200" ]] && wedged=1
(( ring_logsig == 1 )) && wedged=1

# --- 4. Data age: newest row in the FILE vs newest Loki actually serves -----
# Idleness is judged against the file: if the file has nothing recent, a blank
# panel is expected, not a flap.
if [[ ! -f "$metrics_file" ]]; then
  echo "observability-doctor: metrics file not found: $metrics_file" >&2
  echo "  Cannot judge data freshness without it." >&2
  echo "DOCTOR_SUMMARY: stack=up metrics_file=missing verdict=metrics-file-missing"
  exit 2
fi

file_newest=$(jq -rs '
  [ .[] | (.ts? // empty)
    | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime ] | (max // empty)
' "$metrics_file" 2>/dev/null)

if [[ -z "$file_newest" ]]; then
  file_age="n/a"
  file_recent=0
else
  file_age=$(( now - file_newest ))
  if (( file_age <= stale_seconds )); then file_recent=1; else file_recent=0; fi
fi

# Newest timestamp Loki actually holds (best-effort: a wedged Loki returns
# nothing here, which corroborates the flap). seconds = ns / 1e9.
loki_newest=""
loki_body=$(curl -s -m 5 -G "${loki_url%/}/loki/api/v1/query_range" \
  --data-urlencode 'query={service="delegate-local"}' \
  --data-urlencode 'direction=backward' \
  --data-urlencode 'limit=1' 2>/dev/null || true)
if [[ -n "$loki_body" ]]; then
  loki_newest=$(printf '%s' "$loki_body" | jq -r '
    [ .data.result[]?.values[]?[0] | tonumber ] | (max // null)
    | if . == null then "" else (. / 1000000000 | floor) end
  ' 2>/dev/null || echo "")
fi
if [[ -n "$loki_newest" ]]; then loki_age=$(( now - loki_newest )); else loki_age="n/a"; fi

# Loki is "behind" the file when the file has recent rows but Loki's newest is
# missing or lags by more than the staleness window (a sync that fell behind).
loki_behind=0
if (( file_recent == 1 )); then
  if [[ -z "$loki_newest" ]]; then
    loki_behind=1
  elif (( file_newest - loki_newest > stale_seconds )); then
    loki_behind=1
  fi
fi

# --- 5. Grafana / Tempo reachability (report-only) -------------------------
grafana_code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "${grafana_url%/}/api/health" 2>/dev/null || echo "000")
tempo_code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "${tempo_url%/}/ready" 2>/dev/null || echo "000")
[[ "$grafana_code" == "200" ]] || echo "observability-doctor: note — Grafana /api/health returned $grafana_code (dashboards UI may be down independently of Loki)." >&2
[[ "$tempo_code" == "200" ]]   || echo "observability-doctor: note — Tempo /ready returned $tempo_code (live trace path; independent of the Loki ring)." >&2

summary() {
  echo "DOCTOR_SUMMARY: stack=up ready=$ready_code ring_logsig=$ring_logsig file_age_s=$file_age loki_age_s=$loki_age verdict=$1"
}

# --- 6. Verdict ------------------------------------------------------------
if (( file_recent == 0 )); then
  if (( wedged == 1 )); then
    echo "observability-doctor: no delegations in the last $((stale_seconds/60))m, so a blank recent-window panel is expected — not a flap. Loki's ring is currently re-forming (ready=$ready_code); with nothing recent to chart this is not data loss and it will self-heal. Re-run after new delegations if a panel stays blank." >&2
  else
    echo "observability-doctor: healthy-idle — no delegations in the last $((stale_seconds/60))m, so an empty recent-window panel is expected, not a fault. Loki is ready and the trace path is up." >&2
  fi
  summary "idle"
  exit 0
fi

if (( wedged == 0 && loki_behind == 0 )); then
  echo "observability-doctor: healthy — Loki is ready, the ring is clean, and Loki's newest data tracks the metrics file (file_age=${file_age}s, loki_age=${loki_age}s)." >&2
  summary "healthy"
  exit 0
fi

# Recoverable: either the ring flapped or the sync fell behind, and there IS
# recent data that should be visible.
if (( wedged == 1 )); then
  echo "observability-doctor: Loki ring flap detected (ready=$ready_code, log-signature=$ring_logsig) while recent delegations exist — the query path is down so the dashboards are blank." >&2
else
  echo "observability-doctor: Loki is ready but its newest data lags the metrics file by $((file_newest - loki_newest))s — the sync fell behind." >&2
fi

if (( fix == 0 )); then
  echo "  Recover by either waiting out the ~10-minute ring auto-forget, or re-run with --fix to restart Loki and re-sync now:" >&2
  echo "    bash scripts/observability-doctor.sh --fix" >&2
  summary "wedged-recoverable"
  exit 1
fi

# --fix: restart Loki to rejoin the ring fresh, wait for /ready, re-sync.
echo "observability-doctor: --fix — restarting Loki and re-running the metrics sync..." >&2
docker compose -f "$compose_file" restart loki >/dev/null 2>&1 || {
  echo "observability-doctor: 'docker compose restart loki' failed." >&2
  summary "fix-restart-failed"
  exit 1
}
ready_after=""
i=0
while (( i < 30 )); do
  ready_after=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "${loki_url%/}/ready" 2>/dev/null || echo "000")
  [[ "$ready_after" == "200" ]] && break
  sleep 2
  i=$((i + 1))
done
if [[ "$ready_after" != "200" ]]; then
  echo "observability-doctor: Loki did not return ready within the timeout (last ready=$ready_after); check 'docker compose -f $compose_file logs loki'." >&2
  summary "fix-ready-timeout"
  exit 1
fi
DELEGATE_LOKI_URL="$loki_url" DELEGATE_METRICS_FILE="$metrics_file" \
  bash "$REPO/scripts/sync-metrics-to-loki.sh" >/dev/null 2>&1 || true
echo "observability-doctor: recovered — Loki is ready again and the sync has re-run." >&2
ready_code="$ready_after"
summary "recovered"
exit 0
