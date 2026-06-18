#!/usr/bin/env bash
# Benchmark the PRODUCTION verify-and-escalate gate (ADR 0020) end-to-end
# through scripts/delegate.sh — not the prototype harness, which bypassed the
# wrapper. Runs the commit-message recipe over a built-in diff set with a cheap
# primary and a stronger escalation target, and reports for each case whether
# the gate fired (a capability check failed on the primary) and whether the
# escalated output was adopted, plus latency, then an aggregate fire/adopt rate.
#
# No model name is hardcoded: the caller supplies the escalation target and a
# substring that pins the cheap primary (prepended to the tier's preference list
# via a temp DELEGATE_LOCAL_CONFIG), mirroring how delegate.sh resolves models.
#
# Usage:
#   escalate-gate-eval.sh --escalate-model <name> --primary <pref-substring> \
#       [--tier code] [--backend mlx]
#
# Example (the 2026-06-18 reading):
#   escalate-gate-eval.sh \
#     --escalate-model lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit \
#     --primary qwen3-0.6 --backend mlx

set -uo pipefail

escalate_model=""
primary_substr=""
tier="code"
backend="${DELEGATE_BACKEND:-auto}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --escalate-model) [[ $# -ge 2 ]] || { echo "--escalate-model requires a value" >&2; exit 2; }; escalate_model="$2"; shift 2 ;;
    --primary)        [[ $# -ge 2 ]] || { echo "--primary requires a value" >&2; exit 2; }; primary_substr="$2"; shift 2 ;;
    --tier)           [[ $# -ge 2 ]] || { echo "--tier requires a value" >&2; exit 2; }; tier="$2"; shift 2 ;;
    --backend)        [[ $# -ge 2 ]] || { echo "--backend requires a value" >&2; exit 2; }; backend="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
if [[ -z "$escalate_model" || -z "$primary_substr" ]]; then
  echo "usage: escalate-gate-eval.sh --escalate-model <name> --primary <pref-substring> [--tier code] [--backend mlx]" >&2
  exit 2
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
delegate="$here/../scripts/delegate.sh"
work="$(mktemp -d)" || { echo "mktemp failed" >&2; exit 1; }
[[ -n "$work" && -d "$work" ]] || { echo "bad workdir" >&2; exit 1; }
trap 'rm -rf "$work"' EXIT
cfg="$work/cheap.sh"
printf 'prefs=(%s "${prefs[@]}")\n' "$primary_substr" > "$cfg"
chmod 600 "$cfg"
metrics="$work/metrics.jsonl"; : > "$metrics"

# Built-in diff set: one per conventional-commit type, small enough that a
# below-floor model tends to mis-type or drop the body (the capability checks
# the gate keys on). name|type|why|diff(\n-encoded).
cases=(
'add-logging|feat|add request logging|diff --git a/srv.py b/srv.py\n--- a/srv.py\n+++ b/srv.py\n@@ -5,2 +5,4 @@\n def handle(req):\n+    log.info("req", req.id)\n     return ok(req)\n+# end'
'fix-null|fix|guard against null user|diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n@@ -2 +2,3 @@\n def f(u):\n-    return u.name\n+    if u is None:\n+        return ""\n+    return u.name'
'docs-install|docs|document the install step|diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -10 +10,2 @@\n ## Install\n+Run npm install first.'
'chore-bump|chore|bump dep version|diff --git a/pkg.json b/pkg.json\n--- a/pkg.json\n+++ b/pkg.json\n@@ -3 +3 @@\n-lodash 4.0.0\n+lodash 4.17.21'
'test-add|test|add a regression test|diff --git a/t.py b/t.py\n--- a/t.py\n+++ b/t.py\n@@ -1 +1,3 @@\n+def test_lock():\n+    assert lock(5) is True'
'refactor-extract|refactor|extract validation helper|diff --git a/v.py b/v.py\n--- a/v.py\n+++ b/v.py\n@@ -1,4 +1,6 @@\n-def run(x):\n-    if x<0: raise ValueError\n-    return x\n+def _validate(x):\n+    if x<0: raise ValueError\n+def run(x):\n+    _validate(x); return x'
'perf-cache|perf|memoise expensive call|diff --git a/c.py b/c.py\n--- a/c.py\n+++ b/c.py\n@@ -1,2 +1,3 @@\n+@lru_cache\n def slow(n):\n     return heavy(n)'
'style-imports|style|reformat imports|diff --git a/i.py b/i.py\n--- a/i.py\n+++ b/i.py\n@@ -1,2 +1,2 @@\n-import os,sys\n+import os\n+import sys'
)

echo "================================================================"
echo "verify-and-escalate gate benchmark (ADR 0020)"
echo "tier=$tier  primary~=$primary_substr  escalate=$escalate_model  backend=$backend"
echo "================================================================"
n=0; fired=0; adopted=0
for c in "${cases[@]}"; do
  name="${c%%|*}"; rest="${c#*|}"
  type="${rest%%|*}"; rest="${rest#*|}"
  why="${rest%%|*}"; diff_enc="${rest#*|}"
  diff="$(printf '%b' "$diff_enc")"
  n=$((n+1))
  if ! printf '%s' "$diff" | env DELEGATE_BACKEND="$backend" DELEGATE_LOCAL_CONFIG="$cfg" \
    DELEGATE_ESCALATE_MODEL="$escalate_model" DELEGATE_METRICS_FILE="$metrics" \
    DELEGATE_LOCAL_NO_VERDICT_NUDGE=1 \
    bash "$delegate" --recipe auto --var why="$why" --var type="$type" "$tier" >/dev/null 2>"$work/err"; then
    echo "  warn: delegate.sh failed for case '$name' — stderr:" >&2
    sed 's/^/    /' "$work/err" >&2
  fi
  row="$(tail -1 "$metrics")"
  esc="$(printf '%s' "$row" | jq -r '.escalated_to // ""')"
  adopt="$(printf '%s' "$row" | jq -r '.escalation_adopted // ""')"
  dur="$(printf '%s' "$row" | jq -r '.duration_ms // 0')"
  [[ -n "$esc" ]] && fired=$((fired+1))
  [[ "$adopt" == "true" ]] && adopted=$((adopted+1))
  printf '  %-18s type=%-9s fired=%-4s adopted=%-5s dur_ms=%s\n' \
    "$name" "$type" "$([[ -n "$esc" ]] && echo yes || echo no)" "${adopt:-n/a}" "$dur"
done
echo "----------------------------------------------------------------"
echo "GATE_SUMMARY: n=$n fired=$fired adopted=$adopted"
