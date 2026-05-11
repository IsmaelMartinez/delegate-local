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
Draft a git commit message in EXACTLY the same shape as these recent examples.
Subject ≤ 72 chars starting with '<TYPE>:' (feat, fix, ci, docs, chore, refactor, test).
Then a blank line, then 1-2 short flowing-prose paragraphs (NO bullet lists, NO indentation).

Subjects ending in (#NN) are REJECTED. The (#NN) suffix in every recent
example below was appended by GitHub's squash merge AFTER the commit was
written. Your subject MUST NOT include (#NN). This rule is non-negotiable.
Wrong: feat: delegate.sh recipe loading and placeholder validation (#73)
Correct: feat: delegate.sh recipe loading and placeholder validation

Do NOT indent the body lines — output should be flush-left.
Stop each paragraph after the substantive sentences. Do NOT add a trailing
sentence that restates the point. Restating happens in two shapes, both
rejected: participial form (", ensuring that…", ", enabling…", ", allowing…")
and declarative form ("This ensures…", "This enables…", "…closing the gap
in X", "…going forward"). Both lengthen the body without adding new
information about what the commit changed.
Output ONLY the commit message itself, nothing else.

=== Recent commit examples to match ===
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

## Invocation

```bash
bash scripts/delegate.sh --recipe commit-message \
  --var recent_commits="$(git log main --pretty=fuller -3)" \
  --var diff_stat="$(git diff --cached --stat)" \
  --var why="<one or two sentences>" \
  prose "Match the example commit messages exactly in shape and tone."
```

The trailing prompt arg is the reinforcement instruction; the recipe template carries the structural directives.

## Anti-hallucination guards (each line addresses a real past MISS)

- "EXACTLY the same shape" — generic "match the style" produces bullets.
- "Subject ≤ 72 chars starting with '<TYPE>:'" — without this, the model inflates subjects past 100 chars or invents non-conventional prefixes.
- "NO bullet lists, NO indentation" — required because `git log --pretty=fuller` outputs bodies indented 4 spaces; the model copies the indentation literally if not told otherwise.
- "Subjects ending in (#NN) are REJECTED ... non-negotiable" with a Wrong/Correct contrastive
  example — the bare negation `Do NOT append any (#NN)` did not hold across sessions: the
  model pattern-matched on the `(#NN)` suffix in every recent-commits anchor and inferred
  the next number. Strengthened on 2026-05-10 (issue #74) after a 3/3 MISS reproduction;
  the contrastive Wrong/Correct one-shot plus the "non-negotiable" directive flipped it
  to 5/5 HIT on the same input.
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
<type>: <subject in flowing prose, ≤ 72 chars, no PR ref>

<paragraph 1: what the change does and why, 2-4 sentences>

<paragraph 2 if needed: secondary context — alternative approaches considered,
 follow-up work, related issues>
```

Verify before recording verdict: subject is ≤ 72 chars and starts with a conventional-commit type, body is flush-left flowing prose with no bullets, no fake `(#NN)` reference, no surrounding meta-prose.

## Calibration notes

This recipe is distilled from session 2026-05-09 where the same task delegated three times to `qwen3.6:35b-a3b-q8_0` (prose tier):

- **MISS** (ts=2026-05-09T18:56:22Z) — prompt asked for "concise commit message ... bullets ... terse style"; got bulleted list when project style is flowing prose. The abstract descriptor failed.
- **HIT with light edits** (ts=2026-05-09T20:18:08Z) — added "match these recent examples" + 3 verbatim recent commits; flowing-prose paragraphs produced. Edits: stripped a hallucinated `(#NN)` and 4-space indentation.
- **HIT verbatim** (ts=2026-05-09T20:23:04Z) — same recent-examples anchor PLUS explicit "Do NOT append (#NN)" and "Do NOT indent" guards added in response to the previous MISS-mode in the HIT-with-edits run. Output used with zero edits.

The progression from MISS → HIT-with-edits → HIT-verbatim is the empirical evidence behind every guard above: each guard came from a real failure observed in this sequence.

### 2026-05-10 — strengthening the (#NN) guard (issue #74)

The 2026-05-09 verbatim-HIT proved fragile. PR #73's commit message regenerated with the same recipe shape produced `feat: ... (#73)` on the subject despite the `Do NOT append any (#NN)` line. Reproducing on the same host with a multi-file diff stat (matching PR #73's 9-file shape) produced 3 of 3 MISS deterministically — the model pattern-matched on the `(#NN)` suffix in the recent-commits anchors and inferred the next number, treating the bare-negation guard as advisory. The trigger is the diff-stat shape: a "real-PR-sized" diff strengthens the model's prior that the commit will land via squash merge.

The fix promotes the guard from a bare negation to a directive-rule with a contrastive Wrong/Correct one-shot example, following the v5/v7 retrospective pattern measured at Opus parity in `experiments/sessions/2026-05-03-*`. The new wording is `Subjects ending in (#NN) are REJECTED ... non-negotiable` plus an explicit `Wrong: feat: ... (#73)` / `Correct: feat: ...` pair. Re-measured on the same input post-fix: 5 of 5 HIT (`feat: delegate.sh recipe loading and placeholder validation`, no suffix), deterministic at temperature 0.

### 2026-05-11 — anti-padding directive added after PR #84 commit message

The recipe shipped without the SKILL.md "anti-padding directive on prose-tier prompts" line from the Discipline section. Dogfooding the recipe to draft the commit message for PR #84 (Layer 4 issue template) produced a HIT-with-edits: all earlier guards held (no `(#NN)` suffix, no bullets, flush-left), but both body paragraphs ended with the classic participial-padding tails — "ensuring that every recurring miss has a clear path…" and "…not just local development setups." Recorded as HIT in the metrics with the reason naming the missing directive (ts=2026-05-11T08:01:34Z).

The fix mirrors the SKILL.md guidance: an explicit "Stop each paragraph after the substantive sentences. Do NOT add a trailing sentence that restates the point with a participial clause…" line in the prompt template, plus three concrete bad-pattern examples drawn from this session's MISS output. The pattern follows the v5/v7 directive-rule-plus-example approach that closed the `(#NN)` gap above. Re-measurement against PR #84's commit body shape is the next iteration's job — not blocking on a re-run because the guard is the same shape that worked for `(#NN)` and SKILL.md already records the directive as established practice across other recipes.

### 2026-05-11 — declarative-rephrase form added after PR #86 T4 dogfood

The first T4 dogfood (PR #86 against `qwen3.6:35b-a3b-q8_0`, prose tier, via the HTTP API path with `think:false`) scored 6/6 against the participial-only `PADDING_REGEXES` yet still emitted two declarative-form restating sentences: "This ensures the anti-padding hardening is measured rather than merely asserted." (paragraph 1 tail) and "…closing the gap in the empirical-accuracy framework." (paragraph 2 tail). The recipe had told the model to drop participial tails but had not named the declarative restating shape, and the model complied literally with the rule it knew. The participial-only directive was strictly weaker than the failure modes the project's prose style rejects.

The fix extends the directive text to name both shapes: participial (`, ensuring that…`, `, enabling…`) AND declarative (`This ensures…`, `This enables…`, `…closing the gap in X`, `…going forward`). The fixture is updated in-place (still dated 2026-05-11 because today is still 2026-05-11; incremental directive extension rather than a fresh baseline) and `experiments/score-t4.sh` `PADDING_REGEXES` is extended with the corresponding patterns — sentence-anchored `(^|[.!?,][[:space:]]+)this[[:space:]]+(ensures|enables|guarantees|delivers)([[:space:]]|[.!?,])` so mid-sentence legitimate use ("this approach ensures correct rendering") doesn't false-positive, while still firing after `!` and `?` terminators and on the no-trailing-space form `This ensures.`; `clos(es|ing)[[:space:]]+the[[:space:]]+(gap|loop)` for the high-signal restating-tail shape; `(going|moving)[[:space:]]+forward` for the closing-flourish form. 13 new test assertions cover each pattern's positive case (including the `!`/`?` and trailing-punctuation edge cases gemini-code-assist flagged on PR #93) plus the legitimate-mid-sentence-not-flagged negative case.

Second dogfood against the same model on the extended fixture: 6/6 under the extended scorer, no padding shapes detected in either form. The model produced "but without a fixture, that hardening remains asserted rather than measured" — the same "asserted vs measured" concept the first dogfood put in a restating tail, this time woven into a substantive descriptive sentence inside paragraph 1 instead of dangling at the end. Two consecutive dogfoods are enough to declare the declarative-rephrase pattern consistent rather than session-specific; the recipe + scorer are locked in at this state.

Provenance for this recipe also lives in the `feedback_delegate_prose_prompt_anchoring.md` memory file.
