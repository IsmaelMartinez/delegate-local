# Self-improvement issue queue, round three (2026-08-27)

Successor to `2026-08-27-self-improvement-queue-two.md`, which closed at seven
issues and released 0.30.0. Same rules, restated because they are what makes a
queue produce measurements rather than opinions:

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

Gate reading 2026-08-27, watermark 2026-08-26T19:29:41Z, newest row
2026-08-27T07:58:47Z, 20 new delegations, all `--source agent`. The human tier
is n=0, so nothing below is a quality rate.

Per-recipe usable rate, 7d: `github-issue-body` 0% (n=1, ignore),
`maintainer-reply` 21% (n=33), `pr-description` 37% (n=8),
`commit-message` 82% (n=34).

Corpus since the 2026-08-19 reset: 92 delegations, 89 feedback rows, 70 of
them rejections, 17 of those carrying a captured `final_file`.

Rejections and captured finals, per recipe, whole corpus:
`maintainer-reply` 32 rejections / 0 finals, `commit-message` 29 / 13,
`pr-description` 7 / 4, `github-issue-body` 1 / 0, bare 1 / 0.

Boundary-hook opportunity rows, all time: `git-commit` 42/183 delegated,
`comment-reply` 11/74, `pr-create` 7/61, `pr-review-comment` 0/49,
`issue-create` 0/17. 60/384 overall.

Deterministic check failures, 7d: `body_max_words` x6, `no_example_echo` x3,
`no_padding_tail` x2, `subject_max` x1.

### One correction carried in from round two's closing report

