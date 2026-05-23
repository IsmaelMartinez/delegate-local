#!/usr/bin/env bash
# Unit tests for scripts/model-change-audit.sh.
# PATH-shadows ollama, eval-skill-triggers.sh, and run-baseline.sh on a
# restricted PATH so the verdict logic is exercised without any installed
# model or live network. The scorers (experiments/score-t*.sh) execute
# for real against the mock raw output we synthesise.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/model-change-audit.sh"
SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

pass=0
fail=0

assert_eq() {
  local expected="$1" actual="$2" name="$3"
  if [[ "$expected" == "$actual" ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (expected '$expected', got '$actual')"; fail=$((fail+1)); fi
}
assert_contains() {
  local needle="$1" haystack="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (missing '$needle' in '$haystack')"; fail=$((fail+1)); fi
}

# Build an ollama mock that lists the named installed tags and prints a
# trivial chat template on `ollama show --modelfile`. The list body is
# a multi-line string with each tag on its own line.
make_ollama_mock() {
  local dir="$1" installed="$2" template="${3:-}"
  cat > "$dir/ollama" <<EOF
#!/usr/bin/env bash
case "\$1" in
  list)
    echo 'NAME ID SIZE MODIFIED'
EOF
  local tag
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    printf '    echo %q\n' "$tag aaaaaa 30GB 1 day ago" >> "$dir/ollama"
  done <<< "$installed"
  cat >> "$dir/ollama" <<EOF
    ;;
  show)
    cat <<'TEMPLATE_EOF'
$template
TEMPLATE_EOF
    ;;
esac
EOF
  chmod +x "$dir/ollama"
}

# Build an eval-skill-triggers mock that mimics the script's success path
# output. recall/neg_prec are configurable.
make_eval_mock() {
  local dir="$1" recall="$2" neg_prec="$3" exit_code="${4:-0}"
  mkdir -p "$dir/scripts"
  cat > "$dir/scripts/eval-skill-triggers.sh" <<EOF
#!/usr/bin/env bash
echo "shape: total=16 positive=8 negative=8 missing-fields=0"
echo "scoring: backend=ollama model=mock-model"
echo "results: tp=8 fn=0 tn=8 fp=0 recall=$recall negative-precision=$neg_prec"
echo "OK trigger evals (ollama)"
exit $exit_code
EOF
  chmod +x "$dir/scripts/eval-skill-triggers.sh"
}

# Build a run-baseline mock that writes the raw file containing T4/T5/T6
# rep blocks. Each rep is a tiny "all checks pass" or "all checks fail"
# block depending on the requested score profile.
#
# Profile shapes:
#   perfect   — all scorers see 6/6 on every rep
#   marginal  — drop on T4 only (subject too long → 5/6)
#   reject    — T4 catastrophic (broken format → 0/6)
make_baseline_mock() {
  local dir="$1" profile="$2"
  mkdir -p "$dir/experiments"
  # The mock writes its raw under $REPO/experiments/results/raw so the
  # script-under-test finds it via the slug.
  cat > "$dir/experiments/run-baseline.sh" <<EOF
#!/usr/bin/env bash
# Parse args: ... --reps N <model>
model="\${@: -1}"
slug="\$(printf '%s' "\$model" | tr '/:.' '___')"
out="$REPO/experiments/results/raw/\$slug.txt"
mkdir -p "\$(dirname "\$out")"
profile="$profile"
cat > "\$out" <<RAW
MODEL: \$model
BACKEND: ollama
DATE: 2026-05-23T00:00:00Z
REPS: 3
T3_SNAPSHOT: 2026-04-28
T4_SNAPSHOT: 2026-05-21
T5_SNAPSHOT: 2026-05-11
T6_SNAPSHOT: 2026-05-11

RAW
case "\$profile" in
  perfect)
    for rep in 1 2 3; do
      cat >> "\$out" <<RAW
===== T4-commit-message rep \$rep =====
DURATION_SEC: 2
RUN_STATUS: 0
OUTPUT:
feat: prompts/foo — short subject under limit

A flush-left body paragraph. No bullets. No padding tail.

