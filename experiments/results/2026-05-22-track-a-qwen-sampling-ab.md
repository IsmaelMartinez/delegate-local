# Track A — Qwen3-family sampling A/B

## Setup

Model: `qwen3.6:35b-a3b-q8_0` (Ollama backend, HTTP `/api/generate` with
`think:false`).

Treatment landed in `scripts/delegate.sh` (this branch): Qwen3-family models
(qwen3.6, qwen3-coder, qwen3-next, qwen3.5) get Alibaba's recommended
instruct/non-thinking profile (`temperature=0.7`, `top_p=0.8`, `top_k=20`,
`presence_penalty=1.3`). Greedy can be restored per call via
`DELEGATE_TEMPERATURE=0`.

`experiments/runner.sh` was updated in the same patch to mirror the same
sampler-resolution logic on its API dispatch path, so the A/B reflects the
production code path.

## Commands

Baseline (greedy):

```bash
DELEGATE_TEMPERATURE=0 bash experiments/runner.sh --reps 5 qwen3.6:35b-a3b-q8_0
bash experiments/score-t4.sh experiments/results/raw/qwen3_6_35b-a3b-q8_0.txt
mv experiments/results/raw/qwen3_6_35b-a3b-q8_0.txt experiments/results/raw/qwen3_6_35b-a3b-q8_0-greedy.txt
```

Treatment (default Qwen profile after this PR):

```bash
bash experiments/runner.sh --reps 5 qwen3.6:35b-a3b-q8_0
bash experiments/score-t4.sh experiments/results/raw/qwen3_6_35b-a3b-q8_0.txt
mv experiments/results/raw/qwen3_6_35b-a3b-q8_0.txt experiments/results/raw/qwen3_6_35b-a3b-q8_0-qwen-profile.txt
```

## T4_SUMMARY lines

Baseline (greedy, `DELEGATE_TEMPERATURE=0`):

```
T4_SUMMARY: reps=5 total_passed=30 total_checks=30 mean=1.0000 stdev=0.0000 min=1.0000 max=1.0000
```

Treatment (Qwen instruct profile):

```
T4_SUMMARY: reps=5 total_passed=26 total_checks=30 mean=0.8666 stdev=0.0667 min=0.8333 max=1.0000
```

## Interpretation

The Qwen instruct profile regresses T4 on `qwen3.6:35b-a3b-q8_0` against the
2026-05-21 commit-message fixture. Mean drops from 1.00 to 0.87 (-0.13), and
three of the five reps now produce a participial-padding tail (`,
allowing direct comparison…`-style) that the commit-message recipe's
guards explicitly reject. One rep also exceeds the 72-char subject ceiling.

The drop is below the >0.5 hard-fail threshold called out in the Track A
brief, but the new padding tails fall under the "more padding tails
appear" reject condition. Mechanism: greedy decoding produces verbatim
deterministic output (the same commit message across all five reps,
matching every guard); Alibaba's recommended `temperature=0.7 +
presence_penalty=1.3` reintroduces lexical variety, which in this fixture's
prompt shape tends to land on participial-form restatement tails the
guards were designed to block.

Recommendation: do not merge as default. The treatment is the right
direction for prose-shaped tasks where temperature-induced variety helps,
but on the T4 calibration axis it hurts. The PR ships the code path (env-
var overrides remain useful, the metrics fields land), but the user should
review the A/B numbers before deciding whether to (a) keep the Qwen
profile as default and tighten the commit-message recipe guards further,
or (b) flip the default back to greedy and keep the env-var override for
opt-in.

## Raw artefacts

- `experiments/results/raw/qwen3_6_35b-a3b-q8_0-greedy.txt`
- `experiments/results/raw/qwen3_6_35b-a3b-q8_0-qwen-profile.txt`
