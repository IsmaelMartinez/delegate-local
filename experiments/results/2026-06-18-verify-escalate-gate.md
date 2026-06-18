# 2026-06-18 — verify-and-escalate gate, production-path reading

Backend: MLX (`mlx_lm.server`, localhost:8080). Path: the production gate inside `scripts/delegate.sh` (ADR 0020), not the prototype harness. Primary model pinned to `mlx-community/Qwen3-0.6B-4bit` (a deliberately below-floor choice, via a temp `DELEGATE_LOCAL_CONFIG`); escalation target `lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit` via `DELEGATE_ESCALATE_MODEL`. Recipe: `commit-message` (the only production recipe with capability checks today — `subject_max`, `subject_type`, `body_required`). Reproduce with `experiments/escalate-gate-eval.sh --escalate-model <strong> --primary qwen3-0.6 --backend mlx`.

## Gate firing and adoption across eight conventional-commit diffs

| Case | type | gate fired | adopted | duration |
|---|---|---|---|---|
| add-logging | feat | no | — | 1.6s |
| fix-null | fix | yes | yes | 3.8s |
| docs-install | docs | yes | yes | 4.3s |
| chore-bump | chore | yes | yes | 4.7s |
| test-add | test | yes | yes | 4.1s |
| refactor-extract | refactor | yes | yes | 4.1s |
| perf-cache | perf | yes | no | 4.9s |
| style-imports | style | yes | yes | 4.0s |

Fired on 7 of 8, adopted on 6. The 0.6B is below the capability floor for typed commit messages — it failed a capability check (most often `subject_type` or a dropped body) on seven of eight diffs — and escalating to the Coder-30B recovered six of those seven to zero capability failures. The one case that fired without adopting (`perf-cache`) is the gate working correctly in the other direction: the 30B also failed the capability check, so there was no strict improvement and the primary output was kept rather than swapping in an equally-failing-but-slower answer. The single no-fire case (`add-logging`) is where the 0.6B already passed the capability checks, so the strong model was never loaded and the call returned in 1.6s.

## Cost is asymmetric, as designed

The cheap-only path (no capability failure) returned in ~1.6s. The escalated path cost ~3.8–4.9s — the cheap generation (~1.6s) plus one 30B generation (~2.2–3.3s). The strong model is paid for only when a capability check has already failed; the happy path never loads it. This is the property that makes "default to the smallest model, escalate on a measured failure" cheaper on average than "always use the big model," while landing the big model's quality on the cases that need it.

## The boundary the gate does not cross

A separate single-diff probe made the limit concrete. On an account-lockout diff the 0.6B produced a structurally clean message — correct `feat:` prefix, a real body, only the style `no_padding_tail` flagged — but the body described "stale lock file when daemon crashes," a verbatim regurgitation of a recent-commit example from its own context window, with nothing to do with the actual change. Because the output was structurally clean, `capability_failed` was zero and the gate correctly did not fire; a stronger model would have helped, but the structural checks cannot see a faithfulness failure, so the gate had no signal to act on. Faithfulness is the dominant remaining miss bucket (ADR 0016, ~23%) and the lever for it is capability-matched primary routing — do not send `commit-message` to a 0.6B in the first place — not escalation.

The complementary observation: the recipes where the prototype (ADR 0019) showed the largest gains were the structured-output ones (T6 regex 0.50→1.00, T5 JSON 0.67→1.00), and those recipes do not yet declare capability checks, so the production gate rarely fires on them today. Adding a structured capability check (valid-JSON, anchored-regex) so those recipes can trigger the gate is the named next lever; this reading deliberately measured only the mechanism on the one recipe that already carries capability checks.
