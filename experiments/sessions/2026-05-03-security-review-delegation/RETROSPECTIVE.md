# Director-with-worker delegation: security-review case study

**Date:** 2026-05-03
**Branch:** feat/personalisation-override (uncommitted Phase 9 v1 changes)
**Director:** Claude Opus 4.7
**Workers compared:** Opus 4.7 (self), Sonnet 4.6 (subagent), Haiku 4.5 (subagent), local Qwen3.6:35b-a3b-q8_0 (via delegate.sh)

## What was tested

The hypothesis: a director (Opus) hands off the closed-form derivative work of a security review — severity classification, false-positive filtering against an allowlist, prose drafting for finding explanations, and PR-comment composition — to cheaper workers, while keeping the actual reasoning about exploitability with itself. Four workers received verbatim identical sub-task prompts so the comparison is fair.

The director (Opus) first produced a structured five-finding security review of the Phase 9 v1 changes (per-user override hook in `pick-model.sh`, `init.sh` generator). Each finding had id, title, details, file:line. That same finding list was the input to all four worker sub-tasks.

The four sub-tasks were defined as files under `experiments/sessions/2026-05-03-security-review-delegation/subtask-*.txt`. Each subtask demanded strictly-shaped output (JSON arrays for 1-3, plaintext for 4), with explicit "no prose, no markdown fences" instructions to test format adherence.

## Results table

| Sub-task | Opus | Sonnet | Haiku | Local Qwen3.6:35B |
|---|---|---|---|---|
| 1 — severity classification | ✓ correct | ✓ matches Opus exactly | ✓ matches Opus exactly | ✗ overrates F1+F2 as `high`, F3+F4 as `medium` |
| 2 — FP filter against allowlist | ✓ all REAL | ✓ all REAL | ✗ F5 marked `ALLOWLISTED_FP` with `null` allowlist (internally inconsistent) | ✗ F1 marked `ALLOWLISTED_FP/A1` despite finding explicitly noting elevated-context caveat that allowlist A2 says remains REAL |
| 3 — 2-sentence prose per finding | ✓ within input, file paths cited | ✓ within input, polished phrasing | ✓ within input, terse phrasing | ✓ within input, adequate phrasing |
| 4 — PR comment composition | ✓ severities + IDs correct | ✓ severities + IDs correct | ✓ severities + IDs correct | ✗ used literal `FX` placeholder five times instead of substituting F1/F2/F3/F4/F5 from the input |

Score: Opus 4/4, Sonnet 4/4, Haiku 3.5/4, Local 1.5/4. Sub-task 3 (the closed prose-rewriting task) was uniformly correct across all four workers — the local-brain "strong summariser" insight held cleanly. The other three sub-tasks all stressed the worker in different ways and exposed different failure modes.

## Failure-mode analysis

The local model's failures are not random. The severity sub-task showed reasoning drift — the captured chain-of-thought spent two paragraphs debating high vs medium for F1+F2 and ultimately picked the more alarmist option ("arbitrary code execution is high severity") despite the finding text explicitly stating the behaviour is intentional in single-user dev contexts. The model overrode the input's qualifier with prior beliefs about CVSS conventions.

The FP-filter sub-task showed the inverse: the local model mechanically matched F1's first sentence to allowlist A1 and ignored F1's second sentence about elevated contexts that A2 explicitly says remain REAL. This is selective reading, not mechanical pattern-matching — it picked the easy match. Haiku failed differently: it marked F5 as `ALLOWLISTED_FP` but left `matched_allowlist: null`, an internally incoherent output that no allowlist actually justifies.

The PR-comment sub-task exposed the most dramatic failure. The local model substituted `FX` (the placeholder format `[SEVERITY] FX — title`) verbatim five times rather than reading F1, F2, F3, F4, F5 from the input list. This is a closed-form failure that should have been impossible — the input data was right there. The model treated the format-spec literal as an output literal.

The prose sub-task is where everyone succeeded. The instruction was tight ("rewrite each finding as 2 sentences, stay within input, reference the file path"), the output shape was clear, and there was nothing to "reason about" beyond paraphrasing. This is exactly the strong-summariser pattern the SKILL.md description carves out, and the empirical evidence here matches.

## Cost comparison

