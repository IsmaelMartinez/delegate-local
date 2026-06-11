#!/usr/bin/env bash
# Unit tests for scripts/observability-doctor.sh. Mocks docker + curl on a
# restricted PATH (the run-tests.sh / test-sync-metrics-to-loki.sh idiom) so no
# container or network is touched, and pins the two load-bearing behaviours:
# the staleness-vs-idleness discriminator and the exit-code contract
# (0 healthy/idle, 1 recoverable flap, 2 stack-down/usage/dep).

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/observability-doctor.sh"
SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

pass=0
fail=0
assert_eq() { if [[ "$1" == "$2" ]]; then echo "  PASS  $3"; pass=$((pass+1)); else echo "  FAIL  $3 (expected '$1', got '$2')"; fail=$((fail+1)); fi; }
assert_contains() { case "$2" in *"$1"*) echo "  PASS  $3"; pass=$((pass+1));; *) echo "  FAIL  $3 (missing '$1')"; fail=$((fail+1));; esac; }
assert_absent() { case "$2" in *"$1"*) echo "  FAIL  $3 (unexpected '$1')"; fail=$((fail+1));; *) echo "  PASS  $3"; pass=$((pass+1));; esac; }

tmp=$(mktemp -d)
sentinel="$tmp/restart.sentinel"
met="$tmp/m.jsonl"
trap 'rm -rf "$tmp"' EXIT

iso_ago() { perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - $ARGV[0]))' "$1"; }
now=$(date +%s)

# Mock docker: `compose ... ps` prints $DOCTOR_RUNNING (space-separated services,
# one per line); `compose ... logs` prints $DOCTOR_LOGS; `compose ... restart`
# touches the sentinel so the curl mock can model "restart fixed the ring".
cat > "$tmp/docker" <<EOF
#!/usr/bin/env bash
sub=""
for a in "\$@"; do case "\$a" in ps) sub=ps;; logs) sub=logs;; restart) sub=restart;; esac; done
case "\$sub" in
  ps) for s in \$DOCTOR_RUNNING; do echo "\$s"; done ;;
  logs) printf '%s\n' "\$DOCTOR_LOGS" ;;
  restart) : > "$sentinel" ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$tmp/docker"

# Mock curl: routes by the http(s) URL in the args. Loki /ready returns 200 once
# the restart sentinel exists (modelling recovery), else $DOCTOR_READY_CODE.
cat > "$tmp/curl" <<EOF
#!/usr/bin/env bash
url=""
for a in "\$@"; do case "\$a" in http://*|https://*) url="\$a";; esac; done
case "\$url" in
  *query_range*) printf '%s' "\$DOCTOR_LOKI_BODY"; exit 0;;
  *loki*ready) if [[ -f "$sentinel" ]]; then echo -n 200; else echo -n "\${DOCTOR_READY_CODE:-200}"; fi; exit 0;;
  *tempo*ready) echo -n "\${DOCTOR_TEMPO_CODE:-200}"; exit 0;;
  *api/health*) echo -n "\${DOCTOR_GRAFANA_CODE:-200}"; exit 0;;
  *push*|*flush*) echo -n 204; exit 0;;
  *ready*) if [[ -f "$sentinel" ]]; then echo -n 200; else echo -n "\${DOCTOR_READY_CODE:-200}"; fi; exit 0;;
  *) echo -n 200; exit 0;;
esac
EOF
chmod +x "$tmp/curl"

# Scenario knobs (defaults: a clean, running stack).
S_RUNNING="tempo loki grafana"
S_LOGS="level=info ts=now caller=loop.go msg=ready"
S_LOKI_BODY="{\"data\":{\"result\":[{\"values\":[[\"${now}000000000\",\"line\"]]}]}}"
S_READY="200"

run_doctor() {
  rm -f "$sentinel"
  local ec=0
  LAST_OUT=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
    DELEGATE_LOKI_URL=http://loki DELEGATE_GRAFANA_URL=http://grafana DELEGATE_TEMPO_URL=http://tempo \
    DOCTOR_RUNNING="$S_RUNNING" DOCTOR_LOGS="$S_LOGS" DOCTOR_LOKI_BODY="$S_LOKI_BODY" DOCTOR_READY_CODE="$S_READY" \
    bash "$SCRIPT" --metrics-file "$met" --compose-file "$tmp/compose.yml" "$@" 2>&1) || ec=$?
  LAST_EC="$ec"
}

# --- T1: healthy — recent data, Loki ready, ring clean, Loki tracking file ---
printf '%s\n' "{\"ts\":\"$(iso_ago 60)\",\"source\":\"delegate\",\"recipe\":\"commit-message\",\"tier\":\"prose\"}" > "$met"
S_RUNNING="tempo loki grafana"; S_READY="200"; S_LOGS="msg=ready"
S_LOKI_BODY="{\"data\":{\"result\":[{\"values\":[[\"${now}000000000\",\"line\"]]}]}}"
run_doctor
assert_eq "0" "$LAST_EC" "T1: healthy -> exit 0"
assert_contains "verdict=healthy" "$LAST_OUT" "T1: summary verdict healthy"
assert_absent "ring flap detected" "$LAST_OUT" "T1: no false flap alarm"