===== T5-json-shape rep \$rep =====
DURATION_SEC: 2
RUN_STATUS: 0
OUTPUT:
{"owner": "ismael", "items": [{"task": "A", "due": "2026-04-22"}, {"task": "B", "due": "2026-04-30"}, {"task": "C", "due": "2026-05-08"}]}

===== T6-regex-generation rep \$rep =====
DURATION_SEC: 2
RUN_STATUS: 0
OUTPUT:
^[A-Z]{2}-[0-9]+\$

RAW
    done
    ;;
  marginal)
    # T4 has one fail (SUBJECT_LEN exceeds 72) on each rep -> 5/6 ≈ 0.83
    # which is below incumbent's perfect 1.0 by ≥ 0.10 → FAIL, or by
    # < 0.10 → MARGINAL depending on incumbent presence. T5/T6 perfect.
    for rep in 1 2 3; do
      cat >> "\$out" <<RAW
===== T4-commit-message rep \$rep =====
DURATION_SEC: 2
RUN_STATUS: 0
OUTPUT:
feat: prompts/foo — a really long subject line that pads past the limit by enough chars

A flush-left body paragraph. No bullets. No padding tail.

===== T5-json-shape rep \$rep =====
DURATION_SEC: 2
RUN_STATUS: 0
OUTPUT:
{"owner": "ismael", "items": [{"task": "A", "due": "2026-04-22"}, {"task": "B", "due": "2026-04-30"}, {"task": "C", "due": "2026-05-08"}]}

===== T6-regex-generation rep \$rep =====
DURATION_SEC: 2
RUN_STATUS: 0
OUTPUT:
^[A-Z]{2}-[0-9]+\$

RAW
    done
    ;;
  reject)
    # T4 catastrophic: 0/6 every rep (no subject at all → all checks fail)
    for rep in 1 2 3; do
      cat >> "\$out" <<RAW
===== T4-commit-message rep \$rep =====
DURATION_SEC: 2
RUN_STATUS: 0
OUTPUT:

===== T5-json-shape rep \$rep =====
DURATION_SEC: 2
RUN_STATUS: 0
OUTPUT:
{"owner": "ismael", "items": [{"task": "A", "due": "2026-04-22"}, {"task": "B", "due": "2026-04-30"}, {"task": "C", "due": "2026-05-08"}]}

===== T6-regex-generation rep \$rep =====
DURATION_SEC: 2
RUN_STATUS: 0
OUTPUT:
^[A-Z]{2}-[0-9]+\$

RAW
    done
    ;;
esac
EOF
  chmod +x "$dir/experiments/run-baseline.sh"
}

# Helper to clean up raw files our mocks dropped into the real tree.
cleanup_raw() {
  local model="$1"
  local slug
  slug=$(printf '%s' "$model" | tr '/:.' '___')
  rm -f "$REPO/experiments/results/raw/$slug.txt"
}

