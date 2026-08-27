# Self-improvement issue queue, round two (2026-08-27)

Successor to `2026-08-26-self-improvement-issue-queue.md`, which closed at ten
issues and released 0.29.0. Same rules, restated because they are what made the
first queue produce measurements rather than opinions:

1. One issue per PR.
2. Prefer a deterministic check or a mechanical guard over prompt wording. A
   third prose fix for a defect that survived two is not allowed.
3. Every new check must be proven to DISCRIMINATE: run the new tests against
   the tree WITHOUT the implementation, observe them fail, then apply and
   observe them pass. "The suite is green" is not evidence on its own.
4. Every recipe edit gets a dated entry in that recipe's `## Calibration notes`.
5. Quote the `n` beside every rate and say which verdict tier it came from.
6. Do not re-edit a recipe edited in the previous 24 hours unless new evidence
   contradicts that edit.

## Evidence this queue is drawn from

Gate reading 2026-08-27, watermark 2026-08-26T19:29:41Z, 14 new delegations,
all `--source agent` (human tier n=0, so nothing below is a quality rate).

Per-recipe usable rate, 7d: `github-issue-body` 0% (n=1, ignore),
`maintainer-reply` 21% (n=33), `pr-description` 37% (n=8),
`commit-message` 82% (n=29).

Deterministic check failures, 7d: `body_max_words` x6, `no_example_echo` x2,
`no_padding_tail` x1, `subject_max` x1. Ten failures, ten hand-edits or
discards; `no_padding_tail` is the only check in the wrapper that repairs
rather than reports.

Boundary-hook opportunity rows, all time: `git-commit` 38/149 delegated,
`comment-reply` 11/73, `pr-create` 6/48, `pr-review-comment` 0/30,
`issue-create` 0/15. 55/315 overall.

### Two corrections carried in from the previous queue's closing report

`#442` (derive the commit body shape from the word cap) was reported as
working on the strength of a controlled measurement: 92,92,92,92 words before
against 45,45,45,45 after, on the diff of `fafd439` at temperature 0. The
production rows tell a weaker story. It merged at 2026-08-26T23:19:35Z; the
three `commit-message` calls after it are 23:22:08 (`body_max_words` FAILED),
23:29:29 (clean), 23:34:15 (`subject_max`). One in three still overshoots.
n=3 is not a measurement, so the honest status is unresolved, and Issue 1
below is the response that does not depend on which way it resolves.

`#441` (guide callers to pick unrelated exemplars) merged at
2026-08-26T23:06:30Z. Both `no_example_echo` events predate it (20:02:51 and
22:11:08) and `pr-description` has taken no calls since. It is un-measured, and
under rule 6 the recipe is closed to further edits until it has taken some.
That is why the exemplar-contamination guard I proposed yesterday is NOT in
this queue.

---

## Issue 1 — a failed check reports but never repairs (#384)

**Evidence.** Ten deterministic check failures in the 7-day window across two
recipes. Every one of them ended with a human or agent rewriting or discarding
the draft. The wrapper already knows precisely what went wrong (it names the
check) and already holds the exact prompt that produced the bad output, but it
hands the failure to the caller instead of spending one more cheap generation
on it. `no_padding_tail` is the sole exception and repairs in place (ADR 0017).

**Fix shape.** One bounded retry. When a declared check fails, re-send the same
templated prompt with the failure named, once, and re-run the checks on the
second output. Not a loop, not a repair heuristic per check.

**Goals (each independently verifiable).**
- G1.1 A run whose first output fails a declared check issues exactly two
  model calls; a run whose first output passes issues exactly one. Verified by
  counting requests in the mocked-curl suite.
- G1.2 The retry prompt names the failed check(s) and the constraint violated.
  Verified by asserting the second request body contains the check name.
- G1.3 At most one retry per call, even if the retry also fails. Verified by a
  mock whose every response fails the check: exactly two calls, then exit.
- G1.4 The metrics row records `retried:true` and the post-retry
  `checks_failed_names`; a row with no retry carries no `retried` field.
- G1.5 `DELEGATE_NO_RETRY=1` restores today's single-call behaviour exactly.
- G1.6 The new assertions fail against the tree without the implementation.

**Result.** Done. `tests/test-delegate.sh` 686 -> 699 assertions, all green.

G1.6 first, because it is what makes the rest evidence: run against the tree
before the implementation, five of the thirteen new assertions failed — two
dispatches (got 1), the retried output reaching the caller (missing), the
second request naming the check (missing), the bounded count on a
always-failing mock (got 1), and `retried:true` on the row (missing). The other
eight are negative controls (no retry on a pass, `DELEGATE_NO_RETRY=1`, a bare
call, the first request carrying no rejection notice) and correctly passed
both before and after.

G1.1 47a/47b, G1.2 47c, G1.3 47d, G1.4 47e, G1.5 47f, plus 47g for the bare
call. Confirmed end-to-end outside the suite as well, against a mocked
provider: two dispatches, the second output shipped, and the appended block
reading `- subject_max: the first line must be at most 12 characters.` — the
limit read back out of the recipe's own frontmatter rather than restated, so
the sentence and the check cannot drift apart on the number.

One design point worth recording. The first pass's stderr is captured and
released only when no retry follows. Without that the caller sees "check
'subject_max' FAILED — REJECT this draft" immediately above a clean answer,
which is a complaint about a draft that was thrown away. `checks_failed` on
the metrics row is now the POST-retry state, which is what SKILL.md already
told the agent it meant ("the model's text still violates").

---

## Issue 2 — `INVENTED` reports a hallucination when the human only cut for length

