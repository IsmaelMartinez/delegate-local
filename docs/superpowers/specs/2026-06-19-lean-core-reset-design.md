# Lean-core reset — design spec

Date: 2026-06-19
Status: Approved (pending maintainer review of this document)
Author: brainstormed with Claude Code

> Amendment (2026-06-19, during execution): the OTEL → Loki/Grafana
> observability pipeline listed under "Archive" below was **kept**, not
> archived, on maintainer direction — it is the live visibility into delegation
> traffic. `otel.sh` emission, the `sync-metrics-to-loki.sh` / `backfill-otel.sh`
> exporters, `dashboards/`, `observability/`, and `docs/observability/` all stay
> in the core. The embeddings/semantic-search path (`embed.sh`,
> `semantic-search.sh`, and the `semantic-search` recipe) was likewise restored
> — it was complete and genuinely used (122 embedding calls), not half-done.
> Three orphaned experiment learnings surfaced by a retrospective audit were
> written up as ADRs 0022–0024. Everything else in the archive boundary stands.

## Why this exists

delegate-local started as a deliberately tiny thing: route "gather context once,
send one prompt, return text" tasks to a local model via a shell pipe, with the
entire runtime surface being two bash scripts. Over roughly two months of
high-cadence iteration (peaking at 55 commits in a single week, sustained at
18–55/week) it accreted a great deal of machinery. The repo now carries 28
scripts, 27 recipes, 49 test files, 359 files under `experiments/`, 21 ADRs, a
Python MCP server, an OpenTelemetry/Loki/Grafana observability stack, an
embeddings/semantic-search path, and several recent prototype quality gates
(fan-out ensemble, verify-and-escalate, faithfulness grounding). The headline
documents have bloated in step: ROADMAP.md is 144KB (399 lines, of which the
first 258 are an unordered backlog before the phases even begin, and the phase
numbering jumps from 12 to 22), CLAUDE.md is 36KB, SKILL.md 40KB, README 25KB.

The maintainer's read is that quality has measurably dropped over the recent
iterations and that the cause is over-building rather than under-building. Two
findings during the planning investigation support that read directly, and they
reframe this work from "tidy the file tree" into "recover quality":

- `delegate.sh` is now a 91KB bash script. Beyond its legitimate job (resolve a
  tier, post to the backend, return clean text, log a metric) it has absorbed a
  preflight canary, deterministic output checks, an auto-strip pass, a
  verify-and-escalate gate, and a grounding check — most of the last several
  bolted on during the high-churn period.
- `commit-message.md`, the single most-used recipe (255 calls, ~53% of all
  recipe traffic in the metrics log), is a 62KB prompt template. A prompt that
  large almost certainly carries diluting or self-contradictory instructions,
  which is a plausible direct cause of the observed quality slip.

The lean-core reset and the quality recovery are therefore the same piece of
work. Shrinking the core wrapper and the top recipe back to something a model
can follow cleanly is the lever; archiving the research machinery is what makes
that shrink safe and the repo legible again.

## Goal

A new user can install delegate-local and make a working delegated call in under
five minutes, and every path that ships is exercised and verified. The runtime
is back to a small, legible core — tier routing, the wrapper, a tight recipe
set, the calibration feedback loop, and a verified install/onboarding path. The
research and observability machinery is archived out of the main branch but
fully recoverable from a tag and an archive branch. Quality is restored by
shrinking the over-stuffed core artifacts, not by adding more gates.

## Non-goals

- Not deleting history. Everything archived stays recoverable via the
  `pre-cleanup-2026-06-19` tag and the `archive/research-machinery` branch.
- Not rewriting the core routing logic. `pick-model.sh` tier routing stays as
  is. The `delegate.sh` trim removes accreted gates; it does not redesign
  backend selection, recipe substitution, or metrics logging.
- Not publishing anything new, changing the install command, or touching
  release-please's machinery. CHANGELOG.md is release-please-managed and is left
  untouched.
- Not chasing the archived features back into main. If a real consumer appears
  (e.g. someone actually wanting the MCP server, or observability), it is a
  fresh, evidence-gated decision, not a default.

## Decisions taken during brainstorming