Round two reported the bounded retry (#446) as 0-for-2 in production. Both of
those rows (2026-08-27T06:43:28Z and 06:44:53Z) were written from the feature
branch before #446 merged at 08:06:04Z, by a build that had `retried` but not
yet the `retry_chars` field Copilot's review added later — both rows carry
`retried:true` with no `retry_chars`, which is the signature. `main`'s retry
has a production record of n=0, not 0-for-2. The honest status is unmeasured.

---

## Issue 1 - a trailing `--final` is swallowed into the reason text

**Evidence.** `delegate-feedback.sh` parses flags only until the first
non-flag argument, which is the verdict; everything after is reason words.
Three rejections in the live corpus therefore recorded a reason ending
`--final /Users/.../tmp/msg.txt` and no `final_file` at all. Against 17
successfully captured finals that is 3 of 20 capture attempts lost, 15%, and
each loss is a rejection that reaches the loop as prose about a draft nobody
can look at again — the exact ceiling ADR 0029 was written to break.

Reproduced on a synthetic corpus: `--final shipped.txt scaffold "reason"`
stores `20260827T090000Z-abcd1234.final.txt`; `scaffold "reason" --final
shipped.txt` stores nothing and writes the reason as
`body too long --final shipped.txt`.

**Goal.** Flag parsing continues past the verdict, so `--final`, `--ts` and
`--source` are honoured wherever they appear. A test that fails on the current
tree and passes after.

**Result.** Done, PR #454, merged as `e13e820`. Positionals are collected while
scanning continues and re-established as `"$@"` afterwards; `--` before the
verdict ends flag parsing so a reason can still name a flag verbatim. The
empty-array expansion uses the `${arr[@]+"${arr[@]}"}` form because bash 3.2 is
the macOS baseline. Seven new assertions were run against the tree without the
fix and all seven failed; three more are regression pins that passed before it.
Copilot approved with zero comments.

It proved itself on its own first production use: the verdict for this PR's own
commit message was recorded with a trailing `--final`, and the row carries
`final_file: 20260827T120143Z-76430325.final.txt` with a clean reason.

## Issue 2 - `pr-review-reply` is shaped for a workload that does not exist

**Evidence.** The `pr-review-comment` boundary has fired 49 times, 19 of them
today, and has never once been credited: 0/49 delegated, 0 pre-drafted. The
recipe it names has been called once in the corpus's lifetime and that call
was rewritten.

The cause is not that the replies are too short to be worth delegating. The 23
review-comment replies actually posted on PRs #440-#452 measure min 43, p25
230, median 312, p75 472, max 562 characters; only 4 of 23 are under 100. The
recipe permits "the opener, and at most one short clause... No additional
sentences beyond the opener and that single clause", which is roughly 150
characters. The mandatory three-opener contract holds on all 23 replies, so
the opener is right and the length cap is wrong: 19 of 23 posts could not have
been produced by the recipe the boundary keeps naming.

**Goal.** The recipe keeps its opener contract and its anti-flattery and
anti-padding rules, and gains an evidence body whose length is set by how much
evidence there is, in the PR-author voice (`maintainer-review-reply` is the
maintainer voice and is explicitly not this role). Prove the change with a
controlled generation at temperature 0 against a real posted reply's inputs,
before and after, and record it as a dated calibration note.

**Result.** Done, PR #456. The cap was doing two jobs — stopping padding and
stopping invention — and only the first survives a body long enough to carry
evidence, so `no_padding_tail` was declared to enforce that half
deterministically and an anchor-grounding rule states the other half directly.
`maintainer-review-reply` was rejected as the destination: it is the maintainer
voice judging someone else's contribution, and this is the PR author answering
a reviewer. The three cross-references that described the two recipes as
differing in length now say the axis is role.

Measured at temperature 0 on the prose tier against two real Copilot comments,
same `fix_summary` both times. #446 retry accounting: 145 chars / 1 fact before,
605 / 4 after, 482 / 4 posted by hand. #450 `--body-file /dev/zero`: 116 / 1
before, 291 / 3 after, 472 / 4 posted by hand. Both "before" outputs kept the
opener and dropped every piece of evidence, which is precisely the reply that
then had to be written by hand.

Two invariants pin the removal and the replacement check; both fail against the
pre-change recipe.

## Issue 3 - the worst recipe at scale has no captured evidence

**Evidence.** `maintainer-reply` is the weakest recipe with any volume: 21%
usable over n=33, 32 rejections. Not one of those 32 carries a captured final.
`commit-message` captures 13 of 29 and `pr-description` 4 of 7, so this is not
general discipline — it is structural. A commit message is written to a file
before `git commit -F` reads it, and a PR body likewise; a `maintainer-reply`
is posted inline inside `gh pr comment --body "..."`, so at the moment the
verdict is recorded there is no path on disk to hand to `--final`.

The result is that the recipe most in need of a (generated, shipped) pair is
the only one that has never produced one.

**Goal.** A mechanical capture path, not a prose instruction: the boundary
hook already sees the posted body and already knows whether the post is the
shipped form of a recent delegation (`delegated:true`). When it is, the hook
stores the body locally beside the drafts; `delegate-feedback.sh` adopts it as
the final when the caller passed no `--final`, and marks the row so an adopted
final is distinguishable from a hand-supplied one. Pairing must be tight
enough that a stale post cannot be filed against an unrelated draft.

**Result.** Done, PR #457. The hook stores a credited post's body at
`<data dir>/drafts/<stem>.final.txt` under the credited draft's own stem,
oldest-unspent-first to match the order a sweep posts in;
`delegate-feedback.sh` adopts it when the caller passed no `--final` and marks
the row `final_source:"posted"`. An explicit `--final` always wins, a `hit`
does not adopt, the hook never clobbers, and `DELEGATE_LOCAL_NO_METRICS=1`
suppresses the capture with the row. `self-improve.sh` prints "captured from
the post" beside those pairs, because the capture is pre-post and therefore
stores what was about to go out rather than what demonstrably did.

The body extractor was refactored so one awk scan serves both callers —
`want=len` returns exactly what #450's routing was calibrated against,
`want=text` returns the body — and all 205 existing boundary-hook assertions
passed unchanged across it.

21 new assertions across three suites. Eleven are negative pins that
necessarily pass on the old code; the ten that discriminate were run against
the tree without the change and failed there.

## Issue 4 - #450's routing threshold has no recorded measurement

**Evidence.** Round two routed the `comment-reply` boundary by posted body
size with a 600-character default, chosen without data, and said so. The
population is now measurable: 27 issue comments authored by the maintainer on
this repo measure min 8, p25 573, median 950, p75 1417, max 2522. A 600-char
split sends 19 to `maintainer-review-reply` and 8 to `maintainer-reply`, and
the short cluster it keeps (two comments under 200 characters) is exactly the
status-line shape `maintainer-reply` is capped for.

**Goal.** Record the measurement where the threshold is defined, so the next
person to move it knows what it was set against. Docs and calibration notes
only, no behaviour change.

**Result.** Done, PR #459. The guess holds and nothing moves: the split keeps
the two comments under 200 characters with `maintainer-reply` and sends the
rest to `maintainer-review-reply`. The measurement sits beside the pin in
`delegate-boundary-hook.sh` and in both recipes' calibration notes, with the
caveat that matters more than the number — the `pr-review-comment` population
has a median of 312 over n=23, where 600 would route nothing, so the threshold
is not transferable between boundaries.

## Issue 5 - `pr-description` invents headings the exemplars do not use

**Evidence, and a correction to it.** The first version of this issue said the
model invented `### Implementation Details` and `### Testing` against two
heading-free exemplars. That was wrong: I asserted the exemplars were
heading-free without checking, and `#413` carries three `###` headings, so the
model was matching a shape it had been shown. The check I had already written
stayed correctly silent on that input, which is how the error surfaced.

Re-measured against exemplars verified heading-free (`#422`, `#424`, both 0 by
the same scan the check uses), same facts, `DELEGATE_NO_RETRY=1` so the first
pass is visible: 4 runs of 4 invented at least one markdown heading. In the run
inspected in full the heading was `## Test plan`, whose items
`no_invented_task_list` already catches, so on this input the two checks
overlap; the independent value of the heading check is a section heading that
arrives without checkbox items under it. The SHAPE rule states the constraint
in prose — "Do NOT add '## Summary', '## Test plan', or any heading that the
examples themselves do not use" — and it has not held.

**Goal.** A deterministic check in the shape of `no_invented_task_list`, which
is already parameterised by `recent_prs`: when the exemplars carry no markdown
heading, an output that carries one fails. Proven to discriminate against
today's captured output, and warn-plus-retry like its sibling so the wrapper
gets one chance to fix it.

**Result.** Done, PR #458. `no_invented_headings: recent_prs` fires only when
the output has a heading and the named examples have none, so a repo whose
merged PRs all carry `## Summary` still gets that shape back. Fenced blocks are
skipped on both sides, because a PR body pasting a shell snippet carries
`# comment` lines that are not headings, and `#!/usr/bin/env bash` has no space
after the hash so it never matched. Eight new assertions, all eight failing
without the change — though on the old tree the negative cases fail because an
undeclared check prints "unknown check" rather than because the check
misbehaves, which is a weaker form of discrimination than the positive ones.

The recipe also gained the caller-side note F1a asks for: write `{{context}}`
as terse notes, not as finished sentences.

One result worth carrying forward: the PR body for this very PR passed every
declared check — no heading, no task list, no echoed exemplar line — and was
still fabricated. It invented a "previous implementation" of
`no_invented_task_list` that mishandled shell comments and described this
change as refining it. Notes-shaped context fixed the shape and not the facts.
Structural checks bound the shape of an answer and say nothing about whether it
is true, and this queue's four checks should not be read as covering more than
they do.

Copilot then caught the correction's own loose end: the check's provenance
comment in `delegate.sh` still named `#413` as heading-free, because I fixed the
calibration note and not the code comment. It now carries the correction rather
than only the corrected fact.

---

## Findings log

**F1 — WITHDRAWN, and the correction is the finding.** Two `pr-description`
calls (12:03 and 14:35) came back as the `--var context` file reflowed into
paragraphs — every line, in order, no synthesis. Both had fired #446's retry on
`no_invented_task_list`, and the obvious reading was that the retry satisfies a
constraint by copying the input, because copying invents nothing. That reading
is wrong. Re-running the 14:35 call with `DELEGATE_NO_RETRY=1` produces the
same verbatim echo on the FIRST pass, plus the invented `## Test plan` the
check exists to catch. The retry's only effect was removing that section, which
is exactly its job.

The retry's production record on `main` is 3 firings, 3 repairs, `checks_failed:0`
on all three. It has not been observed to damage an answer.

**F1a — `pr-description` returns prose context verbatim.** The real defect the
above uncovered. Given a `context` written as finished sentences the model
reflows and returns it; given the same facts as terse notes it does synthesise,
and glosses a fact while doing so (`DELEGATE_LOCAL_NO_METRICS=1 suppresses
capture` became "suppresses capture in local runs"). Same tier property
`pr-review-reply`'s calibration note recorded three hours earlier: the recipe
reshapes evidence, it does not compress it. No fix in this queue — the
mitigation is caller-side (pass notes, not prose) and belongs in that recipe's
`## Context to gather first`, which Issue 5's PR carries.

**F5 — I asserted a property of my own evidence without measuring it.** Issue 5
opened on the claim that two exemplars were heading-free prose. One of them
(`#413`) carries three `###` headings, so the output I called invented was the
model matching a shape it had been shown. The check caught the error by staying
silent where I expected it to fire. Same class as F3's non-discriminating test:
in both cases the instrument was right and the expectation was wrong, and in
both cases the only thing that surfaced it was running the measurement rather
than reasoning about it.

**F3 — a real path traversal, caught by Copilot and reproduced.** `draft_file`
is read out of the metrics JSONL and became part of a path both scripts write
to. A row carrying `../escaped.draft.txt` wrote the captured body one directory
above the drafts store. Both scripts now require a bare filename with a
`.draft.txt` suffix. The exposure on `delegate-feedback.sh`'s `parent_draft`
predates this queue; the capture path is what made it worth finding.

The near-miss is worth recording too: my first traversal test PASSED against
the unguarded code. The absolute path I built produced a doubled path that did
not exist, so the write failed by accident and the assertion read as a guard
working. A relative `../` landing in a directory that does exist is what
exposed it. Same failure mode as the non-discriminating test in round two —
an assertion that passes for the wrong reason looks exactly like one that
passes.

**F4 — an uncommitted edit for one issue rode into another issue's PR.**
Issue 4's threshold comment was written on its own branch, left uncommitted
during a `git checkout` back to Issue 3's branch (which carries uncommitted
work across), and swept up by a `git add -A scripts tests`. Caught by reading
the commit, removed in `de9b7b1`. Cheap here, but the general shape — a
partially-staged edit surviving a branch switch — is how one-issue-per-PR
quietly stops being true.

