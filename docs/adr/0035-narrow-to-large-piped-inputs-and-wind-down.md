# ADR 0035: Narrow delegate-local to large piped inputs and wind the experiment down

Status: accepted. Supersedes ADRs 0013, 0024, 0025, 0026, 0027, 0030, 0032 and 0034, and the recipe scope of 0023.
Date: 2026-10-18

## Context

delegate-local started in May 2026 on a simple bet: a local model could take
the "gather context once, send one prompt, return text" work off Claude, so
the content stays on the machine, the main context window stays clear and a
few API tokens are saved on the way. Five months later the skill had 13
recipes, three Claude Code hooks enforcing delegation at every commit, PR,
issue and comment, a daily calibration loop with a replay gate, a model
report card, a decision backend and an observability stack, documented by 34
ADRs. This ADR measures whether that machinery paid for itself. It did not.

### What the delegations cost Claude

The metrics row's `estimated_tokens_avoided` is characters in and out of the
local model divided by four. `delegate.sh` already labels it "kept local", not
"saved from Claude", but `metrics-summary.sh` prints it as "Tokens avoided" and
it is easy to read as a saving. On 2026-10-18 the corpus since the
2026-08-19 reset (ADR 0028) was measured against what Claude actually did:
2,667 delegations, of which 2,159 sit in sessions whose main and subagent
transcripts still exist. For each call the measurement credits the caller
input that reached the model without Claude typing it, plus the full output
of every draft shipped as-is, and charges the `delegate.sh` command Claude
typed (mostly the `--var` values), the tool result it read back, the verdict
commands and any batch script written to drive calls. Characters are divided
by four, as the metrics row does.

| Recipe | Calls | Net tokens, best case | Shipped as-is |
|---|---|---|---|
| commit-message | 698 | +658k | 13% |
| pr-description | 189 | +87k | 5% |
| github-issue-body | 189 | +30k | 18% |
| maintainer-review-reply | 498 | -146k | 0% |
| maintainer-reply | 288 | -103k | 6% |
| pr-review-reply | 293 | -54k | 60% |
| verdict commands | 1,969 | -308k | |
| batch scripts | 295 | -115k | |
| All | 2,159 | +43k, about 20 per call | |

The best case assumes Claude would otherwise have had to read every diff and
thread that was piped to the model. That assumption is what makes
commit-message and pr-description positive: 3.9M characters of staged diffs
went to the model. Claude writes a commit message about changes it has just
made, so it had read that diff already. Without the assumption the corpus
spent about 1.1M tokens of Claude-side text to save about 33k output tokens.

The split by token kind is worse than the totals. Claude typed about 650k
output tokens (briefs, vars, verdicts) to avoid about 33k output tokens of
drafting; everything else it avoided was input. At the prices published on
2026-10-18 an Opus 5.5 output token costs as much as 5 fresh input tokens and
about 100 cached ones (pricing and prompt-caching docs below). A delegation
can only pay when it keeps fresh, uncached input out of Claude's context and
adds almost no output of its own, and the writing recipes do the opposite:
the substance has to be in the brief, because Claude knows it and the model
does not. The largest single quality gain the reply recipes ever had, the
caller-written `lead` sentence (#531, 1 of 16 replays shippable before and 6
of 16 after), is the same fact seen from the quality side.

### What the delegations cost in time

From the same transcripts, `delegate.sh` took 9.0 s per call on average
(1,777 calls, including the pre-flight canary, the output checks and the one
retry), composing each verdict took 4.9 s of Claude's turn and running it
5.8 s (about 1,970 each). That is about 20 s added per delegation and about
10.3 hours of blocked session time over the corpus. The generation itself is
not the slow part: the prose-tier median in the 2026-10-09 to 10-18 window
was 3.8 s (p95 13.1 s, 131 calls, 1 error).

### What the drafts were worth

