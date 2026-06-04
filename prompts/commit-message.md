---
inputs:
  recent_commits: string
  diff_stat: string
  why: string
  type: string?
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
Subject ≤ 72 chars starting with '<TYPE>:' (feat, fix, ci, docs, chore, refactor, test).
Then a blank line, then 1-2 short flowing-prose paragraphs (NO bullet lists, NO indentation).

Subject length — first match wins, non-negotiable:
Count the characters in your subject line including the '<TYPE>:' prefix.
If the count exceeds 72, REWRITE the subject before emitting. Drop adjectives,
collapse "X and Y" pairs to whichever is primary, prefer the shorter
synonym. The 72-char limit is a hard ceiling, not a guideline.
Wrong: feat: prompts/summarise-issue — OMIT-EMPTY positive directive + Comment-N citation guard (79 chars)
Correct: feat: prompts/summarise-issue — OMIT-EMPTY + Comment-N guard (60 chars)

TYPE override (highest priority): {{type}}
If a non-empty value appears immediately above, use it verbatim as the subject
prefix — a value of `chore` means the subject MUST start with `chore:` — and
SKIP the priority list below entirely. If the line above is blank, ignore it and
select the type from the priority list.

TYPE selection — first match wins, non-negotiable:
1. If the diff body or WHY paragraph mentions "fix", "bug", "regression", "broken", "hang", "crash", or "leak" → `fix:`
2. If the diff adds a NEW file, function, recipe, command-line flag, or env var that did not exist on main → `feat:`
3. If the diff is only documentation (.md edits, comments, ADRs, README, ROADMAP) → `docs:`
4. If the diff only adds or changes tests (tests/, *_test.sh) → `test:`
5. If the diff only touches `.github/workflows/`, release config, or build/CI scaffolding → `chore:`
6. Default: `feat:`
Wrong: feat: handle stale lock file when daemon crashes (this is a bug fix — should be fix:)
Correct: fix: handle stale lock file when daemon crashes

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
- `{{type}}` — OPTIONAL. The conventional-commit type (`feat`, `fix`, `docs`, `chore`, `refactor`, `test`) when the caller already knows it. When set, it overrides the TYPE-selection priority list and forces the subject prefix verbatim, sidestepping the model's type inference entirely. Omit it to let the priority rules choose; an omitted value is blanked by `delegate.sh` so the override line collapses to empty.

## Invocation

```bash
bash scripts/delegate.sh --recipe commit-message \
  --var recent_commits="$(git log main --pretty=fuller -3)" \
  --var diff_stat="$(git diff --cached --stat)" \
  --var why="<one or two sentences>" \
  --var type=feat \
  prose "Match the example commit messages exactly in shape and tone. Keep subject ≤ 72 chars. Use the feat: prefix."
```

