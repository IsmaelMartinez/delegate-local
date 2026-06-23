# Commit-Message Body-Drop Regression — Diagnosis, Fix, and Testing Pathway (v2, post-review)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Outcome (the one goal):** The commit-message recipe stops emitting subject-only messages on thin diffs, proven by a reproducible benchmark that exercises the real code path, scores with the *exact* production `body_required` check, separates infra errors from genuine body-drops, and survives in the repo as an opt-in gate.

**Architecture:** A single small bench script (`tests/bench-commit-message-body.sh`) drives `delegate.sh --recipe auto` with a **real unified diff piped on stdin** — the same path any fix must touch — across a set of diverse thin-diff fixtures, and reports `body_drops` / `errors` per (resolved-model). The bench is the diagnostic that *chooses* the fix and the gate that proves it. The fix is decided by the baseline, cheapest-and-leakless lever first.

**Tech Stack:** bash 3.2+, `jq`, `awk`, `perl`, `git`, `curl`; existing `scripts/delegate.sh`, `scripts/pick-model.sh`, `scripts/delegate-feedback.sh`.

## Root cause (data-backed)

The delegate-local hit-rate drop stems from a commit-message regression with a two-part cause. First, the MLX Qwen3.6-35B model exhibits a defect where thin git diffs yield subject-only outputs, missing the required body text; this failure mode emerged in mid-June and differs from earlier participial-padding issues. Second, PR #310 (16 June) introduced a mandatory-body directive and the `body_required` check, and PR #316 (18 June) began persisting these results, making the previously silent defect visible in metrics. The MLX backend default is ruled out as the primary cause, as quality generally improved after its adoption (74%→79%) and the 87% peak was on MLX. Reverting to Ollama lacks data support — commit-message is 73% on MLX versus 70% on Ollama — though it is unconfirmed and tested in G1. Compounding the issue, the regression harness was archived out of main in commit 22395b2 (19 June), removing the tool needed to measure and validate a fix.

Evidence: `checks_run` is absent on commit-message rows until 18 June, then 31 rows / 11 fails as the weekly rate hits 62%; body-drop misses ("subject-only, no body") are all on `[mlx]` from ~13 June; the recipe's only body material is a `diff_stat` summary + `recent_commits` + `why` — it never sees the actual change (`prompts/commit-message.md`, `delegate.sh:540-569`). Verified: `body_required` fails on `< 2` non-empty lines (`delegate.sh:1373`); the auto-derivation is gated on `[[ "$recipe" == "auto" ]]` with stdin (`delegate.sh:~540`).

## Global Constraints

- Portable bash 3.2+: no associative arrays, no `grep -P` (use `perl -CSD`). macOS is first-class.
- Never hardcode model names — resolve via `scripts/pick-model.sh <tier>`; select a backend with `DELEGATE_BACKEND=mlx|ollama`.
- **Lean-core (19 Jun reset):** keep the bench to one script + one `has_body` function (no parallel scorer, no `results/` accretion); fold the baseline into the PR description / the single ADR — do **not** create a standing `docs/research/` tree that rebuilds the archived harness.
- **Privacy:** today's `auto` path reduces the diff to a `--stat` (a privacy floor — a stat line can't leak `KEY=secret`). Any change that surfaces raw diff content must redact secret-shaped lines, cap size, be opt-out, and never persist to a durable/off-host surface (the OTel content field when `DELEGATE_OTEL_INCLUDE_CONTENT=1`, and shell history). The JSONL stores only `prompt_chars` (a count), not content.
- Bench runs set `DELEGATE_LOCAL_NO_METRICS=1` (so they never pollute the production hit-rate) and are deliberately verdict-less.
- Greedy `temperature:0` is the default and stays. Per ADR 0018, MLX is deterministic per (prompt, temperature) and ignores seed — **repeats add no signal; diversity comes from fixtures, not reps.**
- Do not merge or push autonomously; open one PR and stop for review.

---

## Sub-goals (ordered, each behind one gate)

