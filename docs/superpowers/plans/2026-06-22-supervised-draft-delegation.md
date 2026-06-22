# Supervised Draft Delegation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Claude use the local `code` tier as a divergent, executable draft generator under a verify loop, recorded and measured, without making the skill the handler for coding tasks.

**Architecture:** Five ordered goals from `docs/superpowers/specs/2026-06-22-supervised-draft-delegation-design.md`. G1 lands the measurement (`scaffold` verdict) first so every later code draft is gradeable. G2 adds the `code-draft` recipe. G3 lands the body doctrine in SKILL.md (frontmatter untouched). G4 records the ADR. G5 sets up the evidence gate and seeds its first data points via this session's own dogfood.

**Tech Stack:** Bash 3.2, `jq`, `awk`, `perl`. No build step. Tests are bash assertion scripts run via `bash tests/<name>.sh`. Frontmatter/content validators gate every PR.

## Global Constraints

- Frontmatter `description` in `SKILL.md` MUST be byte-identical to `main` — the trigger-eval CI gate depends on it. Verify with `git diff main -- SKILL.md` showing no frontmatter change.
- Backward compatibility is mandatory: legacy hit/miss feedback rows and existing metrics output stay byte-identical when no `scaffold` row is present (mirror the existing `agent=` gating).
- No associative arrays (bash 4 only); no `grep -P` (GNU only); prefer `perl -CSD` for unicode. The "two bash scripts at the core" rule holds — no new runtime deps.
- Dogfood `delegate.sh` for prose where a recipe exists (commit messages via `--recipe commit-message`), record a verdict after each via `delegate-feedback.sh --source agent hit|miss|scaffold`.
- TDD: failing test → run-fail → implement → run-pass → commit. Frequent commits, one per goal.
- No autonomous merge. After the PR opens, run `/address-pr-comments` and stop.

---

### Task G1: `scaffold` verdict in the calibration loop

**Files:**
- Modify: `scripts/delegate-feedback.sh` (verdict parse, row builder, OTel verdict string, stdout word, MISS-nudge gating + matcher skip)
- Modify: `scripts/metrics-summary.sh` (verdict-string maps, gated `scaffold=` column across the calibration / per-tier / per-recipe / per-project sections + Agent-observed line)
- Test: `tests/test-delegate-feedback.sh`, `tests/test-metrics-summary.sh`

**Interfaces:**
- Produces: a feedback JSONL row shape `{source:"feedback", ref_ts, kept:false, scaffold:true, ...}` for the scaffold verdict. `kept:false` keeps any naive `kept`-only reader treating scaffold as "not used verbatim" (never inflating hit-rate); `scaffold:true` is the new discriminator.
- Produces (metrics): a jq verdict helper `def fbv: if (.scaffold // false) then "scaffold" elif .kept then "hit" else "miss" end;` and ref_ts→verdict-string maps. `scaffold=N` column appears only when `n_scaffold > 0`.

- [ ] **Step 1 (delegate-feedback.sh):** add `scaffold` to the verdict case → `kept=false; verdict=scaffold`; add `verdict=hit`/`verdict=miss` to the existing arms; thread a `--argjson scaffold` true/false into both row-builder jq calls appending `{scaffold:true}` only when set; set `verdict_word`/`verdict_lower` to HIT/MISS/SCAFFOLD; gate the MISS-recurrence nudge on `verdict == "miss"` (not `kept == false`); add `next if $j->{scaffold};` to the Perl matcher so historical scaffold rows aren't counted as similar misses; extend `usage()` to list `hit|miss|scaffold`.
- [ ] **Step 2 (tests):** add assertions to `tests/test-delegate-feedback.sh`: `scaffold "note"` exits 0, appends one row with `"scaffold":true` and `"kept":false`, stdout says `SCAFFOLD recorded`; `--source agent scaffold` also writes `verdict_source:"agent"`; a scaffold does NOT fire the MISS nudge even with prior similar misses; row is valid JSON.
- [ ] **Step 3:** run `bash tests/test-delegate-feedback.sh` — new assertions FAIL first (before Step 1) then PASS; existing assertions stay green.
- [ ] **Step 4 (metrics-summary.sh):** add `n_scaffold` (count feedback rows with `.scaffold==true`); compute `show_scaffold`; replace the boolean maps with `fbv`-derived verdict-string maps in all three jq programs (main, per-project, per-recipe); translate every `select(.h==true)`→`=="hit"`, `select(.h==false)`→`=="miss"`, `select(.a==true)`→`=="hit"`, `select(.a==false)`→`=="miss"`; append a gated `scaffold=` column after `misses=` in the headline, per-tier, per-recipe, per-project rows and a `scaffold=` count on the Agent-observed line, all `(if $show_scaffold then ... else "" end)`.
- [ ] **Step 5 (tests):** add a `test-metrics-summary.sh` fixture with hit+miss+scaffold feedback rows; assert the calibration headline shows `hits=… misses=… scaffold=…`, that scaffold is NOT counted in `hits` or `misses`, and that coverage counts the scaffold-covered delegation. Add a negative-gate assertion: a fixture with no scaffold rows must NOT print `scaffold=`.
- [ ] **Step 6:** run `bash tests/test-metrics-summary.sh` and `bash tests/test-delegate-feedback.sh` — all green; spot-run the whole suite touchpoints.
- [ ] **Step 7:** commit (dogfood `--recipe commit-message`, record `--source agent` verdict).

