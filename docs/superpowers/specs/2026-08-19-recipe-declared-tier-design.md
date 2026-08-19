# Stop callers guessing the tier: design

**Date:** 2026-08-19
**Issue:** #411

An adversarial review of the first draft found four blockers, one of them fatal
to the central mechanism. Each correction is recorded rather than quietly
applied.

## The bug

44 delegations in the live metrics passed a tier that does not exist. All 44
were rejected correctly — exit 1 or 2, `model=(none)`, `output_chars=0` — so
these are honest records of refused calls, not corrupt rows. 16 were never
successfully retried, so those delegations were lost.

Two distinct causes needing different fixes.

### Cause 1: the tool advises a flag it does not have (5 rows)

`tier` is positional (`delegate.sh:365`) and the argument loop ends in a
catch-all that pushes anything unrecognised into `positional`. So
`delegate.sh --tier prose "..."` sets `tier="--tier"`.

The first draft blamed the caller for inventing `--tier`. That was wrong.
**`delegate.sh:1037` tells them to use it**, on the flaky-gate refusal path:

```
- route to a different tier (e.g. --tier code) and retry
```

`docs/adr/0012-flaky-on-models-tier-gate.md:39` repeats the advice, and two
recipes carry `flaky_on_models:` blocks that fire on the currently resolved
model, so this is a live path rather than a dormant one. The tool taught the
flag and then rejected it.

