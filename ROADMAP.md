# Roadmap

This is the authoritative, intentionally short project plan. The full historical
record lives in git history, `CHANGELOG.md` and the ADRs under `docs/adr/`.
Everything the 2026-10-18 wind-down removed is recoverable from commit
`a00b2e9`; the 2026-06-19 lean-core reset is at the `pre-cleanup-2026-06-19`
tag and the `archive/research-machinery` branch.

## What this is

delegate-local is a Claude Code skill that reads a large text input on the
local machine instead of in the agent's context: the input is piped, in
chunks, to a locally-installed model over a shell pipe, and the agent gets back
a short answer anchored to the input that it spot-checks with `grep`. The
runtime path is two scripts: `scripts/pick-model.sh` resolves a tier to the
best model a running provider serves (MLX, Docker Model Runner or Ollama), and
`scripts/delegate.sh` posts the prompt and returns clean text plus a metrics
row. Three recipes fit the shape: `summarise-issue`, `bulk-classify` and
`file-summary`.

The discriminator is the local-brain insight, sharpened by ADR 0035: local
models are strong summarisers and weak agents, and a delegation only pays when
it keeps a large input out of Claude's context without making Claude write a
brief as long as the answer.

## Where we are (2026-10-18)

The experiment is wound down. ADR 0035 measured 2,159 delegations against
their transcripts: drafting text Claude would publish (commit messages, PR
descriptions, issue bodies, replies) cost more Claude output tokens than it
saved, added about 20 seconds per call, and its shipped-as-is rate stayed at
2-20% a week through a month of daily calibration. Only large piped inputs
came out ahead. The ten writing and code recipes, the three boundary and
verdict hooks, the calibration loop (`self-improve.sh`, its launchd runner,
`replay-recipe.sh`, `export-verdicts.sh`, `eval-model.sh`), the onboarding
wizard and flavor profile, and `apply-and-test.sh` left `main`.
`docs/learnings.md` keeps what the experiment taught; ADR 0035's "When to look
again" table lists what would justify reopening it.

The OpenTelemetry and Loki tooling, `delegate-feedback.sh`, `verify-draft.sh`,
`decide.sh`, `embed.sh` and `semantic-search.sh` remain but are dormant: they
cost nothing per session and go with the repository when it is archived.

## Active work: the wind-down (2026-10-18)

These are the maintainer's steps once the wind-down PR merges, in order:

1. Remove the three delegate-local hook entries (`delegate-boundary-hook.sh`,
   `delegate-boundary-confirm-hook.sh`, `delegate-verdict-stop-hook.sh`) from
   both Claude profiles' `settings.json`, before pulling the live clone, or
   every Bash call runs a hook script that no longer exists.
2. Unload the launchd self-improve job
   (`launchctl bootout gui/$(id -u)/com.delegate-local.self-improve`) and
   remove its plist from `~/Library/LaunchAgents`.
3. Pull the live clone (`git -C ~/.local/share/delegate-local-live pull --ff-only`).
4. Drop the "delegate commit messages and PR descriptions" rule from the
   global instructions, so sessions stop paying the cost ADR 0035 measured.
5. Disable the two cloud routines that watch this repository (the #662
   read-out reminder and the daily issue watcher).
6. Close the open epics, issues and calibration PRs with a pointer to
   ADR 0035, and decide whether to delete `config.sh` (the Gemma trial needs no
   read-out).

## Where we're going

One decision is left: archive the GitHub repository once the wind-down ships,
or keep it as a small, frozen skill for large inputs that must stay on the
device. Nothing in it needs further development either way. A revival starts
from ADR 0035's signposts and re-runs the measurements in
`docs/learnings.md` on a fresh corpus before building anything.

## Out of scope

- Drafting text the agent will publish: commit messages, PR descriptions,
  issue bodies, review or maintainer replies, release notes, documentation.
  Measured net negative in ADR 0035.
- Code edits, refactors, code drafts or feature implementation. Local models
  are weak agents ("they didn't need Smolagents, they needed
  `git status | ollama run model`").
- Enforcement hooks and per-call verdicts. They created ritual delegations and
  cost more than the calibration they fed.
- Auto-pulling models without confirmation. Multi-GB downloads stay
  user-decided; the audit script suggests, never installs.
- A general-purpose router deciding between Claude and a local model, and
  critic, judge or multi-round loops on the same local model (ADR 0031).