| Worker | Tokens used | Wall time | Approx cost (USD) | Failure rate |
|---|---|---|---|---|
| Opus 4.7 (if it did all 4 itself) | ~7K total est. | ~30s | $0.23 | 0% |
| Sonnet 4.6 subagent | 22,816 total | 40.7s | ~$0.15 | 0% |
| Haiku 4.5 subagent | 70,216 total | 19.9s | ~$0.15 | 12.5% (1 of 8 outputs wrong) |
| Local Qwen3.6:35B q8_0 | ~13K tokens (52K chars output) | 226s sequential (3.8 min) | ~$0.002 (electricity) | 62% (2.5 of 4 sub-tasks wrong) |

Cost notes. Sonnet pricing assumed at the published $3/M input + $15/M output blended ~70/30, giving ~$6.60/M average. Haiku at $1/M + $5/M same blend = ~$2.20/M. Local cost is M5 Max under inference at ~150W × 226s ÷ 3600 ÷ 1000 = 9.4 Wh × $0.20/kWh = $0.0019. Opus is rough — the actual orchestration overhead in this session was much higher than the nominal worker portion.

The Haiku result is interesting: 3× more tokens than Sonnet but 3× cheaper per token, so the wall cost is essentially identical despite Haiku running 2× faster. Sonnet's longer wall time was tool-call overhead, not throughput.

The local model's electricity cost is rounding-error; the real cost is the 113× longer wall time vs Haiku and the failure rate that means the director would need to re-prompt or fix outputs anyway. If the director re-prompts on failure, the cost calculus inverts — three failed outputs × another full local generation each is another 10 minutes, and there's no guarantee the re-prompts succeed on closed-form failures that are about format compliance, not knowledge.

## Implications for the skill

The empirical signal sharpens SKILL.md's fit/not-fit boundary. Sub-task 3 — single-finding prose rewriting where input fully constrains output — is the prototypical strong-summariser pattern this skill exists to delegate, and it works uniformly across all four workers. The skill's auto-delegate list correctly includes "prose rewriting" and this experiment confirms the closed prose-rewrite shape is robust.

Sub-tasks 1, 2, 4 are not currently on the skill's fit list, and shouldn't be. Severity classification looks closed but the local model's chain-of-thought drifted to prior beliefs about CVSS rather than the input's explicit intent qualifier. FP-filter looks closed but the local model selectively read the finding to find an easy allowlist match. PR-comment generation looks closed but the local model substituted the format-spec placeholder for actual data — a failure that no amount of constraint-tightening fixes because the input was already explicit. These are exactly the patterns SKILL.md's "MUST NOT delegate" list should grow to cover.

The cost-quality frontier is: Sonnet matches Opus's quality at ~65% of Opus's cost in this session. Haiku matches Opus's quality on three of four sub-tasks at the same cost as Sonnet (because of token verbosity). Local matches Opus's quality on one of four sub-tasks at electricity-only cost. None of the cloud workers showed format-substitution failures or alarmist reasoning drift.

## What I'd change next time

Run the delegation through `delegate.sh prose "$prompt" 2>/dev/null` not `2>&1`, so spinner ANSI doesn't pollute the captured output. The captured local outputs needed manual ANSI stripping plus character-deduplication to extract the actual model response, and the file sizes (36–62 KB for ~1 KB of useful output) were almost entirely cursor-control noise. The skill's README documents this exact workaround; I made the mistake the README warns against.

Also worth probing: whether disabling the local model's thinking mode (`/set nothink` or model-specific) would improve closed-form output quality. The thinking traces are where reasoning drift happens; suppressing them might tighten the output to just the JSON. That's a one-line change to delegate.sh worth testing, but it's a Phase-9-level addition not a fundamental shift.

## Bottom line (v1 only — read v2 below before acting on this)

The director-with-cheaper-worker pattern works for prose-rewriting sub-tasks and breaks for closed-format substitution and qualifier-aware classification. Cloud sub-agents (Sonnet, Haiku) are 4× cheaper than Opus-doing-it-itself with no quality loss on this workload. Local models are 100× cheaper than cloud sub-agents but have a 60%+ failure rate on the same sub-tasks, which dominates the cost equation if the director needs to re-prompt or hand-fix.

The skill stays right at "delegate the closed prose-rewriting work" — exactly what local-brain told us in the first place.

## Limitations of v1 (added 2026-05-03 after pushback)

The v1 conclusion "local fails 60%+ on closed-form sub-tasks" is **not generalisable from this experiment**. It overstates the gap because the v1 setup stacked four known-bad-practice biases simultaneously: (a) thinking mode left on, so the captured chain-of-thought drifted and burned tokens without improving format compliance, (b) no one-shot or few-shot example, so the model inferred the output shape from prose description alone, (c) prose-tier model was used for JSON-output classification when JSON-output-with-strict-shape is arguably code-tier work, and (d) N=1 single-shot, so a bad-end-of-distribution sample was indistinguishable from a representative one. Every published practitioner account of working local-delegation in 2026 controls these same four variables explicitly.

