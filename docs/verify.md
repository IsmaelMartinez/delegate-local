# The draft verifier: `verify-draft.sh`

`scripts/verify-draft.sh` checks whether a draft is grounded in the inputs it was written from: whether every claim in it is stated in or directly implied by the facts it was given. It catches what the deterministic output checks in [`checks.md`](checks.md) cannot, a fluent draft that reverses, swaps or adds a fact without introducing a new identifier the anchor checks would notice. It runs offline on any stored delegation, and inline on recipe calls that opt in: since #661 `delegate.sh` scores the final draft of every recipe whose frontmatter sets `verify: true`, or any recipe call under `DELEGATE_VERIFY=1`, and reports a flag without touching the draft ([`checks.md`](checks.md#the-draft-verifier)). The read-out on real delegations that decided to wire it in, and on which recipes, is at the end of this page (#660, epic #663).

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

A threshold is per model, because the models spread p(supported) differently. `--calibrate FILE.jsonl` takes rows of `{facts, draft, label}`, where the label is one of `supported`, `contradicted` or `unsupported` (any other value exits 2 before anything is scored) and the last two count as not supported, scores each one on the model the verify tier resolves, and prints n, AUROC, the chosen threshold with its balanced accuracy, accuracy there and at 0.5, recall per label and p50 latency. The chosen threshold is the observed p(supported) that maximises balanced accuracy; on a tie the higher threshold wins, since a missed contradiction ships while a false flag costs one look. It is recorded as `model<TAB>threshold` in `<data dir>/verify-thresholds.tsv`, replacing that model's earlier line; `--dry-run` records nothing. A calibration in which any row could not be scored prints its summary but exits 3 and records nothing, and one in which the resolved model changes mid-run stops there with exit 3. At check time `DELEGATE_VERIFY_THRESHOLD` overrides the recorded value, and with neither the check uses 0.5 and says on stderr that the model is uncalibrated.

## The 2026-10-07 measurements

The calibration set is 120 rows kept in the data dir under `spikes/clef/grounding/ground.jsonl`, outside the repo: 60 drafts that shipped unedited, each paired with a copy carrying one planted semantic error, 30 contradicted and 30 unsupported, none introducing a new identifier. Scored with the question above (AUROC of 1 − p for not supported, n=120 each):

| Model | AUROC | Accuracy at 0.5 | Recall at 0.5 (supported / contradicted / unsupported) | p50 latency |
|---|---|---|---|---|
| Qwen3.8-27B | 0.972 | 112/120 | 59/60, 27/30, 26/30 | 1.7 s |
| Gemma 4 26B-A4B | 0.932 | 88/120 | 60/60, 19/30, 9/30 | 0.7 s |
| Qwen3.6-35B-A3B (resident) | 0.882 | 82/120 | 60/60, 16/30, 6/30 | 0.7 s |
| Clef-flash | 0.674 | | | |

The resident model ranks drafts well but puts almost every one above 0.5, so at the default threshold it passes most planted errors; that is why the threshold is calibrated per model rather than fixed. Re-run through `verify-draft.sh --calibrate` on the same set the same day, it scored AUROC 0.883 (81/120 at 0.5, one row of drift at temperature 0) and chose a threshold of 0.8354, at which it got 97/120 right, balanced accuracy 0.808, recalling 53/60 supported, 27/30 contradicted and 17/30 unsupported. Its weakest recipe was `commit-message` (AUROC 0.735 over 40 rows, against 0.937 for `pr-review-reply` over 60 and 1.000 for `maintainer-reply` over 20, small enough to read as directional).

## Read-out on real delegations (2026-10-07, #660)

The question #660 put was whether the verifier, at a calibrated threshold, flags real drafts that were rewritten more often than real drafts that shipped, and flags few of the latter. The corpus was every post-reset (2026-08-19) recipe delegation with a verdict, 1,406 of them, of which 1,291 still had their stored draft and structured inputs (drafts from before 2026-09-22 had been pruned). Their verdicts were 268 kept, 750 scaffold and 273 rewritten. Each was scored with `verify-draft.sh --id` on two verifiers, the resident Qwen3.6-35B-A3B and Qwen3.8-27B served beside it.

On the 120-row synthetic grounding set above, Qwen3.8-27B reached AUROC 0.972 at a threshold of 0.562 with balanced accuracy 0.942, and Qwen3.6-35B-A3B AUROC 0.883 at 0.835 with balanced accuracy 0.808. Carried over to the real corpus at those thresholds, Qwen3.8 flagged 7% of kept drafts (19 of 268) and 32% of rewrites, and Qwen3.6 flagged 14% of kept drafts (39 of 268). `commit-message` was where it failed: Qwen3.8 flagged 17 of its 76 kept drafts, because a commit message's stored inputs are the diff stat and the why, not the diff, so a correct claim read from the diff has nothing in the facts to stand on.

With `commit-message` excluded, and each model's threshold set so that it flags 5% of kept drafts, Qwen3.8 at 0.679 caught 7 of the 13 rewrites identified by hand as factual errors and flagged 95 of 244 rewrites, while Qwen3.6 at 0.755 caught 5 of 13 and flagged 56 of 244. At Qwen3.8's 0.679, flagged drafts were rewritten 57% of the time against 25% for unflagged ones, a 2.3x lift, which meets #660's keep rule of at most 5% of kept drafts flagged and at least twice the rewrite rate.

The caveats are real and should travel with the result. `commit-message` was excluded after seeing the data, not before. Thirteen factual-error cases is a small N. Most flagged rewrites were drafts discarded in favour of pre-approved text rather than drafts with a factual error, so the lift measures "this draft did not ship" more than "this draft was wrong". And on planted errors Qwen3.8 caught 56 of 60 but on real factual errors only about half, because a real error usually confuses facts that are all present in the input, which is harder to see than a fact the input never states.

Decision: keep, opt-in on the five non-commit recipes (`maintainer-reply`, `maintainer-review-reply`, `pr-description`, `pr-review-reply`, `github-issue-body`), wired as described in [`checks.md`](checks.md#the-draft-verifier). On the maintainer's machine the verify tier is Qwen3.8 through `config.sh` (`verify) prefs=(qwen3.8 "${prefs[@]}") ;;`) with 0.6792 recorded for it in `verify-thresholds.tsv`; while it is loaded it adds about 28 GB beside the 35 GB prose model. Elsewhere the verify tier falls back to the prose model at no extra memory, and needs its own `--calibrate` run, since the uncalibrated 0.5 passes almost every draft on Qwen3.6. The raw data is in the data dir's `spikes/verify-readout-2026-10-07/`.
