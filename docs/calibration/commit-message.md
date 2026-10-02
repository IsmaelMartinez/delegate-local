# Calibration history for [`prompts/commit-message.md`](../../prompts/commit-message.md)

## Calibration notes

This recipe is distilled from session 2026-05-09, where the same commit-message
task delegated three times to `qwen3.6:35b-a3b-q8_0` (prose tier) progressed
MISS → HIT-with-edits → HIT-verbatim. Each guard in the prompt template above
came from a real failure in that sequence: the abstract "concise / bulleted"
descriptor produced bullets when the project style is flowing prose; adding
verbatim recent-commit anchors plus explicit "no `(#NN)`", "no indentation", and
anti-padding-tail guards produced output used with zero edits.

The full dated calibration history (15+ entries from 2026-05-09 to 2026-06-16,
covering the subject-length ceiling, the TYPE-priority list, and the participial
and declarative padding-tail guards) lived inline here until the 2026-06-19
lean-core reset removed it for legibility. It is preserved verbatim in the
`pre-cleanup-2026-06-19` tag and the `archive/research-machinery` branch — read
it with `git show pre-cleanup-2026-06-19:prompts/commit-message.md`. The prompt
template above, the only part the model ever sees, is unchanged by the reset.

### 2026-08-26 — observed, not yet actioned: the body copies its input

Logged by the self-improvement loop so the next run has the history rather than
rediscovering it. Three rejections describe the body being lifted from the
prompt rather than composed from it: "near-verbatim restatement of the why
input rather than a compression" and "again restated the why input across two
paragraphs instead of compressing" (both 2026-08-19), and on 2026-08-26 a
subject that "echoed the recent_commits example ... wrong version (v4.37.6, the
version being bumped away from) and omitted the osv-scanner half of the
change". That last one is the `no_example_echo` failure shape (ADR 0029) aimed
at a `--var` value instead of the template, which the shipped check cannot see:
it compares against the PRE-substitution template precisely so caller-supplied
content never flags.