**Evidence.** `self-improve.sh` computes `INVENTED` as salient tokens present
in the draft and absent from the shipped text, and `docs/self-improvement-loop.md`
calls it "The hallucination signal". The dominant `commit-message` rejection
shape is a pure compression: the facts are right, the body is too long, the
human cuts clauses. Every token cut for length therefore lands in `INVENTED`.

Four of the six rejections in the current window are exactly this, and each
one's own reason says so: 19:56:19 `INVENTED: delegate.sh test-delegate.sh`
against "the draft's facts were all correct but the body ran 92 words";
22:32:47 against "compressed to 37"; 22:49:38 against "that half-sentence was
cut"; 22:59:55 against "dropping the recipe name the subject already carries".
The two `pr-description` rejections in the same window are real fabrication
("fabricated two contradictions against its own input") and both carry a
non-empty `DROPPED` list as well.

**Fix shape.** A compression is distinguishable from a rewrite by the `DROPPED`
list: if the human added no salient token the draft lacked, and the shipped
text is shorter, nothing was replaced — material was removed. Label that case
`CUT` with the reason stated, and reserve `INVENTED` for the case where the
shipped text also carries tokens the draft lacked.

**Goals.**
- G2.1 A draft/final pair where the final's salient set is a strict subset of
  the draft's and the final is shorter prints `CUT`, not `INVENTED`.
- G2.2 A pair where the final carries at least one salient token the draft
  lacks still prints `INVENTED`.
- G2.3 Replaying the six pairs in the current window classifies the four
  compressions as `CUT` and the two `pr-description` fabrications as
  `INVENTED`. 6/6, recorded here as the measurement.
- G2.4 `docs/self-improvement-loop.md` describes both labels and says which
  one is the hallucination signal.
- G2.5 The new assertions fail against the tree without the implementation.

**Result.** _(to fill in)_

---

## Issue 3 — the boundary hook nudges on artifacts too small to be worth delegating

**Evidence.** `pr-review-comment` has fired 30 times and been satisfied by a
delegation 0 times. `issue-create` has fired 15 times and been satisfied 0
times. Those are the only two boundaries at an absolute zero, and 45 of the
315 opportunity rows sit in them.

For `pr-review-comment` the zero is very likely correct behaviour rather than
non-compliance: its recipe is `pr-review-reply`, whose entire output is a line
like "Applied in `<hash>`". A model round-trip for one line costs more than
writing it. If that reading holds, the hook has spent 30 nudges asking for
something nobody should do, which both pollutes the denominator of the
trigger-rate metric (#277) and trains the session to ignore the nudge.

**Fix shape.** The body being posted is present in the command the hook already
parses. Extract it and apply a floor: below N characters, record the
opportunity but do not nudge. This is a sensor fix, not a recipe change.

**Goals.**
- G3.1 A `gh api .../comments -f body="Applied in \`abc123\`"` produces no
  nudge; the same command with a multi-paragraph body still nudges.
- G3.2 A body passed via `--body-file` is measured from the file when it is
  readable and treated as above-floor when it is not (never silently skipped).
- G3.3 The opportunity row still records the boundary, so the denominator
  keeps the event; a new field distinguishes "not nudged, below floor" from
  "nudged and ignored".
- G3.4 The floor is one named constant with an env override.
- G3.5 The new assertions fail against the tree without the implementation.

**Result.** _(to fill in)_

---

## Issue 4 — `comment-reply` pins the closed short recipe for evidence-led replies

**Evidence.** `maintainer-reply` is the worst recipe in the corpus with a
meaningful sample: 21% usable over n=33, 26 rewrites. The rejection reasons are
one shape repeated: "collapsed all 14 facts into a single run-on sentence",
"dropped every measured fact from the context", "returned two sentences instead
of a four-paragraph body", "collapsed a four-paragraph review body into a
one-line summary". That is the closed two-sentence shape doing exactly what it
is designed to do, to a workload it explicitly excludes.

`#440` fixed the routing for `gh pr review --body`, which was not a boundary at
all. It has taken no traffic since (zero `pr-review-body` rows). The remaining
path is `comment-reply`, which pins `maintainer-reply` unconditionally.

Input size was tested as a discriminator on the OUTPUT side twice and dropped
both times (a kept call at 5,561 chars sits inside a rewrite range of
4,408-9,546). This issue is about the INPUT side at the boundary — the size of
the body being posted — which is a different measurement and has not been
tested.

**Fix shape.** Depends on Issue 3 landing the body extraction. Route
`comment-reply` by the size of the body being posted: short stays
`maintainer-reply`, long names `maintainer-review-reply`.

**Goals.**
- G4.1 A short `gh pr comment --body` still names `maintainer-reply`.
- G4.2 A long body names `maintainer-review-reply`.
- G4.3 The threshold is justified against the observed corpus, and the
  justification names the numbers it rests on.
- G4.4 The `suggested_recipe` on the opportunity row reflects the routing, so
  the change is measurable from the metrics alone.
- G4.5 The new assertions fail against the tree without the implementation.

**Result.** _(to fill in)_

---

## Issue 5 — record the post-landing measurements

Not a code change. `#442` and `#441` both closed with "re-measure after ~10
more calls"; this queue's opening reading is the first data point for one and
zero for the other. The queue closes by writing what the numbers actually say
into the affected recipes' calibration notes, including the possibility that
`#442` did not hold.

**Goals.**
- G5.1 `commit-message` calibration notes carry the post-`#442` production
  reading with its n.
- G5.2 `pr-description` calibration notes record that `#441` is un-measured.
- G5.3 Neither note claims a fix worked without a post-landing measurement.

**Result.** _(to fill in)_

---

## Findings log

New defects found while working the queue go here, with the evidence, and are
either promoted to an issue in this queue or reported and left.