# Stage a self-contained sandbox under $tmp with:
#   - PATH-shadowed ollama mock
#   - eval-skill-triggers and run-baseline replacements that the
#     script-under-test will reach via $repo_root paths (we set
#     repo_root by invoking the script's own copy with HOME pinned and
#     by PATH-shadowing only the bits the script execs externally).
# For the gates, the script invokes scripts/eval-skill-triggers.sh and
# experiments/run-baseline.sh via "$repo_root/<path>". Repo root is
# fixed (the worktree). We test by running the script unmodified against
# replaced mock copies that we drop into the actual repo's scripts /
# experiments dirs — but we restore the originals afterwards. To avoid
# editing the real tree we instead use a thin shim: copy the
# script-under-test into a sandbox, rewrite it so $repo_root points at
# the sandbox where our mocks live.
#
# Sandbox layout under $tmp:
#   $tmp/repo/scripts/model-change-audit.sh   (copy of real script)
#   $tmp/repo/scripts/eval-skill-triggers.sh  (mock)
#   $tmp/repo/scripts/pick-model.sh           (symlink to real)
#   $tmp/repo/experiments/run-baseline.sh     (mock)
#   $tmp/repo/experiments/score-t4.sh         (symlink to real)
#   $tmp/repo/experiments/score-t5.sh         (symlink to real)
#   $tmp/repo/experiments/score-t6.sh         (symlink to real)
#   $tmp/repo/experiments/results/raw/        (writable)
stage_sandbox() {
  local tmp="$1"
  mkdir -p "$tmp/repo/scripts" "$tmp/repo/experiments/results/raw"
  cp "$SCRIPT" "$tmp/repo/scripts/model-change-audit.sh"
  ln -s "$REPO/scripts/pick-model.sh" "$tmp/repo/scripts/pick-model.sh"
  ln -s "$REPO/experiments/score-t4.sh" "$tmp/repo/experiments/score-t4.sh"
  ln -s "$REPO/experiments/score-t5.sh" "$tmp/repo/experiments/score-t5.sh"
  ln -s "$REPO/experiments/score-t6.sh" "$tmp/repo/experiments/score-t6.sh"
  # T7/T8 are present in the tree; symlink them so the script's optional
  # scorer path is exercised. Real fixtures are absent from our mock raw
  # output so the score helpers will exit non-zero (no reps found), and
  # the script treats them as SKIPPED via the empty-mean guard.
  [[ -x "$REPO/experiments/score-t7.sh" ]] && ln -s "$REPO/experiments/score-t7.sh" "$tmp/repo/experiments/score-t7.sh"
  [[ -x "$REPO/experiments/score-t8.sh" ]] && ln -s "$REPO/experiments/score-t8.sh" "$tmp/repo/experiments/score-t8.sh"
}

# Re-point the run-baseline mock at the sandbox raw dir.
patch_baseline_mock_path() {
  local mock="$1" raw_dir="$2"
  # The make_baseline_mock writes raw to $REPO/experiments/results/raw —
  # replace that with the sandbox raw_dir so the script's lookups stay
  # inside the sandbox.
  perl -i -pe "s|$REPO/experiments/results/raw|$raw_dir|g" "$mock"
}

echo "=== model-change-audit.sh ==="

# 1. Missing required arg -> exit 3 + usage on stderr.
EC=0
out=$(env -i PATH="$SAFE_PATH" HOME="$(mktemp -d)" bash "$SCRIPT" 2>&1) || EC=$?
assert_eq 3 "$EC" "no args -> exit 3"
assert_contains "usage:" "$out" "no args -> usage on stderr"

# 2. Unknown tier arg -> exit 3 with informative stderr.
tmp=$(mktemp -d)
make_ollama_mock "$tmp" "qwen3-coder:30b-a3b-q8_0" "TEMPLATE \"\"\"{{ .Prompt }}\"\"\""
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" bash "$SCRIPT" qwen3-coder:30b-a3b-q8_0 bogus-tier 2>&1) || EC=$?
assert_eq 3 "$EC" "unknown tier -> exit 3"
assert_contains "unknown tier:" "$out" "unknown tier -> informative stderr"
rm -rf "$tmp"

# 3. Model not installed -> exit 3 with named stderr.
tmp=$(mktemp -d)
make_ollama_mock "$tmp" "other-model:1b" "TEMPLATE \"\"\"{{ .Prompt }}\"\"\""
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" bash "$SCRIPT" qwen3-coder:30b-a3b-q8_0 code 2>&1) || EC=$?
assert_eq 3 "$EC" "model not installed -> exit 3"
assert_contains "model not installed:" "$out" "model not installed -> named stderr"
rm -rf "$tmp"

# 4. ollama not on PATH -> exit 3.
tmp=$(mktemp -d)
EC=0
out=$(env -i PATH="$SAFE_PATH" HOME="$tmp" bash "$SCRIPT" qwen3-coder:30b-a3b-q8_0 code 2>&1) || EC=$?
assert_eq 3 "$EC" "ollama missing -> exit 3"
assert_contains "ollama not on PATH" "$out" "ollama missing -> stderr"
rm -rf "$tmp"

