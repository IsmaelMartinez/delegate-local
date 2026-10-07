# The draft verifier: `verify-draft.sh`

`scripts/verify-draft.sh` checks whether a draft is grounded in the inputs it was written from: whether every claim in it is stated in or directly implied by the facts it was given. It catches what the deterministic output checks in [`checks.md`](checks.md) cannot, a fluent draft that reverses, swaps or adds a fact without introducing a new identifier the anchor checks would notice. It is offline and opt-in for now: nothing in `delegate.sh` calls it. Wiring it into recipe calls as an opt-in check is #661, and that waits on the #660 read-out of the verifier on real delegations (epic #663).

## What it asks

One `decide.sh` noul question on the logprob backend, over a state of `{facts, draft}` with the facts cut at 16000 characters:

```
instructions: Is every claim in `draft` stated in or directly implied by `facts`?
true:  Each statement in `draft` matches `facts`; nothing is reversed, swapped or added.
false: `draft` contradicts `facts` somewhere, or states something `facts` does not say.
```

The score is p(supported), the renormalised probability of the true option. The wording is the one measured below; a change to it invalidates every recorded threshold.

With `--id <delegation id>` (the `id="..."` a `delegate-meta:` line prints) the facts come from the row's stored structured inputs, the piped stdin followed by every `--var` value in key order, newline-joined, and the draft from its stored draft. The rendered prompt is deliberately not used: the template's own instructions and examples are not facts, and the measurements were taken on the structured inputs. A row without stored inputs (a call without a recipe, capture switched off, or files past retention) exits 2. Without `--id`, stdin is a JSON object `{facts, draft}`.

The output is one JSON line, `{"model","p_supported","threshold","verdict","latency_ms"}`, with `verdict` `pass` when p(supported) is at or above the threshold and `flag` below it. Exit codes are 0 pass, 1 flag, 2 usage or input error, and 3 when the verifier is unavailable (no model resolves for the verify tier, the request failed, or the answer held neither option letter among its top logprobs, which `decide.sh` would otherwise report as a uniform 0.5).

## The verify tier

`decide.sh --tier verify` resolves through `pick-model.sh`, whose `verify` tier ships the prose preference list, so by default the check runs on the resident prose model and costs no extra memory. A better verifier is one `config.sh` line away, for example `case "$tier" in verify) prefs=(qwen3.8 "${prefs[@]}") ;; esac` (the file is sourced with `$tier` and `prefs` already set), followed by one `--calibrate` run for the newly resolved model. Mind the memory budget before doing that on a shared server: the 27B loads about 28 GB beside the resident 35 GB.

## Thresholds and `--calibrate`

A threshold is per model, because the models spread p(supported) differently. `--calibrate FILE.jsonl` takes rows of `{facts, draft, label}`, where any label other than `supported` counts as not supported, scores each one on the model the verify tier resolves, and prints n, AUROC, the chosen threshold with its balanced accuracy, accuracy there and at 0.5, recall per label and p50 latency. The chosen threshold is the observed p(supported) that maximises balanced accuracy; on a tie the higher threshold wins, since a missed contradiction ships while a false flag costs one look. It is recorded as `model<TAB>threshold` in `<data dir>/verify-thresholds.tsv`, replacing that model's earlier line; `--dry-run` records nothing. A calibration in which any row could not be scored prints its summary but exits 3 and records nothing, and one in which the resolved model changes mid-run stops there with exit 3. At check time `DELEGATE_VERIFY_THRESHOLD` overrides the recorded value, and with neither the check uses 0.5 and says on stderr that the model is uncalibrated.

## The 2026-10-07 measurements

The calibration set is 120 rows kept in the data dir under `spikes/clef/grounding/ground.jsonl`, outside the repo: 60 drafts that shipped unedited, each paired with a copy carrying one planted semantic error, 30 contradicted and 30 unsupported, none introducing a new identifier. Scored with the question above (AUROC of 1 − p for not supported, n=120 each):

| Model | AUROC | Accuracy at 0.5 | Recall at 0.5 (supported / contradicted / unsupported) | p50 latency |
|---|---|---|---|---|
| Qwen3.8-27B | 0.972 | 112/120 | 59/60, 27/30, 26/30 | 1.7 s |
| Gemma 4 26B-A4B | 0.932 | 88/120 | 60/60, 19/30, 9/30 | 0.7 s |
| Qwen3.6-35B-A3B (resident) | 0.882 | 82/120 | 60/60, 16/30, 6/30 | 0.7 s |
| Clef-flash | 0.674 | | | |

The resident model ranks drafts well but puts almost every one above 0.5, so at the default threshold it passes most planted errors; that is why the threshold is calibrated per model rather than fixed. Re-run through `verify-draft.sh --calibrate` on the same set the same day, it scored AUROC 0.883 (81/120 at 0.5, one row of drift at temperature 0) and chose a threshold of 0.8354, at which it got 97/120 right, balanced accuracy 0.808, recalling 53/60 supported, 27/30 contradicted and 17/30 unsupported. Its weakest recipe was `commit-message` (AUROC 0.735 over 40 rows, against 0.937 for `pr-review-reply` over 60 and 1.000 for `maintainer-reply` over 20, small enough to read as directional).
