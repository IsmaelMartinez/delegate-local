# Code-generation fan-out Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make local fan-out finally pay on code patches by drawing N diverse candidate patches from a warm code model and keeping the smallest one that passes a director-provided failing test, escalating to a strong model only when all cheap samples fail and never returning an unverified patch.

**Architecture:** A new `scripts/fanout-patch.sh` orchestrator composes two existing trustworthy pieces — `scripts/delegate.sh` (patch generation via the new `prompts/fix-with-test.md` recipe, made diverse by a new `DELEGATE_SEED` passthrough at temperature > 0) and `scripts/apply-and-test.sh` (the test oracle that applies each patch to a throwaway copy and runs pytest). The orchestrator owns only the fan-out decision logic: generate, score by the oracle, select the smallest passing diff, escalate-then-hand-back on failure. A measurement harness under `experiments/` answers whether best-of-N beats single-shot on a fixture suite with genuine single-shot headroom.

**Tech Stack:** bash (3.2+, macOS-shipped), `jq`, `awk`, `perl`, `python3`/`pytest` (oracle only), `curl` (Ollama/MLX HTTP). No build step, no package manager.

## Global Constraints

- bash 3.2 compatible: NO associative arrays (`declare -A`), NO `grep -P` (use `perl -CSD`), NO `date +%s.%N` reliance for sub-second math.
- All JSON built and parsed with `jq`; all HTTP via `curl`.
- New scripts resolve sibling scripts via `$(dirname "${BASH_SOURCE[0]}")`, with an env-var override for testability (the `DELEGATE_QUALITY_DELEGATE_SH` / `APPLY_AND_TEST_PYTHON` convention).
- Fan-out defaults to the Ollama backend — the per-request seed only works on Ollama until upstream mlx-lm #1331 ships (our issue #323).
- Single-file patches only for v1. The oracle runs pytest with full user privileges and no sandbox, so `fanout-patch.sh` is strictly for the director's own author-controlled source/tests and locally-chosen models — refused at the boundary, the same rule `apply-and-test.sh` already states.
- Every new test file is registered as a named step in `.github/workflows/ci.yml`.
- Commit messages drafted via `bash scripts/delegate.sh --recipe auto` where possible; commit trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File Structure

