---
tier: prose
inputs:
  recent_commits: string
  diff_stat: string
  why: string
  type: string?
echo_guard_vars: recent_commits
checks:
  subject_max: {{flavor_commit_subject_max}}
  no_padding_tail: true
  body_required: true
  body_max_words: {{flavor_commit_body_max_words}}
  subject_type: {{type}}
---
# commit-message

## When to use

The user has staged a change and wants a git commit message in the project's voice. Subject line plus a short body explaining the WHY. Single commit per message — squash-merge style, not multi-bullet release notes (use `release-note.md` for that).

## Context to gather first

Run all three before invoking the recipe:

```bash
git log <main-branch> --pretty=fuller -3   # 3 verbatim recent commits as shape anchors
git diff --cached --stat                    # what changed
git diff --cached                           # full diff if the change is small enough
```

The `--pretty=fuller` flag is load-bearing — the model learns the project's body shape (flowing prose paragraphs vs bullet lists vs hybrid) from these examples, not from any abstract description. Without them the prose-tier default is bulleted lists regardless of what you ask for.

## Prompt template

```
Draft a git commit message from the staged diff and recent-commit anchors below. Do not invent file paths, PR numbers, or features that are not present in the diff.

Draft a git commit message in EXACTLY the same shape as these recent examples.
SHAPE-NOT-CONTENT — non-negotiable, outranks every other instruction about the examples:
The recent commits below show you the FORM of a message in this project: the type vocabulary, the subject length, the register, whether there is a scope. Their WORDS and their VALUES belong to changes that already happened and are not yours to reuse. Never copy a subject from them. Never carry over a version number, a file path, a PR number, a package name or a count that appears only in them. Every fact in your message must come from the diff and the WHY context; if the examples are the only place a detail appears, it is not a detail about this change.
Subject ≤ {{flavor_commit_subject_max}} chars starting with '<TYPE>:' ({{flavor_commit_types}}).
Then a blank line, then {{flavor_commit_body_shape}}, {{flavor_commit_body_max_words}} words maximum for the whole body (NO bullet lists, NO indentation).

BODY — mandatory, non-negotiable:
Every message MUST have a body, not just a subject. After the subject and a blank
line, write {{flavor_commit_body_shape}} saying WHY the change was made.
This holds even when the diff is tiny — a rename, a one-line config edit, a
test-only or docs-only change — and even when every recent-commit example below
is subject-only. Those examples are squash-merge subjects with their bodies
stripped; do NOT copy their bodyless shape. When the change looks too small to
explain, state what it does and draw the motivation from the WHY context below —
never fall back to a subject-only message. A subject with no body is REJECTED.
Wrong:
fix: bump the model-resolution cache TTL to 60s
Correct:
fix: bump the model-resolution cache TTL to 60s

The 10s TTL re-shelled out to the model list on nearly every delegation, adding
latency on hosts with many installed models. Sixty seconds keeps resolution
fresh while collapsing the repeated process spawns.

Subject length — first match wins, non-negotiable:
Count the characters in your subject line including the '<TYPE>:' prefix.
If the count exceeds {{flavor_commit_subject_max}}, REWRITE the subject before emitting. Drop adjectives,
collapse "X and Y" pairs to whichever is primary, prefer the shorter
synonym. The {{flavor_commit_subject_max}}-char limit is a hard ceiling, not a guideline.
Wrong: feat: prompts/summarise-issue — OMIT-EMPTY positive directive + Comment-N citation guard (79 chars)
Correct: feat: prompts/summarise-issue — OMIT-EMPTY + Comment-N guard (60 chars)

TYPE override (highest priority): {{type}}
If a value appears after the colon immediately above, use it verbatim as the
subject prefix — for example a value of `chore` means the subject MUST start with
`chore:`, a value of `ci` means it MUST start with `ci:`, and so on for any type
in the vocabulary — and SKIP the priority list below entirely. If no value
appears after the colon, ignore it and select the type from the priority list.

TYPE selection — first match wins, non-negotiable. Stop at the first rule
that matches. `feat:` means a NEW user-facing capability, so it is checked ahead of the
path-scope and keyword rules: a new recipe is a feat, but a new ADR, an
extracted internal helper, or a docs/CI-only edit is not. `chore:` is the
catch-all for housekeeping that matches nothing more specific.
1. If the diff body or WHY paragraph mentions "fix", "bug", "regression", "broken", "hang", "crash", or "leak" → `fix:` (a fix confined to docs/CI/tests is still `fix:`, not `docs:`/`ci:`/`test:`; whether to add an area scope like `fix(ci):` follows the SCOPE rule below)
2. If the diff adds a NEW user-facing capability — a command-line flag, env var, recipe, subcommand, or standalone CLI script that did not exist on main → `feat:`. Extracting an internal helper from existing code is NOT a feat (see rule 4).
3. If the WHY or diff is about performance — "performance", "faster", "optimise", "optimize", "latency", "throughput", or "speed up" → `perf:`
4. If the WHY or diff describes restructuring existing code with no new capability and no behaviour change — "refactor", "restructure", "extract", "rename", "move", "simplify", "deduplicate", "consolidate", or "inline" → `refactor:`
5. If the diff touches ONLY tests (tests/, *_test.sh, fixtures under tests/) → `test:`
6. If the diff touches ONLY documentation (.md edits, comments, ADRs, README, ROADMAP) → `docs:`
7. If the diff touches ONLY CI config (.github/workflows/, .gitlab-ci.yml, other pipeline files) → `ci:`
8. If the diff touches ONLY the build system or dependencies (Makefile, Dockerfile, package manifests, lockfiles) → `build:`
9. If the diff is other maintenance — housekeeping config (.gitignore, editor/lint config), release scaffolding, or a version bump → `chore:`
10. Default: `feat:`
Wrong: feat: handle stale lock file when daemon crashes (this is a bug fix — should be fix:)
Correct: fix: handle stale lock file when daemon crashes
Wrong: docs: add the code-draft recipe (a new recipe is a new capability — should be feat:)
Correct: feat: add the code-draft recipe
Wrong: chore: add a CI job to run the trigger eval (CI-only change — should be ci:)
Correct: ci: add a CI job to run the trigger eval
Wrong: feat: extract the model lookup into a helper (no new capability — should be refactor:)
Correct: refactor: extract the model lookup into a helper

SCOPE: if the recent examples use `<type>(<scope>):`, your subject must too, naming the diff's main area; else bare `<type>:`.
Wrong: fix: refresh token before handshake
Correct: fix(auth): refresh token before handshake

Subjects ending in (#NN) are REJECTED. The (#NN) suffix in every recent
example below was appended by GitHub's squash merge AFTER the commit was
written. Your subject MUST NOT include (#NN). This rule is non-negotiable.
Wrong: feat: delegate.sh recipe loading and placeholder validation (#73)
Correct: feat: delegate.sh recipe loading and placeholder validation

Do NOT indent the body lines — output should be flush-left.
Stop after the substantive content. Do NOT add a trailing sentence that restates the point. Do NOT append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting", "providing", "allowing", "making", "enabling", "highlighting", "underscoring", "replacing", "supporting", "keeping", "exemplified"). Do NOT end with a declarative rephrase ("This means", "This approach", "The result is", "In effect", "Overall", "In summary", "To summarise", "This ensures", "This enables", "This guarantees", "This delivers", "This provides"). Do NOT end with restating phrases ("this distinction is crucial", "this is crucial", "this is essential", "across diverse environments", "closes the gap", "closing the gap", "closes the loop", "closing the loop", "going forward", "moving forward"). End on a finite verb introducing new content, or stop.
Wrong: The endpoint validates JSON inputs, providing structured error responses on failure.
Correct: The endpoint validates JSON inputs and returns structured error responses on failure.
Wrong: The migration script copies rows in batches, allowing the source table to stay readable.
Correct: The migration script copies rows in batches so the source table stays readable.
Wrong: This ensures the rate limiter and the cache invalidator stay in sync.
Correct: (sentence ends after the substantive content; no This-X restating tail at all.)
Wrong: This closes the gap between the documented contract and the wire payload.
Correct: (sentence ends after the substantive content; no closes/closing-the-gap or -loop tail at all.)
Output ONLY the commit message itself, nothing else.

=== Recent commit examples (SHAPE ONLY — copy the form, never the words or values) ===
{{recent_commits}}

=== This commit (changes) ===
{{diff_stat}}

=== Context for the WHY paragraph ===
{{why}}
```

