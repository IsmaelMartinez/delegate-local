# 2026-06-15 — Prose-tier audit: gpt-oss-120b → KEEP INCUMBENT (with two recorded findings)

`audit-models.sh` flagged `openai/gpt-oss-120b` (llmfit composite 97.2) as the second-ranked untested prose/reasoning/long-context candidate after `Qwen3-Next-80B-A3B-Thinking` (already rejected 2026-06-05 for unstrippable reasoning traces). This audits gpt-oss-120b against the `mlx-community/Qwen3.6-35B-A3B-8bit` prose incumbent. Verdict: **KEEP INCUMBENT** — do not swap the prose tier. gpt-oss is quality-competitive and uniquely clears the T4 commit-message padding ceiling, but a ~2–3× slower API path and a 65 GB footprint (vs the incumbent's 38 GB) make it a worse default for a tier whose whole value is fast, lightweight local offload. Two findings worth carrying forward are recorded below. `pick-model.sh` prefs unchanged.

## Setup

Pulled `gpt-oss:120b` (65 GB MXFP4 via Ollama) and ran `DELEGATE_STRIP_THINK=1 bash experiments/run-baseline.sh --reps 3 gpt-oss:120b`, then scored with the deterministic T3–T6 scorers. The candidate ran via Ollama; the structured tasks (T4/T5/T6) go through `runner.sh`'s `run_task_api` path with `think:false` — the same path `delegate.sh` uses in production — while T1/T2/T3 use the `ollama run` CLI path. A smoke test confirmed up front that gpt-oss returns clean output under `think:false` (no `<think>` pollution), which is the wall `Qwen3-Next-Thinking` failed. Incumbent numbers are carried from the `2026-06-03-baseline.md` MLX run (the prose incumbent is unchanged since). The run was executed twice — once initially, then a second time under `caffeinate -i` after the first run's later cells showed sleep-inflated durations; both runs produced bit-identical scores, and the committed raw is the caffeinated re-run.

## Results

| Task | gpt-oss-120b | Qwen3.6-35B incumbent | Read |
|---|---|---|---|
| T3 citation | 0.00 (0/11) | 0.75 | format non-adherence + scorer blind-spot — see below; output is grounded, not hallucinated |
| T4 commit-message | **1.00 (18/18)** | 0.83 | gpt-oss **wins** — first model to clear the padding ceiling |
| T5 JSON-shape | 1.00 (18/18) | 1.00 | tie |
| T6 regex-generation | 1.00 (18/18) | 1.00 | tie |

All gpt-oss reps were deterministic (stdev 0.00).

## Finding 1 — gpt-oss clears the T4 commit-message padding ceiling

The commit-message recipe's BODY_NO_PADDING failure is documented across ~10 calibration iterations as a model-independent ceiling: every model on the prose/reasoning tiers (qwen3.6, qwen3-coder, deepseek-r1) fails exactly this one check at 0.83, because each emits a participial-tail (`, enabling X`) or declarative-rephrase (`This ensures Y`) at the end of a body sentence, and per-verb prompt enumeration is a confirmed treadmill. gpt-oss scores 1.00 across all three reps. It does so by naturally writing the effect as a coordinate clause — `…makes the commit-message recipe measurable across models and enables direct comparison…` — instead of the `, enabling…` participial tail the scorer rejects. The ceiling is therefore not strictly model-independent; it is unmovable on the incumbent via the prompt, but a different base model writes past it. If per-recipe model routing is ever introduced (the architecture today routes per-tier, not per-recipe), gpt-oss is the commit-message candidate.

## Finding 2 — the T3 0.00 is format non-adherence plus a scorer blind-spot, not hallucination

gpt-oss's T3 0.00 is **not** a hallucination failure, but it is two distinct things at once. First, it is a format-adherence miss: the task asks for `CONCERN | FILE/PATTERN` pipe-separated lines, and gpt-oss ignored the separator entirely — rep 1 used a `→` arrow, reps 2–3 used markdown headings and newlines. The scorer splits on `|`, so the only pipes it saw were the ones inside the grep commands themselves (`| sort | uniq -d`, `TODO\|FIXME`); that is why it registered any "claims" at all and why their parsing is meaningless. Second, the citations gpt-oss did express are grounded but not verbatim: the four concerns (duplicate `listPosition` ordering, stale imports after a constants move, hard-coded party-colour literals, invalid JSON in `news.json`) each reference a real fixture path — `data/regional-candidates` (15 occurrences), `src/pages/candidates` (3), `data/news.json` (2), `party-config` (4), `listPosition` (2) are all present — but are written as grep commands whose literal text is not a fixture substring. So the 0.00 reflects an instruction-following miss layered on a scorer blind-spot, not invention. Two follow-ups: gpt-oss would need the `|`-separator format reinforced for this task, and the scorer could credit a citation when the file paths it names appear in the fixture rather than requiring the whole pattern string verbatim (needs its own false-positive corpus; not changed here).

## Reliability and cost — why the incumbent stays

The case is efficiency, not unreliability. The first run showed rep 3 of T1/T2/T3 at 523 s / 1286 s / 118 s, which the original draft of this audit misread as the model spiralling into long reasoning on the CLI path. A caffeinated re-run (`caffeinate -i`, lid open) disproved that: it reproduced every score exactly and brought those same three cells to 11 s / 13 s / 16 s. The first run's spikes were the laptop sleeping mid-run, not the model — gpt-oss's latency is bounded and deterministic. That claim is retracted.

What does hold after the re-run: the API path — the one `delegate.sh` uses — is ~2–3× slower than the incumbent (T4 14 s vs ~5 s across both runs), and the model is 65 GB vs the incumbent's 38 GB. For a tier whose entire value is fast, lightweight local offload, paying 2–3× latency and ~1.7× memory for quality that only wins on T4 and ties elsewhere is not a net upgrade. One genuine edge also reproduced across both sessions: the trigger-eval gate (a large 41-query batched judge prompt) returns an **empty** response under `think:false` — `think:false` appears to route a reasoning-heavy task's content into the suppressed channel, leaving the final empty. This is narrow (the prose tasks T3–T6 all produced clean output across two full runs, so ordinary summarise/extract work is unaffected), but it is a real failure mode on prompts that strongly invite reasoning.

## Decision and future levers

Keep `mlx-community/Qwen3.6-35B-A3B-8bit` on the prose and long-context tiers; `pick-model.sh` prefs unchanged. The model-eval sweep that motivated this audit is complete: both llmfit prose/reasoning candidates above the incumbent are now measured — `Qwen3-Next-Thinking` rejected (trace pollution), `gpt-oss-120b` competitive-but-not-a-net-upgrade. Two open follow-ups: (1) the T4 padding ceiling is model-movable, so per-recipe routing would let commit-message use gpt-oss while everything else stays on the fast incumbent — worth weighing if commit-message body padding becomes a priority again; (2) the T3 scorer's verbatim-substring citation check under-credits grep-command-style grounded output and should be refined to match on referenced file paths. gpt-oss:120b is left installed (`ollama rm gpt-oss:120b` to reclaim 65 GB).
