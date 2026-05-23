# pr-review-reply

## When to use

The user (or the `address-pr-comments` skill) has applied a fix in response to a PR/MR review comment and wants a one-sentence reply to post under the original inline comment. Concise, factual, no PR-author-pleasing fluff. Output shape is one of three: "Applied in `<hash>`. <optional one-line addendum>", "Partially applied in `<hash>` — <one-line reason>", or "Not applied — <one-line reason>".

Not for: drafting the full review response (use the review skill itself), explaining a non-trivial design decision (write that yourself), or any reply that needs to push back on the reviewer's premise. The recipe deliberately constrains the model to summarise *what was done* — disagreement is the agent's call.

## Context to gather first

The agent already knows these by the time it reaches this step in the address-pr-comments flow:

```bash
# The verdict (decide before calling): applied | partial | not_applied
# The fix hash (when verdict is applied or partial):
git rev-parse --short HEAD
# The comment text (so the reply names what the reviewer flagged):
gh api repos/<owner>/<repo>/pulls/<pr>/comments/<comment_id> --jq '.body'
```

## Prompt template

```
Draft a one-sentence reply to this code-review comment.
The reply MUST start with EXACTLY one of these three openers, chosen by the verdict:
  - "Applied in `{{hash}}`."           when verdict = applied
  - "Partially applied in `{{hash}}` — " when verdict = partial
  - "Not applied — "                    when verdict = not_applied
After the opener, add at most one short clause naming what was actually done (for applied/partial) or why it wasn't (for not_applied). No additional sentences beyond the opener and that single clause. No PR-author flattery ("Great catch!", "Thanks for the suggestion"). No restating the reviewer's comment back to them.
Stop after the substantive content. Do NOT add a trailing sentence that restates the point. Do NOT append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting", "providing", "allowing", "making", "enabling", "highlighting", "underscoring"). Do NOT end with a declarative rephrase ("This means", "This approach", "The result is", "In effect", "Overall", "In summary", "To summarise", "This ensures", "This enables", "This guarantees", "This delivers"). Do NOT end with restating phrases ("this distinction is crucial", "this is crucial", "this is essential", "across diverse environments", "closes the gap", "closing the gap", "closes the loop", "closing the loop", "going forward", "moving forward"). End on a finite verb introducing new content, or stop.
Output ONLY the reply text, no markdown wrapper, no quoting.

Example shape (do not copy literally — the input below is different):

Wrong: Good point — the awk script was indeed fragile, so I switched to a perl-based parser. Thanks, this has been fixed in `8b3424a`.
Correct: Applied in `8b3424a`. Switched the awk parser to perl so literal-newline SEARCH/REPLACE blocks no longer get split mid-block.

=== Verdict ===
{{verdict}}

=== Reviewer's comment ===
{{comment}}

=== What was done (only for applied/partial) ===
{{fix_summary}}
```

## Variables

- `{{hash}}` — short git hash of the fix commit (e.g. `git rev-parse --short HEAD`). Empty string is acceptable when verdict is `not_applied`.
- `{{verdict}}` — exactly one of `applied`, `partial`, `not_applied`.
- `{{comment}}` — body of the reviewer's comment, verbatim.
- `{{fix_summary}}` — 1-2 sentences naming what was changed in the fix commit (for `applied`/`partial`), or the reason for not applying (for `not_applied`). The agent authors this from its own knowledge of the fix.

## Invocation

```bash
bash scripts/delegate.sh --recipe pr-review-reply \
  --var hash="$(git rev-parse --short HEAD)" \
  --var verdict="applied" \
  --var comment="$(gh api repos/owner/repo/pulls/N/comments/CID --jq '.body')" \
  --var fix_summary="Switched the unsubstituted-placeholder check to compare against the original-template placeholder set so substituted values containing {{...}} no longer false-positive." \
  prose "Adhere to the opener rules exactly. One sentence only."
```

## Anti-hallucination guards (each line addresses a recurring miss-mode)

- "MUST start with EXACTLY one of these three openers" — the address-pr-comments contract is the opener wording; without binding it, prose-tier output drifts into "Thanks, this has been fixed in <hash>" which loses the structured signal future tooling needs.
- "No second sentence" — observed on similar short-reply patterns: prose tier loves the closing-paraphrase sentence (see SKILL.md's anti-padding directive). One sentence + at-most-one clause keeps it tight.
- "No PR-author flattery ... No restating the reviewer's comment" — observed on first-attempt drafts: the model echoes the reviewer's wording ("Good point — the awk script was indeed fragile, so I ...") which doubles the reply length for no information gain.
- "Output ONLY the reply text" — without it the model wraps in ``` blocks or prefaces with "Here's the reply:".

## Expected output shape

```
Applied in `8b3424a`. The unsubstituted-placeholder check now compares against the original template's placeholder set, so substituted values containing `{{...}}` no longer false-positive.
```

```
Partially applied in `2865835` — flush-left the contrastive example; left the long calibration-notes bullet as-is because the wrap suggestion would push the line past 100 chars per wrap segment.
```

```
Not applied — the suggested `mktemp -t` is BSD-only and breaks on GNU coreutils where `-t` takes a different argument shape.
```

Verify before recording verdict: starts with the exact opener for the verdict, no additional sentences beyond the opener and the descriptive clause, no flattery, no echo of the reviewer's wording.

## Calibration notes

Initial recipe drafted 2026-05-10 from the address-pr-comments skill's per-comment reply contract. The 2026-05-10 session posted 8 such replies by hand across PRs #73, #76, #77 — those replies are the shape anchor.

### 2026-05-10 dogfood: HIT verbatim on first attempt

First-pass against `qwen3.6:35b-a3b-q8_0` (prose tier) on a real reviewer comment from PR #73 (the unsubstituted-placeholder finding). Reply produced was: `Applied in \`8b3424a\`. The check now records which placeholder names the original template required and compares against the set of names satisfied by --var (and {{stdin}} when applicable), instead of grepping the post-substitution string.` — exact opener, one sentence, no flattery, no echo. Posted-by-hand equivalent was nearly identical wording. HIT, no edits needed.

### 2026-05-10 dogfood: graceful degradation when {{comment}} is empty

Second batch on PR #80 used a buggy `gh api` invocation that passed an empty string for `{{comment}}` on two of three replies. The recipe correctly produced opener-only output (`Applied in \`2b7308d\`.`) rather than fabricating a descriptive clause from the verdict alone. The third reply, with all vars populated, produced the full "Applied in `<hash>`. <clause>" shape. This is a useful fail-safe property: when context is missing, the recipe degrades to the minimum-information valid reply rather than inventing context. The opener-only form is technically allowed by the spec ("at most one short clause") even though the descriptive clause is the more useful default.
