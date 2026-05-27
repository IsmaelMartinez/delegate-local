# delegate-local — Expansion Research and Plan

Date: 2026-05-27. This is a research document, not an implementation plan. It synthesises findings from the session analysis, model audit, web research, and roadmap review into a set of prioritised directions for discussion.

## Current state

The skill has processed 992 invocations since 2026-05-03, routing 1,075K tokens locally with an 80% hit rate on tracked verdicts. Prose tier dominates (420 of 483 delegate calls), reasoning accounts for 57, code has exactly 1 call, and the remaining 5 are spread across long-context and embedding tiers. The average delegation is ~930 tokens (3K prompt chars in, 674 output chars out). At Opus 4.7 pricing that represents roughly $12 of avoided API cost against an estimated $398 of total session spend — a 3% offset.

The system is heavily dogfooded within the delegate-local repo itself (635 of 647 recent calls). Only 12 calls came from other projects. Session analysis suggests 30-40% of all Claude Code sessions involve at least one delegatable sub-task, but the skill currently covers ~10% of sessions. The gap between 10% actual and 35% potential represents the main expansion opportunity.

MLX is the default backend since 2026-05-26 (launchd auto-start), running at p50 3.3s vs Ollama's 6.9s. Only one MLX model is downloaded (Qwen3.6-35B-A3B-8bit for prose); code and reasoning tiers still fall back to Ollama.

## Model audit findings

llmfit scores the installed Qwen3.6-35B-A3B at 91.7 composite. The top suggestion is Qwen3-Next-80B-A3B-Thinking at 96.4, but the 2026-04-28 baseline showed larger models performing worse on structured tasks (the 80B was the worst T3 performer). No urgent model change is needed.

The actionable model gap is MLX tier coverage. Downloading additional MLX-community models for the `code` and `reasoning` tiers would let those calls use the faster MLX backend instead of falling back to Ollama. Candidate downloads: `mlx-community/DeepSeek-R1-Distill-Qwen-32B-MLX-8Bit` (reasoning) and `lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit` (code).

Any new model introduction should follow the existing due-diligence protocol from Phase 14: download, run the T3-T6 benchmark suite via `experiments/runner.sh`, compare against the current baseline, and only promote to `pick-model.sh` if scores match or exceed the incumbent. Prompt adjustments are model-specific — the anti-padding directives, subject-required guards, and contrastive anchors were calibrated against Qwen3.6; a different model family (DeepSeek, Gemma) may need its own calibration pass.

## Delegation coverage gaps

### 1. Cross-project adoption (highest impact)

635 of 647 calls come from the skill's own repo. The skill is installed at user scope (`~/.claude/skills/delegate-local`), so it is available in every session, but other repos do not trigger it at the same rate. The rename from `delegate-to-ollama` to `delegate-local` removes the Ollama-specific framing that may have narrowed the perceived scope.

### 2. Untracked verdicts (46% of calls)

300 of 647 calls have no hit/miss feedback. The nudge line after each call serves as the reminder, but agents in fast-paced sessions skip it. Reducing the untracked rate would improve recipe calibration signal. Possible interventions: a session-end sweep that prompts for bulk verdicts, or a background routine that flags untracked rows older than 1 hour.

### 3. pr-description recipe (45% hit rate)

The flaky-on-models gate (Phase 16) now refuses this recipe on 35B-class models, which is the right operational fix. The recipe needs either a model class that handles it reliably or a fundamental redesign of the prompt shape.

### 4. commit-message recipe (73% hit rate)

The main failure mode is type-selection (choosing `docs:` when `feat:` is correct). The Phase 15 contrastive-anchor work and Phase 17 Track E clusters already address this, but the 73% rate is below the 80% project average.

## Expansion opportunities (from web research)

Five task categories have evidence supporting delegation at the 14B-35B scale, ordered by expected ROI.

### A. Test-stub scaffolding

Generating boilerplate test-file skeletons from function signatures — the structural frame, not the assertions. This is pattern-matching work where the model fills in imports, class setup, and method stubs while the agent writes the actual test logic. Viable at 7B-14B based on documented evidence.

