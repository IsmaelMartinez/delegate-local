# 2026-06-19 — does the 0.6B add anything but time? (cheap-first break-even)

Question (the maintainer's): if the 0.6B is that bad, is it worth using as a cheap primary at all, or does cheap-first-then-escalate only add latency? Backend MLX, the six fixtures (T1–T6) on `mlx-community/Qwen3-0.6B-4bit` and `lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit`, reps=4 (the MLX greedy path is deterministic, so every rep is identical — reps add no variance, only confirm stability). Scored with `experiments/score-t{3,4,5,6}.sh`; T1/T2 read by hand.

## The break-even

Always-strong costs the 30B latency `S`. Cheap-first costs the 0.6B every time plus the 30B on every failure, i.e. `C + (1−p)·S` where `p` is the 0.6B's usable-output rate. Cheap-first wins only when `p > C/S`. With the 0.6B near-instant here (0–4s) and the 30B a few seconds, the bar sits roughly at `p > 0.4`. So the whole question reduces to: on which tasks does the 0.6B produce a usable answer more than ~40% of the time?

## Scores, and why two of them lie

| Task | 0.6B score | 30B score | what the 0.6B actually produced |
|---|---|---|---|
| T1 doc-drift | — | — | literal `<no evidence reference>` placeholders — didn't do the task |
| T2 party-config | — | — | duplicated `reform-uk`, verbose, malformed |
| T3 merge-patterns | 1.00 | 1.00 | `NONE` — found nothing; 1.00 is the scorer rewarding silence |
| T4 commit-message | 1.00 | 0.86 | regurgitated "stale lock file" + "The commit message is complete." — structurally perfect, semantically garbage |
| T5 json-shape | 0.67 | 1.00 | valid JSON but 2 of 3 items, one invented date |
| T6 regex-generation | 0.50 | 1.00 | output the literal string `"12345-6789"`, not a regex |

The two scores where the 0.6B "passes" are both artefacts. T3's citation-rate rewards saying `NONE` — nothing claimed, nothing to fail. T4's seven checks are all structural (subject length, type prefix, body present, no padding); they are blind to faithfulness, so a regurgitated message about an unrelated topic scores a perfect 7/7. The grounding check (ADR 0021) exists precisely because of that blind spot, and on this same T4 output it flags UNGROUNDED. On every task where the scorer measures actual correctness — T5's values, T6's behaviour, T2's content — the 0.6B fails outright.

## Answer: only time, never help — on this lineup

The 0.6B does not produce a usable answer on a single one of these tasks. Its usable-output rate is effectively 0%, far below the ~40% break-even, so cheap-first with the 0.6B is strictly worse than just using the 30B: it adds the 0.6B's latency (small — it is fast) and the verify/escalate round-trip, and returns nothing the 30B would not have returned anyway. It is below the floor across the entire delegate-local task surface, not just commit-message. (It is already unrouted — no tier resolves to it on MLX — which is the correct state; this measurement confirms that should stay so.)

The reason cheap-first cannot pay here is a capability cliff in the installed lineup: the routed models jump from the 0.6B (useless) straight to the 30B (good), with nothing competent in between. Cheap-first needs a primary that is genuinely cheaper *and* clears ~40% usable — a mid-tier 4B–8B-class model — and none is installed on the MLX side.

## Consequences

1. Route to the smallest *sufficient* model, which for every task measured here is the 30B, not the 0.6B. "Smallest sufficient" was always the rule; the 0.6B is not sufficient for anything in this suite.
2. The verify-and-escalate gate (ADR 0020) and the grounding check (ADR 0021) are validated *mechanisms*, but they have no viable cheap primary on this host, so the cheap-first performance play they enable cannot be realised here today. They are waiting for a competent mid-tier model, not for more wiring.
3. Therefore the planned wiring of grounding into the gate is SHELVED, not built — there is no cheap primary whose drift it would usefully catch in production. The grounding check stays useful as a standalone verification tool and as a net to switch on if and when a mid-tier model is installed and benchmarked above the break-even.
4. Next experiment worth running, if the maintainer wants the cheap-first win: install a 4B–8B MLX model, run this same six-task matrix, and check whether its usable rate clears ~40% — that is the precondition for the gate to pay.
