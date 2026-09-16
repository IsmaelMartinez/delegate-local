# Would pydantic-ai or docker agent lift the weak recipes?

Spike, 2026-09-15 to 2026-09-16. Everything under `spikes/agent-frameworks/` is throwaway: it exists to answer this question, not to ship.

## The question and its scope

The metrics for the thirty days to 2026-09-15 put two recipes far below the rest. `maintainer-reply` ran 134 times with 1 draft kept as-is, 51 used as scaffold and 60 thrown away; `maintainer-review-reply` ran 73 times with 0 kept, 22 scaffold and 34 thrown away. `pr-description` is middling at 34 runs, 6 kept, 18 scaffold, 9 thrown away. `commit-message`, `github-issue-body` and `pr-review-reply` are at or above 90% usable and were left alone, as asked. The question was whether expressing a delegation as a flow, either with pydantic-ai (validators, retries, structured output, evals) or with docker agent (YAML-defined multi-agent pipelines), would make the weak recipes better or cheaper, and which areas of the skill such a change would suit.

## What was measured

The evaluation set is 26 real delegations from 2026-09-01 onward, recovered from Claude Code session transcripts with the exact piped facts and `--var` values, paired through the metrics file with the stored draft, the agent's verdict and reason, and the reply the maintainer actually posted (21 of the 26 have one). Eighteen are `maintainer-reply`, eight are `maintainer-review-reply`; none of the corpus's rows for either recipe carries a kept verdict, so the set has no hits to include. The set lives outside the repository at `~/.local/share/delegate-local/spikes/` because the facts are private review notes.

Every arm ran the recipe's own rendered prompt against the prose tier's model, `mlx-community/Qwen3.6-35B-A3B-8bit` on `mlx_lm.server`, at temperature 0 with thinking off, which is exactly what `scripts/delegate.sh` sends. The arms were: the bash wrapper itself with metrics switched off (A0-bash); the same prompt through pydantic-ai with no validator, as a harness sanity check (A0-py); pydantic-ai with output validators computed from the inputs alone that raise `ModelRetry` naming the offending sentences, two retries, the retry carrying the whole conversation (A1-validate); pydantic-ai structured output through a tool call, with field validators for the recipe's shape and deterministic assembly of handle, opener, statement, asks and sign-off (A2-struct); a draft, critic, revise pipeline in plain Python around three agents, once with the same model as critic and once with `Qwen3.8-27B-8bit` as critic (A3-critic-same, A3-critic-27b); the plain prompt on `Qwen3.8-27B-8bit` as drafter, to separate the model from the flow (A5-qwen3.8-27b); the plain prompt with thinking switched on, because the docker agent path cannot switch it off (A6-think, eight cases); and docker agent itself, one agent on the MLX endpoint and a three-agent `force_handoff` pipeline (A4a-single, A4b-pipeline, on a subset because each call costs minutes).

Two scorers read every output. The deterministic one mirrors the recipe's rules: two or more piped sentences reproduced verbatim, output at or above 0.8 of the facts' length, a question count different from the shipped reply's, anchors the maintainer kept that the candidate dropped, numbers or issue references absent from the input, a numbered list where the maintainer wrote prose or the reverse. Its "ship" column is the conjunction; "core" ignores the two length rules, because 6 of the 21 shipped replies break one of them (the maintainer writes over the ask's word limit, and two of five shipped review replies are longer than their facts, which the recipe's 0.8 ratio check would have rejected). The second scorer is a blind grade from 1 to 5 by a Claude Opus grader that saw the facts, the vars, the shipped reply and the candidates shuffled under letters, never the arm names; 5 means postable in place of the reference, 4 one small edit away, 3 a usable scaffold, 2 mostly a rewrite. ADR 0030's objection to a local-model judge does not apply here, since the grader is the stronger model, not the weaker one.

## Results

`maintainer-reply`, 18 cases, 16 with a shipped reply to grade against. "questions" and "anchors" are the number of cases failing those two rules; "kept" is the mean share of the anchors the maintainer kept that the candidate also carried.

