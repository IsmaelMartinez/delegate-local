# ADR 0033: Typed decision questions are adopted on the resident model; Clef is kept for batched labelling only

Status: accepted.
Date: 2026-10-06

## Context

Cloudflare released Clef (27B) and Clef-flash (9B) on 2026-10-01: open
"decision models" that take a state and a set of typed questions (`noul`
for a probability, `choice` for one category, `score` for an ordered rubric)
and return a calibrated probability for every option of every question in a
single forward pass, with no text generated. The question put was whether a
model built for decisions rather than prose could make this skill's own
decisions better: whether to fire the skill, which recipe failed and how,
which of two replayed drafts is better, whether a draft will be kept, and
small labelling chores such as which labels an issue carries or which
conventional-commit type a diff is.

The skill already has one free decision backend: the resident prose model
(`Qwen3.6-35B-A3B-8bit` on `mlx_lm.server`) asked a lettered question with
`max_tokens` 1 and the option letters read off `top_logprobs` (at most 10;
the server drops the connection above that). It costs no new runtime, so it
is the control every Clef number is read against. The spike is epic #642
with #636 to #641; `scripts/decide.sh` (#643) sends the same SystemOne body
to either backend and `scripts/export-verdicts.sh` (#645) builds a
dev/holdout dataset from the verdict corpus. Clef-flash runs on Apple
Silicon through a small `uv` server in the data dir (`spikes/clef/serve.py`,
MPS, bfloat16, about 29 s to load, about 18 GB); the 27B was downloaded and
not loaded, because it needs about 55 GB beside the 33 GB resident model and
the Docker stack.

## Investigation

The first round asked each question the way the skill's prompts already
phrase it: a free-text state and one question per request. Every gate
failed, for both backends. The trigger eval (#638) reached 19 of 22 gated
recall for Clef-flash and for the control against a gate of 0.9 at
negative-precision 15 of 15; the failure-mode label (#639) matched 40 hand
labels on 28 cases for Clef and 27 for the control; the replay tie-break
(#640) chose draft B in 7 of 8 ties whichever draft was B; and the
usability predictor (#641) had an AUROC of 0.476 within `commit-message`
for Clef and 0.392 for the control, with a `choice` Brier score worse than
the base rate. A rerun of the trigger eval with the GPU otherwise idle
reproduced the first numbers to four decimal places, so contention had cost
time and not accuracy.

The second round rewrote the questions on the published guidance for these
models rather than on the skill's prompt habits: the state is a JSON object
with named fields, questions refer to fields in backticks, each question is
atomic and the combination is done in code, `choice` options carry
contrastive `what` and `not_for` descriptions plus an `other`, and the
criteria for the trigger question are cut mechanically from `SKILL.md`'s
own MUST and Do NOT sentences. Under that format the trigger eval passes for
both backends: at a threshold of 0.5 Clef-flash reaches 22 of 22 recall and
14 of 15 negative-precision with an AUROC of 1.0 and a Brier score of 0.017,
and the control 21 of 22 and 15 of 15 with a Brier score of 0.024; a 2-fold
cross-validated threshold of 0.85 gives Clef-flash 22 of 22 and 15 of 15.
The format was the defect, not the model, and the resident model alone can
revive the CI trigger gate that died with GitHub Models (#548, #625).

The same rewrite did not rescue the judgment tasks. Contrastive criteria
took the failure-mode label from 28 to 28 of 40 with a better Brier score
(0.411 from 0.482) and a multi-label variant fell to 15. The tie-break asked
in both orders agreed with itself in 2 of 8 `maintainer-review-reply` ties
and 13 of 33 `pr-description` ties, so averaging the orders hides a bias
rather than removing it, and scoring each draft alone on five atomic checks
picked the shipped candidate in 14 of 33, which is chance; the ground truth
is also weak there, since a tied pair may be equal. The usability predictor
rebuilt from five atomic checks (grounded, restates, key facts, follows
format, filler) and fitted by logistic regression on 802 dev rows scored
0.849 AUROC on 158 holdout rows, but that is recipe identity leaking through
(issue bodies are always kept, replies never are); within `commit-message` it
is 0.425 and within `pr-description` 0.100, and the one recipe with signal is
`pr-review-reply` at 0.870 on 18 rows. Clef-flash's own card puts it at 35.6
on RAGTruth against 79.4 for the 27B, so the grounding check this predictor
leans on is the one capability the small model is known not to have.

Labelling is where the decision format earned its place. Three closed-set
tasks were built from this repository's own history, each one `choice` with
contrastive criteria over a named state: the type label of 69 issues (bug,
enhancement or documentation), the plan lane of 39 issues, and the
conventional-commit type of the last 160 commits on `main` from the diff,
file list and body with the subject hidden. Accuracy against the majority
baseline was 0.84 (Clef-flash) and 0.88 (control) over 0.62 for issue type,
0.92 and 0.82 over 0.31 for lane, and 0.77 and 0.84 over 0.43 for commit
type, at a median of 0.5 to 1.2 s a call with no errors in 536 calls. The
control's confidence is the usable one: at `p >= 0.9` it covers 68% of
commits at 0.95 accuracy and 70% of issue types at 0.94, so a tool can apply
those and hand the rest back; Clef-flash at `p >= 0.8` on commit type was
right 74% of the time, a threshold that is not honest on this corpus. Both
leaned on `fix`, and both told `chore` apart in 3 of 11 cases, which is
partly the inconsistency of the labels themselves.

What a single-question comparison hides is the structural difference.
Clef scores every question of a request in one forward pass and its joint
head lets options cross-attend to each other and back to the state; the
control pays one chat call per question. Measured on three issues: one
question costs 0.46 s on Clef-flash and 0.48 s on the control, five cost
0.49 s against 2.1 s, and fourteen cost 1.1 s against 5.4 s. So a
select-all-that-apply pass over a whole corpus, one request per record with
a `noul` per label, is where Clef-flash is cheaper by the number of
questions, and the hosted model takes up to 64 a request.

That pass was then run over the 114 labelled issues with fourteen `noul`
questions a request, one per label, phrased two ways (as a question, and
with true and false criteria), both ways in one request, and on the
control. Ranking is good on both backends for any label with more than a
handful of positives: bug at 0.94 and 0.95 AUROC, prompt-pattern at 0.98
and 0.98, lane-analytics at 0.96 and 0.90, with Clef-flash ahead on the
lanes and the control ahead on needs-decision (0.85 against 0.76).
Deciding is not. At a 0.5 cut the control over-fires on every rare label
and gets the exact label set right on 4 of 112 issues, Clef-flash on 16 of
114; a per-label threshold chosen by 2-fold cross-validation lifts
Clef-flash's criteria phrasing to 25 and the control to 13, because two to
eight positives cannot set a threshold. Three aggregation results answer
whether asking more buys accuracy. Both phrasings in one request gave the
same answers as each alone (bug F1 0.74 against 0.75), so the joint head
neither helped nor hurt; averaging the two phrasings moved bug's F1 to 0.81
and the exact sets to 23, not a consistent gain; averaging Clef-flash with
the control lifted the hard labels (enhancement F1 0.68 against 0.62 and
0.59, lane-core 0.56 against 0.36 and 0.22) and matched the best single run
at 25 exact sets. The cost side is the structural one: 1.8 s an issue for
all fourteen labels on Clef-flash, 4.1 s for twenty-eight questions, and
7.9 s on the control for fourteen calls. The shape that fits exclusive
groups, a `choice` for the type and one for the lane with an explicit none
beside `noul`s for the independent flags, is written and smoke-tested but
not run: the batch jobs had the laptop at 96 °C and were stopped, so it is
the first run to make once #646 gates the GPU.

## Decision

Typed decision questions are adopted as maintainer tooling through
`scripts/decide.sh`, in the second-round format: a named-field JSON state,
backtick references to fields, one atomic question per property and the
combination, weights and thresholds in code, with every threshold calibrated
on this corpus before it gates anything. The default backend is the resident
model's logprobs, because it is free, better calibrated on single questions
here and already running; `--backend clef` keeps Clef-flash as the
backend for batched many-question jobs over a corpus, where its one-pass
scoring is measured to be four to five times cheaper, and its server stays
in the data dir rather than the repo. Set-valued labels use a `choice` for
each mutually exclusive group and a `noul` only for an independent flag,
with any threshold set per label on this corpus, and where a label is rare
the two backends are averaged, which was the best run measured. The first uses are the ones measured:
reviving the trigger gate with the `ref` format on the resident model
(#638), feeding the commit type into `commit-message` as an input instead
of a guess, and suggesting issue labels at creation. Nothing is wired into
the delegation hot path, and no decision model grades drafts, breaks replay
ties or predicts verdicts; those stay with the replay harness of ADR 0031
and the agent's own verdict (ADR 0030).

## Consequences

Decision questions are a cheap, measurable primitive this skill did not have,
and their quality depends on the question's format more than on the model
behind it, so the format rules above are the thing to keep. Batch jobs over
the corpus heat the laptop and contend with the live server for the GPU;
#646 gates them. The 27B is the model to test on grounding before any
hallucination check is trusted, and only once the GPU gate exists, since it
cannot sit beside the resident model and Docker. Cloudflare's RL fine-tuning
of Clef on a customer's own labels is a hosted service, so the verdict corpus
cannot train a local predictor by that route. This decision is revisited on
a new lever: a hallucination check from the 27B that beats the base rate
within a recipe, or a decision task whose ground truth is less ambiguous
than kept-versus-edited.

## Alternatives considered

Wiring Clef into `delegate.sh` as a pre-check on every delegation: rejected,
since no measured check predicts a kept draft within a recipe and it would
add a second model server to a skill installed by `npx skills add`. Using
Clef as the replay judge: rejected on the order inconsistency above. Keeping
only the control and dropping `--backend clef`: rejected because the
many-question cost curve is a real difference for corpus-wide labelling and
the client is one case branch. Loading the 27B alongside the resident model
for every question: rejected on memory; it is a scheduled test, not a
runtime.