**Create:**
- `prompts/fix-with-test.md` — the patch-generation recipe (source + failing test → SEARCH/REPLACE patch or `REFUSE:`).
- `scripts/fanout-patch.sh` — the fan-out orchestrator.
- `tests/test-fanout-patch.sh` — unit tests for the orchestrator (mocks `delegate.sh` + `apply-and-test.sh`).
- `experiments/fanout-patch-eval.sh` — measurement harness (single-shot vs best-of-N pass-rate over a fixture suite).
- `experiments/fixtures/fanout/<case>/{source.py,test_source.py,reference.patch}` — the buggy-source + failing-test fixture suite (5 cases).
- `tests/test-fanout-fixtures.sh` — fixture-integrity test (each fixture's test fails on the buggy source and passes after `reference.patch`); CI-able, no model needed.
- `docs/adr/0022-code-gen-fanout.md` — the design + measurement record.

**Modify:**
- `scripts/delegate.sh` — add the `DELEGATE_SEED` passthrough to both backend payloads.
- `tests/test-delegate.sh` — assert the seed reaches the payload and is omitted when unset.
- `prompts/README.md` — add `fix-with-test.md` to "Current recipes".
- `SKILL.md` — add a one-line pointer to the orchestrator under the existing "minimal single-file code patches" Fits bullet (body only — NOT the frontmatter `description`, which is trigger-eval-gated).
- `.github/workflows/ci.yml` — register `test-fanout-patch.sh` and `test-fanout-fixtures.sh`.
- `CLAUDE.md` — one architecture paragraph for `fanout-patch.sh`.
- `ROADMAP.md` — a "shipped" entry.

---

## Task 1: `DELEGATE_SEED` passthrough in `delegate.sh`

**Goal:** A per-request integer seed reaches the wire payload on both backends, so N samples at temperature > 0 are genuinely diverse on Ollama. **Done when:** `tests/test-delegate.sh` asserts `"seed":7` appears in the Ollama `options` payload when `DELEGATE_SEED=7` and is absent on a bare greedy call, and the full suite passes.

**Files:**
- Modify: `scripts/delegate.sh` (sampling vars ~1010-1017, validation ~1033-1052, Ollama payload ~1181-1187, MLX payload ~1213-1219)
- Test: `tests/test-delegate.sh`

**Interfaces:**
- Consumes: nothing new.
- Produces: env var `DELEGATE_SEED=<integer>` → Ollama `options.seed` and MLX top-level `seed`. Omitted entirely when unset (no metrics-row change — seed is a diversity knob, not a quality signal).

- [ ] **Step 1: Write the failing test** — append to `tests/test-delegate.sh` after the existing bare-greedy payload block (near line 195):

```bash
# Seed passthrough: DELEGATE_SEED reaches Ollama options.seed; absent when unset.
tmp=$(mktemp -d); sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" DELEGATE_SEED=7 \
  bash "$SCRIPT" prose "hello" </dev/null 2>/dev/null)
payload=$(cat "$sniff")
assert_contains '"seed":7' "$payload" "SEED: DELEGATE_SEED reaches options.seed"
rm -rf "$tmp"

tmp=$(mktemp -d); sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  bash "$SCRIPT" prose "hello" </dev/null 2>/dev/null)
payload=$(cat "$sniff")
case "$payload" in
  *'"seed"'*) echo "  FAIL  SEED: bare greedy must NOT carry seed"; fail=$((fail+1));;
  *) echo "  PASS  SEED: bare greedy omits seed"; pass=$((pass+1));;
esac
rm -rf "$tmp"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-delegate.sh 2>&1 | grep -A0 "SEED:"`
Expected: `FAIL  SEED: DELEGATE_SEED reaches options.seed` (the seed is not yet in the payload).

- [ ] **Step 3: Implement — declare the seed vars.** In `scripts/delegate.sh`, after line 1017 (`metric_sampling_presence_penalty=""`), add:

```bash
sampling_seed=""
```

- [ ] **Step 4: Implement — validate the seed.** After the `DELEGATE_PRESENCE_PENALTY` block (ends ~line 1052), add:

```bash
if [[ -n "${DELEGATE_SEED:-}" ]]; then
  if ! [[ "$DELEGATE_SEED" =~ ^-?[0-9]+$ ]]; then
    echo "delegate: DELEGATE_SEED='$DELEGATE_SEED' is not an integer" >&2
    exit 2
  fi
  sampling_seed="$DELEGATE_SEED"
fi
```

- [ ] **Step 5: Implement — Ollama payload.** In `dispatch_to_model`, extend the Ollama `jq` call. Add `--arg seed "$sampling_seed"` to the arg list (after the `--arg pp` line ~1183) and add the seed overlay inside the `options` object (after the presence_penalty line ~1187):

```bash
  payload=$(jq -nc --arg m "$_model" --arg p "$full_input" --argjson th "$think" \
    --argjson temp "$sampling_temperature" \
    --arg top_p "$sampling_top_p" --arg top_k "$sampling_top_k" --arg pp "$sampling_presence_penalty" \
    --arg seed "$sampling_seed" \
    '{model:$m, prompt:$p, stream:false, think:$th, options:({temperature:$temp}
      + (if $top_p != "" then {top_p:($top_p|tonumber)} else {} end)
      + (if $top_k != "" then {top_k:($top_k|tonumber)} else {} end)
      + (if $pp != "" then {presence_penalty:($pp|tonumber)} else {} end)
      + (if $seed != "" then {seed:($seed|tonumber)} else {} end))}')
```

- [ ] **Step 6: Implement — MLX payload.** Extend the MLX `jq` call (~1213-1219): add `--arg seed "$sampling_seed"` and a top-level overlay:

```bash
  payload=$(jq -nc --arg m "$_model" --arg p "$full_input" --argjson mt "$max_tokens" --argjson et "$think" \
    --argjson temp "$sampling_temperature" \
    --arg top_p "$sampling_top_p" --arg top_k "$sampling_top_k" --arg pp "$sampling_presence_penalty" \
    --arg seed "$sampling_seed" \
    '{model:$m, messages:[{role:"user", content:$p}], stream:false, temperature:$temp, max_tokens:$mt, chat_template_kwargs:{enable_thinking:$et}}
      + (if $top_p != "" then {top_p:($top_p|tonumber)} else {} end)
      + (if $top_k != "" then {top_k:($top_k|tonumber)} else {} end)
      + (if $pp != "" then {presence_penalty:($pp|tonumber)} else {} end)
      + (if $seed != "" then {seed:($seed|tonumber)} else {} end)')
```

- [ ] **Step 7: Document the env var.** In the `delegate.sh` header env-var doc block (near the `DELEGATE_TEMPERATURE` entry ~line 234), add:

```bash
#   DELEGATE_SEED=<integer>                 # per-request sampler seed. With
#                                           #   temperature>0 this makes repeat
#                                           #   calls diverge deterministically
#                                           #   (Ollama options.seed / MLX seed).
#                                           #   Ollama-only until mlx-lm #1331
#                                           #   ships per-request seeds (#323).
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `bash tests/test-delegate.sh`
Expected: the two new `SEED:` assertions PASS; the existing count grows by 2 with zero new failures.

- [ ] **Step 9: Commit**

```bash
git add scripts/delegate.sh tests/test-delegate.sh
git commit -m "feat: DELEGATE_SEED passthrough for diverse fan-out sampling

Adds a per-request integer seed to both backend payloads (Ollama
options.seed, MLX top-level seed). Omitted when unset so bare greedy
calls keep their existing shape. The seed is what makes N samples at
temperature>0 genuinely diverse, which the code-gen fan-out orchestrator
relies on. Ollama-only until mlx-lm #1331 ships per-request seeds.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `fix-with-test` recipe

**Goal:** A calibrated recipe that turns a source file plus a failing pytest into a minimal SEARCH/REPLACE patch (or an honest `REFUSE:` when the test is self-contradictory), in exactly the format `apply-and-test.sh` parses. **Done when:** `tests/test-prompts-library.sh` passes with the new recipe present, listed in `prompts/README.md`, and pointed at from `SKILL.md`.

**Files:**
- Create: `prompts/fix-with-test.md`
- Modify: `prompts/README.md` (Current recipes list), `SKILL.md` (Fits bullet pointer)
- Test: `tests/test-prompts-library.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: recipe name `fix-with-test` with declared inputs `source: string`, `test: string`, `why: string?`. Invoked by Task 3 as `delegate.sh --recipe fix-with-test --var source=… --var test=… --var why=… code "…"`.

- [ ] **Step 1: Write the failing test** — confirm the library test fails before the recipe exists.

Run: `bash tests/test-prompts-library.sh 2>&1 | tail -5`
Expected: PASS currently (no `fix-with-test` referenced yet). After Step 3 adds the SKILL.md/README pointers but before the file exists, it FAILS. So do Step 2 first, then pointers.

- [ ] **Step 2: Create the recipe** — `prompts/fix-with-test.md`:

````markdown
---
inputs:
  source: string
  test: string
  why: string?
---
# fix-with-test

## When to use

The director has a single source file plus a pytest that currently fails, and wants a minimal patch that makes the test pass. The failing test is the oracle: the patch is verified by re-running it, never trusted on the model's say-so. Scope is one file. Multi-file edits, cross-module reasoning, and tests the director cannot re-run are out of scope — those stay with the director.

## Context to gather first

```bash
cat path/to/source.py        # the file to patch
cat path/to/test_source.py   # the failing test (the oracle)
python3 -m pytest -q path/to/test_source.py   # confirm it fails first
```

The failing test is load-bearing — without a test the director can re-run, this recipe does not apply.

## Prompt template

```
Produce a minimal patch to the source file below so the failing test passes. Change only what the test requires. Do not rewrite unrelated code, rename symbols, reformat, or add features the test does not exercise.

Output format — non-negotiable:
Emit one or more SEARCH/REPLACE blocks and NOTHING else. No prose, no explanation, no markdown code fence. Each block is exactly:
<<<<<<< SEARCH
<lines copied VERBATIM from the source, enough to match exactly once>
=======
<the replacement lines>
>>>>>>> REPLACE

The SEARCH text must be copied character-for-character from the source, including indentation, and must appear exactly once. If it would match more than once, include more surrounding lines so it is unique.

Example (illustrative — use the real source below, not this):
<<<<<<< SEARCH
def total(items):
    return sum(items)
=======
def total(items):
    return sum(items) if items else 0
>>>>>>> REPLACE

If the test is wrong, self-contradictory, or cannot be satisfied by editing this one file, do NOT invent a patch. Emit a single line instead:
REFUSE: <one sentence on why the test cannot be honestly satisfied>

=== Source file ===
{{source}}

=== Failing test ===
{{test}}

=== Why / intent (optional) ===
{{why}}
```

## Variables

- `{{source}}` — verbatim contents of the file to patch.
- `{{test}}` — verbatim contents of the failing pytest.
- `{{why}}` — OPTIONAL one-sentence intent. Omit to let the test speak for itself; `delegate.sh` collapses the empty placeholder.

## Invocation

```bash
bash scripts/delegate.sh --recipe fix-with-test \
  --var source="$(cat source.py)" \
  --var test="$(cat test_source.py)" \
  code "Output ONLY SEARCH/REPLACE blocks (or a single REFUSE: line). Minimal diff."
```

In practice the `fanout-patch.sh` orchestrator wires these for you across N seeds; this direct form is for one-off use.

## Expected output shape

One or more `<<<<<<< SEARCH … ======= … >>>>>>> REPLACE` blocks with no surrounding prose or fence, OR a single `REFUSE: …` line. Verify by piping the output to `apply-and-test.sh` and reading the `VERDICT:` — a patch is only HIT if the oracle returns `PASS`.

## Anti-hallucination guards (each line addresses a real failure mode)

- "Change only what the test requires … do not rewrite unrelated code" — small models over-edit, rewriting whole functions when a one-line fix suffices; the oracle's smallest-diff tie-break rewards the minimal patch.
- "No prose, no explanation, no markdown code fence" — a wrapping ```python fence or a "Here's the fix:" preamble corrupts the SEARCH block so `apply-and-test.sh` returns APPLY/PARSE instead of PASS.
- "copied character-for-character … must appear exactly once" — `apply-and-test.sh` does literal-substring matching and treats >1 match as APPLY (ambiguous); the guard pushes the model to include unique context.
- "REFUSE: …" hatch — when the test is wrong, a fabricated patch wastes an escalation; the oracle and orchestrator treat a majority REFUSE as a signal the test may be broken.

## Calibration notes

New recipe (2026-06-19), shipped with the code-gen fan-out initiative. Unlike the prose recipes it has a hard oracle (the test), so its calibration loop is the `experiments/fanout-patch-eval.sh` pass-rate measurement rather than hit/miss verdicts. The output is code, not prose, so no `checks:` block (the padding/subject guards do not apply). Future guards land here as `fanout-patch-eval.sh` surfaces recurring patch-format failures.
````

- [ ] **Step 3: Add the README entry** — in `prompts/README.md`, under "Current recipes", add:

```markdown
- `fix-with-test.md` (universal) — turn a single source file plus a failing pytest into a minimal SEARCH/REPLACE patch (or an honest `REFUSE:` line). The only recipe with a hard oracle: the patch is verified by re-running the test via `apply-and-test.sh`, not trusted on the model's say-so. Drives `scripts/fanout-patch.sh`'s fan-out loop.
```

- [ ] **Step 4: Add the SKILL.md pointer** — in `SKILL.md`, on the existing Fits bullet "Minimal single-file code patches where you supply the failing test…", append one sentence (do NOT touch the frontmatter `description`):

```
  When you have several seeds to spare, `scripts/fanout-patch.sh` fans this out with the `fix-with-test` recipe and keeps the smallest patch that passes the test.
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/test-prompts-library.sh && bash scripts/validate-skill-content.sh SKILL.md`
Expected: both PASS (recipe has all required sections, is listed in README, pointed at from SKILL.md; no dangerous content).

- [ ] **Step 6: Commit**

```bash
git add prompts/fix-with-test.md prompts/README.md SKILL.md
git commit -m "feat: fix-with-test recipe (source + failing test -> patch)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `fanout-patch.sh` orchestrator + tests + CI

**Goal:** The orchestrator that generates N diverse candidate patches, scores each with the oracle, selects the smallest passing diff, escalates to a strong model when all cheap samples fail, hands back "the test may be wrong" on a refuse-majority, and never returns an unverified patch. **Done when:** `tests/test-fanout-patch.sh` passes every branch (select-passer, smallest-diff tie-break, escalation-pass, refuse-majority, no-pass handback, oracle-over-prose) and CI runs it.

**Files:**
- Create: `scripts/fanout-patch.sh`, `tests/test-fanout-patch.sh`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `delegate.sh --recipe fix-with-test` (Task 2) with `DELEGATE_SEED` (Task 1); `apply-and-test.sh` (existing).
- Produces: CLI `fanout-patch.sh [--n N] [--escalate-m M] [--tier T] [--strong-tier T] [--temperature F] [--timeout S] [--test-script NAME] [--source-name NAME] [--why TEXT] [--out FILE] <source-dir>`. Env overrides `FANOUT_DELEGATE_SH`, `FANOUT_APPLY_AND_TEST_SH`, `FANOUT_BACKEND`. Output: a `FANOUT_RESULT:` line on stdout (`outcome=PASS_LOCAL|PASS_ESCALATED|REFUSE_MAJORITY|NO_PASS`, plus `n/passes/refuses/fails/selected/escalated/refuse_coexist/patch_file`), a `DETAIL:` line on non-PASS, the selected/closest patch written to `--out` (default temp). Exit codes: 0 PASS, 1 NO_PASS, 2 REFUSE_MAJORITY, 3 USAGE.

- [ ] **Step 1: Write the orchestrator** — `scripts/fanout-patch.sh`:

```bash
#!/usr/bin/env bash
# fanout-patch.sh — fan-out code-patch generation with a test oracle.
#
# Draw N diverse candidate patches from a warm code model (seeds at
# temperature>0 via DELEGATE_SEED), apply-and-test each against the
# director-provided failing test, and keep the smallest diff that passes. If
# every cheap sample fails, optionally escalate to a strong model; if a
# majority refuse, hand back "the test may be wrong"; never return an
# unverified patch — the worst case is "no patch", never "a broken patch that
# looks fine".
#
# Composes two trustworthy pieces and owns only the fan-out decision logic:
#   delegate.sh --recipe fix-with-test   generation (diversity via DELEGATE_SEED)
#   apply-and-test.sh                     the oracle (apply to a copy, run pytest)
#
# Usage: fanout-patch.sh [OPTIONS] <source-dir>
#   <source-dir>  dir with source.py + test_source.py (the failing test = oracle)
# Options: --n N (5) --escalate-m M (2; 0 disables) --tier T (code)
#   --strong-tier T (reasoning) --temperature F (0.7) --timeout S (30)
#   --test-script NAME (test_source.py) --source-name NAME (source.py)
#   --why TEXT  --out FILE
# Env: FANOUT_DELEGATE_SH FANOUT_APPLY_AND_TEST_SH (sibling defaults)
#      FANOUT_BACKEND (ollama — seed works there; MLX broken until #1331)
# Exit: 0 PASS  1 NO_PASS  2 REFUSE_MAJORITY  3 USAGE
#
# Security: apply-and-test.sh runs model-generated pytest with no sandbox.
# Strictly for the director's own author-controlled source/tests and
# locally-chosen models — never untrusted source, an externally-supplied
# test, or model output from a non-local source.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
delegate_sh="${FANOUT_DELEGATE_SH:-$repo_root/scripts/delegate.sh}"
apply_sh="${FANOUT_APPLY_AND_TEST_SH:-$repo_root/scripts/apply-and-test.sh}"
backend="${FANOUT_BACKEND:-ollama}"

n=5 escalate_m=2 tier="code" strong_tier="reasoning" temperature="0.7"
timeout_secs=30 test_script="test_source.py" source_name="source.py" why=""
source_dir="" out_file=""

usage() {
  cat >&2 <<'EOF'
usage: fanout-patch.sh [--n N] [--escalate-m M] [--tier T] [--strong-tier T]
       [--temperature F] [--timeout S] [--test-script NAME] [--source-name NAME]
       [--why TEXT] [--out FILE] <source-dir>
EOF
  exit 3
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --n) n="$2"; shift 2 ;;
    --escalate-m) escalate_m="$2"; shift 2 ;;
    --tier) tier="$2"; shift 2 ;;
    --strong-tier) strong_tier="$2"; shift 2 ;;
    --temperature) temperature="$2"; shift 2 ;;
    --timeout) timeout_secs="$2"; shift 2 ;;
    --test-script) test_script="$2"; shift 2 ;;
    --source-name) source_name="$2"; shift 2 ;;
    --why) why="$2"; shift 2 ;;
    --out) out_file="$2"; shift 2 ;;
    -h|--help) usage ;;
    --*) echo "unknown flag: $1" >&2; usage ;;
    *) if [[ -z "$source_dir" ]]; then source_dir="$1"; else echo "too many positional args" >&2; usage; fi; shift ;;
  esac