## Variables

- `{{recent_commits}}` — output of `git log <main-branch> --pretty=fuller -3`. Load-bearing shape anchor.
- `{{diff_stat}}` — output of `git diff --cached --stat` (and optionally the full `git diff --cached` if small).
- `{{why}}` — one or two sentences explaining the motivation: what bug, what user-visible change, what reviewer feedback. Authored by the agent, not gathered from a command.
- `{{type}}` — OPTIONAL. The conventional-commit type (any type in the flavor vocabulary, e.g. `feat`, `fix`, `docs`) when the caller already knows it. When set, it overrides the TYPE-selection priority list and forces the subject prefix verbatim, sidestepping the model's type inference entirely. Omit it to let the priority rules choose; an omitted value is blanked by `delegate.sh` so the placeholder collapses to empty. When set, it also feeds the frontmatter `subject_type: {{type}}` check (ADR 0014), which warns on stderr if the emitted subject does not start with that type — the deterministic backstop for the recurring "model ignored the explicit override" MISS.
- `{{flavor_commit_subject_max}}` — subject-length ceiling in characters. Injected from the flavor profile (ADR 0013), not passed via `--var`: shipped default `72` (the git subject convention), overridable per-user through `~/.local/share/delegate-local/profile.sh` (generate one with `scripts/onboard.sh` or `scripts/derive-flavor.sh`).
- `{{flavor_commit_types}}` — allowed conventional-commit type vocabulary for the subject prefix. Injected from the flavor profile, not passed via `--var`: shipped default `feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert` (the @commitlint/config-conventional standard enum), overridable per-user.
- `{{flavor_commit_body_shape}}` — the body's structural instruction. Injected from the flavor profile and DERIVED from `{{flavor_commit_body_max_words}}` rather than shipped as a constant: at or below 60 words it resolves to `one short flowing-prose paragraph of one or two sentences`, above it to `1-2 short flowing-prose paragraphs`. The derivation runs after the profile is read, so tightening the cap cannot leave the prompt asking for a shape that does not fit inside it. Set `FLAVOR_COMMIT_BODY_SHAPE` in `profile.sh` to override it outright.