### Task G2: `code-draft` recipe

**Files:**
- Create: `prompts/code-draft.md`
- Modify: `prompts/README.md` (Current recipes list)
- Test: `tests/test-prompts-library.sh` (no edit needed — structural validator runs over the new file)

**Interfaces:**
- Produces: a recipe with frontmatter `inputs: { goal: string, scope: string, constraints: string?, verification: string }` (NO `stdin` declared — `{{stdin}}` stays the implicit optional pipe slot, collapsed to empty by `delegate.sh` when nothing is piped). Routes to `code` tier. Emits a focused full snippet (not a unified diff). Required sections: When to use, Context to gather first, Prompt template, Variables, Invocation, Anti-hallucination guards, Expected output shape, Calibration notes. Title line `# code-draft`.

- [ ] **Step 1:** write `prompts/code-draft.md` — identity-and-scope opener (Convention 1), the four-part brief (`{{goal}}`/`{{scope}}`/`{{constraints}}`/`{{verification}}`) plus `{{stdin}}` for surrounding source, full-snippet-not-diff directive, output-only / no-prose / no-invented-API guards. Document each `{{placeholder}}` (except stdin) in `## Variables`.
- [ ] **Step 2:** add the `code-draft.md (universal)` entry to `prompts/README.md` Current recipes.
- [ ] **Step 3:** run `bash tests/test-prompts-library.sh` — green (title matches, four required sections, every placeholder documented, README lists it, inputs block flat key:type).
- [ ] **Step 4 (live smoke + G5 seed):** run a real bounded `delegate.sh --recipe code-draft code` against a genuinely forked/executable task; confirm a focused snippet comes back; record the verdict via `delegate-feedback.sh --source agent hit|miss|scaffold "<note>"`. Note the result in the PR.
- [ ] **Step 5:** commit (dogfood commit-message recipe, record verdict).

### Task G3: SKILL.md body doctrine (frontmatter untouched)

**Files:**
- Modify: `SKILL.md` (body only, after the frontmatter `---` on line 4)

- [ ] **Step 1:** add a tight subsection under "## When to delegate" (after the density-threshold paragraph) titled around "### Supervised code drafts — a divergent, executable second opinion" carrying: the amended discriminator (weak *unsupervised* agent → supervised draft generator under a verify loop), the value trigger (forked approach OR execution-teaches-more), the bounded guard (single file/function, small output, named verification), disposable-draft / verify-before-keep, the `--recipe code-draft` pointer, the scaffold-verdict pointer, and the explicit "this is NOT delegate-all-coding" caveat.
- [ ] **Step 2:** verify `git diff main -- SKILL.md` shows zero changes inside the frontmatter block (lines 1–4).
- [ ] **Step 3:** run `bash scripts/validate-frontmatter.sh SKILL.md` and `bash scripts/validate-skill-content.sh SKILL.md` — both pass.
- [ ] **Step 4:** commit (dogfood commit-message recipe, record verdict).

### Task G4: ADR 0025

**Files:**
- Create: `docs/adr/0025-supervised-draft-delegation.md`

- [ ] **Step 1:** write the ADR in the house format (`# 25. <title>`, `Date:`, `## Status`, `## Context`, `## Decision`, `## Consequences`) recording the discriminator amendment, the experiment frame, the success/kill criteria, and a reference to the design spec.
- [ ] **Step 2:** commit (dogfood commit-message recipe, record verdict).

### Task G5: evidence-gate setup + first data points

- [ ] **Step 1:** confirm the gate is now measurable — `metrics-summary.sh` shows the `scaffold` column once a scaffold verdict exists; the success (`hit+scaffold` ≥ ~60% over ≥ ~10 code-draft delegations + net-positive honest review) and kill (revert G2+G3, keep G1) criteria are recorded in ADR 0025.
- [ ] **Step 2:** ensure the session's own `code-draft` dogfood verdict(s) are recorded, seeding the first evidence-gate data points; note remaining count toward the ~10 window in the PR body.

### Verification (workflow)

- [ ] Run the full suite: `bash tests/run-tests.sh` plus every `tests/test-*.sh` touched, the three validators, and `scripts/eval-skill-triggers.sh` shape mode.
- [ ] Run an adversarial verification workflow: one verifier per goal checks its spec "Done when" against the actual diff; a completeness critic checks for missed spec requirements. Fix anything flagged, re-run.

## Self-Review

- Spec coverage: G1→G5 each map to a task above with concrete file edits and acceptance checks. ✓
- No placeholders: every step names the exact files, the exact jq/bash change, and the exact test command. ✓
- Type consistency: the `fbv` verdict helper and the ref_ts→verdict-string map shape are named once and reused across all three metrics-summary jq programs; the feedback row shape (`kept:false, scaffold:true`) is fixed in G1 Step 1 and asserted in G1 Step 2. ✓