1. North star: lean core, install-first. (Over "reorganise, keep all" and "keep
   proven, archive research".)
2. Archive method: cut a git tag and an `archive/research-machinery` branch,
   then delete the archived material from main entirely, because the skill is
   installed by copying the tree — anything left in main is downloaded by every
   user.
3. MCP server: archive it. It does not help the Claude Code skill at all (the
   skill shells out to the bash scripts directly; ADR 0004 and CLAUDE.md both
   state this), there is no evidence a non-Claude consumer ever materialised, it
   was never published, and its `recommend_prompt` tool has already drifted from
   the ADR's wrapper-not-reimplementation rule by reimplementing recipe matching
   and metrics joining in Python. It is the only thing keeping Python in an
   otherwise bash-only runtime.
4. All four grey-area calls resolved as "archive":
   - the verdict-automation hooks (`delegate-verdict-stop-hook.sh`,
     `delegate-boundary-hook.sh`, `verdict-sweep.sh`);
   - the maintainer analysis tools (`quality-report.sh`, `audit-metrics.sh`,
     `model-change-audit.sh`);
   - the faithfulness grounding prototype (`grounding-check.sh`, the duplicate
     `ground-check.sh`, and `prompts/ground-check.md`);
   - and `delegate.sh` itself is trimmed of the verify-and-escalate gate,
     grounding, and fan-out, keeping backend selection, recipe substitution, and
     metrics logging.

## Keep / archive boundary

### Keep — the lean runtime, install path, CI gates, calibration loop

Scripts: `pick-model.sh`, `delegate.sh` (trimmed), `audit-models.sh`,
`init.sh`, `onboard.sh`, `derive-flavor.sh`, `load-flavor.sh`,
`flavor-defaults.sh` (the flavor trio is load-bearing for the commit-message
recipe's `{{flavor_*}}` substitution and for onboarding), `validate-frontmatter.sh`,
`validate-skill-content.sh`, `eval-skill-triggers.sh`, `delegate-feedback.sh`,
`metrics-summary.sh`.

Tests for each kept script: `run-tests.sh`, `test-delegate.sh` (re-baselined
after the trim), `test-delegate-feedback.sh`, `test-metrics-summary.sh`,
`test-validate-content.sh`, `test-validate-frontmatter.sh`,
`test-eval-skill-triggers.sh`, `test-prompts-library.sh`, `test-onboard.sh`,
`test-project-name.sh` (verify it still applies; drop if orphaned).

Docs: `SKILL.md` (tightened), `README.md` (trimmed), `CLAUDE.md` (trimmed to
match the lean repo), `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`,
the install guides under `docs/` (`install-claude-code.md`, `install-codex.md`,
`install-opencode.md`; `install-mlx.md` kept since MLX is a supported backend),
`docs/README.md`, and all 21 ADRs (ADRs are durable history — kept, but the ones
describing archived features get a one-line "superseded / archived" note).

Recipes: the head of the usage distribution — `commit-message` (rewritten
small), `summarise-issue`, `doc-section`, `pr-description`, `maintainer-reply`,
`file-summary`, `release-note`, `summarise-diff` (kept despite low logged use
because it is a canonical example in the README/SKILL surface — confirm during
the prune), `pr-review-reply`, `bulk-file-summary`. Final kept set is fixed in
the recipe-prune workstream against the metrics.

### Archive — research, observability, speculative interop

Observability: `backfill-otel.sh`, `sync-metrics-to-loki.sh`,
`observability-doctor.sh`, `scripts/lib/otel.sh`, `observability/`,
`dashboards/`, the `docs/observability/` guides, `docs/otel-schema.md`,
`metrics.loki-sync`.

Embeddings / semantic search: `embed.sh`, `semantic-search.sh`,
`prompts/semantic-search.md`.

Experiments: the whole `experiments/` tree — `runner.sh`, `run-baseline.sh`,
scorers `score-t3.sh`..`score-t9.sh`, `escalate-eval.sh`,
`escalate-gate-eval.sh`, `fanout-eval.sh`, `quality-trend.py`, the phase-12
runners, `sessions/`, `results/`, `fixtures/`, `lib/`, `apply-and-test.sh`.

Verdict automation: `delegate-verdict-stop-hook.sh`, `delegate-boundary-hook.sh`,
`verdict-sweep.sh`, `.verdict-stop-markers/`.

Maintainer analysis: `quality-report.sh`, `audit-metrics.sh`,
`model-change-audit.sh`.

Grounding prototype: `grounding-check.sh`, `ground-check.sh`,
`prompts/ground-check.md`.

Interop: `mcp/` (entire Python server + its CI job).

Recipe experiment forks: `prompts/_experiments/` (the v2-domain-priming /
v3-persona variants) and the zero/single-use recipe tail confirmed during the
prune — each judged against logged usage, not deleted blindly.

Tests for archived scripts: `test-backfill-otel.sh`, `test-observability-doctor.sh`,
`test-sync-metrics-to-loki.sh`, `test-embed.sh`, `test-semantic-search.sh`,
`test-ground-check.sh`, `test-grounding-check.sh`, `test-apply-and-test.sh`,
`test-audit-metrics.sh`, `test-model-change-audit.sh`, `test-quality-report.sh`,
`test-quality-trend.sh`, `test-dashboards.sh`, `test-runner.sh`,
`test-run-api-cell.sh`, `test-score-t3.sh`..`test-score-t9.sh`,
`test-delegate-verdict-stop-hook.sh`, `test-delegate-boundary-hook.sh`,
`test-verdict-sweep.sh`.

CI: drop the `mcp-server` Python job; prune CI steps that invoke archived
scripts. Keep the validate + bash-test + trigger-eval jobs.

## Workstreams (ordered)

The order is deliberate: capture the install truth before changing anything,
archive next so later edits target a lean tree, then do the high-value/high-risk
core shrink, then the mechanical prune and doc reset, then re-verify.

### 1. Verify the current install (capture facts before changing anything)

Exercise the real install path end to end on a clean target — `npx skills add`
(or the `cp -r` fallback if the network/registry is unavailable), then
`audit-models.sh`, then `onboard.sh`, then a first `delegate.sh` call against
whatever local backend is available (Ollama on this host). Write down exactly
what is broken or surprising. Acceptance: a short findings note committed to
`docs/superpowers/specs/`, listing each defect with a reproduction. Any
trivial, obviously-correct install fix is made here; anything larger is logged
as a follow-up rather than scope-creeping this reset.

### 2. Archive (tag + branch, then remove from main)

Create the tag `pre-cleanup-2026-06-19` on the current main commit and push it;
create and push `archive/research-machinery` from the same commit. Then, on the
cleanup branch, `git rm` the entire archive set above plus their tests, and
remove the corresponding CI jobs/steps. Acceptance: the tag and branch exist on
the remote; main no longer contains any archived path; `bash tests/run-tests.sh`
and the remaining per-script test files pass; CI config references no deleted
script.

### 3. Shrink the core artifacts (the quality lever)

Trim `delegate.sh`: remove the verify-and-escalate gate, the grounding hook, and
the fan-out path, keeping backend selection (auto/ollama/mlx), recipe loading +
`{{var}}`/`{{flavor_*}}`/`{{stdin}}` substitution, the deterministic output
checks that are cheap and proven (subject_max, no_padding_tail, subject_type,
body_required) plus their auto-strip, the preflight canary, and metrics logging.
Re-baseline `test-delegate.sh` against the trimmed script. Then rewrite
`commit-message.md` from 62KB down to a lean, single-purpose template (target
well under 10KB) that preserves the proven skeleton + one or two verbatim anchor
examples + the anti-padding guard, and drops the accumulated redundant
instruction layers. Acceptance: `delegate.sh` materially smaller with all kept
behaviour still tested green; `commit-message.md` rewritten and passing
`test-prompts-library.sh`; the T4 structural checks still pass on a sample
commit (run the kept `delegate.sh --recipe commit-message` path manually if a
backend is available).

### 4. Prune recipes

Fix the final kept recipe set against logged usage (head of the distribution),
move the zero/single-use tail and the `_experiments/` forks into the archive
branch, update `prompts/README.md` and the SKILL.md "Recipes" pointer so no kept
doc references an archived recipe. Acceptance: `test-prompts-library.sh` passes
with the reduced set; no dangling references; `eval-skill-triggers.sh` shape
check still green.

### 5. Doc reset

Rewrite ROADMAP.md into something legible: a short "where we are / where we're
going" header, the shipped state, and a small ordered next-steps list — not a
258-line backlog. Trim CLAUDE.md's architecture section so it describes only the
kept surface (it currently documents every archived feature in dense prose).
Trim README internals while keeping the clean 30-second quickstart. Add the
"superseded / archived" note to ADRs whose features moved to the archive branch.
Acceptance: ROADMAP.md, CLAUDE.md, README.md describe only what main contains;
`validate-skill-content.sh` and `validate-frontmatter.sh` pass on SKILL.md;
no doc references a deleted path.

### 6. Re-verify the lean install + repo hygiene

Re-run the workstream-1 install exercise against the now-lean tree and confirm
the under-five-minutes goal. Clean stragglers: the stale
`.claude/worktrees/agent-a362d7460185ae840` worktree (still referencing the old
`delegate-to-ollama` repo name), the in-tree `metrics.jsonl.bak-*` backups,
`.verdict-stop-markers/`, `metrics.loki-sync`. Acceptance: clean `git status`
save for intended changes; the lean install path verified working end to end and
the result noted in the findings doc.

## Execution model

All workstreams land on one branch (`worktree-lean-core-reset`) with one clean,
self-contained commit per workstream so the maintainer can review the work
workstream-by-workstream. The archive tag and `archive/research-machinery`
branch are pushed as plain git refs (not PRs). When the implementation is
complete and verified, one PR is opened for the cleanup branch; per the
maintainer's standing rule, `/review` then `/address-pr-comments` runs against
it, and the loop stops there. Nothing is merged autonomously — "completed" means
the work is implemented, verified, and the PR is open with review addressed,
awaiting the maintainer's explicit merge decision.

## Verification

The gate at every step is the existing test suite minus the archived tests:
`bash tests/run-tests.sh` plus the kept per-script test files, and the
shape-mode trigger eval. The trim in workstream 3 specifically re-baselines
`test-delegate.sh`. Where a local backend is available, the kept recipe paths
are exercised end to end (a real `delegate.sh --recipe commit-message` call) so
the quality claim is measured, not asserted.

## Rollback / recovery

Every archived file is one `git show archive/research-machinery:<path>` away, or
recoverable wholesale by branching from the `pre-cleanup-2026-06-19` tag. If the
`delegate.sh` trim regresses a behaviour the tests did not cover, revert that
single workstream commit without disturbing the others.