# 5. Tier inference from model name (qwen3-coder → code) works without
# explicit tier arg. Verified via the inference echo line; the rest of
# the pipeline is short-circuited by an unreachable mock (no eval
# script in sandbox) so we expect exit 3 with the inference printed
# before the failure. The inference itself is the assertion target.
tmp=$(mktemp -d)
make_ollama_mock "$tmp" "qwen3-coder:30b-a3b-q8_0" "TEMPLATE \"\"\"x\"\"\""
# Sandbox without scripts/eval-skill-triggers.sh — the script will fail
# gate 1 with a non-zero exit, but the inference line is emitted before
# that and shows up on stdout.
mkdir -p "$tmp/sandbox-repo/scripts"
cp "$SCRIPT" "$tmp/sandbox-repo/scripts/model-change-audit.sh"
ln -s "$REPO/scripts/pick-model.sh" "$tmp/sandbox-repo/scripts/pick-model.sh"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" bash "$tmp/sandbox-repo/scripts/model-change-audit.sh" qwen3-coder:30b-a3b-q8_0 2>&1) || EC=$?
assert_contains "inferred tier: code" "$out" "tier inference: qwen3-coder -> code"
rm -rf "$tmp"

# 6. End-to-end: all three gates pass -> ADOPT, exit 0.
tmp=$(mktemp -d)
make_ollama_mock "$tmp" "qwen3-coder:30b-a3b-q8_0" 'TEMPLATE """{{ .Prompt }}"""'
stage_sandbox "$tmp"
make_eval_mock "$tmp/repo" "1.000" "1.000" 0
make_baseline_mock "$tmp/repo" perfect
patch_baseline_mock_path "$tmp/repo/experiments/run-baseline.sh" "$tmp/repo/experiments/results/raw"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" bash "$tmp/repo/scripts/model-change-audit.sh" qwen3-coder:30b-a3b-q8_0 code 2>&1) || EC=$?
assert_eq 0 "$EC" "all-pass: exit 0"
assert_contains "verdict: ADOPT" "$out" "all-pass: verdict ADOPT"
assert_contains "recall=1.000" "$out" "all-pass: trigger recall=1.000"
assert_contains "T4 mean:" "$out" "all-pass: T4 line printed"
assert_contains "T5 mean:" "$out" "all-pass: T5 line printed"
assert_contains "T6 mean:" "$out" "all-pass: T6 line printed"
assert_contains "chat template:" "$out" "all-pass: chat template line"
assert_contains "COMPATIBLE" "$out" "all-pass: template COMPATIBLE"
rm -rf "$tmp"

# 7. End-to-end: gate 1 marginal (recall 0.85) -> INVESTIGATE, exit 1.
tmp=$(mktemp -d)
make_ollama_mock "$tmp" "qwen3-coder:30b-a3b-q8_0" 'TEMPLATE """{{ .Prompt }}"""'
stage_sandbox "$tmp"
make_eval_mock "$tmp/repo" "0.850" "0.900" 1
make_baseline_mock "$tmp/repo" perfect
patch_baseline_mock_path "$tmp/repo/experiments/run-baseline.sh" "$tmp/repo/experiments/results/raw"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" bash "$tmp/repo/scripts/model-change-audit.sh" qwen3-coder:30b-a3b-q8_0 code 2>&1) || EC=$?
assert_eq 1 "$EC" "gate1 marginal: exit 1"
assert_contains "verdict: INVESTIGATE" "$out" "gate1 marginal: verdict INVESTIGATE"
assert_contains "MARGINAL" "$out" "gate1 marginal: status surfaced"
rm -rf "$tmp"

# 8. End-to-end: gate 1 fails materially (recall 0.5) -> REJECT, exit 2.
tmp=$(mktemp -d)
make_ollama_mock "$tmp" "qwen3-coder:30b-a3b-q8_0" 'TEMPLATE """{{ .Prompt }}"""'
stage_sandbox "$tmp"
make_eval_mock "$tmp/repo" "0.500" "0.500" 1
make_baseline_mock "$tmp/repo" perfect
patch_baseline_mock_path "$tmp/repo/experiments/run-baseline.sh" "$tmp/repo/experiments/results/raw"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" bash "$tmp/repo/scripts/model-change-audit.sh" qwen3-coder:30b-a3b-q8_0 code 2>&1) || EC=$?
assert_eq 2 "$EC" "gate1 fail: exit 2"
assert_contains "verdict: REJECT" "$out" "gate1 fail: verdict REJECT"
rm -rf "$tmp"