## Invocation

Run the context commands above as their own step, then pass what they printed as literal `--var` values:

```bash
bash scripts/delegate.sh --recipe commit-message \
  --var recent_commits="<the git log --pretty=fuller output>" \
  --var diff_stat="<the git diff --cached --stat output>" \
  --var why="<one or two sentences>" \
  --var type=feat \
  "Match the example commit messages exactly in shape and tone. Keep subject ≤ 72 chars. Use the feat: prefix."
```

The trailing prompt arg is the reinforcement instruction; the recipe template carries the structural directives. When you already know the type, pass it as `--var type=<type>` — the template substitutes it as a highest-priority override that short-circuits the priority-list reasoning entirely, which is the most reliable lever because the model copies a literal token rather than inferring a rule (see the 2026-06-04 calibration entry). Leave `--var type` off to let the priority list choose. The `Use the <type>: prefix.` suffix is the call-site reinforcement for the no-explicit-type case — walk the TYPE-selection priority list in the template body top to bottom, take the first matching rule's type, and substitute it literally into the trailing prompt. (The mapping is intentionally not re-enumerated here so it cannot drift out of sync with the list above.) The 2026-05-23 calibration entry below documents why this hint is part of the recipe rather than a workaround.

## Anti-hallucination guards (each line addresses a real past MISS)