| arm | ship | core | questions | anchors | kept | grade mean | grade ≥4 | p50 latency | requests |
|---|---|---|---|---|---|---|---|---|---|
| stored draft (what the wrapper produced at the time) | 1 | 1 | 13 | 13 | 0.54 | 2.56 | 12% | | |
| A0-bash | 1 | 1 | 13 | 11 | 0.58 | 2.50 | 6% | 3.1 s | 1 |
| A0-py | 1 | 1 | 13 | 14 | 0.43 | 2.50 | 6% | 2.3 s | 1 |
| A1-validate | 2 | 2 | 11 | 14 | 0.43 | 2.56 | 12% | 3.4 s | 1.6 |
| A2-struct | 1 | 1 | 13 | 11 | 0.56 | 2.50 | 0% | 7.2 s | 2.2 |
| A3-critic-same | 0 | 0 | 12 | 11 | 0.54 | 2.56 | 6% | 16.5 s | 3 |
| A3-critic-27b | 2 | 3 | 10 | 7 | 0.71 | 2.38 | 12% | 42.0 s | 3 |
| A5-qwen3.8-27b | 3 | 4 | 7 | 12 | 0.56 | 2.75 | 25% | 17.3 s | 1 |
| A6-think (8 cases, 6 graded) | 1 | 1 | 4 | 7 | 0.19 | 1.83 | 0% | 120.9 s | 1 |
| A4a-single, docker agent (6 cases, 4 graded) | 1 | 2 | 3 | 1 | 0.80 | 2.25 | 0% | 110.0 s | 1 |
| A4b-pipeline, docker agent (4 cases, 2 graded) | 2 | 3 | 1 | 0 | 1.00 | 3.00 | 50% | 304.7 s | 3 |
| shipped reply | 12 | 16 | 0 | 0 | 1.00 | 5 by definition | | | |

`maintainer-review-reply`, 8 cases, 5 graded. "echo" and "ratio" are the number of cases failing those rules.

| arm | ship | core | echo | ratio | grade mean | grade ≥4 | p50 latency |
|---|---|---|---|---|---|---|---|
| stored draft | 0 | 2 | 4 | 7 | 3.00 | 40% | |
| A0-bash | 1 | 3 | 3 | 6 | 2.80 | 20% | 7.1 s |
| A0-py | 1 | 2 | 4 | 6 | 3.00 | 20% | 3.7 s |
| A1-validate | 1 | 3 | 3 | 6 | 3.00 | 40% | 11.1 s |
| A2-struct | 2 | 2 | 5 | 5 | 2.80 | 20% | 14.4 s |
| A3-critic-same | 2 | 4 | 1 | 6 | 3.00 | 20% | 20.0 s |
| A3-critic-27b | 1 | 3 | 3 | 6 | 3.20 | 20% | 44.9 s |
| A5-qwen3.8-27b | 1 | 1 | 4 | 6 | 3.00 | 40% | 23.4 s |
| shipped reply | 3 | 5 | 0 | 2 | | | |

Across 168 blind grades no candidate from any arm earned a 5; 14% earned a 4, 37% a 3, 48% a 2. Nothing any flow produced would have been posted unedited, which is also what the corpus says about the wrapper.

## What the arms did

The validator loop fired on 13 of 26 cases and fixed 3 of them on a retry; the other 10 ran out of both retries with the same violation still present (echo, length, or a supplied fact turned into a question). The retry carried the full conversation and a precise complaint, so this is a stronger repair signal than the wrapper's appended notice, and it still did not move the model. That is the same finding ADR 0018 and 0019 recorded for this backend: greedy decoding is deterministic and the failures are systematic, so re-asking the same model produces the same defect.

Structured output enforced the shape and nothing else. The tool call worked on `mlx_lm.server` (verified directly with `tool_choice: required`), the field validators bounced statements containing a question mark and asks without one, and 12 of 26 cases ran out of retries on that bouncing; the assembled replies carried the same missing verdicts and confirm-questions as the text arms, and the grader gave the arm the lowest share of 4s on `maintainer-reply`. The recipe's prompt, which ends with "output only the reply text", also fights the tool mode on a long rule-heavy input.