done

[[ -n "$source_dir" ]] || usage
[[ -d "$source_dir" ]] || { echo "source-dir not a directory: $source_dir" >&2; exit 3; }
[[ -f "$source_dir/$source_name" ]] || { echo "missing $source_name in $source_dir" >&2; exit 3; }
[[ -f "$source_dir/$test_script" ]] || { echo "missing $test_script in $source_dir" >&2; exit 3; }
[[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "--n must be a positive integer" >&2; exit 3; }
[[ "$escalate_m" =~ ^[0-9]+$ ]] || { echo "--escalate-m must be a non-negative integer" >&2; exit 3; }
[[ -f "$delegate_sh" ]] || { echo "delegate.sh not found: $delegate_sh" >&2; exit 3; }
[[ -f "$apply_sh" ]] || { echo "apply-and-test.sh not found: $apply_sh" >&2; exit 3; }

work="$(mktemp -d "${TMPDIR:-/tmp}/fanout-patch.XXXXXX")"
trap 'rm -rf "$work"' EXIT
[[ -n "$out_file" ]] || out_file="$work/selected.patch"

src_text="$(cat "$source_dir/$source_name")"
test_text="$(cat "$source_dir/$test_script")"

# Generate one candidate for (label, seed, tier); write the patch and run the
# oracle. Echoes the bare verdict word (PASS/FAIL/REFUSE/APPLY/PARSE/TIMEOUT).
generate_and_test() { # label seed gtier
  local label="$1" seed="$2" gtier="$3"
  local patch_file="$work/patch.$label" verdict_file="$work/verdict.$label"
  env DELEGATE_SEED="$seed" DELEGATE_TEMPERATURE="$temperature" DELEGATE_BACKEND="$backend" \
    "$delegate_sh" --recipe fix-with-test \
    --var source="$src_text" --var test="$test_text" --var why="$why" \
    "$gtier" "Output ONLY SEARCH/REPLACE blocks (or a single REFUSE: line). Minimal diff." \
    > "$patch_file" 2>/dev/null
  "$apply_sh" --test-script "$test_script" --source-name "$source_name" --timeout "$timeout_secs" \
    "$source_dir" "$patch_file" > "$verdict_file" 2>/dev/null
  local v; v="$(sed -n 's/^VERDICT: //p' "$verdict_file" | head -1)"
  printf '%s' "${v:-PARSE}"
}

# Rank a non-pass verdict by how close it got: FAIL applied+ran (closest),
# TIMEOUT applied but hung, APPLY did not apply, PARSE/other produced no block.
rank_of() { case "$1" in PASS) echo 5;; FAIL) echo 4;; TIMEOUT) echo 3;; APPLY) echo 2;; REFUSE) echo 1;; *) echo 0;; esac; }