### B. Lint-style diff feedback

Reading a diff and flagging style violations against a known ruleset (not finding bugs — flagging conventions). LintLLM (GLSVLSI 2025) measured 19% improvement over commercial EDA tools with smaller models. For delegate-local the shape would be: inject the project's style conventions as prompt context, pipe in the diff, get back violation flags. Verifiable output, no repo-wide context needed.

### C. Confidence-based cascading

Currently the routing decision is static: task type determines tier. The literature (Sakota et al., arXiv 2502.11021; Chen et al., arXiv 2603.04445) shows that confidence-based cascading — try local first, escalate to cloud on low confidence — consistently outperforms static routing. A simple proxy that does not need logprob access: compare output length to input length. Suspiciously short answers to long prompts catch the most common "model punted" failure mode. This could be a post-hoc advisory check in `delegate.sh`.

### D. Structured data extraction expansion

T5 (JSON schema) and T6 (regex) benchmarks already validate this category. The expansion is making it a documented first-class recipe category for meeting-notes-to-action-items, error-log-to-structured-fields, and config-to-table conversions.

### E. Changelog and release-note batching

Multiple items of the same shape (changelog entries, release bullets) can batch into a single call. The aggregate-density fix in PR #228 documents the pattern; a recipe that takes N changelog entries and produces N release-note bullets in one call would save per-call overhead.

## Risks

Small-model overconfidence is the primary documented risk (OpenAI September 2025). Local models bluff rather than abstain — the hit/miss feedback loop is the right mitigation, not model self-assessment. Cascading hallucination (OWASP ASI-08, 2026) applies when local-model output is silently injected into cloud-model reasoning; the current design (return to user for review) is the safe pattern. Quantization at Q4 loses 0.4-0.6 F1 on structured extraction vs Q8; the current Q8 default is the right choice.

## Proposed phases (for discussion, not implementation)

### Phase A: MLX tier coverage (low effort, immediate)

Download MLX-community models for reasoning and code tiers. Run the T3-T6 baseline. Promote to `pick-model.sh` if scores match. No prompt changes needed if the model is the same family.

### Phase B: Cross-project adoption push (medium effort)

Track delegation volume per-project in the metrics JSONL (the `delegate.project` attribute shipped in PR #224). Identify the top 3 repos by session count that have zero delegations. Run a dogfooding session in each to validate the skill fires naturally.

### Phase C: Confidence post-check in delegate.sh (medium effort)

Add an output-length-vs-input-length ratio check after each call. If the ratio is below a threshold (model punted), emit a warning on stderr. Advisory only, does not block output. Calibrate the threshold against the existing MISS rows in the metrics JSONL.

### Phase D: Test-stub recipe (medium effort, requires baseline)

Write a `prompts/test-stub.md` recipe for generating test-file skeletons. Calibrate against the code tier. Measure with a T7 fixture. The verification step (pytest on the stubbed file) is load-bearing.

### Phase E: Untracked verdict reduction (low effort)

Add a session-end reminder mechanism or a background routine that surfaces untracked rows older than 1 hour. Target: reduce untracked rate from 46% to under 20%.

## Sources

- Sakota et al., "Leveraging Uncertainty Estimation for Efficient LLM Routing", arXiv 2502.11021
- Chen et al., "Dynamic Model Routing and Cascading for Efficient LLM Inference: A Survey", arXiv 2603.04445
- "A Unified Approach to Routing and Cascading for LLMs", arXiv 2410.10347
- LintLLM, "Open-Source Verilog Linting with LLMs", GLSVLSI 2025 (ACM)
- "Cascading Failures in Agentic AI", OWASP ASI-08 Guide, 2026
- "Bridging On-Device and Cloud LLMs for Collaborative Reasoning", arXiv 2509.24050
- delegate-local metrics JSONL (992 rows, 2026-05-03 to 2026-05-27)
- llmfit audit output (2026-05-27)
- Claude Code session data (~204 sessions across 24 tracked days)
