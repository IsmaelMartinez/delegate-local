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

## Where we are (2026-10-09)

The skill installs via `npx skills add` (or `cp -r`) and routes the `code`,
`prose`, `reasoning` and `long-context` tiers, where `code`, `reasoning` and
`long-context` follow the `prose` list (#652), as does `verify`, the model
`verify-draft.sh` asks whether a draft's claims are in its input (opt-in per
recipe, `docs/verify.md`); `vision`, `embedding` and `reasoning-vision`
resolve when a matching model is served, and `premium-general` resolves only
when `config.sh` opts in. It ships 13 recipes since #616 retired ten unused ones. Recipe calls run
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
merged and released: the recipe keep list (#568), CLAUDE.md to about 3k tokens (#571),
calibration history out of the recipe files (#569), the SKILL.md body halved
(#570), and this file, the docs tree and the env-var table (#572).

Two October efforts followed. The Clef spike (epic #642, ADR 0033) found that
the question format, not the model, is the lever: `scripts/decide.sh` asks
typed questions of the resident model's logprobs, which revived the trigger
gate as `eval-skill-triggers.sh --decide` (#649), and batch callers wait on
`scripts/lib/gpu-gate.sh` when the machine is hot or busy (#650). Model
portability (epic #663) made trying a model cheap and safe: `config.sh`
prepends to the shipped lists instead of freezing them (#653), rates and
replays split by model (#655, #656), the grounding verifier shipped opt-in
(#659 to #661), and `docs/model-swap.md` is the trial runbook (#658, #676).
v0.50.0 adds `scripts/eval-model.sh`, one report card per candidate model
against the prose tier's, so a new model is measured with one command before
anyone trials it (ADR 0034, #680).

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

## Active work (2026-10-09)

This is the resume point. When a session is asked to "continue with what we
were doing", it starts here. Three tracking epics are open, and their issue
bodies, not this file, are the source of truth for status, so read them first
with `gh issue view 663`, `gh issue view 574` and `gh issue view 642`. In
order:

- The Gemma 4 prose trial (#662, the last item of epic #663). Since
  2026-10-09T12:47:19Z the data dir's `config.sh` puts the candidate ahead of
  the shipped prose list, and `verify` moves with it because the shared MLX
  server swaps models rather than stacking them. A cloud routine comments on
  #662 on 2026-10-30 when the read-out is due; the issue holds the commands,
  the keep criteria and the rollback (delete `config.sh`).
- New models. Run `eval-model.sh` before any trial; only a TRIAL card starts
  one (`docs/model-swap.md`). The 2026-10-09 shortlist of five low-active
  models all stopped (#679, ADR 0034): 1 to 2B active parameters halve the GPU
  time but invent or drop facts. The nearest, Gemma 4 E4B, is the one to
  measure again when its family updates.
- Wave 5 of the Lean and correct plan (epic #574): #573, recipe-quality
  follow-ups one replay-gated edit at a time, and decision D9, narrowing
  recipe scopes once the #588 ritual tags give honest rates. Both wait for
  the #662 decision, because every recipe guard was calibrated on the shipped
  model and a switch resets that calibration.
- The Clef spike (epic #642) is measured and recorded in ADR 0033. What is
  left is its closing summary and a heat-gate call in the `--decide`
  per-query loop of `eval-skill-triggers.sh`.

The maintainer still has manual steps: create the release GitHub App (the
`RELEASE_APP_ID` variable and the `RELEASE_APP_PRIVATE_KEY` secret, #549), add
the `ANTHROPIC_API_KEY` secret for the CI trigger eval, and run
`self-improve.sh --quarantine` on the live data dir.

The working method is the same for every batch:

- The session coordinates. Each issue goes to its own worktree agent on its
  own branch (`w<wave>/<issue>-<slug>` or `mp/<issue>-<slug>`), with a failing
  test first, and at most five PRs are in flight. Issues that edit the same
  files run one after another rather than in parallel; the paragraphs they
  share in CLAUDE.md are the usual conflict.
- Branches are never stacked. Commit and PR text is delegated through the
  live skill's recipes, and verdicts are recorded with `--id` and `--final`.
- Long local runs (replay, `eval-model.sh`, calibration) go one at a time
  through the heat gate and from a copy of the scripts, not the worktree
  being edited, because bash reads a script as it runs. Check free memory
  before loading a second model on the shared server.
- The coordinator runs the Copilot review loop on each PR, replies to every
  comment, resolves the threads, and asks the maintainer to merge each PR. It
  never merges on its own.
- After merges it pulls the live clone
  (`git -C ~/.local/share/delegate-local-live pull --ff-only`), smoke-tests the
  hooks, and ticks the epic. Release PRs follow CONTRIBUTING.md "Releasing":
  on the `GITHUB_TOKEN` fallback the maintainer approves the held runs, and
  the App removes that step.

## Where we're going (next, priority-ordered)

1. Decide the prose tier from the #662 read-out, and switch the shipped list
   only if its criteria hold.
2. Finish the Lean and correct plan (#573, D9) on whichever model that leaves.
3. Re-verify the install on a genuinely clean machine (not the maintainer's
   live clone) and keep the install path covered as the headline trust surface.

Anything beyond this is a fresh, evidence-gated decision. Re-introducing an
archived capability (MCP, experiments) should be driven by a real consumer
asking for it, not by default.

## Out of scope

- Code edits, refactors, or feature implementation. Local models are weak agents and the skill description explicitly rejects these. The local-brain finding stands: "they didn't need Smolagents, they needed `git status | ollama run model`".
- Auto-pulling models without confirmation. Multi-GB downloads stay user-decided; the audit script suggests, never installs.
- A general-purpose router that competes with Claude on routing decisions. This skill picks a model among the local providers; it does not decide whether to call Claude or a local model. That decision belongs in the skill description, evaluated by Claude itself.
- A critic, judge or multi-round loop on the same local model, and agent frameworks around the wrapper. Measured on real cases in ADR 0031: the loop oscillates and never converges, structured output enforces shape only, and docker agent cannot cycle without the local model's cooperation, which it does not give. Revisit only on a new lever (a different model, a narrower task, or docker agent as a zero-install runner once it can send `chat_template_kwargs`).
