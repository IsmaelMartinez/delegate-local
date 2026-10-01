---
tier: prose
inputs:
  hash: string
  verdict: string
  comment: string
  fix_summary: string
checks:
  no_padding_tail: true
---
# pr-review-reply

## When to use

The user (or the `address-pr-comments` skill) has applied a fix in response to a PR/MR review comment and wants the reply to post under the original inline comment. You are the PR AUTHOR answering a reviewer — `maintainer-review-reply.md` is the maintainer voice judging someone else's contribution and is not this role.

The opener is fixed and is one of three: "Applied in `<hash>`.", "Partially applied in `<hash>` — ", or "Not applied — ". What follows is the evidence the verdict rests on, in prose, and its length is set by how much evidence there is. Concise, factual, no PR-author-pleasing fluff.

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
Draft a reply to this code-review comment. You are the PR author answering the reviewer.
The reply MUST start with EXACTLY one of these three openers, chosen by the verdict:
  - "Applied in `{{hash}}`."           when verdict = applied
  - "Partially applied in `{{hash}}` — " when verdict = partial
  - "Not applied — "                    when verdict = not_applied
After the opener, write the evidence for that verdict in flowing prose sentences. Its length is set by how much evidence there is and by nothing else: a one-line fix takes one clause, and a fix resting on a measurement, a portability constraint, or a test that had to be built a particular way takes the sentences that carry them. Never write a sentence the evidence below does not support.
Every anchor — file path, function or variable name, flag, commit hash, count, issue or PR number — MUST appear in the inputs below. Do not produce one that is not there, and do not adjust one that is.
No PR-author flattery ("Great catch!", "Thanks for the suggestion"). No restating the reviewer's comment back to them. Prose sentences only, never a bullet or numbered list.
Stop after the substantive content. Do NOT add a trailing sentence that restates the point. Do NOT append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting", "providing", "allowing", "making", "enabling", "highlighting", "underscoring"). Do NOT end with a declarative rephrase ("This means", "This approach", "The result is", "In effect", "Overall", "In summary", "To summarise", "This ensures", "This enables", "This guarantees", "This delivers"). Do NOT end with restating phrases ("this distinction is crucial", "this is crucial", "this is essential", "across diverse environments", "closes the gap", "closing the gap", "closes the loop", "closing the loop", "going forward", "moving forward"). End on a finite verb introducing new content, or stop.
Output ONLY the reply text, no markdown wrapper, no quoting.

Example shape (a skeleton, not sentences to copy — the input below is different):

Wrong: Good point — <restates what the reviewer flagged>, so I <describes the fix>. Thanks, this has been fixed in `<hash>`.
Correct: Applied in `<hash>`. <what the fix changes, in one sentence>. <the evidence it rests on — the measurement, the constraint, or why the test is shaped the way it is>.

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
- `{{fix_summary}}` — the facts the reply will rest on: what changed in the fix commit (for `applied`/`partial`), or why it was not applied (for `not_applied`), plus any measurement, constraint or test-shape decision the reviewer needs to see. Write the anchors the way they should appear, because the recipe forbids the model from producing one that is not here. One fact per line is easiest to check afterwards. The agent authors this from its own knowledge of the fix.

## Invocation

You already read the hash and the comment body in the earlier steps of the flow, so pass them as literal `--var` values:

```bash
bash scripts/delegate.sh --recipe pr-review-reply \
  --var hash=8b3424a \
  --var verdict="applied" \
  --var comment="This check false-positives when a substituted value happens to contain braces." \
  --var fix_summary="Switched the unsubstituted-placeholder check to compare against the original-template placeholder set so substituted values containing {{...}} no longer false-positive." \
  "Adhere to the opener rules exactly. Every anchor must come from the inputs."
```

## Anti-hallucination guards (each line addresses a recurring miss-mode)

- "MUST start with EXACTLY one of these three openers" — the address-pr-comments contract is the opener wording; without binding it, prose-tier output drifts into "Thanks, this has been fixed in <hash>" which loses the structured signal future tooling needs.
- "Never write a sentence the evidence below does not support" plus the anchor-grounding rule — these replace the one-clause cap the recipe used to enforce. The cap was doing two jobs: keeping the model from padding, and keeping it from inventing. Only the first survives a body long enough to carry evidence, so the second is stated directly. `no_padding_tail` now enforces the anti-padding half deterministically rather than by prose alone.
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

```
Applied in `244ad56`. It was worse than a theoretical hang — an assertion against the un-hardened version exits 142 on SIGALRM, so `--body-file /dev/zero` really did stall the hook indefinitely on every Bash call. It reads regular files only now, and the parse takes an optional opening quote and cuts at the first shell punctuation.
```

Verify before recording verdict: starts with the exact opener for the verdict, every anchor traceable to an input, no flattery, no echo of the reviewer's wording, no closing sentence that restates the point.

## Calibration notes

The dated calibration history for this recipe lives in [`docs/calibration/pr-review-reply.md`](../docs/calibration/pr-review-reply.md); add each new entry there.