The other four rows (`--file`, `--print-model`, `--ts`, and `--project` before
#355 fixed it) are flags the caller assumed existed.

### Cause 2: callers supply a model-size word (39 rows)

`small`, `fast`, `medium`, `quick`, `light`, `standard`, `default`, `balanced`,
`mlx`. Tiers name the task, not the model size, and #348 added a message saying
exactly that on 2026-08-03. It did not help.

The first draft claimed a Fisher exact p of 3.7e-09 for a rise from 1.7% to
10.6% across the #348 boundary. The arithmetic reproduces, but **the comparison
is confounded and #348 is not the change point.** Per fortnight:

```
2026-05-H2  0.16%    2026-07-H2   9.56%   <- already high, BEFORE #348
2026-06-H1  0.36%    2026-08-H1  10.94%
2026-06-H2  4.08%    2026-08-H2   2.70%
```

The trend is monotone from 2026-06 and the sharpest split is two weeks *before*
#348. The "before" window also contains a 20-day dead zone with zero calls, and
the caller population changed at the real change point: 18 projects first appear
on or after 2026-07-22. Recipe calls also rose from 52% to 76% of traffic while
carrying roughly four times the bad-tier rate, so part of the headline is mix
rather than behaviour.

The honest statement, which is all the design needs: **among recipe calls the
bad-tier rate went from 2.9% to 12.0% across a rollout to 18 new projects, and
#348's message did not arrest it.** A message that arrives after the call has
already failed cannot fix a problem whose cause is that the caller had to guess.

## The observation that decides the design

**39 of the 44 bad-tier calls supplied a `--recipe`** (commit-message 29,
pr-description 7, maintainer-reply 2, pr-review-reply 1). And every recipe's
production traffic routes to one dominant tier: prose for commit-message (449
against 8), maintainer-reply, pr-description, github-issue-body and eleven
more; reasoning for summarise-issue, ci-log-triage, bulk-classify,
miss-theme-cluster, ground-check, long-thread-distillation; code for code-draft.

The caller is being asked for a value the recipe already implies. Remove the
question and the wrong answers go with it.

## Fatal correction: the tier slot cannot simply become optional

The first draft proposed making the positional tier optional when `--recipe` is
given. That does not work. The grammar is `[<tier>] [<prompt>]`, and **17 of the
20 recipes carry a trailing reinforcement prompt** — `commit-message.md:14` calls
it load-bearing: "the trailing prompt arg is the reinforcement instruction".

With both positionals optional, `positional[0]` is still read as the tier, so a
caller following the new documentation gets:

```
$ delegate.sh --recipe commit-message --var ... "Match the example messages in shape and tone."
delegate: unknown tier: Match the example messages in shape and tone.
```

The design would have replaced "caller guessed `small`" with "caller followed
the docs", for 17 recipes. `SKILL.md:89`'s own example breaks the same way.

## Decision

### 1. `--tier NAME` becomes a real flag

Not a new invention: it is what `delegate.sh:1037` already tells callers to use,
and what one of the five swallowed rows literally is. It guards a following
`-` token exactly as `--recipe`, `--var` and `--project` already do. Line 1037
and ADR 0012 stop being wrong the moment it exists.

### 2. Recipes declare their tier

An optional top-level `tier:` scalar in recipe frontmatter, populated for the 20
real recipes from the tier their own production traffic uses.

Safety verified rather than assumed: there are **four** independent frontmatter
parsers, not three — `inputs:`, `checks:`, `flaky_on_models:` in `delegate.sh`
and a fourth in `delegate-boundary-hook.sh:420` — and each was tested against
copies carrying `tier:` inserted first, middle and last. All four terminate
cleanly on a top-level key and behave identically to baseline.

### 3. A lone positional is disambiguated by the tier list

This is what makes the slot droppable without breaking the 17 reinforcement
prompts:

- two positionals → `[0]`=tier, `[1]`=prompt, exactly as today
- one positional → tier if it **exactly** matches one of the eight names in
  `pick-model.sh:57`, otherwise the prompt
- no positional, recipe set → the recipe's declared tier
- `--tier` given → always wins, and every positional is a prompt

The heuristic is bounded and testable: the eight names are fixed single tokens,
and a reinforcement prompt equal to one of them is not a real case. Every
existing invocation keeps its current meaning byte for byte.

### 4. The documented invocation drops the tier

Inert without this, and the first draft's scope missed most of it. The tier slot
appears in 17 recipe `## Invocation` blocks, `prompts/README.md` twice,
`SKILL.md:89`, `README.md:218`, `CLAUDE.md:95`, `scripts/onboard.sh:298`, and
`delegate.sh`'s own header at lines 10 and 30. `SKILL.md:91` explicitly points
the agent at the recipe Invocation blocks as the authority, so leaving them is
leaving the documented invocation unchanged.

One line in `SKILL.md` and `prompts/README.md` keeps documenting `--tier` as the
override, so the deliberate `commit-message` on `code` experiments — nine rows,
most recent 2026-08-14 — stay discoverable rather than merely still-working.

### 5. Unknown `-` tokens are rejected, loudly and with telemetry

Two constraints the review surfaced. A dash-leading prompt **works today**
without `--` (`delegate.sh prose "-not a flag"` succeeds), so this is a real if
narrow break; `--` is an untested, undocumented path that fix 5 would make
load-bearing, so it gets documented in `usage()` and tested. And argument
parsing ends at line 355 while `log_metric` is not defined until 459, so a bare
`exit 2` writes no metrics row — destroying the only telemetry that found this
bug, which a sibling design dated today depends on. The unknown-flag path
therefore emits a row with `tier="(unknown-flag)"`.

## Rejected: accepting the size words as aliases

`small` → `prose` and so on would make all 39 rows succeed, which is why it is
wrong: it teaches that the size framing is valid, then silently routes `small`
to a 35B model. It cannot be right for `mlx`, which is a backend.

## Rejected: inferring the tier from the prompt

More guessing, with less information than the recipe already has.

## Scope, split across two PRs

**PR A** — `--tier` flag, the line 1037 and ADR 0012 corrections, unknown-flag
rejection with its metrics row, `--` documented and tested. Self-contained, and
a prerequisite for PR B's documentation.

**PR B** — `tier:` frontmatter for 20 recipes, the lone-positional
disambiguation, and the documentation sweep above.

Recipes served from `DELEGATE_PROMPTS_DIR` (`ground-check` and six
`_experiments` variants have no file in `prompts/`) declare no tier and keep the
positional form; `README.md:198` documents that override as user-facing, so the
tier slot stays documented for exactly that case.

## Verification

PR A: `--tier` sets the tier; `--tier` with a following flag errors; `--tier`
overrides a positional; line 1037's advice now executes successfully; every
unknown `-` token errors and writes one metrics row; `--` passes a dash-leading
prompt; `-h`/`--help` unchanged.

PR B: a recipe call with no tier resolves the declared tier, asserted per tier
class rather than once; an explicit tier still overrides; a lone positional
matching a tier name is still the tier; a lone positional that is a sentence is
the prompt; a recipe declaring no tier with no positional errors naming both
remedies; a bare call with no recipe and no tier errors as today.

The structural assertion is "every recipe declares `tier:`", scoped to files
with frontmatter and a `## Prompt template` block — `prompts/README.md` has no
frontmatter and `prompts/semantic-search.md:13` says it "does NOT go through
`delegate.sh --recipe`", so both are excluded. That is 20 recipes, not 22.
