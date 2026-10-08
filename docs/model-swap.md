# Trialling and switching a model

This is the end-to-end procedure for deciding whether a new local model should replace the resident prose model, and for switching to it if it should. It is written from the 2026-10-07 comparison of the resident Qwen3.6-35B-A3B against Qwen3.8-27B and Gemma 4 26B-A4B, and it replaces the `llmfit` upgrade suggestions `audit-models.sh` used to print (#658): a hardware-fit score says nothing about how a model handles the recipes this skill actually serves, and on that day it was still recommending a Qwen2.5 coder. Every step below measures the candidate on this skill's own work, and nothing in it edits routing until the last step.

Since #652 the `code`, `reasoning` and `long-context` tiers resolve the prose list, so "the model" in this document is the prose tier's model and a switch moves every one of them. The `verify` tier ships the prose list too, but it is a separate choice with its own per-model threshold, and this procedure leaves it alone (step 7). `scripts/audit-models.sh` prints the current routing and is the place to start; the 2026-10-07 numbers are quoted with their N where they help calibrate expectations, and none of them is a threshold.

## 1. Check the machine, then start the candidate on its own server

Check free memory and the thermal state before loading anything. `memory_pressure` (or Activity Monitor) gives the first; the second is the same read the heat gate uses, `source scripts/lib/gpu-gate.sh` followed by `gpu_gate_thermal`, which prints macOS's thermal state (0 nominal, 1 fair, 2 serious, 3 critical). Look for other sessions running batches as well, since a replay competes with them for the GPU.

Never ask the shared `:8080` server for the candidate. An `mlx_lm.server` lists every model in the Hugging Face cache from `/v1/models` and loads whichever one a request names beside the resident model, so anything that routes to the candidate there by substring stacks a second set of weights on the server every session shares. Start the candidate on its own server instead:

```bash
mlx_lm.server --model <hf-id> --port 8081
```

Nothing routes to `:8081` by default, because it is not in `DELEGATE_BASE_URL`, so the candidate only answers the calls this procedure aims at it. Keep the total resident weights around 60 GB on the 125 GB laptop: on 2026-10-07 the resident model was about 35 GB and the candidates about 28 GB (Qwen3.8-27B) and 27 GB (Gemma 4 26B-A4B), so one candidate at a time fits and two do not. Never load a 122B-class model beside the resident one; its roughly 65 GB load killed Docker once. Stop the candidate server when the offline steps are done.

## 2. Paired replay of the busiest recipes

`scripts/metrics-summary.sh --days 30` names the recipes with the most delegations; replay each busy one with the template held fixed and the model varied:

```bash
bash scripts/replay-recipe.sh --recipe commit-message --limit 20 \
  --candidate-model <id> --candidate-base http://127.0.0.1:8081/v1
```

`--candidate-model` runs the champion template on the current model and on `<id>`, which is requested by that exact id (`DELEGATE_MODEL`) at `--candidate-base` and never through a tier list, so the arm cannot quietly resolve to a different cached model. The run goes through `delegate.sh` itself, honours the heat gate in `scripts/lib/gpu-gate.sh` (it waits while the machine is hot and holds `caffeinate -i`; `DELEGATE_GPU_GATE=0` turns it off), caches each arm's outputs under its model's key and writes nothing to the metrics file. The section "Comparing models" in [`self-improvement-loop.md`](self-improvement-loop.md) has the detail.

Read the edited cases, not the kept ones. A kept case's reference is a model's own draft (usually, not always, the incumbent's, since the corpus is not filtered by model) rather than a human-edited target, so it measures similarity to that draft, not quality, and an arm can lose it for sounding different rather than for being worse; the report lists those cases and tallies them on their own `Kept (not counted)` line, outside the sign test. The edited cases carry the signal, and on 2026-10-07 they were a dead heat: 26-25 against Qwen3.8 and 22-21 against Gemma 4 across the six busiest recipes. A tie there is a common outcome and is not a reason to stop; it means the remaining steps decide.

## 3. A blind judge over the edited cases

The replay scores anchors against what shipped; it does not say whether a draft was good enough to post. For that, take the edited cases and every arm's output for each, shuffle the arm labels per case so the judge cannot tell which model wrote which draft, and have a judge (a fresh agent session works) grade each draft as shippable with light edits or not. Keep the shuffle key apart and unblind only after every case is graded. There is no script for this step; it is a manual read. On 2026-10-07 it was the discriminating one: of 51 edited cases the judge rated 21 of the incumbent's drafts shippable, 33 of Qwen3.8's and 33 of Gemma 4's.

## 4. Grounding calibration

Score the candidate on the labelled grounding set with `verify-draft.sh --calibrate`, pointing the verify tier at the candidate for the run:

```bash
DELEGATE_BASE_URL=http://127.0.0.1:8081/v1 DELEGATE_MODEL=<id> \
  bash scripts/verify-draft.sh --calibrate ~/.local/share/delegate-local/spikes/clef/grounding/ground.jsonl --dry-run
```

The set is the 120 rows in the data dir under `spikes/clef/grounding/ground.jsonl`, outside the repo: 60 drafts that shipped unedited and 60 copies each carrying one planted contradicted or unsupported claim. The run prints AUROC, the chosen threshold and recall per label; `--dry-run` keeps it from recording a threshold for a model that is not live yet, and dropping the flag records one once the model is switched. On 2026-10-07, at n=120 each, Qwen3.8 scored AUROC 0.972, Gemma 4 0.932 and the resident Qwen3.6 0.882. [`verify.md`](verify.md) has the question, the threshold rule and the full table.

## 5. Trigger gate

The skill's own description has to read the same way to the candidate. Run the on-device trigger gate against it:

```bash
DELEGATE_BASE_URL=http://127.0.0.1:8081/v1 DELEGATE_MODEL=<id> \
  bash scripts/eval-skill-triggers.sh --decide
```

`--decide` asks one `decide.sh` question per query on the prose tier, which `DELEGATE_MODEL` pins to the candidate. Compare its recall and negative precision with the same command run without the two variables, which answers on the resident model; the gate CLAUDE.md sets for a description edit (both at or above 0.9) is the bar here too.

## 6. Speed and cold load

Time the candidate on a handful of real prompts, about ten, through `delegate.sh` with `DELEGATE_BASE_URL` and `DELEGATE_MODEL` set as above and `DELEGATE_LOCAL_NO_METRICS=1` so the bench stays out of the metrics. Time the first request after the server starts separately: most of a delegation's wall-clock is the time to first byte, and a model that is fast warm but slow to load costs every session that finds it cold. On 2026-10-07 the warm mean per call was 3.8 s for Qwen3.6, 12.2 s for Qwen3.8 and 3.2 s for Gemma 4. A dense model can win the quality steps and still lose here: active parameters, not total size, set the latency on the prose tier.

## 7. The live trial

A candidate that holds up offline gets a trial on real traffic before any edit to the repo. Make it the model the resident server serves (restart `:8080` with `--model <hf-id>`, after the offline steps have freed the candidate server), and prepend one line to `config.sh` in the data dir so every tier that shares the prose list asks for it first:

```bash
case "$tier" in prose|code|reasoning|long-context) prefs=(<substring> "${prefs[@]}") ;; esac
```

The verify tier keeps its own line: it is chosen independently and its threshold is calibrated per model, so folding it into a prose trial would silently swap the verifier and invalidate that threshold. If the trial model should also verify, calibrate it first with `verify-draft.sh --calibrate`.

Prepend rather than replace, so later changes to the shipped list still reach the machine; `audit-models.sh` warns when a tier is frozen by a replacement. Prepending to every shared tier matters on an `mlx_lm.server`: a tier left on the old list would still name the old model, and the server would load it beside the new one.

Note the minute the line went live, and read the trial against it:

```bash
bash scripts/metrics-summary.sh --since <switch-minute ISO-8601> --model <substring>
bash scripts/metrics-summary.sh --since <switch-minute ISO-8601>
```

`--model` restricts every section to the delegations whose model contains the substring, with their verdicts, and a recipe that more than one model served in the window gets a sub-line per model. Split the read at the switch minute rather than by day, so rows from before the switch never mix in, and quote the N beside every rate: at this volume a single delegation moves the percentages.

## 8. Switch

When the trial holds, make the change in the repo on a branch. Edit `PROSE_PREFS` in `scripts/pick-model.sh`, spelling the new model for every provider (its Ollama tag and its Hugging Face name, as the existing entries do), and update the prose-ordering test in `tests/run-tests.sh`, which encodes the measured order. Add a dated entry naming the model to each busy recipe's `docs/calibration/<recipe>.md` with the replay and judge numbers. Expect recipe guards written against the old model to need re-measuring: each recipe was calibrated against one model's greedy output (ADR 0009), so a guard that bound on the old model can stop binding or start over-firing on the new one. Re-run the replay per recipe after the switch and treat a regression there as a recipe edit with its own gate. Once the PR merges and the live clone is pulled, remove the `config.sh` line. If the verify tier now resolves to the new model, run `verify-draft.sh --calibrate` without `--dry-run` to record its threshold.

## 9. Rollback

During the trial, rollback is removing the `config.sh` line (and restarting `:8080` on the previous model if it was swapped); the next call resolves the shipped list again. After a switch has merged, it is a revert of the `PROSE_PREFS` edit. Either way, read `metrics-summary.sh --model` split at the rollback minute to confirm the old model is serving again.
