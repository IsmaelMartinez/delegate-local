# commit-message-v3-persona

> **EXPERIMENT VARIANT (Phase 12 Track A, issue #160)** — copy of `prompts/commit-message.md` with a single persona-priming opening line added to the prompt template (negative control vs the v2 domain-priming variant). Do not use in production.

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
You are an expert software engineer drafting a commit message.
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
rejected: participial form (", ensuring…", ", enabling…", ", allowing…",
", providing…", ", keeping…", ", reflecting…", ", supporting…") and
declarative form ("This ensures…", "This enables…", "This prevents…",
"This guarantees…", "This delivers…", "This is crucial/essential",
"This distinction is crucial", "This closes the gap in X", "…closing
the gap", "…closes the loop", "…going/moving forward", "…across diverse
environments"). Both "closes" and "closing" forms are rejected; both
finite-verb and participial shapes of the same restating cliché count.
Wrong: This closes the gap between asserted hardening and measured accuracy.
Correct: (sentence ends after the substantive content; no closing-the-gap
or closing-the-loop tail at all)
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
  prose "Match the example commit messages exactly in shape and tone. Keep subject ≤ 72 chars."
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

### 2026-05-13 — T4 fixture regen confirms MLX 18/18 after closes-the-gap extension

`experiments/fixtures/task-4-commit-message-2026-05-13.txt` ships the substituted current recipe template with the same diff_stat + recent_commits + why anchors as the 2026-05-11 fixture, so the only intentional variable is the recipe's directive paragraph (extended in PR #114 with the finite-verb `closes the gap` Wrong/Correct one-shot). Re-running the MLX baseline (`mlx-community/Qwen3.6-35B-A3B-8bit`, 3 reps, via `runner.sh --backend mlx`) against the new fixture scored **18/18** — up from 15/18 on the 2026-05-11 fixture in PR #115's v2 baseline. The closes-the-gap guard binds when measured against the regenerated input.

Side observation worth recording: re-running Ollama (`qwen3.6:35b-a3b-q8_0`, same 3 reps) against the same new fixture dropped from 18/18 on the 2026-05-11 fixture to 15/18, all three reps failing SUBJECT_LEN with a 77-char subject (`feat: add T4 commit-message fixture and score-t4.sh for empirical calibration`). The new directive paragraph is ~150 chars longer than the old one; the extra preamble appears to nudge Ollama toward a longer subject. Same MISS shape PR #94 documented. The recipe's existing 2026-05-11 calibration entry already notes the next step if SUBJECT_LEN recurs: promote the length reminder from the invocation example's trailing prompt into a directive inside the template body, with a v5/v7 Wrong/Correct one-shot. Not bundling that promotion into this PR — it's a separate calibration question with its own dogfooding cycle.

Load-bearing layout finding (added 2026-05-13 after PR #119 review): the line break inside `"This closes the gap in X"` (currently split across lines 36-37 in this file's `## Prompt template` section) is empirically load-bearing. gemini-code-assist's PR #119 review reasonably suggested keeping the quoted string on one line to avoid potential literal-newline reproduction. Tested in dogfood: removing the line break made MLX (`mlx-community/Qwen3.6-35B-A3B-8bit`, 3 reps) regress from 18/18 to 12/18, with all three reps hitting both SUBJECT_LEN (77-char subject) AND BODY_NO_PADDING — the latter via a second paragraph ending `, closing the gap between asserted hardening and measured accuracy.`, the exact failure shape the directive paragraph was supposed to prevent. Restoring the line break restored 18/18. The current layout stays. Speculative explanation: the line-break-mid-quote anchors the model's attention on the rule by interrupting fluent reading of the surrounding examples; removing it lets the eye skim past and the rule weight drops. Don't reflow this paragraph for readability without a fresh empirical re-measurement.

### 2026-05-12 — finite-verb closes-the-gap form caught by T4 in MLX baseline

The 2026-05-12 MLX-vs-Ollama baseline (`experiments/results/2026-05-12-mlx-vs-ollama.md`) scored `qwen3.6` 18/18 on Ollama T4 but 15/18 on MLX — and every MLX miss was the same shape: `This closes the gap between asserted hardening and measured accuracy.` as the body's final sentence. The scorer's regex `clos(es|ing)[[:space:]]+the[[:space:]]+(gap|loop)` catches both finite-verb (`closes`) and participial (`closing`) forms; the recipe directive only named `closing the gap in X`. The model complied with the rule it could see and emitted the finite-verb variant, an unambiguous declarative restating tail that the directive intended to prohibit but did not literally enumerate.

The fix extends the rejected-shapes list to name both `closing the gap` AND `closes the gap` / `closes the loop`, and adds a Wrong/Correct one-shot using the exact MLX miss sentence so the contrastive anchor is grounded in the failure shape rather than a paraphrase. Same v5/v7 directive-rule-plus-example pattern that closed the `(#NN)` and declarative-rephrase gaps before it. Re-measurement against the same T4 fixture on MLX is the next iteration's job — the scorer already fires correctly, so the question is whether the extended directive flips the 3/3 MISS to HIT under MLX's chat-template regime.

### 2026-05-11 — declarative-rephrase form added after PR #86 T4 dogfood

The first T4 dogfood (PR #86 against `qwen3.6:35b-a3b-q8_0`, prose tier, via the HTTP API path with `think:false`) scored 6/6 against the participial-only `PADDING_REGEXES` yet still emitted two declarative-form restating sentences: "This ensures the anti-padding hardening is measured rather than merely asserted." (paragraph 1 tail) and "…closing the gap in the empirical-accuracy framework." (paragraph 2 tail). The recipe had told the model to drop participial tails but had not named the declarative restating shape, and the model complied literally with the rule it knew. The participial-only directive was strictly weaker than the failure modes the project's prose style rejects.

The fix extends the directive text to name both shapes: participial (`, ensuring that…`, `, enabling…`) AND declarative (`This ensures…`, `This enables…`, `…closing the gap in X`, `…going forward`). The fixture is updated in-place (still dated 2026-05-11 because today is still 2026-05-11; incremental directive extension rather than a fresh baseline) and `experiments/score-t4.sh` `PADDING_REGEXES` is extended with the corresponding patterns — sentence-anchored `(^|[.!?,][[:space:]]+)this[[:space:]]+(ensures|enables|guarantees|delivers)([[:space:]]|[.!?,])` so mid-sentence legitimate use ("this approach ensures correct rendering") doesn't false-positive, while still firing after `!` and `?` terminators and on the no-trailing-space form `This ensures.`; `clos(es|ing)[[:space:]]+the[[:space:]]+(gap|loop)` for the high-signal restating-tail shape; `(going|moving)[[:space:]]+forward` for the closing-flourish form. 13 new test assertions cover each pattern's positive case (including the `!`/`?` and trailing-punctuation edge cases gemini-code-assist flagged on PR #93) plus the legitimate-mid-sentence-not-flagged negative case.

Second dogfood against the same model on the extended fixture: 6/6 under the extended scorer, no padding shapes detected in either form. The model produced "but without a fixture, that hardening remains asserted rather than measured" — the same "asserted vs measured" concept the first dogfood put in a restating tail, this time woven into a substantive descriptive sentence inside paragraph 1 instead of dangling at the end. Two consecutive dogfoods are enough to declare the declarative-rephrase pattern consistent rather than session-specific; the recipe + scorer are locked in at this state.

### 2026-05-11 — invocation-example reinforcement for subject length (SUBJECT_LEN)

Three data points from this session showed the recipe's `Subject ≤ 72 chars` template directive not binding consistently in real PRs. PR #85 (`fix: commit-message anti-padding + pr-description long-context note`) produced an 80-char subject that required manual trimming. PR #94 (`feat: T5 structured-extraction-into-JSON benchmark with scorer and fixture`) produced a 74-char subject, also manually trimmed. PR #96 (`feat: T6 regex-generation fixture + scorer (Phase 7 follow-up)`) produced a 62-char HIT verbatim — the only difference being that the trailing reinforcement prompt appended `"Keep subject ≤ 72 chars"` to the existing shape-and-tone reminder.

The fix updates only the `## Invocation` example's trailing prompt arg to include the explicit length reinforcement (`"Match the example commit messages exactly in shape and tone. Keep subject ≤ 72 chars."`). The recipe-level directive in the template body was NOT changed — the rule `Subject ≤ 72 chars starting with '<TYPE>:'` remains the load-bearing structural anchor that fixture-based T4 scoring pins against. This is a confidence-building data-point, not a final fix: one HIT under the new invocation is encouraging but doesn't yet prove the trailing reinforcement is necessary or sufficient. If a future session re-shows a SUBJECT_LEN miss despite the new invocation example, the next step is to promote the length reminder into a directive inside the template body (alongside the existing `≤ 72 chars` rule, perhaps with the v5/v7 contrastive Wrong/Correct one-shot pattern that closed the `(#NN)` gap).

**Caveat (shell-var expansion):** the `--var why="<sentences>"` argument is double-quoted in the invocation example, so any literal `$VARNAME` token in the WHY paragraph (e.g. a sentence mentioning `$PR_AGENT_GITLAB_TOKEN` or `$AWS_PROFILE` by name) will be silently substituted by the surrounding shell before `delegate.sh` sees it — unset variables expand to empty and the token vanishes from the prompt, while set variables expand to their literal value and leak the secret into both the model prompt and the metrics JSONL row. Switch the affected `--var` arg to single quotes, escape the dollar as `\$VARNAME` inside the double quotes, or pass the value via a `<<'EOF'` heredoc. See SKILL.md's Pattern-section pitfall callout.

### 2026-05-21 — extending the verb enumeration to match the scorer's regex set

The 2026-05-21 MISS-themes summarisation (delegated to the prose tier itself, 20 reasons from the rolling 30-day feedback log) confirmed that participial and declarative padding tails remain the most persistent failure mode despite the template body already shipping the v5/v7 directive-rule-plus-example pattern. Two specific gaps in the existing enumeration showed up across multiple sessions: `This prevents…` (declarative restating verb not yet named — observed on `This prevents null leakage when a backend bucket contains rows with missing fields` against an earlier-session metrics-schema commit) and `, keeping…` (participial verb not yet named — observed on `, keeping the output numeric for manual JSONL edits or external imports` against the same session). Both are exactly the restating-tail shape the directive prohibits, but the model emits them because they are not literally enumerated alongside `ensuring`/`enabling`/`allowing` and `This ensures`/`This enables`. Same compliance-literally-with-the-rule-it-knows pattern that the 2026-05-11 declarative-form extension was filed against.

The fix extends both enumerations only — the recipe already carries a Wrong/Correct example for the declarative form (`This closes the gap…`) since the 2026-05-12 closes-the-gap extension, and the enumerated keywords are doing the structural work. A first iteration of this edit added a parallel Wrong/Correct one-shot for the participial form plus a generalising backstop sentence about -ing tails, but T4 re-measurement showed those richer additions regressed the empirical baseline by 3 checks on subject length without changing the body-padding checks (which already pass). The 2026-05-11 calibration entry above had specifically anticipated this trade-off — adding more preamble nudges the model into a longer subject — so the iteration rolled back the high-char-cost additions and kept only the minimal keyword extensions. A second pass (after gemini-code-assist flagged prompt ↔ scorer drift on PR #147) folded in the remaining verbs the `experiments/score-t4.sh` `PADDING_REGEXES` array already enforces but the prompt did not previously mention: `, providing…` (participial), `This guarantees…` / `This delivers…` / `This is crucial` / `This is essential` / `This distinction is crucial` (declarative), `moving forward` (closing-flourish counterpart to the already-named `going forward`), and `across diverse environments` (stylistic cliché). The principle: the scorer is the empirical gate, so the prompt's enumeration must at minimum name every shape the scorer rejects, otherwise model misses on scorer-only verbs are not actionable from the model's point of view.

T4 re-measurement: regenerated the fixture as `experiments/fixtures/task-4-commit-message-2026-05-21.txt` by substituting the scorer-aligned template into a copy of the 2026-05-13 fixture's `recent_commits`/`diff_stat`/`why` anchors, then bumped `experiments/runner.sh`'s `t4_snapshot` default from `2026-05-13` to `2026-05-21`. Three reps of `qwen3.6:35b-a3b-q8_0` on Ollama scored 18/18 — up from the 15/18 2026-05-13 baseline where all three reps had failed SUBJECT_LEN at 77 chars. The scorer-aligned extension is empirically net-positive: subject came in at 67 chars across all three reps (`feat: add commit-message fixture and scoring for empirical accuracy`), body checks all pass, no padding tails of any enumerated shape. Surprising direction — the earlier minimal-extension iteration (which named only `This prevents` + `, keeping` + `, reflecting` + `, supporting`) had stayed at the 15/18 baseline, while the fuller alignment with the scorer's regex set flipped to 18/18. Speculative reading: the broader enumeration shifts the model's prior on what "restating" means and incidentally nudges the subject toward a tighter, more abstract phrasing rather than the verbose 77-char form the earlier prompts produced. Not relying on that interpretation — the empirical signal is the gate, and the gate cleared.

Provenance for this recipe also lives in the `feedback_delegate_prose_prompt_anchoring.md` memory file.