**F2 — the pr-description recipe lost a call to one bad output.** The PR body
for #456 was hand-written without delegating, and the boundary hook correctly
recorded the miss. The reason was the 12:03 echo: having watched the recipe
return the context verbatim an hour earlier, delegating again looked like a
waste of a call. Worth naming because it is how a recipe's usable rate decays
without any further defect — one bad output changes the caller's behaviour
before the metrics can show it, and in this case the caller's diagnosis of
that output was itself wrong (F1).

## Closing record

Five issues, five PRs: #454 (trailing flags), #456 (the `pr-review-reply` cap),
#457 (capturing the posted body), #458 (`no_invented_headings`), #459 (the
threshold measurement). No release; that decision has not been asked for.

### What this round's own delegations measured

The session dogfooded the changes as it made them. Twelve delegations against
`delegate-local` between 11:40 and 15:18, twelve verdicts, all `--source agent`
(the human tier is still n=0, so none of this is a quality rate): 10 scaffold,
2 miss, 0 hit. Every one carries a captured final, against 17 of 70 across the
corpus before today. By recipe: `pr-review-reply` 5 scaffold, `commit-message`
4 scaffold, `pr-description` 1 scaffold and 2 miss.

`pr-review-reply` is the result to watch. It had one call in the corpus's
lifetime and its boundary had converted 0 of 49. After the cap came off it took
five calls in one afternoon and the boundary converted 5 of 6. All five were
scaffolds, and the edits were compression, a backticked literal, and two
inverted causal clauses — which is what a working recipe looks like at this
tier. Five calls is not a keep rate; it is evidence the recipe is now reachable.