The critic pipelines produced plausible labels and noisy findings. The same-model critic reported 18 dropped anchors on one case, and its revisions grew the draft by 25% on average; the 27B critic kept the most anchors of any arm (0.71 against 0.54 for the stored draft) but grew the drafts by 63% on average, in one case from 414 to 1784 characters, took 20 to 90 seconds per critique, and ended with the lowest grade mean of all on `maintainer-reply`. On `maintainer-review-reply` the critic did cut verbatim echo from four cases to one, which is what it was told to look for, while the length ratio failed on six of eight in every arm including that one.

The model moved more than any flow. `Qwen3.8-27B-8bit` as drafter halved the fact-turned-into-question failures (7 against 13), shipped 3 of 18 on the deterministic scorer against 1, and earned a 4 on 25% of graded cases against 6%, at a median of 17 seconds against 3, since a dense 27B model decodes far slower than a 35B model with 3B active parameters. It is a small lift, not a fix.

Thinking on, which is what docker agent forces on this stack, cost a median of two minutes per call, and four of eight calls returned nothing at all within 8192 tokens.

Docker agent v1.139.0 does what its documentation says: `docker agent run --exec --json` runs headless and emits NDJSON events with reasoning and answer chunks separated per agent, `force_handoff` chains drafter, critic and reviser in a fixed order without any model deciding, `structured_output` has a tool mode for local models, and a model block with `provider: openai` and `base_url` reaches the MLX endpoint. What it cannot do is switch Qwen's thinking off: the YAML has no pass-through for `chat_template_kwargs`, and `thinking_budget: none`, a `provider_opts` attempt and a `/no_think` prefix all left the reasoning stream intact (209 to 231 reasoning chunks on a three-word probe). With a 2048-token cap the model spent the whole budget thinking and returned nothing on a real prompt, forty seconds per call; with the cap raised, the single-agent arm's first real case took 155 seconds and 8564 reasoning chunks to produce 702 characters. The Docker Model Runner route with `--reasoning-budget 0` in `runtime_flags` still reasoned, and loading that second 35B copy left the machine with 0.1 GB free, so it was abandoned. The docker agent numbers in the tables above are on a subset for that reason; see the addendum at the end for the final figures.

## What the failures actually are

The grader's notes across all 168 candidates name the same defects the verdict reasons in the corpus name: the verdict is missing (about 30 candidates describe the change and never state the decision), the facts come back as the reply (about 22, several sentence for sentence including head SHAs and the maintainer's private probe counts), the reader is asked to confirm something the facts already settle (about 22), the caller's answers or asks are handed back as questions (about 19, in one case six of eight candidates returned the reporter's own three questions to him), and thanks is missing, generic or credited to the wrong action (about 20). These are judgment calls: which fact is the verdict, which fact is settled, what the contributor did that deserves the thanks. The recipe carries 7,037 characters of rules to compensate, and the maintainer's shipped reply is typically 500 to 800 characters written from the same facts. The task as posed is "be the maintainer", and a local model at this size is not. No validator, schema or critic on the same model supplied the judgment, because the check can say a sentence is a question but cannot say the answer was already in the facts.

## The libraries, as measured

pydantic-ai 2.43.0 installs on this machine's Python 3.14 through `uv run` in seconds (32 packages for `pydantic-ai-slim[openai]`). `OpenAIChatModel` with `OpenAIProvider(base_url=...)` reaches `mlx_lm.server`; the `extra_body` setting carries `chat_template_kwargs` to the server, verified by the latency difference between thinking off and on. Tool-call output, native JSON-schema output and plain text all work against this server. The validator and `ModelRetry` loop is the wrapper's check-and-resend expressed in twenty lines, with a conversational retry instead of an appended notice, but when retries run out the library raises without the last draft, so a port would have to stash it the way the wrapper ships the flagged second generation. `pydantic-graph` is not needed for a fixed draft, critique, revise sequence; the library's own guidance says to use plain Python for that. `pydantic-evals` rendered the same scorers as a per-case table with averages in thirty lines; it is a nicer presentation of what `report.py` does, not new information. Its instrumentation emits `gen_ai.*` spans that overlap the schema the repo's own OTEL exporter already writes. What a port would replace is roughly the five hundred lines of check, autofix and retry logic between `retry_constraint_for` and the metrics row in `scripts/delegate.sh`. What it would cost is a Python runtime in a skill whose entire runtime is two bash scripts by decision (ADR 0001), an install step for every consumer of `npx skills add`, and a rewrite of the draft capture, feedback, boundary-hook and metrics integration around the new call path. No quality was gained in exchange in this spike.

