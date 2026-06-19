# 2026-06-19 — faithfulness grounding check, precision/recall reading

Tool: `scripts/grounding-check.sh` (ADR 0021). Backend MLX. Six diffs, each run through the `commit-message` recipe (`--recipe auto`, which includes recent commits as context) on a weak primary (`mlx-community/Qwen3-0.6B-4bit`) and a strong one (`lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit`), then scored by the grounding check. Labels are hand-assigned after reading each output.

## Per-case outcome

| Case | 0.6B output (labelled) | check on 0.6B | 30B output (labelled) | check on 30B |
|---|---|---|---|---|
| lockout | drifted ("stale lock file") | UNGROUNDED ✓ | faithful | GROUNDED ✓ |
| cache | drifted (body = #315 regurgitation) | GROUNDED ✗ (subject named the file) | faithful | GROUNDED ✓ |
| retry | drifted ("stale lock file") | UNGROUNDED ✓ | faithful | GROUNDED ✓ |
| timeout | drifted ("stale lock file") | UNGROUNDED ✓ | faithful | GROUNDED ✓ |
| parser | drifted (#315 regurgitation) | UNGROUNDED ✓ | faithful | GROUNDED ✓ |
| metrics | drifted (#315 regurgitation) | UNGROUNDED ✓ | faithful | GROUNDED ✓ |

## Headline

The weak model was catastrophically unfaithful on this task: 6 of 6 outputs ignored the diff and regurgitated unrelated content from the recipe's own context window. The strong model was faithful on all 6.

The grounding check, against the hand labels:

- Precision (of the outputs it flagged UNGROUNDED, how many were truly drifted): 5/5 = 100%. Zero false alarms — it never flagged a faithful output.
- Recall (of the truly drifted outputs, how many it flagged): 5/6 = 83%. The miss (`cache`) had a subject that coincidentally named `resolver.py` while its body was pure regurgitation — the documented subject-only-grounding blind spot.

## What this does and does not mean for quality

It does NOT meaningfully move the production miss rate on the current strong-default routing: the strong model produced zero gross drifts here, and the subtle faithfulness misses it does make in production (right identifier, wrong claim) are invisible to a grounding check. Expect ~0–2 points off the ~19.7% miss rate from this lever alone on the strong default, likely less.

It DOES make a cheap-first default viable. The 0.6B's regurgitations are structurally clean, so the ADR 0020 gate alone would never escalate them (capability-failure count zero). With grounding wired in as a capability check, that drift becomes visible, the gate escalates to the faithful strong model, and cheap-first faithfulness on this task goes from ~0% (6/6 garbage kept) to ~83% recovered at 100% precision. That is the number that matters: it is what lets "default to the small fast model, pay for the big one only on drift" actually work.

## Reproduce

```bash
echo "<model output>" | bash scripts/grounding-check.sh --input <diff-file>
# GROUNDING: GROUNDED|UNGROUNDED|SKIP  matched=k distinctive=d input_idents=m sample=...
```