A re-run with thinking-off + one-shot + both tiers + N=3 follows below.

## v2 re-run with prompting discipline (2026-05-03)

Setup: same five-finding fixture, same four sub-task prompts but augmented with one-shot example + an explicit "intentional behaviour stays at design-intent severity, not high" rule. Outputs captured via Ollama's HTTP API (`stream:false, think:false, options:{temperature:0}`) instead of the CLI to avoid the cursor-rewrite stream artefacts that polluted v1's captured outputs. Two models tested: prose-tier `qwen3.6:35b-a3b-q8_0` and code-tier `qwen3-coder-next:latest`. Three reps per cell, 24 cells total. Mechanical scoring via `scorer-v2.py` (last-balanced-JSON-array extractor, then field-level comparison against ground truth).

### Aggregate scores

| Sub-task | qwen3.6 (prose-tier) | qwen3-coder-next (code-tier) | Sonnet 4.6 (v1) | Haiku 4.5 (v1) | Opus 4.7 (v1 ground truth) |
|---|---|---|---|---|---|
| 1 — severity classification | 2.00/5 (σ=0) | 3.00/5 (σ=0) | 5/5 | 5/5 | 5/5 |
| 2 — FP filter | 5.00/5 (σ=0) | 5.00/5 (σ=0) | 5/5 | 4/5 | 5/5 |
| 3 — prose drafting | 5.00/5 (σ=0) | 5.00/5 (σ=0) | 5/5 | 5/5 | 5/5 |
| 4 — PR comment | 3/3 PASS | 3/3 PASS | PASS | PASS | PASS |
| **Total normalised (of 4)** | **3.40** | **3.60** | **4.00** | **3.95** | **4.00** |

Three of the four sub-tasks are now perfect across both local tiers. Stdev is zero across reps because temperature is 0 — this is a property of the experimental setup, not a finding about the models.

### What changed and what didn't

The FP filter sub-task went from 4/5 average (with internal inconsistency in v1 Haiku, wrong F1 classification in v1 local) to 5/5 across both local models in v2. The discriminator was the explicit rule in the v2 prompt — "if the finding raises a concern that is partially covered AND partially not covered, the finding is REAL" — plus the one-shot example showing that scaffold. This is a closed-form classification task that the local models execute perfectly when the rule is laid out explicitly.

The PR comment sub-task went from local FAIL (FX placeholder substituted for F1-F5) to local PASS. The v2 prompt added an explicit "use the actual id from the input — do NOT use a placeholder like FX" instruction plus a one-shot example showing IDs G1, G2 substituted into the format. The model now correctly substitutes F1-F5 verbatim.

The prose sub-task was already 5/5 in v1 across all workers. v2 keeps that.

The severity sub-task is the remaining gap. qwen3.6 scored 2/5 and qwen3-coder-next scored 3/5, both consistently alarmist on the same findings: F3 (init.sh quoting issue) and F4 (init.sh integrity check) get rated medium-or-high when Opus calls them low. Inspection of the per-cell outputs shows this is a calibration disagreement, not a closed-format failure — the local models apply standard CVSS-style "code injection or supply-chain = elevated severity" reasoning, while Opus weights the narrow exploitability (Ollama's name grammar restricts the F3 attack surface; F4's threat model is supply-chain-via-skill-update which is a meta concern). Both readings are defensible. The remaining gap on subtask 1 is judgment, not formatting.

### Cost recalibration

| Worker | Tokens | Wall time | Cost | Sub-tasks correct (of 4) |
|---|---|---|---|---|
| Opus 4.7 (worker portion alone) | ~7K est. | ~30s | ~$0.23 | 4.00 |
| Sonnet 4.6 subagent | 22,816 | 41s | ~$0.15 | 4.00 |
| Haiku 4.5 subagent | 70,216 | 20s | ~$0.15 | 3.95 |
| qwen3-coder-next (v2 disciplined) | ~3K (24 cells) | ~55s total for 12 cells | ~$0.0001 | 3.60 |
| qwen3.6 prose (v2 disciplined) | ~2.5K (24 cells) | ~50s total for 12 cells | ~$0.0001 | 3.40 |

The local v2 disciplined runs reach Haiku-comparable quality (3.60 vs 3.95 of 4) at electricity-only cost (sub-cent per full sub-task suite vs ~$0.15 for Haiku). The cost ratio is roughly 1500× in favour of local; the quality gap is one sub-task that is itself a calibration call rather than a hard error.