- **G0 — Build the bench correctly.** Real-diff fixtures piped on stdin via `--recipe auto`; ≥6 diverse thin fixtures + a rich control; scorer identical to production `body_required`; exit-status captured so infra errors are a separate outcome. Gate: `bash -n` passes and a one-fixture smoke prints `model=… drops=…/1 errors=…`.
- **G1 — Baseline, reproduce, diagnose, A/B.** Run the bench; record the resolved model per backend; confirm the defect reproduces as **genuine body-drops (errors=0)**, not infra noise. Gate: a recorded baseline showing thin-diff `drops>0, errors=0` on the MLX model and the Ollama model's rate measured. **DECISION POINT for the user:** which lever the evidence points to, and whether commit-message-only routing is wanted (no global default flip).
- **G2 — Fix, cheapest-leakless lever first.** Gate: the bench goes from red to `drops=0` on all thin fixtures + the rich control, `errors=0`.
- **G3 — Re-validate.** Gate (binding DoD): bench `drops=0, errors=0` across all fixtures. Production hit-rate recovery is a **post-merge observation, not a merge gate.**
- **G4 — Make durable, lean.** Opt-in bench target + a mocked wiring-smoke that never contacts a model; one lean ADR. Gate: `bash tests/run-tests.sh` still passes and stays offline-hermetic.

---

## Task G0.1: Diverse real-diff fixtures (diversity is the statistical power)

**Files:** Create under `tests/fixtures/commit-message/`: `recent_commits.txt`; and for each fixture `<name>.diff` (a real unified diff) + `<name>.why`. Fixtures (≥6 thin + 1 rich):
`thin-rename`, `thin-2file`, `thin-4file`, `thin-config-only`, `thin-test-only`, `thin-docs-only`, `thin-deletion`, and `rich-multifile` (control).

**Interfaces:** Produces `<name>.diff` files containing genuine `diff --git`/`@@`/`+`/`-` hunks (so the auto path has real content to derive from), a paired `<name>.why`, and a shared `recent_commits.txt`. Fixtures are **synthetic and secret-free** (this is also the privacy-test corpus).

- [ ] **Step 1:** Create `recent_commits.txt` (3 real-shaped `<sha> <type>: <subject>` lines).
- [ ] **Step 2:** Create each `thin-*.diff` as a small but **real** unified diff (1–4 files, few hunks) with a paired `.why` stating intent. Include shape variety: a pure rename, a config-only change, a test-only change, a docs-only change, and a pure deletion — these are the real thin-diff surface that starves the body.
- [ ] **Step 3:** Create `rich-multifile.diff` (a multi-hunk substantive change) + `.why` — the control where a body is unambiguously warranted.
- [ ] **Step 4:** Add one fixture line that *looks* secret-bearing for the redaction test (G2.2): e.g. a `+AWS_SECRET_ACCESS_KEY=AKIA...` line inside `thin-config-only.diff`. This fixture must remain secret-shaped-but-fake.
- [ ] **Step 5:** Commit: `git commit -m "test: add diverse real-diff commit-message fixtures (thin shapes + rich control)"`

## Task G0.2: The benchmark harness (real path, real scorer, error-aware)

**Files:** Create `tests/bench-commit-message-body.sh`.