# 9. End-to-end: gate 2 T4 catastrophic -> REJECT, exit 2.
tmp=$(mktemp -d)
make_ollama_mock "$tmp" "qwen3-coder:30b-a3b-q8_0" 'TEMPLATE """{{ .Prompt }}"""'
stage_sandbox "$tmp"
make_eval_mock "$tmp/repo" "1.000" "1.000" 0
make_baseline_mock "$tmp/repo" reject
patch_baseline_mock_path "$tmp/repo/experiments/run-baseline.sh" "$tmp/repo/experiments/results/raw"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" bash "$tmp/repo/scripts/model-change-audit.sh" qwen3-coder:30b-a3b-q8_0 code 2>&1) || EC=$?
assert_eq 2 "$EC" "gate2 catastrophic T4: exit 2"
assert_contains "verdict: REJECT" "$out" "gate2 catastrophic: verdict REJECT"
assert_contains "T4 mean:         0.0000" "$out" "gate2 catastrophic: T4 mean=0"
rm -rf "$tmp"

# 10. End-to-end: gate 3 template diverges (tool_call surface) -> REJECT.
tmp=$(mktemp -d)
divergent_template='TEMPLATE """{{ .Prompt }} <|tool_call|>some surface"""'
make_ollama_mock "$tmp" "qwen3-coder:30b-a3b-q8_0" "$divergent_template"
stage_sandbox "$tmp"
make_eval_mock "$tmp/repo" "1.000" "1.000" 0
make_baseline_mock "$tmp/repo" perfect
patch_baseline_mock_path "$tmp/repo/experiments/run-baseline.sh" "$tmp/repo/experiments/results/raw"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" bash "$tmp/repo/scripts/model-change-audit.sh" qwen3-coder:30b-a3b-q8_0 code 2>&1) || EC=$?
assert_eq 2 "$EC" "gate3 diverges: exit 2"
assert_contains "verdict: REJECT" "$out" "gate3 diverges: verdict REJECT"
assert_contains "DIVERGES" "$out" "gate3 diverges: template DIVERGES status"
rm -rf "$tmp"

# 11. End-to-end: chat template has <think> blocks -> note mentions it
# but template stays COMPATIBLE (the wrapper's think:false handles it).
tmp=$(mktemp -d)
think_template='TEMPLATE """{{ .Prompt }}<think>{{ if .Reasoning }}{{ .Reasoning }}{{ end }}</think>"""'
make_ollama_mock "$tmp" "qwen3-coder:30b-a3b-q8_0" "$think_template"
stage_sandbox "$tmp"
make_eval_mock "$tmp/repo" "1.000" "1.000" 0
make_baseline_mock "$tmp/repo" perfect
patch_baseline_mock_path "$tmp/repo/experiments/run-baseline.sh" "$tmp/repo/experiments/results/raw"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" bash "$tmp/repo/scripts/model-change-audit.sh" qwen3-coder:30b-a3b-q8_0 code 2>&1) || EC=$?
assert_eq 0 "$EC" "think template: exit 0 (compatible)"
assert_contains "verdict: ADOPT" "$out" "think template: verdict ADOPT"
assert_contains "uses <think> blocks" "$out" "think template: note mentions <think>"
assert_contains "COMPATIBLE" "$out" "think template: status COMPATIBLE"
rm -rf "$tmp"

