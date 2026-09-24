# ADR 0031: Agent frameworks and critic loops were measured and not adopted

Status: accepted.
Date: 2026-09-16

## Context

The two reply recipes are the weakest in the library. Over the thirty days
to 2026-09-16, `maintainer-reply` had 133 tracked delegations with 1 kept
as-is and 47% usable (kept plus scaffold), and `maintainer-review-reply` had
75 with 0 kept and 48% usable, while `commit-message`, `github-issue-body`
and `pr-review-reply` sit at or above 90% usable. The question put was
whether expressing a delegation as a flow, with pydantic-ai (validators,
retries, structured output, evals) or with docker agent (YAML-defined
multi-agent teams), would lift them, and whether either would make the skill
easier to distribute.

ADR 0001 set the runtime at two bash scripts and one request per
delegation; the wrapper has since added two bounded extras, a 1-token
preflight canary on recipe calls (#110) and exactly one regeneration after a
failed check (#384), and nothing that cycles. ADR 0018 (fan-out ensemble) and
ADR 0019/0020 (verify and escalate) had already recorded the property of this
backend that matters:
greedy decoding is deterministic and the failures are systematic, so asking
the same model again reproduces the defect. Those were bash experiments; this
one used the frameworks themselves, on real cases, so the finding could not
be attributed to the harness.

## Investigation

A spike on branch `worktree-spike-agent-frameworks` (throwaway code, not to
be merged; report in `spikes/agent-frameworks/REPORT.md` there) recovered 26
real delegations from 2026-09-01 onward with their exact inputs, the stored
draft, the verdict and the reply the maintainer actually posted (21 of 26),
and ran every arm on the prose tier's model, `Qwen3.6-35B-A3B-8bit` on
`mlx_lm.server`, temperature 0, thinking off, which is what `delegate.sh`
sends. Arms: the wrapper itself; pydantic-ai with input-only validators
raising `ModelRetry` and two conversational retries; structured tool output
with field validators; a draft, critic, revise pipeline with the same model
and with `Qwen3.8-27B-8bit` as critic; a three-round critique-and-revise loop
in one conversation; docker agent single agent, `force_handoff` chain and a
model-driven sub-agent loop, first with the model's thinking on (docker agent
cannot switch it off) and then with the server defaulting it off; the plain
prompt with thinking on; and `Qwen3.8-27B-8bit` as drafter, to separate the
model from the flow. Two scorers: deterministic checks mirroring the recipe
rules against the shipped reply, and a blind grade from 1 to 5 by a stronger
model with arm names hidden (three passes, 291 grades).

Findings. No flow lifted either recipe above the wrapper on either scorer;
every Qwen3.6 arm graded between 2.4 and 2.6 out of 5 with 0 to 12% of
replies one edit from postable, which is where the stored drafts sit. The
validator's conversational retry fixed 3 of 13 flagged cases and left 10 with
the same defect. Structured output enforced the shape and nothing else. The
three-round loop stopped clean once in 26 cases, ran to exhaustion on the
rest at seven calls per reply, oscillated on the deterministic count and in
length, and left 13 of 26 clean, the same as the first draft. The docker
agent model-driven loop made zero critic calls on real prompts in 8 of 8
cases; on a one-line prompt the same YAML did transfer, so the local model
ignores the orchestration instruction when a real task is in front of it.
Thinking on cost a median of two minutes per call and returned nothing on
half the cases within 8192 tokens. The only lift came from the model:
`Qwen3.8-27B-8bit` as drafter graded 4 or better on 25% of cases against 6%
and halved the fact-turned-into-question failures, at six times the latency.
The grader's most frequent defects were a missing verdict, facts echoed back,
and asking the reader to confirm what the facts state: judgment, which no
check, schema or same-model critic supplied.

## Decision

The runtime stays two bash scripts and a bounded number of requests per
delegation: the preflight canary, one generation, and at most one retry. No
agent framework, structured-output mode, critic stage, ensemble or multi-round
loop is added for the reply recipes. The lift is sought where the evidence points:
making the judgment failures visible to the calibration loop, cutting the
retry where it is measured not to work, moving the recipe's judgment sentence
to the caller, and measuring a bigger active-parameter model on the existing
`premium-general` tier. Those are milestone "Reply recipes: visible failures,
then a lift" (#513 to #518) and their goals are in `ROADMAP.md`.

## Consequences

A same-model critic loop is not a lever on this backend and is listed as out
of scope in `ROADMAP.md`. This decision is revisited only on a new lever: a
model whose judgment on these tasks is measurably different, a narrower task
definition where the model no longer has to derive the verdict, or a consumer
who needs docker agent as a zero-install runner, which becomes viable only
once docker agent can send `chat_template_kwargs` to custom endpoints (the
fix point is the thinking switch in its OpenAI client; until then every call
carries the model's full reasoning). pydantic-ai fits this codebase's loop
semantics if a framework is ever wanted for maintenance rather than quality;
docker agent's genuine contribution would be distribution, not quality.

## Alternatives considered

Adopting pydantic-ai for the check-and-retry logic alone: shorter and typed,
but it adds a Python runtime to a skill installed by `npx skills add` and a
port of the draft capture, feedback, hook and metrics path, with no measured
quality gain. Adopting docker agent pipelines: at the wrapper's speed once
thinking is off, and graded the same; a fixed one-pass chain with no
deterministic way to cycle. Keeping the spike harness on main as an eval
suite: rejected under the lean-core reset's principle of not adding gates;
the input capture (#516) is what makes a future eval buildable from the
corpus without transcript mining.

## Amendment, 2026-09-19: a replay harness is kept

The last alternative above was rejected too broadly. What the lean-core
principle protects is what a consumer has to take in, and what the loop in
`docs/self-improvement-loop.md` lacked was not a gate on PRs but a
measurement a session could take in minutes. Online, the agent's verdicts
need about 134 tracked delegations per arm to distinguish a fifteen-point
lift in usable rate at a one-sided 5% test with 80% power, which at the
reply recipes' eight to ten calls a day is two to three weeks per edit; the
procedure could rank evidence but never confirm a fix, and the 2-hourly
session that was meant to run it had been dead since 2026-08-27 without
anyone noticing. Offline, the same property this ADR relied on cuts the
other way: greedy decoding is deterministic, so re-rendering a stored case
under two templates is a paired comparison with no sampling noise, and six
wins to no losses is already p = 0.016 on a sign test.

So a replay harness is kept, as maintainer tooling and not a CI gate. Every
recipe call stores its structured inputs (the piped stdin, each `--var`, the
positional prompt) as `<stem>.inputs.json` beside the rendered input, under
the same cap, retention and opt-out, and carries the template's content hash
on the row as `template_sha`. `scripts/replay-recipe.sh` reads the cases the
corpus already holds (a delegation with its inputs, a verdict and the shipped
text, the draft itself when the verdict was kept), re-renders them through
`delegate.sh` under the live template and a candidate, scores each output
against the shipped text on seven columns (the wrapper's failed checks,
supplied anchors dropped, supplied anchors carried past the shipped text,
anchors invented, piped sentences echoed, a shape mismatch and a length
flag; the third and the last were added on 2026-09-20 when the first gated
pass found the restatement defect invisible to the other five and its cure
charged as dropped), and prints ACCEPT, REJECT or INCONCLUSIVE from a sign
test over per-case wins, with a rise in failed checks or length flags
holding the verdict at INCONCLUSIVE. `self-improve.sh` splits a recipe's outcomes by template hash,
which is the post-merge read and the revert signal. Nothing in the installed
runtime changed shape: one request, at most one retry, no critic. The decision
above stands for the runtime; this amendment is about how the loop measures
its own edits, and it does not revive the spike's Python harness, whose
maintainer-reply cases cannot be replayed under the post-#517 template in any
case because their `lead` values were never stored.
