# release-note

## When to use

The user is preparing a release entry — typically a single bullet or short paragraph that summarises one merged PR for inclusion in CHANGELOG.md, a GitHub release body, or a Slack-style "what shipped this week" note. The shape is user-facing: speak about *what changed for the reader*, not the implementation details. One PR per recipe call.

For multi-PR release rollups, run the recipe per-PR and concatenate the results — bundling several PRs into one call collapses the "single atomic output" property and invites fabrication (see SKILL.md's cross-PR commit-drafting failure mode).

For commit messages (different shape: subject + WHY paragraph, internal voice), use `commit-message.md` instead.

## Context to gather first

```bash
gh pr view <pr-number> --json title,body,number,mergeCommit --jq '{number, title, body, sha: .mergeCommit.oid}'
# Optional shape anchor — one recent merged PR's release-note entry from CHANGELOG.md:
grep -B1 -A5 "^- " CHANGELOG.md | head -20
```

The PR title and body carry the "what" and "why"; the recipe extracts the user-facing claim and rewords it for an external reader. The optional CHANGELOG anchor (one recent entry) helps the model match the project's release-note style — bullet-led, past tense, no PR-number prefix.

## Prompt template

```
Draft a single release-note entry for the merged PR below.
Output ONE bullet starting with "- " and a past-tense verb (Added, Fixed, Changed, Removed, Renamed, Documented).
The bullet describes the change from the reader's perspective — what they can now do, or what no longer breaks, or what behaviour shifted. Do NOT describe the implementation.
Length: one sentence, ≤ 200 chars. A second sentence is allowed only when the change has a non-obvious consequence the reader needs to know to use it.
Reference the PR number at the end in parentheses: "(#NN)".
Do NOT include the merge commit hash.
Do NOT echo the PR title verbatim — reword for an external reader who has not seen the PR.
Output ONLY the bullet, no preamble.

=== Recent release-note style anchor (optional) ===
{{anchor}}

=== This PR ===
TITLE: {{title}}
NUMBER: #{{number}}
BODY:
{{body}}
```

## Variables

- `{{title}}` — the PR's title verbatim from `gh pr view`.
- `{{number}}` — the PR number (no `#` prefix; the template adds it).
- `{{body}}` — the PR body verbatim from `gh pr view`.
- `{{anchor}}` — one recent release-note entry from CHANGELOG.md, or the empty string if no anchor is available. Without an anchor the model defaults to a reasonable "Added X (#NN)" shape; with one, it picks up the project's specific phrasing conventions.

## Invocation

```bash
PR=80
bash scripts/delegate.sh --recipe release-note \
  --var title="$(gh pr view $PR --json title --jq .title)" \
  --var number="$PR" \
  --var body="$(gh pr view $PR --json body --jq .body)" \
  --var anchor="$(grep -B1 -A2 '^- ' CHANGELOG.md | head -3)" \
  prose "Adhere to the bullet shape exactly. One sentence, ≤ 200 chars."
```

## Anti-hallucination guards (each line addresses a recurring miss-mode)

- "starting with `- ` and a past-tense verb" — without a concrete starter the model produces sentence-fragment-style entries ("Recipe library expanded to cover ...") that don't match CHANGELOG conventions.
- "describes the change from the reader's perspective ... do NOT describe the implementation" — observed adjacent failure mode in `summarise-diff`: prose-tier models lapse into implementation-speak ("refactored the awk extraction") when asked for user-visible summary. The explicit reframe forces the right register.
- "Length: one sentence, ≤ 200 chars" + "A second sentence is allowed only when the change has a non-obvious consequence" — without this cap the model writes 3-sentence release notes that read like commit-message bodies.
- "Reference the PR number at the end in parentheses" — without this guidance the model omits the PR ref entirely, or prepends it (`PR #NN: ...`) which doesn't match the project convention.
- "Do NOT echo the PR title verbatim — reword" — without this the bullet ends up as the literal PR title with `- ` prepended, which is rarely the right release-note shape (titles are concise internal labels; release notes are external descriptions).
- "Output ONLY the bullet, no preamble" — SKILL.md's anti-padding directive; without it the model wraps in "Here's the release note:".

## Expected output shape

```
- Added a prompts library with calibrated recipes for commit messages, PR descriptions, diff summaries, and review-comment replies (#80).
```

```
- Fixed a silent verdict-misfiling bug in `delegate-feedback.sh` where the implicit "most recent delegate row" lookup would attach to an unrelated row when metrics were off or the delegation was killed before its row was written (#79).
```

Verify before recording verdict: starts with `- ` + past-tense verb, describes user-visible behaviour (not implementation), ≤ 200 chars for the first sentence, PR number in trailing parentheses, no merge-hash, no preamble.

## Calibration notes

Initial recipe drafted 2026-05-10 from the empty release-note slot pointed at by `prompts/commit-message.md`'s "When to use" section ("Single commit per message — squash-merge style, not multi-bullet release notes (use `release-note.md` for that)").

### 2026-05-10 dogfood: HIT verbatim on first attempt

First-pass against `qwen3.6:35b-a3b-q8_0` (prose tier) on the freshly-merged PR #80, anchor left empty: `- Added \`summarise-diff\` and \`pr-review-reply\` recipes to the library, and trimmed \`pr-description\` to a single-example default (#80)` — exact `- ` bullet, past-tense "Added", single sentence under 200 chars, PR number in trailing parentheses, no preamble. HIT, no edits needed. The recipe's reader-perspective guard didn't get a chance to fire because the PR title itself was already external-ish; a more internal-titled PR would exercise the reword guard harder.