Most drafts were edited before shipping. In that window, 90 of 126 recipe
drafts were scaffolds, 24 hits and 12 misses. A scaffold still carried
something: across 107 draft and final pairs, 50% (commit-message) to 85%
(github-issue-body) of the shipped text's content words came from the draft.
But the edited commit messages split three ways: 21 of 56 were thrown away for
a one-line merge or test subject the boundary hook had forced through
delegation (18 of them from one project), 12 were kept with light edits,
most of them adding a `Refs:` line or a scope, and 23 were rewritten. The weekly shipped-as-is rate
ran between 2% and 20% from W35 to W42 with no upward trend after W38, while
the calibration loop ran daily. In June, under the older verdict definitions,
the rate read about 80% (ADR 0023); the two are not comparable, which is
itself a finding (see `docs/learnings.md`).

### The one shape that paid

Every positive balance came from a large input piped straight to the model:
in the 2026-10-09 to 10-18 window, three sessions piped 78k, 55k and 36k
characters while typing 4.9k, 1.5k and 6.7k in their main context.
That is the regime published work supports. The Minions paper (Narayan et al.,
2025) has the local model read a long context the cloud model never sees and
reports a 5.7x cost cut recovering 97.9% of the cloud model's quality, but
only with the MinionS protocol, which splits the input into chunks and the
work into single-step jobs; its naive one-prompt protocol recovers 87%, and
it names multi-step instructions and long contexts as the small model's
failure modes. Long-context benchmarks agree on the second point: RULER finds
only half of 17 models claiming 32k or more hold up at 32k, and NoLiMa puts
Gemma 3 27B's effective length below 1k tokens.

The skill was never used for this shape. Since the reset, summarise-issue,
file-summary and bulk-classify ran zero times and bare tier calls six times;
the large inputs that did arrive were 72 commit-message and 9 pr-description
calls carrying 20k+ character diffs. Prefill on this machine is not the
obstacle: the server log shows about 3,000 tokens/s up to 32k-token prompts
for both the 3B-active Qwen3.6-35B-A3B and the 4B-active Gemma 4 26B-A4B, and
about 1,300 tokens/s above 32k (Qwen3.6, 8 prompts), so a 20k-token log reads
in about 7 s and a 100k-token one in over a minute.

### The alternative that now exists

Claude Code subagents take a `model` field, and the docs recommend a Haiku
subagent when "a side task would flood your main conversation with search
results, logs, or file contents" and should return only the summary. At
$0.10 input and $0.50 output per million tokens (Haiku 5.5, published
2026-10-18), that covers context protection for non-private inputs without a
local model, a resident 28 GB of weights or a shell pipe. What remains unique
to a local model is that the content never leaves the machine and the call
costs no cloud tokens at all.

## Decision

delegate-local narrows to one shape and stops growing. The shape is a large
input Claude has not read and does not need to read in full (a long log, a
long issue or PR thread, a document, a directory of files, a list of items),
piped to the local model in chunks of at most about 8k tokens, with a closed
prompt whose answer is short and anchored to the input (quoted lines, line
numbers, item ids) so Claude verifies it with `grep` rather than by reading
the input. Claude does the decomposition and the combining, as in MinionS;
the model does single-step reading. The skill triggers on that shape, on an
explicit request to delegate or to use a local model, and on a requirement
that content stay on the device. It no longer triggers on writing work.

What stays is the runtime path (`pick-model.sh`, `delegate.sh` and the
libraries it sources), three recipes that fit the shape (`summarise-issue`,
`file-summary`, `bulk-classify`), bare tier calls, the metrics row, the heat
gate for batch callers, the trigger eval and the validators that gate
`SKILL.md`.

What is archived from `main`, recoverable from commit `a00b2e9` (the tip
before this change), is everything whose purpose was the writing recipes or
their calibration:

- the recipes commit-message, pr-description, maintainer-reply,
  maintainer-review-reply, pr-review-reply, github-issue-body, doc-section,
  release-announcement, code-draft and fix-with-test, with their calibration
  logs, fixtures and benches;
- the boundary hook, its PostToolUse confirm companion and the verdict Stop
  hook, with their shared hook libraries and `docs/boundary-hook.md`;