# --- T2: genuine idleness — no recent rows, Loki ready -> exit 0, no restart --
printf '%s\n' "{\"ts\":\"$(iso_ago 10800)\",\"source\":\"delegate\",\"recipe\":\"commit-message\",\"tier\":\"prose\"}" > "$met"
S_READY="200"; S_LOGS="msg=ready"
run_doctor
assert_eq "0" "$LAST_EC" "T2: idle -> exit 0"
assert_contains "verdict=idle" "$LAST_OUT" "T2: summary verdict idle"
assert_contains "no delegations in the last" "$LAST_OUT" "T2: idleness explained, not a flap"
[[ -f "$sentinel" ]] && { echo "  FAIL  T2: idle must not restart"; fail=$((fail+1)); } || { echo "  PASS  T2: idle did not restart Loki"; pass=$((pass+1)); }

# --- T3: wedged via ring log signature, read-only -> exit 1, no restart ------
printf '%s\n' "{\"ts\":\"$(iso_ago 60)\",\"source\":\"delegate\",\"recipe\":\"commit-message\",\"tier\":\"prose\"}" > "$met"
S_READY="200"
S_LOGS="level=error msg=\"error notifying frontend about finished query\" at least 1 healthy replica required, could only find 0 - unhealthy instances: 127.0.0.1:9096 auto-forgetting instance from the ring"
run_doctor
assert_eq "1" "$LAST_EC" "T3: ring-log flap (read-only) -> exit 1"
assert_contains "verdict=wedged-recoverable" "$LAST_OUT" "T3: summary verdict wedged-recoverable"
assert_contains "ring flap detected" "$LAST_OUT" "T3: names the ring flap"
assert_contains "--fix" "$LAST_OUT" "T3: offers the --fix recovery"
[[ -f "$sentinel" ]] && { echo "  FAIL  T3: read-only must not restart"; fail=$((fail+1)); } || { echo "  PASS  T3: read-only did not restart Loki"; pass=$((pass+1)); }

# --- T4: wedged via /ready 503 + --fix -> restart, ready flips, resync, exit 0 -
printf '%s\n' "{\"ts\":\"$(iso_ago 60)\",\"source\":\"delegate\",\"recipe\":\"commit-message\",\"tier\":\"prose\"}" > "$met"
S_READY="503"; S_LOGS="msg=ready"
S_LOKI_BODY="{\"data\":{\"result\":[]}}"
run_doctor --fix
assert_eq "0" "$LAST_EC" "T4: --fix recovers -> exit 0"
assert_contains "verdict=recovered" "$LAST_OUT" "T4: summary verdict recovered"
[[ -f "$sentinel" ]] && { echo "  PASS  T4: --fix restarted Loki"; pass=$((pass+1)); } || { echo "  FAIL  T4: --fix should restart Loki"; fail=$((fail+1)); }

# --- T5: stack down — Loki not in running services -> exit 2 -----------------
printf '%s\n' "{\"ts\":\"$(iso_ago 60)\",\"source\":\"delegate\"}" > "$met"
S_RUNNING="tempo grafana"; S_READY="200"
run_doctor
assert_eq "2" "$LAST_EC" "T5: Loki not running -> exit 2"
assert_contains "verdict=stack-down" "$LAST_OUT" "T5: summary verdict stack-down"
assert_contains "up -d" "$LAST_OUT" "T5: tells the operator to bring the stack up"
S_RUNNING="tempo loki grafana"

# --- T6: usage error — unknown flag -> exit 2 --------------------------------
run_doctor --bogus
assert_eq "2" "$LAST_EC" "T6: unknown flag -> exit 2"
assert_contains "usage:" "$LAST_OUT" "T6: prints usage"

# --- T7: unreadable metrics file -> exit 2 -----------------------------------
S_READY="200"
LAST_EC=0
LAST_OUT=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_LOKI_URL=http://loki DELEGATE_GRAFANA_URL=http://grafana DELEGATE_TEMPO_URL=http://tempo \
  DOCTOR_RUNNING="tempo loki grafana" DOCTOR_LOGS="msg=ready" DOCTOR_LOKI_BODY="$S_LOKI_BODY" DOCTOR_READY_CODE="200" \
  bash "$SCRIPT" --metrics-file "$tmp/does-not-exist.jsonl" --compose-file "$tmp/compose.yml" 2>&1) || LAST_EC=$?
assert_eq "2" "$LAST_EC" "T7: missing metrics file -> exit 2"
assert_contains "metrics-file-missing" "$LAST_OUT" "T7: summary verdict metrics-file-missing"

echo
echo "$pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then exit 1; fi