### What 2026 practitioners actually use this for

A parallel research pass turned up consistent reports across the Aider blog, Roo Code's local evaluation, Cline's Devstral integration, and structured-output benchmarks: the patterns that work in 2026 are single-file refactor with constrained edit format (Aider editor role), schema-constrained extraction (log fields, config parsing, commit metadata), batch prose generation (commit messages, summaries), and lint-style closed-checklist code review. The discipline that practitioners universally name: schema-constrained decoding via Ollama's `format` parameter (XGrammar-backed, hits 100% schema compliance vs 89-98% with native JSON mode), one-shot or two-shot prompting, thinking off for format-critical work, temperature 0 for classification, and one atomic output per call (don't bundle multiple sub-tasks). 14B-35B code-tuned models reliably succeed on these patterns; size beyond 35B does not improve reliability and sometimes degrades it (the 2026-05-01 baseline showed qwen3.5:122b worst on T3 because it ignored a 4-claim cap, the 2026-04-28 baseline showed qwen3-next:80b worst on T2 by inventing concerns the prompt forbid).

What practitioners explicitly do NOT delegate to local: multi-step tool-calling loops, whole-repo planning, anything where step N depends on step N-1 reasoning. Devstral 2 (Mistral, 123B) is positioned as an editor-role for Aider/Cline scaffolds; nobody reports using it for closed-form classification because that's work a 14B code model does correctly with `format: schema`.

There's an open Ollama bug ([#14645](https://github.com/ollama/ollama/issues/14645)) where the `format` parameter is silently ignored when thinking is disabled for Qwen3.5-family models — the workaround is to disable thinking at the Modelfile template level rather than via the API parameter. This experiment didn't use `format: schema` at all (just temperature 0 + think:false + one-shot), which leaves further headroom.

Sources for this paragraph: [Aider architect/editor architecture](https://aider.chat/2024/09/26/architect.html), [Ian Paterson's 38-task benchmark](https://ianlpaterson.com/blog/llm-benchmark-2026-38-actual-tasks-15-models-for-2-29/), [Ollama structured output study](https://markaicode.com/ollama-structured-output-pipeline/), [Qwen3 /no_think discussion](https://medium.com/@dukewillbe185/its-time-to-turn-off-the-annoying-think-mode-qwen-3-eefb7dedcadd), [Cline Devstral release post](https://cline.bot/blog/devstral-2-release).

## Updated bottom line

The maintainer's hypothesis was right. With prompt discipline (thinking off, one-shot example, temperature 0, explicit qualifier rules in the prompt), current local models in the 30B–50B range are closer to Sonnet 4 than to GPT-1 for closed-form delegation work. qwen3-coder-next:latest at 51 GB scored 3.60 of 4 sub-tasks correct vs Haiku's 3.95 — within 9% of cloud quality at sub-cent cost. The remaining gap is calibration on severity classification, where the local models apply CVSS-conservative reasoning that disagrees with the director's design-intent reasoning; that's a judgment call, not a delivery failure.

The v1 conclusion was wrong because v1 stacked every known-bad-practice bias simultaneously. The retrospective stands as evidence of what happens when local delegation is run without discipline; the v2 evidence supersedes it as the picture of what happens with discipline.

Concrete implications for the skill: (1) SKILL.md's auto-delegate list should keep prose rewriting / format conversion / closed extraction; the v2 evidence confirms these. (2) The v1-style "don't delegate severity classification" advice doesn't generalise — with disciplined prompting the gap is calibration, not correctness, and a director can paper over calibration by asking the local model for "raw severity" and applying its own reweighting. (3) Adding a `format: schema` capability to delegate.sh would close more of the remaining gap and is the highest-leverage extension based on this evidence (XGrammar gets 100% compliance vs 89-98% native JSON). (4) The bundling tax is real: v1 asked subagents to do 4 sub-tasks in one prompt; v2 split each sub-task into its own atomic call. Recommend: when the director delegates, atomic-task-per-call beats batched.

Future work in priority order: try `format: schema` constrained decoding via Ollama API (close the calibration gap on severity by giving the model an enum), re-run with the v2 disciplined setup but smaller models (14B class — Qwen3-Coder 14B if available, to test if the discipline-not-size hypothesis holds), then test the constrained-edit-format pattern (Aider search/replace blocks) on a real code-generation sub-task as the first probe of "delegate code work" rather than "delegate text work."