**Interfaces:** Consumes G0.1 fixtures. Produces stdout `<backend>\t<model>\t<fixture>\tresult=BODY|DROP|ERROR` per run and a summary `<backend> drops=D/F errors=E`; exits non-zero under `BENCH_GATE=1` only when a **thin or control** fixture yields `DROP` (an `ERROR` makes the run inconclusive, printed loudly, and also fails the gate so a poisoned run can't pass green). `score_body()` is byte-identical to production `body_required`.

- [ ] **Step 1: Write the bench (note: pipes the REAL diff on stdin via `--recipe auto` — the path any fix touches)**
```bash
#!/usr/bin/env bash
# Commit-message body-drop regression benchmark. Drives delegate.sh --recipe auto
# with a REAL diff on stdin (the production path) and scores with the exact
# body_required logic. Reps add no signal under MLX greedy determinism (ADR 0018);
# diversity comes from fixtures. Usage:
#   [BENCH_BACKENDS="mlx ollama"] [BENCH_GATE=1] bash tests/bench-commit-message-body.sh
set -uo pipefail
SKILL_DIR="${SKILL_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
DELEGATE="$SKILL_DIR/scripts/delegate.sh"; PICK="$SKILL_DIR/scripts/pick-model.sh"
FIX_DIR="$SKILL_DIR/tests/fixtures/commit-message"
BACKENDS="${BENCH_BACKENDS:-mlx ollama}"; RC="$(cat "$FIX_DIR/recent_commits.txt")"
fail=0

# Exact mirror of delegate.sh body_required (>=2 non-empty lines, CR-stripped).
score_body() { printf '%s\n' "$1" | tr -d '\r' | awk 'NF{n++} END{exit (n>=2)?0:1}'; }

for backend in $BACKENDS; do
  model="$(DELEGATE_BACKEND="$backend" bash "$PICK" prose 2>/dev/null || echo '?')"
  # Warm the model once so a cold-load canary doesn't poison the first score.
  printf 'warmup' | DELEGATE_BACKEND="$backend" DELEGATE_LOCAL_NO_METRICS=1 \
    DELEGATE_PREFLIGHT_TIMEOUT="${DELEGATE_PREFLIGHT_TIMEOUT:-90}" \
    bash "$DELEGATE" prose "ok" >/dev/null 2>&1 || true
  drops=0; errors=0; total=0
  for d in "$FIX_DIR"/*.diff; do
    base="$(basename "$d" .diff)"; why="$(cat "${d%.diff}.why")"; total=$((total+1))
    out="$(DELEGATE_BACKEND="$backend" DELEGATE_LOCAL_NO_METRICS=1 \
           DELEGATE_PREFLIGHT_TIMEOUT="${DELEGATE_PREFLIGHT_TIMEOUT:-90}" \
           bash "$DELEGATE" --recipe auto --var why="$why" --var recent_commits="$RC" \
             prose "Write the commit message." < "$d" 2>/dev/null)"; rc=$?
    if (( rc != 0 )) || [[ -z "$out" ]]; then
      res=ERROR; errors=$((errors+1))
    elif score_body "$out"; then res=BODY
    else res=DROP; drops=$((drops+1)); fi
    printf '%s\t%s\t%s\tresult=%s\n' "$backend" "$model" "$base" "$res"
    [[ "${BENCH_GATE:-0}" == 1 && "$res" != BODY ]] && fail=1
  done
  printf '# %s (%s): drops=%d errors=%d total=%d\n' "$backend" "$model" "$drops" "$errors" "$total"
done
exit "$fail"
```
- [ ] **Step 2:** `chmod +x tests/bench-commit-message-body.sh && bash -n tests/bench-commit-message-body.sh` → no output.
- [ ] **Step 3: Smoke one backend** (no gate): `BENCH_BACKENDS=mlx bash tests/bench-commit-message-body.sh` → per-fixture lines + a `# mlx (<model>): drops=… errors=… total=…` summary; exit 0. If every line is `ERROR`, the auto-path `--var` keys drifted — re-check `prompts/commit-message.md` `inputs:`.
- [ ] **Step 4:** Commit: `git commit -m "test: add error-aware commit-message body-drop benchmark"`

## Task G1.1: Baseline, reproduce the defect, A/B by model, decide the lever

**Files:** none yet — capture output for the PR description (no `docs/research/` tree, per lean-core).

- [ ] **Step 1:** Record resolved models: `for b in mlx ollama; do echo "$b -> $(DELEGATE_BACKEND=$b bash scripts/pick-model.sh prose)"; done`. This makes the A/B a **model** comparison (DELEGATE_BACKEND changes runtime AND model), per ADR 0018's finding that body-class failures are model-bound.
- [ ] **Step 2:** Baseline both: `BENCH_BACKENDS="mlx ollama" bash tests/bench-commit-message-body.sh | tee /tmp/bodydrop-baseline.txt`.
- [ ] **Step 3: Validity gate** — the baseline is only usable if `errors=0`. If `errors>0`, raise `DELEGATE_PREFLIGHT_TIMEOUT`, re-warm, and re-run until errors clear; an error-poisoned baseline does not count as "reproduced."
- [ ] **Step 4: Diagnose the lever.** With a clean baseline, decide the cheapest fix the evidence supports, in this order:
  - If reinforcing the *existing* mandatory-body directive or fixing the `recent_commits` squash-anchor starvation plausibly addresses it → try G2.1 (no new diff content, no leak, lean).
  - Only if the model still drops bodies with adequate `recent_commits` + a sharpened directive → escalate to G2.2 (redacted diff excerpt).
  - If the MLX model drops but the Ollama model does not → G2.3 routing is on the table (user decision required).
- [ ] **Step 5: USER DECISION POINT.** Report the baseline table + resolved models, and ask the user: (a) confirm the lever, (b) if routing looks indicated, confirm commit-message-only routing (never a global default flip).

## Task G2.1: Primary fix attempt — leakless directive/anchor reinforcement

**Files:** Modify `prompts/commit-message.md` (sharpen the existing mandatory-body directive and/or the `recent_commits` usage); Test: `tests/bench-commit-message-body.sh`.

**Interfaces:** No new inputs, no diff content surfaced — stays within the lean/privacy floor. The guard tightening must cite the dated body-drop MISS cluster (2026-06-12/13) per the recipe-calibration contract (CLAUDE.md: every guard ties to a real MISS).

- [ ] **Step 1 (red):** `BENCH_BACKENDS=mlx BENCH_GATE=1 bash tests/bench-commit-message-body.sh; echo exit=$?` → `exit=1`.
- [ ] **Step 2:** Sharpen the recipe: strengthen the existing "A body is MANDATORY; never return a subject-only message" directive with a contrastive one-shot (Wrong: subject-only / Correct: subject+body), and ensure `recent_commits` gives the model body material on thin diffs. Tie the change to the 06-12/13 MISS cluster in the recipe's calibration notes.
- [ ] **Step 3 (green?):** re-run Step 1's command. If `exit=0` on all thin fixtures + control, the leakless fix is sufficient — skip G2.2. If still red, proceed to G2.2.
- [ ] **Step 4:** Commit: `git commit -m "fix: sharpen commit-message mandatory-body directive (#NN, 06-12/13 MISS cluster)"`

## Task G2.2 (only if G2.1 insufficient): Redacted, capped, opt-out diff excerpt

**Files:** Modify `prompts/commit-message.md` (`inputs: diff_excerpt: string?` + a scoped template block) and `scripts/delegate.sh` (the auto block, ~540-569, where `diff_stat` is derived at 552-558 — add the excerpt **in the same block the bench exercises**); Test: `tests/test-delegate.sh`.

**Interfaces:** Produces an optional `diff_excerpt` backfilled in the auto block from the piped diff, **after** a redaction + cap pass; gated by `DELEGATE_COMMIT_DIFF_EXCERPT` (default off — opt-in) so the privacy floor is preserved unless the operator opts in. Never added to the OTel content field.

- [ ] **Step 1 (red):** confirm the gate is still red after G2.1.
- [ ] **Step 2 (privacy test first, TDD):** add a `tests/test-delegate.sh` case piping a diff containing a `+AWS_SECRET_ACCESS_KEY=AKIA…` line with `DELEGATE_COMMIT_DIFF_EXCERPT=1 --recipe auto`, asserting the sniffed payload contains the excerpt section but **NOT** the secret-shaped line. Run → fails (no redaction yet).
- [ ] **Step 3:** Implement in the auto block: when `DELEGATE_COMMIT_DIFF_EXCERPT=1` and `diff_excerpt` not supplied, derive it from the piped diff — cap at ~120 lines / ~2 KB, drop lines matching the content-scanner's CRED_EXFIL/`KEY=VALUE`/high-entropy shapes, then `recipe_vars+=("diff_excerpt=…")`. Do not pass it to `emit_otel_span`'s content args.
- [ ] **Step 4:** Add the template block (rendered only when present): `Truncated excerpt of the leading hunks (NOT the whole diff) — use it to write the WHY. Do not quote or enumerate code. Do not assume it is complete: {{diff_excerpt}}`. Keep the mandatory-body directive.
- [ ] **Step 5:** Run `bash tests/test-delegate.sh` → the redaction test and substitution test PASS.
- [ ] **Step 6 (green):** `BENCH_BACKENDS=mlx BENCH_GATE=1 DELEGATE_COMMIT_DIFF_EXCERPT=1 bash tests/bench-commit-message-body.sh; echo exit=$?` → `exit=0`. (The bench sets the opt-in for the gated run.)
- [ ] **Step 7:** Commit: `git commit -m "fix: opt-in redacted diff excerpt for commit-message body on thin diffs (#NN)"`

## Task G2.3 (contingent on G1 A/B + USER approval): commit-message-only routing

- [ ] **Step 1:** Only if G1 showed the Ollama model is body-safe AND the user approved commit-message-only routing. Otherwise mark skipped.
- [ ] **Step 2:** Confirm the candidate is body-safe: `BENCH_BACKENDS=ollama BENCH_GATE=1 bash tests/bench-commit-message-body.sh` → exit 0.
- [ ] **Step 3:** Apply routing in `scripts/pick-model.sh` (never SKILL.md). If the **prose tier order** changes, re-run the Phase 7 baseline (CLAUDE.md: the qwen3.6-ahead-of-qwen3-next ordering test encodes that baseline — do not just flip the assertion) and update `tests/run-tests.sh`.
- [ ] **Step 4:** `bash tests/run-tests.sh` → PASS. Commit.

## Task G3.1: Re-validate (bench is the binding DoD; hit-rate is post-merge)

- [ ] **Step 1:** `BENCH_BACKENDS="mlx ollama" BENCH_GATE=1 bash tests/bench-commit-message-body.sh; echo exit=$?` → `exit=0`, `drops=0 errors=0` on every fixture incl. the rich control.
- [ ] **Step 2 (optional eyeball):** one live `git diff --cached | bash scripts/delegate.sh --recipe auto --var why="…" prose "…"` to sanity-read a real body; if you record a verdict use `--source agent`, and do **not** count a single cherry-picked HIT as "hit-rate recovered."
- [ ] **Step 3:** Note in the PR: production hit-rate recovery is tracked over ≥2 weeks of feedback rows post-merge via `metrics-summary.sh`, not gated here.

## Task G4.1: Durable + lean

**Files:** Modify `tests/run-tests.sh` (mocked wiring-smoke only); create `docs/adr/0026-commit-message-body-drop-and-bench.md`.

- [ ] **Step 1:** In `tests/run-tests.sh`, add a **mocked** smoke that never contacts a model: assert `bash -n tests/bench-commit-message-body.sh`, that the fixtures exist, and unit-test `score_body` (feed `"a\nb"`→pass, `"only-subject"`→fail) so the offline-hermetic contract is preserved.
- [ ] **Step 2:** Document the **opt-in live** run (`BENCH_GATE=1 … bench`) in the ADR / README as the pre-merge gate for commit-message changes — run by a human/CI with a model, not by `run-tests.sh`.
- [ ] **Step 3:** `bash tests/run-tests.sh` → PASS (offline).
- [ ] **Step 4:** Write one lean ADR 0026: the regression, the two-part cause, the bench as the standing gate, and the lesson — the regression harness must not be archived out of core. Fold the baseline/after tables into the PR description, not a new `docs/research/` tree.
- [ ] **Step 5:** Commit and open ONE PR. **Stop for review — no autonomous merge.**

---

## Self-review (post external review)

- **Reachability:** the bench now drives `--recipe auto` with a real diff on stdin — the exact path G2.2's excerpt backfill lives in — so the gate can actually transition. (Fixed blocker.)
- **Scorer parity:** `score_body` is byte-identical to `delegate.sh:1373` (`tr -d '\r' | awk 'NF{n++} END{exit (n>=2)?0:1}'`). (Fixed major.)
- **Determinism:** signal comes from ≥6 diverse fixtures, not reps (ADR 0018). (Fixed blocker.)
- **Infra vs defect:** non-zero exit / empty output is `ERROR`, surfaced separately and failing the gate as inconclusive — never silently counted as a body-drop. (Fixed blocker.)
- **Privacy:** diff content is opt-in, redacted, capped, kept off the OTel content field. (Fixed blocker.) Fixtures are synthetic and double as the redaction test.
- **Lever order:** G1 baseline gates the choice; the leakless directive fix (G2.1) is tried before the heavier excerpt (G2.2). (Fixed strategic finding.)
- **A/B honesty:** framed as a model comparison with resolved models recorded. (Fixed major.)
- **DoD:** bench gate is binding; production hit-rate is a post-merge observation. (Fixed major.)
- **Hermeticity:** the live bench stays out of `tests/run-tests.sh`; only a mocked smoke is wired in. (Fixed major.)
- **Lean-core:** one script, one scorer, one ADR, baseline in the PR — no rebuilt research tree. (Fixed major.)

## Decision the user must make (surfaced from G1)

The Ollama question is an A/B over **models** (DELEGATE_BACKEND changes the model too), not a runtime default flip — the data does not support a global revert. If G1 shows the Ollama-resolved model is body-safe and MLX is not, the contingent fix routes **commit-message only** (G2.3); confirm you want that rather than a global default change.