Boundary conversion for the round: `pr-review-comment` 5/6, `pr-create` 3/5,
`git-commit` 5/17, `pr-review-body` 0/2, `issue-create` 0/1. The `git-commit`
misses are honest — most were `chore: apply Copilot review` commits written
inline mid-loop, and the hook was right to nudge each time. Two of the
`pr-create` misses were the same shape: a body hand-written straight after a
bad delegation (F2), and one written for a docs-only PR without trying.

### What is not measured

Issue 3's capture path has produced zero `final_source:"posted"` rows in
production. It merged at 15:04 and both verdicts since passed `--final`
explicitly, which correctly wins. Its assertions prove the mechanism; nothing
yet proves it fires in a real sweep.

Issue 5's check has never fired outside a controlled run, and its most likely
real firing overlaps with `no_invented_task_list`.

`maintainer-reply` and `maintainer-review-reply` both still need traffic, and
`maintainer-review-reply` is still at n=0 calls behind three routing fixes now.

### Two lessons

Both of this round's real corrections came from running a measurement rather
than reasoning about one. F3's traversal test passed against unguarded code
because the path I constructed failed by accident; F5's heading defect was the
model matching an exemplar I had not looked at. In both cases the instrument
was right and the expectation was wrong. Rule 3 of this queue asks that a new
check be proven to discriminate; the corollary this round adds is that the
evidence a check is built on has to be measured with the same suspicion.

And structural checks are not truth checks. #458's own PR body cleared every
check in the file and was fabricated anyway.