- "EXACTLY the same shape" — generic "match the style" produces bullets.
- "Subject ≤ 72 chars starting with '<TYPE>:'" — without this, the model inflates subjects past 100 chars or invents non-conventional prefixes.
- "NO bullet lists, NO indentation" — required because `git log --pretty=fuller` outputs bodies indented 4 spaces; the model copies the indentation literally if not told otherwise.
- "BODY — mandatory, non-negotiable" block with a contrastive Wrong/Correct one-shot — addresses a body-drop cluster observed 2026-06-12 / 06-13 (5 of 17 `commit-message` calls returned a subject-only message) where bodyless `{{recent_commits}}` anchors (from `git log --oneline` or squash-merged history) led the model to copy the missing-body shape. The bare directive ("A body is MANDATORY … never copy a subject-only shape") held most of the time but still dropped the body on the thinnest diffs; on 2026-06-23 `tests/bench-commit-message-body.sh` reproduced it on the lowest-context fixtures (a test-only add, a config-only add) on both Qwen3.6-35B backends (MLX 8bit and Ollama q8_0), confirming a model-bound, recipe-side starvation rather than a backend-specific bug. The fix mirrors what flipped the subject-length, `(#NN)`, scope, and padding guards from MISS to HIT — converting the bare rule into a prominent non-negotiable block with a contrastive one-shot (using a cache-TTL example unrelated to any bench fixture so it cannot leak an answer). Paired with the warn-only `body_required` check (ADR 0014) as the deterministic backstop.
- "Subjects ending in (#NN) are REJECTED ... non-negotiable" with a Wrong/Correct contrastive
  example — the bare negation `Do NOT append any (#NN)` did not hold across sessions: the
  model pattern-matched on the `(#NN)` suffix in every recent-commits anchor and inferred
  the next number. Strengthened on 2026-05-10 (issue #74) after a 3/3 MISS reproduction;
  the contrastive Wrong/Correct one-shot plus the "non-negotiable" directive flipped it
  to 5/5 HIT on the same input.
- "SCOPE — match the recent examples" with a Wrong/Correct one-shot — addresses a
  2026-06-08 teams-for-linux MISS where the model dropped the repo's `fix(auth):`
  scope convention and emitted a grammatically awkward bare-`fix:` subject. The
  recipe modelled the conventional-commit type thoroughly but had no notion of
  scope, so the model copied shape and tone yet flattened `type(scope):` to bare
  `type:`. The wrapper's `subject_type` check already strips an optional `(scope)`
  (ADR 0014), so the gap was purely the prompt never asking for one.
- "TYPE selection" list extended from 5 types to cover `ci`, `build`, `perf`,
  and `refactor` — addresses a 2026-06-25 cluster (issue #337) of three
  `commit-message` MISSes in one day where the model emitted `chore:` for a
  CI-only change (the old rule mapped CI to `chore:` despite the dedicated
  `ci:` type) and `chore:` for a pure refactor (no `refactor:` rule existed).
  The first cut at the fix demoted `feat:` below the new `docs`/`perf`/
  `refactor` rules and dropped `chore:` from the reachable set; a pre-merge
  review (PR #338) caught the three regressions that introduced: a new recipe
  `.md` mislabelled `docs:` instead of `feat:` (the repo's most common
  change), a real feature whose WHY mentioned "simplify"/"faster" stolen by
  the greedy keyword rules, and housekeeping diffs defaulting to `feat:`
  (an unwanted semantic-release minor bump) because `chore:` was unreachable.
  The shipped ordering keeps `feat:` high but narrows it to a NEW user-facing
  capability (so an extracted internal helper still falls to `refactor:`),
  puts `test:` ahead of `docs:` so a `.md` fixture under `tests/` is `test:`
  not `docs:`, and restores `chore:` as the housekeeping catch-all. Four
  Wrong/Correct one-shots (bug→`fix:`, new-recipe→`feat:`, CI→`ci:`,
  extract→`refactor:`) anchor the confirmed cases; the intent-only
  `fix:`-vs-`feat:` call stays a caller `--var type` decision.
- "Output ONLY the commit message" — without this, the model wraps in prose like "Here's the commit message:" which has to be stripped.
- "Stop each paragraph after the substantive sentences. Do NOT add a trailing
  sentence that restates the point …" — addresses the prose-tier padding
  failure mode documented in SKILL.md's Discipline section. The guard
  names both participial form (", ensuring that…", ", enabling…") AND
  declarative form ("This ensures…", "This enables…", "…closing the gap
  in X", "…going forward"). The participial form was added 2026-05-11
  from PR #84 commit-message HIT-with-edits where 2 of 2 paragraphs
  exhibited the shape despite all earlier guards holding. The declarative
  form was added later the same day after PR #86's T4 dogfood produced
  a 6/6 score on the participial regexes yet still emitted "This ensures
  the anti-padding hardening is measured rather than merely asserted."
  and "…closing the gap in the empirical-accuracy framework." — the
  recipe had told the model to drop participial tails but had not named
  the declarative restating shape, and the model complied literally with
  the rule it knew.

## Expected output shape

```
<type>[(<scope>)]: <subject in flowing prose, ≤ 72 chars, no PR ref>

<paragraph 1: what the change does and why, 2-4 sentences>

<paragraph 2 if needed: secondary context — alternative approaches considered,
 follow-up work, related issues>
```

Verify before recording verdict: subject is ≤ 72 chars and starts with a conventional-commit type, a body is present (a subject-only message is rejected), body is flush-left flowing prose with no bullets, no fake `(#NN)` reference, no surrounding meta-prose.

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