- the calibration loop: `self-improve.sh`, the launchd daily runner,
  `replay-recipe.sh`, `export-verdicts.sh` and `eval-model.sh`;
- the onboarding wizard and the flavor profile (`onboard.sh`,
  `derive-flavor.sh`, `load-flavor.sh`, `flavor-defaults.sh`), which existed
  for commit-message, and `apply-and-test.sh`, which existed for fix-with-test.

Verdicts are no longer asked for. `delegate-feedback.sh` stays as an optional
tool and `delegate.sh` stops printing the reminder after every call.

Left dormant rather than archived, because they cost nothing per session and
cutting them means surgery in `delegate.sh` for no user-visible gain: the
OpenTelemetry spans and the Loki/Grafana stack, the verdict analytics in
`metrics-summary.sh`, `verify-draft.sh`, `decide.sh` and its Clef backend,
`embed.sh` and `semantic-search.sh`, the recipe-specific checks in
`scripts/lib/checks.sh`, and the per-call capture of the draft, rendered input
and `inputs.json` under `drafts/` (its readers were the replay gate and the
calibration bundle; `DELEGATE_NO_DRAFT_CAPTURE=1` turns it off, and it is the
first thing a second pass should default off, since it stores the very inputs
the skill keeps on the device). They go with the repository if it is archived, or in
a second pass if it is not.

## Consequences

The per-session cost disappears with the hooks: no session is forced to
delegate a commit or a comment, and none spends about 20 s and a verdict on
each one. The maintainer's own instructions still say to delegate commit
messages and PR descriptions; that rule should go when this lands, or every
session keeps paying the cost the hooks enforced.

