# Roadmap

This is the authoritative, intentionally short project plan. The full historical
record lives in git history, `CHANGELOG.md`, the ADRs under `docs/adr/`, and —
for everything removed in the 2026-06-19 lean-core reset — the
`pre-cleanup-2026-06-19` tag and the `archive/research-machinery` branch.

## What this is

delegate-local is a Claude Code skill that routes "gather context once, send one
prompt, return text" tasks to a locally-installed model over a shell pipe, for
privacy (content stays on-device) and context protection (the main-agent window
is not spent on paragraph-fills). The runtime path is two scripts:
`scripts/pick-model.sh` resolves a tier to the best model a running provider
serves (MLX, Docker Model Runner or Ollama, probed in that order), and
`scripts/delegate.sh` posts the prompt and returns clean text plus a metrics
row. Everything else — the recipe library, the opt-in hooks, the calibration
loop and the CI gates — exists to make that one path reliable and
self-correcting.

The discriminator for what belongs here is the local-brain insight: local models
are strong summarisers and weak agents. If a task needs multi-step reasoning,
repo-wide context, or tool-calling, it does not belong in this skill even if the
surface looks textual.

## Where we are (2026-10-01)

The skill installs via `npx skills add` (or `cp -r`) and routes the `code`,
`prose`, `reasoning` and `long-context` tiers, where `code`, `reasoning` and
`long-context` follow the `prose` list (#652); `vision`, `embedding` and
`reasoning-vision` resolve when a matching model is served, and
`premium-general` resolves only when `config.sh` opts in. It ships 13 recipes since #616 retired ten unused ones. Recipe calls run
a pre-flight canary, weak-input labels, deterministic output checks and at most
one retry (`docs/checks.md`), and store the draft, the rendered input and the
structured inputs beside the metrics row so a rejection can be diffed against
what shipped. Three opt-in hooks close the loop around posting
(`docs/boundary-hook.md`): a `PreToolUse` boundary hook that credits or denies
commits, PRs, issues and replies, its `PostToolUse` confirm companion that
stores the posted text as the shipped final, and a `Stop` hook that asks for
outstanding verdicts. The agent's verdict is the one calibration signal
(ADR 0030), read by `metrics-summary.sh` and by the `self-improve.sh` bundle;
`replay-recipe.sh` gates every recipe edit offline with a sign test, and
`self-improve-daily.sh` runs the calibration pass from launchd
(`docs/self-improvement-loop.md`). On the maintainer's machine the live skill is
a separate clone of `origin/main`, not the dev checkout (#360).

Most of that state is the outcome of the Lean and correct plan (epic #574,
below), which came from a 2026-09-26 review of main. Waves 1 to 3 are merged and
released as v0.40.1 through v0.44.0: the hooks stopped auto-approving and see
`git -C` commits, the request body is sent safely, CI runs only gates that can
fail and discovers every test file, release PRs no longer need an admin merge
once the release App exists, the recipe-data integrity fixes landed (hook-captured
finals, ritual tagging, scorer fixes, input-quality labels), the shared
libraries (`lib/recipe.sh`, `lib/checks.sh`, `lib/text.sh`, `lib/hook.sh`) and a
single verdict model replaced duplicated code, and v0.44.0 removed `init.sh`,
the legacy `DELEGATE_TO_OLLAMA_*` aliases and the sampler overrides. Wave 4 is
merged: the recipe keep list (#568), CLAUDE.md to about 3k tokens (#571),
calibration history out of the recipe files (#569), the SKILL.md body halved
(#570), and this file, the docs tree and the env-var table (#572).

The OpenTelemetry → Loki/Grafana observability pipeline stays in the core:
`scripts/lib/otel.sh` span emission (opt-in via `DELEGATE_OTEL_ENDPOINT`), the
`sync-metrics-to-loki.sh` and `backfill-otel.sh` exporters, the Grafana
`dashboards/`, `observability/`, and the `docs/observability/` guides are the
maintainer's live view of delegation traffic. Every environment variable the
scripts read is listed in `docs/env.md`.

## Earlier milestones

The reply-recipes milestone (2026-09-16, ADR 0031) made the two reply recipes'
failures visible as checks (`no_fact_as_question`, the echo and length
checks), stopped spending retries that do not repair, moved the
lead sentence to the caller, and measured a bigger model, which graded worse and
was not adopted. It closes when both recipes read usable ≥ 65% and 60% and kept
≥ 10% on `metrics-summary.sh --days 30`, or when the gap is shown to be the
task definition, in which case the recipes are narrowed or retired; that read
now belongs to #573 and decision D9.

The replay-gated self-improvement milestone (2026-09-19) gave the loop a
measurement: every recipe row carries `template_sha`, a successful recipe call
stores its structured inputs unless metrics or capture are off or they exceed
the byte cap,
`replay-recipe.sh` decides an edit with a paired sign test before its PR, and
`self-improve.sh` splits outcomes by template hash for the post-merge read. It
closes once a full cycle has happened: an edit accepted by replay, merged, and
read online at thirty rows. The schedule half is #558, which stays open until
the installed LaunchAgent has advanced the watermark within 26 hours on 7
consecutive days.

## Active work: the Lean and correct plan (epic #574)

This is the resume point. When a session is asked to "continue with what we
were doing", it starts here. The plan is epic #574 in the "Lean and correct"
milestone: a review-driven simplify-and-fix plan in five waves, whose issue
body holds the batch checklist, the scorecard and the open decisions. The epic,
not this file, is the source of truth for status, so read it first with
`gh issue view 574`.

As of 2026-10-01, waves 1 to 3 are merged and released (v0.40.1 to v0.44.0)
and wave 4 is merged (#568, #569, #570, #571, #572). The wave-4 trigger-eval
gate could not score: `eval-skill-triggers.sh --local` sends no
`enable_thinking:false`, so the resident Qwen3.6 spends its output budget
thinking and returns no score on main or the branch. #570 left the SKILL.md
frontmatter byte-identical, so triggering cannot have moved. #638 revived the
gate as `eval-skill-triggers.sh --decide` (one `decide.sh` question per query on
the resident model, 0.955 recall and 1.000 negative precision on 2026-10-07). What remains:

- The wave-4 release, if `gh release list` does not yet show one after
  v0.44.0: approve the release PR's held runs, then merge it.
- Wave 5: #573, recipe-quality follow-ups after the #538 and #535
  per-template reads, one replay-gated edit at a time.

Two decisions are open on the epic: D8, whether the boundary hook keeps forcing
a delegation before posting text that is already written, and D9, narrowing
recipe scopes once the #588 ritual tags give honest rates. The maintainer
still has manual steps: create the release GitHub App (the `RELEASE_APP_ID`
variable and the `RELEASE_APP_PRIVATE_KEY` secret, #549), add the
`ANTHROPIC_API_KEY` secret for the CI trigger eval, install the self-improve
LaunchAgent (#558), and run `self-improve.sh --quarantine` on the live data dir.

The working method is the same for every batch:

- The session coordinates. Each issue goes to its own worktree agent on
  branch `w<wave>/<issue>-<slug>`, with a failing test first, and at most five
  PRs are in flight. Issues that edit the same files run one after another
  rather than in parallel; the paragraphs they share in CLAUDE.md are the
  usual conflict.
- Branches are never stacked. Commit and PR text is delegated through the
  live skill's recipes, and verdicts are recorded with `--id` and `--final`.
- The coordinator runs the Copilot review loop on each PR, replies to every
  comment, resolves the threads, and asks the maintainer to merge each PR. It
  never merges on its own.
- After merges it pulls the live clone
  (`git -C ~/.local/share/delegate-local-live pull --ff-only`), smoke-tests the
  hooks, and ticks the epic. Release PRs follow CONTRIBUTING.md "Releasing":
  on the `GITHUB_TOKEN` fallback the maintainer approves the held runs, and
  the App removes that step.

## Where we're going (next, priority-ordered)

1. Finish the Lean and correct plan above (epic #574).
2. Re-verify the install on a genuinely clean machine (not the maintainer's
   live clone) and keep the install path covered as the headline trust surface.

Anything beyond this is a fresh, evidence-gated decision. Re-introducing an
archived capability (MCP, experiments) should be driven by a real consumer
asking for it, not by default.

## Out of scope

- Code edits, refactors, or feature implementation. Local models are weak agents and the skill description explicitly rejects these. The local-brain finding stands: "they didn't need Smolagents, they needed `git status | ollama run model`".
- Auto-pulling models without confirmation. Multi-GB downloads stay user-decided; the audit script suggests, never installs.
- A general-purpose router that competes with Claude on routing decisions. This skill picks a model among the local providers; it does not decide whether to call Claude or a local model. That decision belongs in the skill description, evaluated by Claude itself.
- A critic, judge or multi-round loop on the same local model, and agent frameworks around the wrapper. Measured on real cases in ADR 0031: the loop oscillates and never converges, structured output enforces shape only, and docker agent cannot cycle without the local model's cooperation, which it does not give. Revisit only on a new lever (a different model, a narrower task, or docker agent as a zero-install runner once it can send `chat_template_kwargs`).