docker agent is a Go binary with a Go SDK and no Python surface, YAML teams, an OCI packaging story, an eval runner that judges with a cloud model by default, and session recording in SQLite. Its pipelines are one-pass DAGs; a loop back from critic to drafter needs LLM-decided handoffs, which is the routing ROADMAP puts out of scope. On this stack every call carries the model's full reasoning, so a three-agent pipeline is three multi-minute calls where the wrapper spends three seconds, and the only remedy is server-side (starting `mlx_lm.server` with a chat-template default that disables thinking), which the wrapper does not need.

## Where each would fit, and how confident

For `maintainer-reply` no framework flow lifted quality, and the confidence is high: 18 real cases, seven arms, two independent scorers that agree, and the same conclusion two prior ADRs reached. Routing the recipe to a bigger dense model gives a small lift at six times the latency, with medium confidence at this sample size. What would help is a narrower task: have the calling agent write the verdict or thanks sentence itself and delegate only the fact-carrying prose, or stop delegating replies whose value is the maintainer's decision.

For `maintainer-review-reply` the ordering between arms is within noise (five graded cases), but the echo-and-length failure is untouched by every arm including the critics, and two of the five shipped replies would themselves fail the recipe's ratio check, so the rule is measuring the wrong thing for this recipe. Low confidence in any ranking, high confidence that a flow is not the lever.

For `pr-description` nothing was measured here. Its recorded failures are fabrication (invented task lists, headings and references), which is the one shape where a schema built from the `recent_prs` input could constrain the output. That is a plausible but untested fit; it would need its own spike of about twenty cases before believing it.

The classification-shaped recipes (`bulk-classify`, `ci-log-triage`, `summarise-issue`) are the natural home for schema output, but they had no volume in the last thirty days, so there is no problem there to fix. The three recipes at 90% usable stay as they are.

Where pydantic-ai would genuinely help is maintenance, not quality: the check and retry logic and the calibration measurements would be shorter and typed in Python, and `pydantic-evals` would give the self-improvement loop a regression table over the drafts-and-finals corpus. That only pays if the skill leaves bash for other reasons.

## Recommendation

Do not migrate. Neither library changes what the local model writes, and the docker agent path is a net loss on this hardware until the server disables thinking by default. Keep the two bash scripts, and treat the two reply recipes as a task-definition problem: either narrow what is delegated to the fact-carrying prose the model handles, or move those two recipes to a bigger dense model in `pick-model.sh` and accept the latency for a modest gain, or stop delegating them. If a framework is ever wanted for its own sake, pydantic-ai is the one that fits this codebase; docker agent is not, for this stack.

## Addendum: docker agent arms, final figures

With the token cap raised to 16384 the single docker agent completed all six of its cases, at a median of 110 seconds and between 4.5k and 13k reasoning chunks per call, and its outputs kept anchors better than any thinking-off arm (0.80) while still turning a supplied fact into a question in half the cases; the blind grader put its four graded replies at a mean of 2.25 with none at 4. The three-agent `force_handoff` pipeline ran exactly as documented, drafter then critic then reviser with every stage's text captured per agent, at a median of 305 seconds per reply and 17k to 27k reasoning chunks. On its four cases the deterministic scorer gave it the best numbers of any arm (2 shipped, every kept anchor present, one question failure), but reading the four replies shows why: the critic's dropped-anchor list pushes every fact back in, so three of the four are single run-on sentences of 100 to 150 words that end by asking the reader to confirm the maintainer's own conclusion, and the one good reply is the shortest case in the set. The two graded replies scored 4 and 2. The second grading pass re-graded the stored drafts at 2.44 against 2.56 in the first pass, so the two passes are comparable. None of this changes the recommendation: a five-minute reply that still needs the judgment edited in is not a delegation the wrapper's three-second draft-and-fix loop loses to.