passers=()            # "<size> <label>" per PASS candidate
refuse_count=0
fail_count=0
best_fail_rank=-1
best_fail_label=""

consider() { # label verdict
  local label="$1" v="$2"
  if [[ "$v" == "PASS" ]]; then
    local sz; sz=$(wc -c < "$work/patch.$label" | tr -d ' ')
    passers+=("$sz $label")
  elif [[ "$v" == "REFUSE" ]]; then
    refuse_count=$((refuse_count + 1))
  else
    fail_count=$((fail_count + 1))
    local r; r=$(rank_of "$v")
    if (( r > best_fail_rank )); then best_fail_rank=$r; best_fail_label="$label"; fi
  fi
}

echo "fanout-patch: source=$source_dir n=$n tier=$tier strong=$strong_tier temp=$temperature backend=$backend" >&2

for ((s=1; s<=n; s++)); do
  v=$(generate_and_test "s$s" "$s" "$tier")
  echo "  seed $s ($tier): $v" >&2
  consider "s$s" "$v"
done

majority=$(( (n + 1) / 2 ))

emit_result() { # outcome selected_label escalated patch_src detail
  local outcome="$1" sel="$2" esc="$3" patch_src="$4" detail="$5"
  local refuse_coexist=0 others=$(( n - ${#passers[@]} ))
  (( others > 0 && refuse_count * 2 > others )) && refuse_coexist=1
  if [[ -n "$patch_src" && -f "$patch_src" ]]; then cp "$patch_src" "$out_file"; else : > "$out_file"; fi
  printf 'FANOUT_RESULT: %s n=%d passes=%d refuses=%d fails=%d selected=%s escalated=%d refuse_coexist=%d patch_file=%s\n' \
    "$outcome" "$n" "${#passers[@]}" "$refuse_count" "$fail_count" "${sel:--}" "$esc" "$refuse_coexist" "$out_file"
  [[ -n "$detail" ]] && printf 'DETAIL: %s\n' "$detail"
}

# A passer exists → smallest diff wins.
if (( ${#passers[@]} > 0 )); then
  sel_label=$(printf '%s\n' "${passers[@]}" | sort -n | head -1 | awk '{print $2}')
  emit_result PASS_LOCAL "$sel_label" 0 "$work/patch.$sel_label" ""
  exit 0
fi

# No passer, and a majority refused → the test is probably wrong. Do not escalate.
if (( refuse_count >= majority )); then
  emit_result REFUSE_MAJORITY "" 0 "" "majority of samples refused — the failing test may be wrong or self-contradictory"
  exit 2
fi

# Escalate to a strong model.
escalated=0
if (( escalate_m > 0 )); then
  escalated=1
  for ((j=1; j<=escalate_m; j++)); do
    v=$(generate_and_test "E$j" "$((n + j))" "$strong_tier")
    echo "  escalate $j ($strong_tier): $v" >&2
    if [[ "$v" == "PASS" ]]; then
      emit_result PASS_ESCALATED "E$j" 1 "$work/patch.E$j" ""
      exit 0
    fi
    consider "E$j" "$v"
  done
fi

# Still nothing — hand back the closest failing attempt.
detail="no candidate passed the test"
patch_src=""
if [[ -n "$best_fail_label" ]]; then
  patch_src="$work/patch.$best_fail_label"
  detail="$detail; closest attempt: $(sed -n 's/^DETAIL: //p' "$work/verdict.$best_fail_label" | head -1)"
fi
emit_result NO_PASS "${best_fail_label:-}" "$escalated" "$patch_src" "$detail"
exit 1
```

- [ ] **Step 2: chmod** — `chmod +x scripts/fanout-patch.sh`

- [ ] **Step 3: Write the unit tests** — `tests/test-fanout-patch.sh`. The harness mocks `delegate.sh` and `apply-and-test.sh` via the `FANOUT_*_SH` overrides. The mock `delegate.sh` emits a patch whose first line is a verdict word chosen by `DELEGATE_SEED` from a seed→verdict map; the mock `apply-and-test.sh` echoes that word as the `VERDICT:` and exits with the matching code.

```bash
#!/usr/bin/env bash
# Unit tests for scripts/fanout-patch.sh. Mocks delegate.sh + apply-and-test.sh
# so the orchestrator's decision logic is exercised without a model or pytest.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/fanout-patch.sh"

pass=0; fail=0
assert_eq() { local e="$1" a="$2" n="$3"; if [[ "$e" == "$a" ]]; then echo "  PASS  $n"; pass=$((pass+1)); else echo "  FAIL  $n (expected '$e', got '$a')"; fail=$((fail+1)); fi; }
assert_contains() { local nd="$1" hs="$2" n="$3"; if [[ "$hs" == *"$nd"* ]]; then echo "  PASS  $n"; pass=$((pass+1)); else echo "  FAIL  $n (missing '$nd' in '$hs')"; fail=$((fail+1)); fi; }

# A throwaway source-dir (content irrelevant — the mock oracle ignores it, but
# fanout-patch validates the files exist).
make_src() { local d="$1"; printf 'def f():\n    return 0\n' > "$d/source.py"; printf 'from source import f\n\ndef test_f():\n    assert f() == 1\n' > "$d/test_source.py"; }

# Mock delegate.sh: writes a patch whose FIRST line is the verdict word that the
# seed maps to (via $SEEDMAP: "seed verdict" lines; default FAIL), then pads the
# body with '#' * seed so a larger seed = a larger patch (smallest-diff test).
make_mock_delegate() {
  local dir="$1"
  cat > "$dir/delegate.sh" <<'EOF'
#!/usr/bin/env bash
v="FAIL"
if [[ -n "${SEEDMAP:-}" && -f "$SEEDMAP" ]]; then
  m=$(awk -v s="${DELEGATE_SEED:-0}" '$1==s {print $2; exit}' "$SEEDMAP")
  [[ -n "$m" ]] && v="$m"
fi
echo "$v"
pad=""; i=0; while (( i < ${DELEGATE_SEED:-0} )); do pad="$pad#"; i=$((i+1)); done
echo "$pad"
EOF
  chmod +x "$dir/delegate.sh"
}

# Mock apply-and-test.sh: reads the patch (last positional arg), takes its first
# line as the verdict, prints VERDICT/DETAIL and exits with the mapped code.
make_mock_apply() {
  local dir="$1"
  cat > "$dir/apply-and-test.sh" <<'EOF'
#!/usr/bin/env bash
pf=""; for a in "$@"; do pf="$a"; done
v=$(head -1 "$pf" 2>/dev/null); v="${v:-PARSE}"
echo "VERDICT: $v"; echo "DETAIL: mock $v"
case "$v" in PASS) exit 0;; FAIL) exit 1;; PARSE) exit 2;; APPLY) exit 3;; TIMEOUT) exit 4;; REFUSE) exit 5;; *) exit 1;; esac
EOF
  chmod +x "$dir/apply-and-test.sh"
}