The trailing prompt arg is the reinforcement instruction; the recipe template carries the structural directives. When you already know the type, pass it as `--var type=<type>` — the template substitutes it as a highest-priority override that short-circuits the priority-list reasoning entirely, which is the most reliable lever because the model copies a literal token rather than inferring a rule (see the 2026-06-04 calibration entry). Leave `--var type` off to let the priority list choose. The `Use the <type>: prefix.` suffix is the call-site reinforcement for the no-explicit-type case — pick the type from the priority list in the template body (rule #1 → `fix:`, #2 → `feat:`, #3 → `docs:`, #4 → `test:`, #5 → `chore:`, default → `feat:`) and substitute it literally into the trailing prompt. The 2026-05-23 calibration entry below documents why this hint is part of the recipe rather than a workaround.

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

### 2026-05-22 — worked example for Phase 12 Track B conventions (#161)

This recipe is the first to adopt the two optional conventions documented in `prompts/README.md` "How to add a new recipe — Optional conventions for new recipes (Phase 12 Track B, #161)". The frontmatter `inputs:` block declares the three required string inputs (`recent_commits`, `diff_stat`, `why`) so `delegate.sh --recipe commit-message` validates them pre-flight rather than letting a missing `--var` surface later as an unsubstituted-placeholder error. The one-sentence identity-and-scope opener at the top of the template body ("Draft a git commit message from the staged diff and recent-commit anchors below. Do not invent file paths, PR numbers, or features that are not present in the diff.") consolidates the recipe's most-repeated forbidden actions — invent-file-paths and invent-PR-numbers — into one upfront sentence the model encounters before the structural directives. The existing `(#NN)` guard and the Wrong/Correct contrastive example remain load-bearing and are NOT removed by the opener; the opener is additive rather than a replacement, on the principle that established calibration evidence outweighs untested condensation. T4 re-measurement remains the empirical gate; whether the opener visibly changes output quality is logged via dogfood verdict, not asserted in advance.

### 2026-05-22 — SUBJECT_LEN promoted to template-body directive + TYPE-selection priority list

The 2026-05-11 calibration entry's stated trigger condition fired during the 2026-05-22 session: three MISS rows in `~/.claude/skills/delegate-local/metrics.jsonl` against `qwen3.6:35b-a3b-q8_0` (prose tier) showed SUBJECT_LEN and wrong-type-tag failures persisting despite the trailing-prompt reinforcement. The verbatim reasons recorded by `delegate-feedback.sh miss`: ts=2026-05-22T09:42:54Z — `SUBJECT_LEN — model emitted 87-char subject for fix:171 even with explicit '72 chars or fewer' reinforcement; trimmed by hand to 64 chars`; ts=2026-05-22T11:14:13Z — `SUBJECT_LEN: subject was 79 chars (>72 limit); body content was usable verbatim. Manually trimmed subject and added '(closes #148)' suffix.`; ts=2026-05-22T09:40:45Z — `wrong type tag (feat: vs fix:) and two participial-padding tails (ensuring..., and a 'but provides' restating tail); also missed the conventional fix: prefix for a bug fix`. Two SUBJECT_LEN misses on the same day flip the prior from "encouraging signal" to "the trailing-prompt reinforcement is insufficient on its own", and the wrong-type-tag MISS adds a separate recurring shape the bare type allowlist `(feat, fix, ci, docs, chore, refactor, test)` does not actively trigger on.

The fix promotes both directives from advisory to first-match-wins template-body rules with v5/v7 Wrong/Correct one-shots. The SUBJECT_LEN block names the recovery procedure (count chars including TYPE prefix, drop adjectives, collapse "X and Y" pairs, prefer shorter synonyms) and grounds the Wrong/Correct in the 2026-05-22T11:14:13Z MISS — the literal 79-char subject the model emitted (`feat: prompts/summarise-issue — OMIT-EMPTY positive directive + Comment-N citation guard`) paired with the 60-char trim that actually landed in PR #180 (`feat: prompts/summarise-issue — OMIT-EMPTY + Comment-N guard`). Using the literal failure shape rather than a paraphrase mirrors the closes-the-gap calibration finding from 2026-05-12, where the verbatim-MISS anchor outperformed a synthetic example. The TYPE-selection directive ports the priority-list shape from the brief: six numbered rules, first match wins, with the trigger keywords (`fix`, `bug`, `regression`, `broken`, `hang`, `crash`, `leak`) and file-pattern triggers (`.github/workflows/`, ROADMAP, tests/) tuned against `git log --oneline -30` so the rules cover the actual type distribution this project ships (34 feat / 12 docs / 8 chore / 5 fix in the rolling 30-commit window). The Wrong/Correct pair shows the exact MISS shape from 2026-05-22T09:40:45Z — `feat:` for a fix that mentions "fix" in the WHY paragraph.

Both directives use the "first match wins, non-negotiable" framing that closed the `(#NN)` gap in 2026-05-10 and the closes-the-gap shape in 2026-05-12. The trailing-prompt reinforcement (`Keep subject ≤ 72 chars`) stays as belt-and-braces — promotion adds, doesn't replace. Dogfood verdict is the empirical gate; the recipe's track record is that the v5/v7 directive-rule-plus-example pattern binds where bare enumeration drifts.

Dogfood result (ts=2026-05-22T12:50:39Z, recorded HIT): the tightened recipe generated this very PR's commit message against `qwen3.6:35b-a3b-q8_0` on the prose tier. Subject came in at 66 chars (`feat: commit-message.md — subject-length + type-selection guards`), below the 72-char ceiling. TYPE-selection picked `feat:` correctly per priority rule #2 — the diff adds two new directives that did not exist on main, and the WHY paragraph contained no rule-1 keywords. No `(#NN)` suffix, body flush-left, no participial- or declarative-padding tails. Both promoted directives bound on the first dogfood after promotion, which matches the empirical pattern observed when `(#NN)` and closes-the-gap were promoted using the same v5/v7 shape. Second dogfood as the recipe gets exercised against further commits will tell whether the bind generalises or whether SUBJECT_LEN needs a sharper anchor for diff shapes the current example does not cover.

### 2026-05-23 — prefix-hint promotion after TYPE-selection MISSes

Two MISSes recorded on 2026-05-23 against `qwen3.6:35b-a3b-q8_0` (prose tier, greedy decoding) showed the TYPE-selection priority-list directive in the template body not binding reliably even after the 2026-05-22 promotion. PR #199 was a pure docs change (a two-line addition to `prompts/README.md`) and the recipe still emitted `feat:` despite rule #3 of the priority list matching the diff exactly (".md edits" only). PR #200's review-fixes commit was a mixed diff where the WHY paragraph described bug fixes from gemini-code-assist review feedback; the recipe emitted `feat:` despite rule #1's keyword `fix` being present in the WHY. Both MISSes match the directive-binding-ceiling pattern documented in the 2026-05-23 Phase 13 ROADMAP entry — the template body's directive text reached saturation under greedy decoding and additional enumeration was no longer the right lever.

The empirical workaround that HIT twice today: append an explicit `Use the <type>: prefix.` suffix to the trailing prompt arg (e.g. `Use the docs: prefix.` for the PR #199 re-run, `Use the chore: prefix.` for a chore commit later in the session). The call-site hint binds where the template-body priority rules drift because the trailing prompt sits closer to the model's attention at generation time than the structural directives buried inside the template body. The same logic that put the SUBJECT_LEN reminder into the trailing prompt before its 2026-05-22 template-body promotion applies here — the call-site reinforcement is the cheap empirical lever before any further template-body work.

The change promotes the prefix-hint from "workaround" to documented invocation form. The `## Invocation` example now shows `Use the feat: prefix.` appended to the trailing prompt, with a one-paragraph clarification on how to pick the type from the priority list. The TYPE-selection priority list in the template body stays load-bearing and is NOT removed or weakened — the same additive principle the 2026-05-11 SUBJECT_LEN invocation-example reinforcement and the 2026-05-22 directive-promotion entries established. Template body and call-site hint together form a belt-and-braces pattern: the template body carries the structural rule the scorer can pin against, the call-site hint carries the per-invocation reinforcement the model sees last.

### 2026-05-24 — contrastive-anchor expansion for the padding family (Phase 15 Track A)

The 2026-05-23 Phase 13 ROADMAP entry named directive-text enumeration as a saturated lever under greedy decoding on `qwen3.6:35b-a3b-q8_0`. Baseline T4 against the prior recipe state (substituted with the 2026-05-21 anchors and preserved as `experiments/fixtures/task-4-commit-message-2026-05-24-pre-phase-15.txt`) confirmed the ceiling empirically: 3 of 3 reps failed SUBJECT_LEN (subject came in at 77 chars) AND BODY_NO_PADDING (the model emitted both `, providing a controlled input shape …` and `, allowing the model's pass rate to be compared …` participial tails despite both verbs being literally named in the directive enumeration). Per-rep score 4/6, cumulative 12/18, mean 0.67.

The intervention promotes a single closes-the-gap Wrong/Correct pair to four pairs covering the three primary padding shapes: participial-`, providing` form, participial-`, allowing` form, declarative-`This ensures` form, and the original closes-the-gap form. The Wrong/Correct content was deliberately rewritten in the second iteration to use domain-neutral subject matter (endpoint validation, migration scripts, rate limiters, contract-vs-payload) rather than the first iteration's recipe-adjacent phrasing — the first iteration scored 18/18 but the model copied a "Correct" sentence verbatim into the body because the example talked about the same change the fixture described. Domain-neutral examples bind the pattern without leaking content.

Post-edit T4 re-measurement against the same anchors via `experiments/fixtures/task-4-commit-message-2026-05-24.txt` (the new runner default): 3 of 3 reps scored 6/6 → cumulative 18/18, mean 1.00 — both SUBJECT_LEN (subject dropped to 50 chars) and BODY_NO_PADDING now pass. The contrastive-anchor expansion successfully pushed past the directive-text-only ceiling on enumerated verbs.

Caveat worth recording for the next iteration: one of the 3 reps emitted `, replacing assertion with data` — a participial-tail shape whose verb (`replacing`) is NOT in the scorer's `PADDING_REGEXES` enumeration, so the rep passed BODY_NO_PADDING. The model now AVOIDS the enumerated verbs but defaults to a structurally-equivalent unenumerated verb instead. This is the next-level directive-binding ceiling — verb-level enumeration succeeds at coverage but the underlying participial-tail STRUCTURE persists. Two future levers worth probing: (1) extend the scorer's regex set with the next batch of unenumerated participial verbs (`replacing`, `supporting`, `reflecting`, `keeping`) and re-measure; (2) attempt a structural regex matcher for any `, [a-z]+ing` trailing-clause shape, with calibrated false-positive thresholds.

PR #208 review iteration (2026-05-24): gemini-code-assist flagged the parenthetical `(sentence ends after the substantive content; …)` Correct form on the two declarative pairs as a content-leakage risk, suggesting concrete-sentence Wrong/Correct shape (Wrong: "X. This ensures Y." / Correct: "X.") parallel to the participial pairs above. Iteration measured against the same fixture and anchors: gemini's concrete-sentence variant scored **15/18 mean 0.83** — REGRESSED from the parenthetical's 18/18 — with 3 of 3 reps failing BODY_NO_PADDING on `, allowing direct comparison …` despite the explicit Wrong/Correct anchor for `, allowing` above. Speculative reading: the parenthetical Correct restates the abstract rule (`no This-X restating tail at all`) in addition to demonstrating the example, while the concrete-sentence Correct loses that abstract reinforcement and the model defaults to participial-tail shapes on different verbs. Decision: keep the parenthetical Correct form for the declarative pairs; the meta-description-leakage risk gemini identified is theoretical (verified: zero leakage across the 18/18 run), the regression risk is measured. Verified additionally that the participial pairs' concrete-sentence Correct form does NOT regress — only the declarative pairs benefit from the parenthetical reinforcement, mirroring the asymmetric semantic distinction (participial-tail content is salvageable by rephrase; declarative-restating content is not).

### 2026-05-24 — Phase 16 Track B: scorer + recipe enumeration extension, treadmill confirmed

Phase 15 Track A's `, replacing assertion with data` caveat became Phase 16 Track B's measurement. The intervention adds five new participial verbs (`replacing`, `supporting`, `reflecting`, `keeping`, `exemplified`) plus one new declarative form (`This provides`) to both `experiments/score-t4.sh` `PADDING_REGEXES` and this recipe's directive enumeration line. Phase 13 scorer-recipe parity convention preserved. Empirical measurement on the same anchors:

```
                                Phase 15 scorer   Phase 16 (extended) scorer
Phase 15 fixture (prior state)  18/18             15/18  (catches `, replacing` + `This provides`)
Phase 16 fixture (new state)    n/a               18/18  (but model shifted to `, moving X`, `, including X`)
```

Two findings, both load-bearing:

**Scorer fidelity improved.** The extended scorer caught two participial-padding shapes (`, replacing`, `This provides`) on stable Phase 15 output that the prior scorer missed, dropping the same-content score from 18/18 to 15/18. Scorer-recipe parity is now stricter and aligns with the calibration evidence in this recipe's history.

**The treadmill is confirmed empirically.** The Phase 16 fixture rep 1 output emitted `, moving the calibration from assertion to empirical data` and `, including subject length, type prefix, fake (#NN) suffixes, flush-left body, absence of bullets, and no participial-padding tails` — two participial-tail shapes whose verbs (`moving`, `including`) are NOT in the extended scorer's regex set. The model AVOIDS each batch of enumerated verbs and substitutes the next structurally-equivalent unenumerated verb. Per-verb enumeration extension is a treadmill, not a fix. This was the predicted-but-not-yet-measured outcome from the Phase 15 calibration note; Phase 16 now provides the measurement.

The next lever named in the Phase 15 calibration note remains correct and is now the highest-leverage open item: **a generalised structural matcher for `, [a-z]+ing` trailing-clause shapes** with calibrated false-positive thresholds. The legitimate-mid-sentence-not-flagged negative cases in `tests/test-score-t4.sh` (line ~378) are the seed for the false-positive corpus the generalised matcher would need to clear before shipping. Deferred to a future iteration because the test surface is bigger than this PR's scope.

Tests added for the new verbs in `tests/test-score-t4.sh` (5 positive cases — one per new participial verb, 1 positive case for `This provides`, 3 negative cases for legitimate mid-sentence use of `Replacing`/`Supporting`/`Reflecting` as sentence-initial verbs). 58/58 passing.

Phase 15 Track B (same session) measured the same post-edit fixture against the code tier (`qwen3-coder-next:latest`, 3 reps) as a tier-escalation control. All 3 reps appended `(#86)` to the subject despite the explicit Wrong/Correct anchor, scoring 5/6 → cumulative 15/18 mean 0.83. The code tier scored WORSE than the prose tier on the same recipe, with all three reps failing SUBJECT_NO_PR. Speculative reading: code-specialised models treat the recent-commits anchors as a sequence to extend (including the trailing `(#NN)` pattern from squash-merges), while prose-specialised models are less prone to this exact-pattern-extension behaviour. The recipe's prose-tier recommendation in the Invocation section stands; code tier is not the right fallback for commit-message work. Worth noting that code tier's body paragraphs were CLEAN of participial tails (0/3 reps), so the tier-vs-recipe interaction is rule-specific rather than uniformly better or worse.

### 2026-05-24 — Phase 17 Track B: generalised participial-tail structural matcher

Phase 16 Track B's treadmill-confirmation caveat named the generalised structural matcher as the next-iteration lever, and Phase 17 Track B ships it. One new POSIX-ERE regex is added to `experiments/score-t4.sh` `PADDING_REGEXES` (additive, not replacing the per-verb regexes): `,[[:space:]]+[a-z]{3,}ing([[:space:]]|[.!?,])`. The `{3,}` minimum on the prefix excludes coincidental bare-noun matches on five-char-or-shorter `-ing` nouns like `ring`, `wing`, `king`, `bring`, `cling`, `fling`, `sting`, `swing` that could appear in legitimate coordination lists after a comma. PR #213 review surfaced an acknowledged false positive that the {3,} floor does NOT exclude: `string` (6 chars, `str` prefix meets the 3-char floor) IS matched, so a body like `feat: support integer, string, and boolean` will trip the regex. The trade-off was deliberate: bumping the floor to {4,} would also exclude `moving`, one of the five MUST-catch positives from the 2026-05-24 dogfood corpus, breaking the empirical signal this PR was designed to capture. Coordination-list-of-types false positives are accepted as the lesser cost; an explicit test in `tests/test-score-t4.sh` test 14l asserts `string` matches so any future tightening regressions surface immediately. The comma anchor and the trailing-boundary clause (`([[:space:]]|[.!?,])`) mirror the existing per-verb regex shape so the matcher composes cleanly with the per-verb enumeration. Five real verb-substitution MISSes from 2026-05-24 dogfoods anchor the positive corpus: `, lifting the mean score from 0.67 to 1.00`, `, exemplified by the output 'No explicit blockers stated'`, `, confirming the need for a generalised structural matcher`, `, moving the calibration from assertion to empirical data`, and `, including subject length, type prefix, fake (#NN) suffixes`. The negative corpus comprises the three sentence-initial legitimate-use cases already in `tests/test-score-t4.sh` test 14k, where the absence of a leading comma distinguishes them from the target pattern.

Empirical measurement confirms the intervention's effect across three reps of `qwen3.6:35b-a3b-q8_0` on Ollama against the unchanged 2026-05-24 fixture and anchors. Before the matcher (Phase 16 baseline): cumulative 18/18, mean 1.00, with the Phase 16-documented `, moving` and `, including` shapes slipping through. After the matcher (Phase 17 Track B): cumulative 15/18, mean 0.83, all three reps fail BODY_NO_PADDING. The model output is bit-identical across the two runs — the score difference is pure scorer-fidelity improvement, not a behaviour change in the model. False-positive risk in the commit-message domain is acceptable: coordination lists of gerunds (`supports caching, batching, retries`), continuative participial phrases (`the loop runs, blocking on I/O`), and 6+-char `-ing` nouns in type lists (`, string,`) are the realistic false-positive shapes — the first two are themselves prose smells the recipe rejects, the third is the documented PR #213 trade-off. The `{3,}` constraint clears the bare-noun false positives on 5-or-shorter words while preserving the five MUST-catch positives, and the false-negative gap for `-ed` and `-ied` past-participle forms is addressed by retaining the per-verb regex for `, exemplified`. A new test 14l block in `tests/test-score-t4.sh` covers the five positive cases, a short-word coordination-list negative case to guard the `{3,}` floor, and an explicit `, string` positive case that documents the acknowledged false positive; test 14k's existing three sentence-initial-use negative cases are reinforced as the false-positive corpus for the generalised matcher.

Caveat for the next iteration: if the model now shifts to a yet-newer unenumerated structural shape — `, supported by X` past-participle, `, X-ed Y` past-tense participle, or sentence-level constructions like `, but Y` adversative tails — the treadmill is still running, just at a higher-order structural level. The recipe's directive enumeration is NOT extended in this PR because the structural matcher does the empirical work; promoting the matcher pattern into the directive text would re-introduce the directive-binding ceiling Phase 13 documented. Future Phase 17 caveats land in this calibration entry as new MISS shapes surface.

### 2026-06-04 — explicit `--var type=` override (separating the solvable case from the ceiling)

A 2026-06-04 MISS-signal analysis over the rolling feedback log surfaced a commit-message miss against the explicit-type case: the caller passed `--var type=chore` and the recipe still emitted `feat:`. The cause was NOT the directive-binding ceiling the 2026-05-23 entry documents (where the model infers the wrong tag from the diff and WHY) — it was that the recipe declared no `type` input and carried no `{{type}}` placeholder, so the undeclared `--var` was silently dropped by the validator (`prompts/README.md` Convention 2 passes undeclared keys through untouched). That makes "honour an explicit caller-supplied type" a genuinely separable lever: when the caller already knows the type there is no inference to get wrong, and copying a literal token is something small models do reliably.

The fix declares `type: string?` (optional) and adds a highest-priority `TYPE override` line at the top of the TYPE handling. When `--var type=chore` is passed it substitutes verbatim and the directive tells the model to use it and skip the priority list; when omitted, `delegate.sh` blanks the optional placeholder (the optional-placeholder-blanking behaviour added to the wrapper in the same change) so the line collapses to empty and the existing priority-list-plus-trailing-hint path is unchanged. The lever is prompt-side, consistent with the rest of the recipe library; if a future dogfood shows the model ignoring an explicit override, the escalation path is wrapper-side prefix enforcement (force `<type>:` on the returned subject), deferred until measured to be necessary. The TYPE-selection priority list and the call-site `Use the <type>: prefix.` hint stay load-bearing for the no-explicit-type case — promotion adds, doesn't replace, the same additive principle the 2026-05-22 and 2026-05-23 entries established.