Four further rejections in the same window name an over-long body ("two
paragraphs against the owner's one-to-two-sentence house style", "three
paragraphs", "four clauses where the repo convention is one or two sentences").
Length may be the symptom rather than the defect: a body copied from `why` is
long because `why` was.

Deliberately unactioned this run, for two reasons. The template already says
"1-2 short flowing-prose paragraphs" twice under a "mandatory, non-negotiable"
heading, so a third rewording is the treadmill the loop is supposed to avoid;
and the input is not stored, so the copy hypothesis cannot be verified from the
corpus. The threshold problem is worse: the captured pairs separate rejected
bodies (104, 80, 61, 56 words) from shipped ones (43, 45) cleanly, but that is
n=2 on the shipped side, and this repo's own last 25 commits have a median body
of 103 words because squash merges absorb PR descriptions. Any numeric cap
picked today would be picked from noise.

What would settle it: enough `--final` pairs on `commit-message` to see whether
the rejected bodies share long verbatim runs with their `why` input. If they
do, the fix is an input-echo check, not a length cap.

### 2026-08-26 — the shape anchors were being copied as content (issue #428)

The question the previous note left open — whether the over-long bodies were a
length problem or a copying problem — was settled by a case with a checkable
answer. A `ci` bump on `ismaelmartinez.me.uk` (delegation ts 13:35:37) returned
the subject `ci: bump codeql-action init and analyze together to v4.37.6`.
Commit `310a855b` on that repo, thirteen days earlier and sitting in the
`recent_commits` anchors, reads `chore(deps): bump codeql-action init and
analyze together to v4.37.6 (#253)`. The words are identical; only the type
prefix and the PR suffix differ. The change being described was a bump TO
v4.37.8, so the message named the version it was moving away from, and dropped
the osv-scanner half of the change entirely. Filed independently as #428, which
reached the same diagnosis: "the likely mechanism is that `recent_commits`
reads as an exemplar to copy rather than as background".

That is the `no_example_echo` failure shape (ADR 0029) aimed at a `--var` value
rather than at the template, where the shipped check could not see it — it
compares against the pre-substitution template precisely so caller-supplied
content never flags. The fix generalises the check instead of adding a second
one: a recipe may declare `echo_guard_vars:` naming the vars whose values are
exemplars, and those join the forbidden-output pattern set. Two normalisations
make the real case catchable, both verified against it: the conventional-commit
type prefix and a trailing ` (#123)` are stripped from both sides, and a line
appearing in more than one exemplar is dropped from the pattern set, because
repeated across the anchors means convention rather than content. `pr-description`
declares `recent_prs` for the same reason — its `recent_prs` sits in the same
exemplar role, and the AI-815 leak was the same shape.

The template was also at fault and was changed, which is not a reworded length
rule but a different defect: it said "Draft a git commit message in EXACTLY the
same shape as these recent examples" under a heading reading "Recent commit
examples to match". SHAPE-NOT-CONTENT now states the precedence explicitly and
the heading says shape only.

Review caught a regression in the first cut, worth recording because it is the
second time this check has failed the same way: the type-prefix strip went on
the output side only, so an echoed template example beginning `fix:` stopped
matching the pattern it came from. The earlier version had the `Wrong:`/
`Correct:` label stripped from the template side only. Both are asymmetry, so
the normalisation is now a single `echo_normalise` applied to every pattern
source and to the output, and any future rule has to go there and nowhere else.

Unmeasured on purpose: this landed 2026-08-26 with no post-change data. The
prior `commit-message` keep rate is 36% over n=22; re-measure after ~10 more
calls before treating any movement as real.
### 2026-08-26 — body length became a check, after the copying fix left it standing

The previous entry closed the copying question and left the length one open.
This closes it, on the pairs the capture work has since produced.

Eight rejections in the rolling week name an over-long body — "two paragraphs
against the owner's one-to-two-sentence house style", "three paragraphs", "four
clauses where the repo convention is one or two sentences" — across four
projects. Three of them now carry a captured draft/final pair, and the pairs
separate without overlap: the bodies that shipped came in at 31, 37 and 43
words, and the drafts they replaced at 76, 104 and 104. Counting the other
rejected drafts in, everything at 56 words or more was cut and everything at 45
or fewer shipped, with nothing in between.

Paragraph count was measured first and discarded: no captured draft exceeds two
body paragraphs, so the "three paragraphs" in the reasons is counting the
subject and a paragraph cap would not discriminate. Word count does.

This is a check rather than a fourth attempt at the wording. The template has
said "1-2 short flowing-prose paragraphs" under a heading marked "mandatory,
non-negotiable" for the whole period the eight rejections cover, which is the
condition `docs/self-improvement-loop.md` names for escalating from prompt text
to a deterministic constraint. The prompt now carries the same number the check
enforces, so the model is not given two different targets.

The limit is `{{flavor_commit_body_max_words}}`, not a constant. How short a
commit body should be is house style, and the corpus that motivated this is one
maintainer's four projects, so baking 50 into the shipped default would be
encoding personal taste as a standard — the thing `scripts/flavor-defaults.sh`
exists to prevent. The default is 120, which is the prompt's own "1-2 short
paragraphs" and nothing tighter, and would have flagged none of the drafts
above. Projects that want the tighter behaviour set
`FLAVOR_COMMIT_BODY_MAX_WORDS` in their own `profile.sh`; 50 sits in the
observed gap between 45 and 56.

Unmeasured: landed 2026-08-26 with no post-change data, and inert at the
shipped default by design. Prior keep rate 34% over n=23. Re-measure after ~10
more calls on a profile that sets a tighter limit before treating any movement
as real.

### 2026-08-27 — the shape instruction and the word cap were contradicting each other

`body_max_words` (added 2026-08-26) made the overshoot visible: five failures in
the rolling week, the worst two at 92 and 71 words against a 50-word profile
limit. Making it visible did not make it stop — the draft still needed hand
compression every time, which is a scaffold rather than a hit. Of the fourteen
`commit-message` scaffolds in the live corpus, eleven are length rewrites.

The recorded reasons name the STRUCTURE, not the count: "body was three
paragraphs against this repo's one-to-two-sentence convention", "body ran to
four clauses where the repo convention is". That is the diagnosis. The prompt
asked for "1-2 short flowing-prose paragraphs" as a hardcoded literal while the
cap beside it came from the flavor profile. At the shipped 120-word default the
two agree; under a profile that tightens the cap to 50 they cannot both be
satisfied, because two stretches of prose short enough to fit do not read as
paragraphs. The model followed the shape it could see and overshot the number it
would have had to count, which is the expected outcome and not a model defect.

The shape is now `{{flavor_commit_body_shape}}`, derived from the cap in
`load-flavor.sh` after the profile is sourced. Measured against the real diff of
`fafd439` at temperature 0, four reps each: the previous wording produced a
92-word body on four of four, the derived shape 45 on four of four. 92 is the
exact number the 2026-08-26 rejection reason named, so this reproduces the
production failure and clears it — from over the limit to under it.

A synthetic one-line diff does NOT reproduce the defect (both wordings land near
30 words), which is worth knowing before anyone tries to re-measure this cheaply.

### 2026-08-27 — the post-landing reading on the derived body shape

`#442` landed at 2026-08-26T23:19:35Z with a controlled measurement behind it:
the same diff (`fafd439`) at temperature 0, four reps each, 92, 92, 92, 92 words
before and 45, 45, 45, 45 after. That is a real result and it is not the same
thing as production moving.

Production, as of 2026-08-27T07:00Z: the `body_max_words` check failed on 5 of
the 28 `commit-message` calls in the seven days before `#442` merged, and on 1
of the 7 since. 18% against 14%, on an n of 7. Those are not distinguishable,
so the honest status is that the fix is measured in the lab and unmeasured in
the field. Re-read this after roughly ten more calls; if the rate has not
moved by then, the contradiction between the hardcoded shape and the profile
cap was not the operative cause and something else is.

One thing did change and is worth separating out. The 2026-08-27 calls include
the first that needed no length edit at all, and the two most recent shipped
at 39 and 45 words. That is consistent with the fix working; it is also
consistent with four calls being four calls.

2026-09-30 (#589): `no_subject_echo` declared. `no_example_echo` let subject
copies through: a lone exemplar subject normalises under its 40-char floor and a
`;`-joined list of subjects is one line. Over the 368 stored drafts it flags 8
(5 rejected, 2 scaffold, 1 unverdicted, 0 kept), 5 of which no check caught.
Template `3c2e0ca3eebd` becomes `a20e93b62bab`.

### 2026-10-02 — a stronger SCOPE rule, rejected by the replay

The daily bundle (watermark 2026-10-01T21:14:59Z) had seven `commit-message`
scaffolds whose reasons say "added scope" or "omitted scope". In five of them
every recent-commit example carried `<type>(<scope>):` (`docs(plan)`,
`feat(yjs)`, `fix(yjs)`) and the draft still wrote a bare `<type>:`. The other
two had one scoped example and one bare one. The one-line SCOPE rule from
2026-06-08 was not holding, and the subject-length line still said "starting
with `'<TYPE>:'`".

Tried: a SCOPE-MATCH block marked non-negotiable (a scope is required when any
example has one, and it still applies under the TYPE override), with the
subject line naming both prefixes. Replay against `a20e93b62bab` on
`mlx-community/Qwen3.6-35B-A3B-8bit`:

    Summary: n=40  wins=1  losses=11  ties=28  errors=0
    Checks failed: champion=0  candidate=7
    Newest third (14 cases): wins=1  losses=3
    Verdict: REJECT — the candidate loses 11 cases and wins 1 (p=0.003).

The candidate added a scope on only two of the seven target cases
(`fix(useAllotmentData)`, `feat(audio)`), so the defect stayed. Where it did add
a scope, the subject sometimes went past `subject_max`, which accounts for most
of the seven new check failures. Reverted. The replay's columns cannot see
scope, so even an edit that worked would show only its cost. This is the
second prompt-text attempt at scope. The next attempt should be a check
(`scope_match` against `recent_commits`, like `subject_type`) or a caller
`--var scope`, and should not reword the rule again.