run() { # extra-env... -- args...   (returns stdout; sets EC)
  local -a envv=(); while [[ "$1" != "--" ]]; do envv+=("$1"); shift; done; shift
  EC=0
  out=$(env FANOUT_DELEGATE_SH="$BIN/delegate.sh" FANOUT_APPLY_AND_TEST_SH="$BIN/apply-and-test.sh" \
    "${envv[@]}" bash "$SCRIPT" "$@" 2>/dev/null) || EC=$?
}

BIN=$(mktemp -d); make_mock_delegate "$BIN"; make_mock_apply "$BIN"

# 1. Usage: no source-dir → exit 3.
EC=0; o=$(bash "$SCRIPT" 2>&1) || EC=$?; assert_eq 3 "$EC" "usage: no source-dir -> exit 3"

# 2. Select a passer: seeds 1..5 all FAIL except seed 3 PASS.
SRC=$(mktemp -d); make_src "$SRC"; MAP=$(mktemp); printf '3 PASS\n' > "$MAP"
run SEEDMAP="$MAP" -- --escalate-m 0 "$SRC"
assert_eq 0 "$EC" "passer: exit 0"
assert_contains "FANOUT_RESULT: PASS_LOCAL" "$out" "passer: PASS_LOCAL outcome"
assert_contains "selected=s3" "$out" "passer: selected seed 3"
rm -rf "$SRC"; rm -f "$MAP"

# 3. Smallest-diff tie-break: seeds 2 and 4 both PASS; seed 2 has the smaller pad.
SRC=$(mktemp -d); make_src "$SRC"; MAP=$(mktemp); printf '2 PASS\n4 PASS\n' > "$MAP"
run SEEDMAP="$MAP" -- --escalate-m 0 "$SRC"
assert_contains "selected=s2" "$out" "tie-break: smallest diff (seed 2) wins"
rm -rf "$SRC"; rm -f "$MAP"

# 4. Refuse-majority: 3 of 5 REFUSE, none pass → exit 2, no escalation.
SRC=$(mktemp -d); make_src "$SRC"; MAP=$(mktemp); printf '1 REFUSE\n2 REFUSE\n3 REFUSE\n' > "$MAP"
run SEEDMAP="$MAP" -- "$SRC"
assert_eq 2 "$EC" "refuse-majority: exit 2"
assert_contains "FANOUT_RESULT: REFUSE_MAJORITY" "$out" "refuse-majority: outcome"
rm -rf "$SRC"; rm -f "$MAP"

# 5. Escalation pass: all 5 cheap FAIL, strong (seed 6 = E1) PASSes → exit 0.
SRC=$(mktemp -d); make_src "$SRC"; MAP=$(mktemp); printf '6 PASS\n' > "$MAP"
run SEEDMAP="$MAP" -- --n 5 --escalate-m 2 "$SRC"
assert_eq 0 "$EC" "escalation: exit 0"
assert_contains "FANOUT_RESULT: PASS_ESCALATED" "$out" "escalation: PASS_ESCALATED outcome"
assert_contains "escalated=1" "$out" "escalation: escalated flag set"
rm -rf "$SRC"; rm -f "$MAP"

# 6. No-pass handback: everything FAILs even after escalation → exit 1, closest attempt.
SRC=$(mktemp -d); make_src "$SRC"; MAP=$(mktemp); : > "$MAP"   # empty map → all FAIL
run SEEDMAP="$MAP" -- --n 3 --escalate-m 1 "$SRC"
assert_eq 1 "$EC" "no-pass: exit 1"
assert_contains "FANOUT_RESULT: NO_PASS" "$out" "no-pass: outcome"
assert_contains "closest attempt" "$out" "no-pass: hands back closest attempt"
rm -rf "$SRC"; rm -f "$MAP"

# 7. Oracle over prose: a sample whose verdict is PASS counts even though its
#    body is irrelevant — the oracle word is authoritative. (seed 1 PASS.)
SRC=$(mktemp -d); make_src "$SRC"; MAP=$(mktemp); printf '1 PASS\n' > "$MAP"
run SEEDMAP="$MAP" -- --escalate-m 0 "$SRC"
assert_eq 0 "$EC" "oracle-authoritative: PASS verdict wins regardless of body"
rm -rf "$SRC"; rm -f "$MAP"

# 8. Escalation disabled (--escalate-m 0) + all FAIL -> NO_PASS exit 1, no escalation.
SRC=$(mktemp -d); make_src "$SRC"; MAP=$(mktemp); : > "$MAP"
run SEEDMAP="$MAP" -- --n 3 --escalate-m 0 "$SRC"
assert_eq 1 "$EC" "no-escalate: exit 1 when escalation disabled and all fail"
assert_contains "escalated=0" "$out" "no-escalate: escalated flag stays 0"
rm -rf "$SRC"; rm -f "$MAP"

# 9. Closest-attempt rank: a FAIL (s2) outranks APPLY (s1,s3) for the handback patch.
SRC=$(mktemp -d); make_src "$SRC"; MAP=$(mktemp); printf '1 APPLY\n2 FAIL\n3 APPLY\n' > "$MAP"
run SEEDMAP="$MAP" -- --n 3 --escalate-m 0 "$SRC"
assert_eq 1 "$EC" "rank: exit 1 (no pass)"
assert_contains "selected=s2" "$out" "rank: FAIL (s2) chosen as closest over APPLY"
rm -rf "$SRC"; rm -f "$MAP"

