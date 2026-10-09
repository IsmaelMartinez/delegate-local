# ADR 0034: A per-model report card decides whether a new local model is worth a trial

Status: accepted.
Date: 2026-10-09

## Context

Open models arrive every few weeks, and the question for each is the same:
would it serve this skill's recipes better than the resident prose model,
and can a smaller one run cooler on the laptop? Heat is the binding
constraint here. It is mostly felt while the skill itself is being developed,
when replays and calibrations run batches against the local server, and
it is why the heat gate exists (#646, #657).

Answering that question for one model took most of a day on 2026-10-07,
when Qwen3.6-35B-A3B, Qwen3.8-27B and Gemma 4 26B-A4B were compared by hand:
a paired replay per busy recipe, a blind judge over the edited cases, a
grounding calibration, the trigger gate and a speed bench, each from a
script in the data dir's `spikes/`. `docs/model-swap.md` (#658) turned that
into a nine-step runbook. Steps 2, 4, 5 and 6 are commands a script can run;
step 3, the blind judge, needs a judge outside the two arms.

Public sources do not answer the question. llmfit 1.1.16 ranks models by
hardware fit and a quality estimate that tracks size: it rates gpt-oss-20b at
61.5 and Gemma 4 12B at 93.5, and neither the resident Qwen3.6-35B-A3B nor
Gemma 4 26B-A4B is in its database. The Vectara hallucination leaderboard
measures grounded summarisation, the public task closest to this skill's,
and it is useful for a shortlist (Gemma 4 26B-A4B at 5.2%, Qwen3.5-35B-A3B at
10.5%), but it lists neither Qwen3.6 nor Qwen3.8 and does not run these
recipes. Artificial Analysis's hallucination board measures recall of facts,
not faithfulness to a supplied input.

Heat follows active parameters, not total size. Every generated token reads
the active weights once and every prompt token is computed over them, so a
dense 9B does three times the work per token of a 3B-active mixture of
experts. On 2026-10-07 the dense Qwen3.8-27B was three times slower per call
than Qwen3.6-35B-A3B (12.2 s against 3.8 s), and the heat gate paused 18 of 20
of its replay calls. Watts need `powermetrics`, which needs sudo, and `top`'s
per-process POWER column mirrors the server's CPU share: on 2026-10-09 it read
65 to 70 during a 4.9 s call while ioreg's Device Utilization read 75 to 89
percent. ioreg is readable without sudo, and the heat gate already uses it.

The candidate also has jobs besides writing. An `mlx_lm.server` swaps models
rather than stacking them (2026-10-08), so the verify tier moves with the
prose tier (#676). The prose model therefore also answers `decide.sh`'s
lettered questions, for the draft verifier and for the trigger gate a
`SKILL.md` edit must pass.

## Decision

`scripts/eval-model.sh --model ID [--base URL]` produces one report card for a
candidate served on its own port, against whatever the prose tier currently
resolves to (the champion), measured on this skill's own work, and ends with
one verdict. The candidate is always asked for by its exact id, so it cannot
resolve to another cached model and the shared server is never asked for
it; a `--base` that is the champion's server is refused unless `--same-server`
says the provider holds both models at once. The champion is asked for by
exact id in the cost, grounding and trigger steps; the replay resolves it
through each recipe's tier, as a delegation does, and counts a case that
ran on any other model as an error. The four steps run in the order below,
the long one last.

The cost step sends the rendered inputs of the newest delegations to both
servers, alternating which goes first, with `delegate.sh`'s request. It
reports seconds, prompt and output tokens per call, and GPU busy-seconds per
call: ioreg's utilisation above the idle level read before the first call,
each sample counted once, for the call that was running. Those are summed
over the prompts both models answered, so a model that fails the long
prompts is not averaged over the short ones. It also counts the calls that
failed (a transport error or an empty answer), ran to `max_tokens` or carried
a reasoning trace although the request turned thinking off. Busy-seconds are
the cost measure, with wall seconds where ioreg reads nothing. The cost step
is measured fresh on both arms every run, because load and heat differ
between runs.

The grounding step runs `verify-draft.sh --calibrate --dry-run` on the
labelled set in the data dir, which records AUROC and the threshold in the
verifier role. The trigger step runs `eval-skill-triggers.sh --decide` on the
skill's own description. Both are cached per model and per hash of what they
read, so a champion measured once costs nothing again.

The replay step runs `replay-recipe.sh --candidate-model --edited-only` on
the busiest recipes. `--edited-only` is new: a model comparison already
leaves kept cases out of its sign test (#656), so generating them was heat
for nothing. The replay is the long step, so it runs last, and not at all
once the cost step has stopped the candidate as a writer (over the cost
bar, or empty answers). A judging failure still lets it run: a model that
writes well and judges badly could take the prose tier with the verifier on
another model's server, and the card should show which it is.

The verdict is one of four:

- STOP when any of these holds. A recipe's replay is a REJECT (the one-sided
  sign test at p < 0.05 against the candidate). The trigger gate fails its
  own bar, recall and negative precision of at least 0.9, or cannot score on
  the candidate at all. Grounding AUROC is more than 0.05 under the
  champion's, or the verifier cannot score half its rows because the
  candidate opens a lettered question with neither letter. The candidate
  fails more calls than the champion. Its cost per call is over 1.5 times
  the champion's.
- INCONCLUSIVE when no bar stopped it but a step that could have did not run,
  through an error or `--skip`.
- TRIAL when it is cheaper, at most 0.9 times the champion's cost, or better
  (a replay ACCEPT, or AUROC at least 0.05 over), and its failed checks and
  length flags did not rise across the replay. That last condition is the
  replay's own rule, under which such a rise holds back an ACCEPT.
- HOLD otherwise: level with the champion and no cheaper, or ahead with the
  checks or length flags rising, so a switch would buy nothing or would buy
  it with worse output.

Each bar has a reason. 0.05 AUROC is about 1.7 standard errors at 60
positives and 60 negatives near 0.9, and it sits inside the spread the
2026-10-07 models showed (0.882 to 0.972). 1.5 times the cost means a
candidate that runs the laptop half again as hot on every delegation; the
dense 27B, at three times, is the case it is for. 0.9 asks a switch to buy at
least a tenth off the heat. A model that cannot answer a lettered question
would break the verifier and the trigger gate wherever the verify tier
follows prose; the trigger gate stops at its first unscorable query, so one
is enough there, while the verifier only loses the drafts it cannot score,
so it stops the card at half. A transport error or an empty answer is a
failed delegation, since `delegate.sh` exits on either.

A TRIAL verdict leads to the runbook's blind judge (step 3) and then the live
trial (step 7). The judge stays manual because it needs a judge that is
neither arm; the card names the edited cases and the replay cache holds both
arms' outputs.

## Consequences

Trying a new model is now one command. The first full card against a
champion took 32 minutes on 2026-10-09: 232 replay calls, of which 112 generated
the champion's own outputs. Those are cached like its grounding and trigger
results, so the next candidate pays only for its own calls. The runbook keeps its steps as
the explanation of what each number means. The card leads it.

The first use, on 2026-10-09 (#679), added three checks no stubbed test would
have suggested: the reasoning trace, the empty answer and the lettered
question. LiquidAI's LFM2.5-8B-A1B, at about 1.5B active and the
coolest model on paper, ignores `enable_thinking:false`. It reasoned before
all eight answers, wrote 2329 tokens a call against the champion's 205, came
back empty on two (one after 2938 tokens of reasoning, one at the 4096-token
cap), and opened every lettered question with `<think>`. Its card stopped
on cost (2.28 times the champion's GPU time), on the empty answers and on
the lettered questions, without running the replay. Active parameters
predict heat only for a model that answers in the shape `delegate.sh` asks
for.

IBM's Granite 4.0-H-Tiny, at about 1B active, showed both sides of the heat
argument. It used 0.44 and 0.57 times the champion's GPU time per call on two
runs and answered cleanly, but the replay rejected it on four of six recipes
(1 win to 17 losses on commit-message) with five times the champion's
invented anchors (72 against 14). Its grounding AUROC was 0.519, and it
answered yes to every trigger query. LiquidAI's LFM2-24B-A2B, at about 2B
active within 24B, failed the other way. It cost 0.44 times the champion's
GPU time but wrote 85 tokens a call against 215, dropping the facts the
shipped text kept (205 against 31 on github-issue-body), and the replay
rejected it on five of six recipes. At one to two billion active parameters
the heat saving costs the writing, by invention or by omission.

The card is only as good as the corpus behind it. The replay needs edited
cases whose inputs are still stored (drafts are kept 14 days). The grounding
set lives in the data dir and is not shipped, so on another machine that step
is reported as not measured and does not gate. The champion runs on the
shared server, where another session's calls queue ahead of its cost calls,
while the candidate has a server to itself. So outside load can only make
the candidate look cheaper. The heat gate waits for a busy GPU before the
first call, and runbook step 1 says to check for other sessions; a cheaper
verdict close to the 0.9 bar deserves a second run on a quiet machine.

This is revisited when watts become readable without sudo, when a model
needs a request shape `delegate.sh` does not send (a reasoning toggle other
than `enable_thinking`, which would be a `delegate.sh` change first), or when
the replay's edited cases thin out enough that the sign test cannot separate
a regression.

## Alternatives considered

Choosing from public leaderboards or llmfit: rejected as the decision, kept
for the shortlist. Neither measures these recipes, and llmfit's quality score
does not separate models of one size.

Keeping the runbook manual: rejected. It costs a day per model, and its
scripts lived outside the repo, where they drift from the code they measure.

Automating the blind judge with an API model: not now. It needs a key and
costs money per run, and the session agent can grade the listed cases
(ADR 0030).

Replaying kept cases too: rejected. A model comparison does not count them,
so they were GPU time for no signal.

Caching the cost step per model, as grounding and the trigger gate are
cached: rejected. Thermal state and other sessions' load change between runs,
so a cost ratio is only fair when both arms run back to back.

Reading heat from `top`'s POWER column: rejected, measured to mirror the
server's CPU share rather than the GPU's work.