The live install needs an order. The three hook entries must leave both
profiles' `settings.json` before the live clone is pulled, or every Bash call
runs a hook script that no longer exists. The launchd self-improve job must be
unloaded for the same reason. Two cloud routines watch this repository (the
2026-10-30 read-out reminder for #662 and the daily issue watcher) and should
be disabled.

The open work stops. The Gemma trial (#662) needs no read-out: the measurement
above is model-independent, since the cost is on Claude's side. The tracking
epics (#663, #574), the recipe follow-ups (#573), the seven calibration-record
PRs and the commit-message scope PR (#675) become moot, and #623's monthly
audit no longer has a purpose. Each should be closed with a pointer here.

The trigger eval set changes with the description: writing tasks, including
"implement this, then commit" requests, move from trigger to no-trigger, and
the large-input queries stay as triggers.

This is a breaking change for anyone using the archived recipes. Before
v1 the release bumps the minor version.

The repository is a candidate for archiving once this ships. The skill can
stay installed for privacy-bound large inputs; for anything else, a Haiku
subagent is the cheaper and likely better tool, and nothing in this
repository needs further development to support it.

## When to look again

The experiment is closed on today's numbers, not on principle. Each signpost
below names what would have to change; the measurement scripts used here
(transcript-based net cost, draft survival, prefill from the server log) are
described in `docs/learnings.md` so a future read uses the same method.

| Signpost | Today | Worth a new look when |
|---|---|---|
| Claude-side overhead per delegation (brief, read-back, verdict) | about 520 tokens per call, about 300 of them output | it falls below a fifth of the fresh input it keeps out of context, the output-to-input price ratio |
| A harness hook that summarises tool output before it enters context | `PostToolUse` `updatedToolOutput` is documented but reported unreliable for Bash | it reliably replaces Bash output, so a local summariser runs with no brief from Claude at all; this is the strongest revival trigger |
| Effective context of a local model that fits in about 30 GB | NoLiMa under 1k for Gemma 3 27B; RULER 64k for Qwen3-30B-A3B | a NoLiMa-style effective length of 32k or more, so chunking stops being mandatory |
| Prefill on this machine | about 3,000 tokens/s to 32k, about 1,300 above | about 5,000 tokens/s at 32k and beyond, so a 100k-token input reads in under 20 s; Apple reports 3.5-4x TTFT gains on M5-class GPUs |
| Drafts shipped as-is on a writing recipe | 2-20% a week | 60% or more on a held-out set, the only case where short-output delegation could pay back the brief |
| Cloud alternative for non-private inputs | Haiku 5.5 at $0.10 / $0.50 per MTok | a measured comparison on the same chunks shows the local model matching it, or cloud prices or usage limits rise enough that input-heavy work is rationed |
| Policy | none | content that must not leave the machine (work data, offline work) arrives in volume |

## Alternatives considered

Keep everything and tune further. Rejected: five template spikes produced no
replay ACCEPT (2026-09-27), six of the seven calibration records still open
as PRs are inconclusive replays, and the shipped-as-is rate did not rise
across a month of daily calibration. The cost sits in the brief and the verdict, which recipe
wording cannot reach.

Archive the repository outright now. Deferred to the maintainer: the
large-input shape has a measured positive balance and published support, and
keeping it costs one narrowed skill and three recipes.

Switch the prose tier and read out #662 first. Rejected as unnecessary: a
better local model changes the drafts, not the Claude-side cost, and the
signposts above already say which model property would matter.

## References

- Anthropic, "How we built our multi-agent research system", 2025-06-13: agents use about 4x and multi-agent systems about 15x the tokens of chat. https://www.anthropic.com/engineering/multi-agent-research-system
- Anthropic, "Building effective agents", 2024-12-19: find the simplest solution and add complexity only when needed. https://www.anthropic.com/engineering/building-effective-agents
- Anthropic, "Effective context engineering for AI agents", 2025-09-29: subagents return a condensed 1,000-2,000 token summary. https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- Anthropic pricing and prompt-caching docs, accessed 2026-10-18: Opus 5.5 $4 input, $0.20 cache hit, $20 output per MTok; Haiku 5.5 $0.10 and $0.50; cache reads 0.1x base input, 0.05x on the 5.5 models. https://platform.claude.com/docs/en/about-claude/pricing and https://platform.claude.com/docs/en/build-with-claude/prompt-caching
- Claude Code docs, subagents (a `model: haiku` subagent for log and file flooding) and hooks (`updatedToolOutput`), accessed 2026-10-18. https://code.claude.com/docs/en/sub-agents and https://code.claude.com/docs/en/hooks
- Narayan et al., "Minions: Cost-efficient Collaboration Between On-device and Cloud Language Models", 2025-02-21, and the Hazy Research post of 2025-02-24. https://arxiv.org/abs/2502.15964 and https://hazyresearch.stanford.edu/blog/2025-02-24-minions
- Chen, Zaharia and Zou, "FrugalGPT", 2023-05-09: up to 98% cost reduction from cascades, measured on per-query API pricing with no orchestrator brief. https://arxiv.org/abs/2305.05176
- Dekoninck, Baader and Vechev, "A Unified Approach to Routing and Cascading for LLMs", 2024-10-14: model selection must stay negligible next to model computation. https://arxiv.org/html/2410.10347
- Hsieh et al., "RULER", 2024-04-09, with the results table at https://github.com/NVIDIA/RULER. https://arxiv.org/abs/2404.06654
- Modarressi et al., "NoLiMa", 2025-02-07. https://arxiv.org/abs/2502.05167
- Liu et al., "Lost in the Middle", 2023-07-06. https://arxiv.org/abs/2307.03172
- Chroma, "Context Rot", 2025-07-14. https://www.trychroma.com/research/context-rot
- Apple Machine Learning Research, "Exploring LLMs with MLX and the Neural Accelerators in the M5 GPU", 2025-11-19: 3.3-4.1x TTFT over M4 on a 4,096-token prompt. https://machinelearning.apple.com/research/exploring-llms-mlx-m5
- houtini-lm, a practitioner MCP server delegating to local models: tool-call overhead of about 250 tokens "is roughly the size of the answer" on small tasks. https://github.com/houtini-ai/houtini-lm