# 12. Incumbent comparison: when a previous tier-incumbent baseline is
# present at the expected slug path, scorer comparison runs against it
# rather than the 0.8 absolute floor. We stage a perfect-baseline file
# for the incumbent slug, then run with a candidate whose baseline is
# also perfect — the verdict should be ADOPT and the incumbent column
# in the output should NOT be blank.
tmp=$(mktemp -d)
make_ollama_mock "$tmp" "qwen3-coder-next:30b
qwen3-coder:30b-a3b-q8_0" 'TEMPLATE """{{ .Prompt }}"""'
stage_sandbox "$tmp"
make_eval_mock "$tmp/repo" "1.000" "1.000" 0
make_baseline_mock "$tmp/repo" perfect
patch_baseline_mock_path "$tmp/repo/experiments/run-baseline.sh" "$tmp/repo/experiments/results/raw"
# Pre-create the incumbent's raw baseline file with perfect output.
# qwen3-coder-next:30b is the code-tier winner via pick-model.sh prefs,
# so it gets resolved as the incumbent. Slug: qwen3-coder-next_30b.
incumbent_slug="qwen3-coder-next_30b"
incumbent_raw="$tmp/repo/experiments/results/raw/$incumbent_slug.txt"
mkdir -p "$(dirname "$incumbent_raw")"
cat > "$incumbent_raw" <<'RAW'
MODEL: qwen3-coder-next:30b
BACKEND: ollama
DATE: 2026-05-01T00:00:00Z
REPS: 3
T3_SNAPSHOT: 2026-04-28
T4_SNAPSHOT: 2026-05-21
T5_SNAPSHOT: 2026-05-11
T6_SNAPSHOT: 2026-05-11

===== T4-commit-message rep 1 =====
DURATION_SEC: 2
RUN_STATUS: 0
OUTPUT:
feat: prompts/foo — short subject

A flush-left body paragraph. No bullets. No padding tail.

===== T5-json-shape rep 1 =====
DURATION_SEC: 2
RUN_STATUS: 0
OUTPUT:
{"owner": "ismael", "items": [{"task": "A", "due": "2026-04-22"}, {"task": "B", "due": "2026-04-30"}, {"task": "C", "due": "2026-05-08"}]}

===== T6-regex-generation rep 1 =====
DURATION_SEC: 2
RUN_STATUS: 0
OUTPUT:
^[A-Z]{2}-[0-9]+$

RAW
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" bash "$tmp/repo/scripts/model-change-audit.sh" qwen3-coder:30b-a3b-q8_0 code 2>&1) || EC=$?
assert_eq 0 "$EC" "incumbent present: exit 0"
assert_contains "incumbent: qwen3-coder-next:30b" "$out" "incumbent present: name surfaced"
# Incumbent column populated with a real number, not the blank-spaces placeholder
assert_contains "incumbent=1.0000" "$out" "incumbent present: T4/T5/T6 incumbent values shown"
rm -rf "$tmp"

# 13. No-tier-no-inference path: model name that does not match any prefs
# substring. Script proceeds to gate 1 but with no incumbent and no tier
# inference; the printed verdict has tier "(none — no incumbent comparison)".
tmp=$(mktemp -d)
make_ollama_mock "$tmp" "myorg-custom:7b" 'TEMPLATE """{{ .Prompt }}"""'
stage_sandbox "$tmp"
make_eval_mock "$tmp/repo" "1.000" "1.000" 0
make_baseline_mock "$tmp/repo" perfect
patch_baseline_mock_path "$tmp/repo/experiments/run-baseline.sh" "$tmp/repo/experiments/results/raw"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" bash "$tmp/repo/scripts/model-change-audit.sh" myorg-custom:7b 2>&1) || EC=$?
assert_eq 0 "$EC" "no inference path: still ADOPT when gates pass"
assert_contains "could not infer tier" "$out" "no inference: explanatory message"
assert_contains "(none" "$out" "no inference: tier shown as none placeholder"
rm -rf "$tmp"

# 14. audit-models.sh integration line — the pointer is appended.
audit_out=$(grep "model-change-audit.sh" "$REPO/scripts/audit-models.sh" || true)
assert_contains "bash scripts/model-change-audit.sh" "$audit_out" "audit-models.sh contains model-change-audit.sh pointer"

# 15. Script is executable.
if [[ -x "$REPO/scripts/model-change-audit.sh" ]]; then
  echo "  PASS  script is executable"; pass=$((pass+1))
else
  echo "  FAIL  script not executable"; fail=$((fail+1))
fi

# 16. Bash syntax check passes.
if bash -n "$REPO/scripts/model-change-audit.sh" 2>/dev/null; then
  echo "  PASS  bash syntax check"; pass=$((pass+1))
else
  echo "  FAIL  bash syntax check"; fail=$((fail+1))
fi

echo
echo "=== Results ==="
total=$((pass+fail))
echo "$pass/$total passed"
[[ "$fail" -eq 0 ]]
