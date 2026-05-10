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
Do NOT append any (#NN) PR number to the subject — that gets added automatically by squash merge.
Do NOT indent the body lines — output should be flush-left.
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
- "Do NOT append any (#NN) PR number" — observed: model invents fake PR numbers from the recent log.
- "Output ONLY the commit message" — without this, the model wraps in prose like "Here's the commit message:" which has to be stripped.

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

Provenance for this recipe also lives in the `feedback_delegate_prose_prompt_anchoring.md` memory file.