rm -rf "$BIN"
echo ""; echo "fanout-patch tests: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
```

- [ ] **Step 4: Run to verify it fails first, then passes.**

Run: `bash tests/test-fanout-patch.sh`
Expected after Steps 1-3: all assertions PASS, final line `fanout-patch tests: N passed, 0 failed`. (If you ran the test before writing the script, it errors on the missing `$SCRIPT` — that is the failing-first state.)

- [ ] **Step 5: Register in CI** — in `.github/workflows/ci.yml`, after the apply-and-test step (~line 102), add:

```yaml
      - name: Fanout-patch.sh tests
        run: bash tests/test-fanout-patch.sh
```

- [ ] **Step 6: Commit**

```bash
git add scripts/fanout-patch.sh tests/test-fanout-patch.sh .github/workflows/ci.yml
git commit -m "feat: fanout-patch.sh orchestrator with test-oracle selection

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Measurement harness + fixture suite + fixture-integrity test

**Goal:** A harness that reports single-shot vs best-of-N pass-rate over a fixture suite with genuine single-shot headroom, plus the fixtures themselves, plus a CI-able integrity test proving each fixture is well-formed. **Done when:** `tests/test-fanout-fixtures.sh` passes (every fixture's test fails on the buggy source and passes after `reference.patch`), and `experiments/fanout-patch-eval.sh --help` parses without a model.

**Files:**
- Create: `experiments/fanout-patch-eval.sh`, `experiments/fixtures/fanout/<case>/{source.py,test_source.py,reference.patch}` (5 cases), `tests/test-fanout-fixtures.sh`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `fanout-patch.sh` (Task 3), `apply-and-test.sh` (existing).
- Produces: `fanout-patch-eval.sh [--n N] [--reps R] [--tier T] [--temperature F] <fixtures-dir>` → per-fixture and aggregate `FANOUT_EVAL_SUMMARY: single_shot=… best_of_n=… lift=… escalation_rate=… handback_pct=…`. Runs with `DELEGATE_LOCAL_NO_METRICS=1` so measurement does not pollute the production metrics log.

- [ ] **Step 1: Author fixture 1 (off-by-one)** — `experiments/fixtures/fanout/01-off-by-one/`:

`source.py` (buggy — the `- 1` is the bug):
```python
def last_n(items, n):
    return items[len(items) - n - 1:]
```
`test_source.py`:
```python
from source import last_n

def test_basic():
    assert last_n([1, 2, 3, 4], 2) == [3, 4]

def test_n_zero():
    assert last_n([1, 2, 3], 0) == []
```
`reference.patch` (drop the `- 1`; `items[len-0:]` is already `[]` so no guard is needed):
```
<<<<<<< SEARCH
def last_n(items, n):
    return items[len(items) - n - 1:]
=======
def last_n(items, n):
    return items[len(items) - n:]
>>>>>>> REPLACE
```
Verify in Step 6 that the buggy source fails both tests and the patch fixes them.

- [ ] **Step 2: Author fixtures 2-5.** Each is a single buggy function plus a 2-3 assertion pytest plus a `reference.patch`. Keep them in the "model gets it right only sometimes" band — small logic bugs, not trivia:
  - `02-wrong-operator/` — `def is_even(x): return x % 2 == 1` → fix to `== 0`; tests assert `is_even(4)` and `not is_even(3)`.
  - `03-missing-edge/` — `def safe_div(a, b): return a / b` → guard `b == 0` returning `None`; tests assert `safe_div(6, 2) == 3` and `safe_div(1, 0) is None`.
  - `04-fencepost/` — `def rng(a, b): return list(range(a, b))` → inclusive `range(a, b + 1)`; tests assert `rng(1, 3) == [1, 2, 3]`.
  - `05-accumulator/` — `def running_max(xs):` returns a list of prefix maxima but resets each step; tests assert `running_max([3,1,4,1,5]) == [3,3,4,4,5]`.

  For each, write `source.py` (buggy), `test_source.py` (failing on the bug), `reference.patch` (the minimal fix in SEARCH/REPLACE form copied verbatim from the buggy source).

- [ ] **Step 3: Write the fixture-integrity test** — `tests/test-fanout-fixtures.sh`:

```bash
#!/usr/bin/env bash
# Integrity check for the fan-out fixture suite: every fixture's test must FAIL
# on the buggy source and PASS after reference.patch. No model needed — this is
# the CI guarantee that each fixture has real single-shot headroom and a known
# good fix, which is what the eval harness's "best-of-N" measurement relies on.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="$REPO/scripts/apply-and-test.sh"
FIX="$REPO/experiments/fixtures/fanout"
pass=0; fail=0
assert_eq() { local e="$1" a="$2" n="$3"; if [[ "$e" == "$a" ]]; then echo "  PASS  $n"; pass=$((pass+1)); else echo "  FAIL  $n (want $e got $a)"; fail=$((fail+1)); fi; }

for d in "$FIX"/*/; do
  name=$(basename "$d")
  # Buggy source fails its own test: a no-op patch (identity SEARCH/REPLACE)
  # leaves the bug in place, so apply-and-test must return FAIL (exit 1).
  noop=$(mktemp)
  firstline=$(head -1 "$d/source.py")
  printf '<<<<<<< SEARCH\n%s\n=======\n%s\n>>>>>>> REPLACE\n' "$firstline" "$firstline" > "$noop"
  # exit 1 = "the test did not pass" (an assertion failed OR the test errored on
  # import); the reference.patch -> exit 0 leg below rules out a never-passable
  # fixture, so the pair together proves real single-shot headroom.
  EC=0; bash "$APPLY" "$d" "$noop" >/dev/null 2>&1 || EC=$?
  assert_eq 1 "$EC" "$name: buggy source fails its test"
  # reference.patch makes it pass (exit 0).
  EC=0; bash "$APPLY" "$d" "$d/reference.patch" >/dev/null 2>&1 || EC=$?
  assert_eq 0 "$EC" "$name: reference.patch makes the test pass"
  rm -f "$noop"
done
echo ""; echo "fanout-fixtures: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
```

(Note: the no-op identity patch requires `source.py`'s first line to be unique in the file. The five fixtures above all have a unique `def …:` first line, so the identity SEARCH matches exactly once. If a future fixture's first line repeats, give the integrity test a dedicated `noop.patch` instead.)

- [ ] **Step 4: Write the eval harness** — `experiments/fanout-patch-eval.sh`:

```bash
#!/usr/bin/env bash
# fanout-patch-eval.sh — measure whether best-of-N code-patch fan-out beats
# single-shot on a fixture suite WITH genuine single-shot headroom.
#
# For each fixture dir (source.py + test_source.py): run R reps of single-shot
# (one delegate.sh+oracle call) and R reps of best-of-N (fanout-patch.sh), and
# report single-shot pass-rate vs best-of-N pass-rate, lift, latency per fix,
# the best-of-N pass-rate distribution across reps, escalation rate, and
# handback %. The load-bearing requirement (the lesson this initiative is built
# on): fixtures MUST have single-shot headroom — if the model nails every
# fixture single-shot, best-of-N cannot lift anything and the result is a false
# "no value", exactly the trap T5/T6 fell into. tests/test-fanout-fixtures.sh
# guarantees the headroom exists; this harness measures the lift.
#
# Runs with DELEGATE_LOCAL_NO_METRICS=1 so measurement does not pollute the
# production metrics/calibration log.
#
# Usage: fanout-patch-eval.sh [--n N] [--reps R] [--tier T] [--temperature F] <fixtures-dir>
set -uo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fanout="$repo_root/scripts/fanout-patch.sh"
delegate="$repo_root/scripts/delegate.sh"
apply="$repo_root/scripts/apply-and-test.sh"
export DELEGATE_LOCAL_NO_METRICS=1 DELEGATE_BACKEND="${DELEGATE_BACKEND:-ollama}"

n=5 reps=3 tier="code" temperature="0.7" fixtures=""
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --n) n="$2"; shift 2 ;;
    --reps) reps="$2"; shift 2 ;;
    --tier) tier="$2"; shift 2 ;;
    --temperature) temperature="$2"; shift 2 ;;
    -h|--help) echo "usage: fanout-patch-eval.sh [--n N] [--reps R] [--tier T] [--temperature F] <fixtures-dir>"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
fixtures="${1:-}"
[[ -n "$fixtures" && -d "$fixtures" ]] || { echo "usage: fanout-patch-eval.sh [opts] <fixtures-dir>" >&2; exit 2; }

# Gather fixtures once (each must carry source.py + test_source.py).
fxs=()
for d in "$fixtures"/*/; do [[ -f "$d/source.py" && -f "$d/test_source.py" ]] && fxs+=("$d"); done
nfx=${#fxs[@]}
(( nfx > 0 )) || { echo "no fixtures with source.py+test_source.py in $fixtures" >&2; exit 2; }

single_shot() { # fixture-dir seed -> 0 if PASS
  local d="$1" seed="$2" p; p=$(mktemp)
  env DELEGATE_SEED="$seed" DELEGATE_TEMPERATURE="$temperature" "$delegate" --recipe fix-with-test \
    --var source="$(cat "$d/source.py")" --var test="$(cat "$d/test_source.py")" \
    "$tier" "Output ONLY SEARCH/REPLACE blocks. Minimal diff." > "$p" 2>/dev/null
  local v; v=$(bash "$apply" "$d" "$p" 2>/dev/null | sed -n 's/^VERDICT: //p' | head -1)
  rm -f "$p"; [[ "$v" == "PASS" ]]
}

ss_pass=0 ss_total=0 bo_pass=0 bo_total=0 esc=0 handback=0 bo_lat_total=0
rep_min="" rep_max=""
# Per-fixture tallies (parallel indexed arrays — no associative arrays on bash 3.2).
i=0; fss=(); fbo=(); while (( i < nfx )); do fss[$i]=0; fbo[$i]=0; i=$((i+1)); done

# reps in the OUTER loop so each rep yields a best-of-N pass-count we can take the
# min/max of — "report the distribution rather than a single point". SECONDS
# (bash builtin, integer) times each best-of-N call without GNU `date +%s.%N`.
for ((r=1; r<=reps; r++)); do
  rep_bo=0; i=0
  for d in "${fxs[@]}"; do
    ss_total=$((ss_total+1))
    if single_shot "$d" "$r"; then ss_pass=$((ss_pass+1)); fss[$i]=$(( ${fss[$i]} + 1 )); fi
    bo_total=$((bo_total+1))
    t0=$SECONDS
    res=$(bash "$fanout" --n "$n" --tier "$tier" --temperature "$temperature" "$d" 2>/dev/null)
    bo_lat_total=$(( bo_lat_total + (SECONDS - t0) ))
    outcome=$(printf '%s' "$res" | sed -n 's/^FANOUT_RESULT: \([A-Z_]*\).*/\1/p' | head -1)
    case "$outcome" in
      PASS_LOCAL)     bo_pass=$((bo_pass+1)); rep_bo=$((rep_bo+1)); fbo[$i]=$(( ${fbo[$i]} + 1 ));;
      PASS_ESCALATED) bo_pass=$((bo_pass+1)); rep_bo=$((rep_bo+1)); esc=$((esc+1)); fbo[$i]=$(( ${fbo[$i]} + 1 ));;
      *) handback=$((handback+1));;
    esac
    i=$((i+1))
  done
  [[ -z "$rep_min" || "$rep_bo" -lt "$rep_min" ]] && rep_min="$rep_bo"
  [[ -z "$rep_max" || "$rep_bo" -gt "$rep_max" ]] && rep_max="$rep_bo"
  echo "rep $r: best-of-$n $rep_bo/$nfx fixtures passed" >&2
done

i=0
for d in "${fxs[@]}"; do
  echo "$(basename "$d"): single-shot ${fss[$i]}/$reps   best-of-$n ${fbo[$i]}/$reps"
  i=$((i+1))
done

rate() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f", (b>0)? a/b : 0}'; }
ss_rate=$(rate "$ss_pass" "$ss_total"); bo_rate=$(rate "$bo_pass" "$bo_total")
echo "----------------------------------------------------------------"
printf 'FANOUT_EVAL_SUMMARY: single_shot=%s best_of_n=%s lift=%s latency_per_fix_s=%s escalation_rate=%s handback_pct=%s rep_bo_min=%s rep_bo_max=%s reps=%d n=%d fixtures=%d\n' \
  "$ss_rate" "$bo_rate" \
  "$(awk -v s="$ss_rate" -v b="$bo_rate" 'BEGIN{printf "%.3f", b-s}')" \
  "$(awk -v t="$bo_lat_total" -v c="$bo_total" 'BEGIN{printf "%.1f", (c>0)? t/c : 0}')" \
  "$(rate "$esc" "$bo_total")" "$(rate "$handback" "$bo_total")" \
  "${rep_min:-0}" "${rep_max:-0}" "$reps" "$n" "$nfx"
```

- [ ] **Step 5: chmod** — `chmod +x experiments/fanout-patch-eval.sh tests/test-fanout-fixtures.sh`

- [ ] **Step 6: Run the integrity test** (needs pytest, no model):

Run: `bash tests/test-fanout-fixtures.sh`
Expected: every fixture reports `buggy source fails its test` and `reference.patch makes the test pass`; final `fanout-fixtures: N passed, 0 failed`. If a fixture's buggy source does NOT fail, the bug is too weak — sharpen it.

- [ ] **Step 7: Register the integrity test in CI** — in `.github/workflows/ci.yml`, after the fanout-patch step, add:

```yaml
      - name: Fanout fixture integrity
        run: bash tests/test-fanout-fixtures.sh
```

- [ ] **Step 8: Commit**

```bash
git add experiments/fanout-patch-eval.sh experiments/fixtures/fanout tests/test-fanout-fixtures.sh .github/workflows/ci.yml
git commit -m "feat: fan-out measurement harness + fixture suite + integrity test

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Documentation — ADR, CLAUDE.md, ROADMAP

**Goal:** The design, the safety boundary, and the architecture are recorded where the repo's conventions expect them. **Done when:** the ADR exists, `CLAUDE.md` has a `fanout-patch.sh` paragraph, `ROADMAP.md` has a shipped entry, and `validate-skill-content.sh` still passes.

**Files:**
- Create: `docs/adr/0022-code-gen-fanout.md`
- Modify: `CLAUDE.md`, `ROADMAP.md`

- [ ] **Step 1: Write the ADR** — `docs/adr/0022-code-gen-fanout.md`, following the existing ADR shape (read `docs/adr/0020-*.md` for the house format first). Sections: Status (Accepted), Context (fan-out was confounded by the MLX seed bug, now fixed; prose has no oracle, code does), Decision (the five spec decisions: director-provided test oracle, single-file v1, N-seeds-one-model diversity, escalate-then-handback, fanout-patch.sh + fix-with-test composing apply-and-test.sh + pick-model.sh (the latter transitively — delegate.sh resolves the tier per call, keeping the model warm across the N back-to-back calls) + DELEGATE_SEED), Measurement (leave a placeholder table to fill from Task 6's run — single-shot vs best-of-N pass-rate, lift, latency per fix, the best-of-N distribution across reps, and the go/no-go threshold 0.2-0.3 lift), Consequences (widens delegation to code; bounded cost N+M; Ollama-only until #1331; the no-sandbox safety boundary).

- [ ] **Step 2: Add the CLAUDE.md architecture paragraph** — in `CLAUDE.md`, after the `apply-and-test.sh` paragraph, add one paragraph describing `fanout-patch.sh`: it composes `delegate.sh --recipe fix-with-test` (diversity via `DELEGATE_SEED` at temp>0) and `apply-and-test.sh` (oracle); generates N cheap samples, selects the smallest passing diff, escalates M strong samples on all-fail, hands back on refuse-majority or no-pass; emits a `FANOUT_RESULT:` line with exit codes 0/1/2/3; Ollama-only until #1331; strictly for author-controlled source/tests (no sandbox). Mention `experiments/fanout-patch-eval.sh` as the measurement surface and `tests/test-fanout-fixtures.sh` as the headroom guarantee.

- [ ] **Step 3: Add the ROADMAP entry** — draft via the recipe, then paste. Gather a recent shipped entry as the shape anchor and the facts, then:

```bash
bash scripts/delegate.sh --recipe roadmap-entry \
  --var style_anchor="$(awk '/^### /{c++} c==1,c==2' ROADMAP.md | head -40)" \
  --var facts="Shipped code-generation fan-out: scripts/fanout-patch.sh draws N diverse fix-with-test patches (DELEGATE_SEED at temp>0), apply-and-test.sh selects the smallest passing diff, escalates to a strong tier on all-fail, hands back on refuse-majority. Measurement harness experiments/fanout-patch-eval.sh + 5-fixture headroom suite. Go/no-go is best-of-N lift over single-shot of 0.2-0.3." \
  prose "Match the recent entry's shape and tone."
```
Record the verdict with `bash scripts/delegate-feedback.sh hit|miss "<reason>"`. Paste the (verified, trimmed) entry under the appropriate phase heading in `ROADMAP.md`.

- [ ] **Step 4: Verify and commit**

Run: `bash scripts/validate-skill-content.sh SKILL.md`
Expected: PASS.

```bash
git add docs/adr/0022-code-gen-fanout.md CLAUDE.md ROADMAP.md
git commit -m "docs: ADR 0022 + architecture notes for code-gen fan-out

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Run the measurement and record the go/no-go

**Goal:** Produce the empirical answer the spec's success criterion asks for — does best-of-N clear single-shot by ~0.2-0.3? — and write it into the ADR. **Done when:** `fanout-patch-eval.sh` has run against a live Ollama model over the fixture suite, the numbers are in the ADR's Measurement section, and the go/no-go decision is stated.

**Files:**
- Modify: `docs/adr/0022-code-gen-fanout.md` (fill the Measurement table), `experiments/results/2026-06-19-fanout-patch.md` (raw output)

- [ ] **Step 1: Confirm the backend is reachable.**

Run: `curl -sS --max-time 5 http://localhost:11434/api/tags >/dev/null && echo OK || echo "no ollama"`
If "no ollama": start `ollama serve`, or record in the ADR that the measurement is pending a host with Ollama and stop here (the code is shipped and CI-green regardless; the go/no-go is the only deferred piece).

- [ ] **Step 2: Run the eval** (warm the model first so cold-load doesn't skew latency):

```bash
bash experiments/fanout-patch-eval.sh --n 5 --reps 3 experiments/fixtures/fanout \
  | tee experiments/results/2026-06-19-fanout-patch.md
```
Expected: per-fixture single-shot vs best-of-5 lines and one `FANOUT_EVAL_SUMMARY:` line.

- [ ] **Step 3: Record the result in the ADR.** Fill the Measurement table with `single_shot`, `best_of_n`, `lift`, `latency_per_fix_s`, `escalation_rate`, `handback_pct`, and the `rep_bo_min`/`rep_bo_max` distribution. State the decision: lift ≥ ~0.2 → "pays, earns the right to widen (multi-file, multi-model)"; lift < ~0.2 → "shelved with the evidence, like cheap-first". If single-shot is already ~1.0 (no headroom), say so and sharpen the fixtures rather than concluding "no value".

- [ ] **Step 4: Update the quality-investigation memory** with the one-line outcome (this is the experiment the user has been driving).

- [ ] **Step 5: Commit**

```bash
git add docs/adr/0022-code-gen-fanout.md experiments/results/2026-06-19-fanout-patch.md
git commit -m "docs: record code-gen fan-out measurement and go/no-go

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (run after the plan is written, before execution)

**Spec coverage:**
- DELEGATE_SEED passthrough → Task 1. ✓
- fix-with-test recipe → Task 2. ✓
- fanout-patch.sh orchestrator (generate N, oracle-select smallest passer, escalate-then-handback, refuse-majority, oracle-over-prose) → Task 3. ✓
- Unit tests mocking delegate.sh + apply-and-test.sh → Task 3. ✓
- Measurement harness with single-shot-headroom fixtures → Task 4. ✓
- Success criterion (measured lift, go/no-go) → Task 6. ✓
- Error handling / safety boundary (no-sandbox, author-controlled only) → Task 3 doc block + Task 5 ADR. ✓
- Ollama-default until #1331 → Task 1 doc, Task 3 default, Task 5 ADR. ✓

**Type/interface consistency:** `FANOUT_RESULT:` field names (`outcome/n/passes/refuses/fails/selected/escalated/refuse_coexist/patch_file`) are defined in Task 3's `emit_result` and read identically by Task 4's eval (`sed -n 's/^FANOUT_RESULT: \([A-Z_]*\).*/\1/p'`). Exit codes 0/1/2/3 consistent across Task 3 script, tests, and eval. `FANOUT_DELEGATE_SH`/`FANOUT_APPLY_AND_TEST_SH` defined in Task 3, used by Task 3 tests. Recipe name `fix-with-test` consistent across Tasks 2, 3, 4.

**Placeholder scan:** Task 5 Step 1 (ADR) and Task 6 Step 3 (Measurement table) are intentionally content-to-be-written-at-execution (the ADR prose and the live numbers), not code placeholders — every code step carries complete code. Task 4 Step 2 describes fixtures 2-5 by their exact bug and fix rather than spelling out every file verbatim; this is concrete enough to author without ambiguity (one buggy function, the named fix, a 2-3 assertion test), and the integrity test in Step 3 is the guard that each one is well-formed.
