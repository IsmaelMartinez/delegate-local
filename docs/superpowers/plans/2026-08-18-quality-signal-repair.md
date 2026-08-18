# Quality-signal repair: plan

**Spec:** `docs/superpowers/specs/2026-08-18-quality-signal-repair-design.md`

**Goal:** Make the two instruments this repo uses to judge itself, the
`no_padding_tail` check and the boundary hook's project attribution, report the
thing they claim to report, and stop the weekly Dependabot failure.

**Global constraints:** bash 3.2 (no associative arrays, no `${var^^}`, no
`mapfile`, no `grep -P`). Every matcher must be linear-time. Do not reformat or
reorder unrelated lines. One PR per task, each followed by a release.

---

## Task 1: anchor the `no_padding_tail` participial arm (#387)

**Files:** modify `scripts/delegate.sh` (the `padding_re` assignment inside
`run_output_checks`); modify `tests/test-delegate.sh`.

- [ ] **Step 1: add the failing fixtures.** In `tests/test-delegate.sh`, next to
  the existing `no_padding_tail` assertions, add cases asserting that a last
  line whose participial is followed by a further sentence does NOT fail the
  check. Use the two hand-written commit bodies (`8010551`, `077c790`) and the
  live `github-issue-body` output from 2026-08-18 as the text.

- [ ] **Step 2: run them and watch them fail.**
  `bash tests/test-delegate.sh` — expect the new assertions to fail against the
  shipped unanchored expression.

- [ ] **Step 3: anchor the arm.** Replace only the first alternative of
  `padding_re`:

  ```
  ,[[:space:]]+[a-z]{3,}ing([[:space:]]|[.!?,]|$)
  ```
  with
  ```
  ,[[:space:]]+[a-z]{3,}ing[^.!?]*[.!?]?[[:space:]]*$
  ```

  Leave the `This-X`, `going/moving forward` and `closes the gap/loop` arms
  byte-identical. Update the adjacent comment to say the arm is anchored to the
  line end and why, mirroring the auto-strip.

- [ ] **Step 4: run the whole suite.** `bash tests/test-delegate.sh` and
  `bash tests/run-tests.sh` — all green, including the pre-existing padding
  assertions, which are the recall guard.

- [ ] **Step 5: confirm recall against the recipes' own examples.** Assert the
  eight `Wrong:` padding examples still FAIL the check.

- [ ] **Step 6: commit.** `fix: anchor no_padding_tail to the line tail`

## Task 2: resolve the boundary repo across a leading `cd` (#385)

**Files:** modify `scripts/delegate-boundary-hook.sh`; modify
`tests/test-delegate-boundary-hook.sh`.

The existing test tmpdir is deliberately not a git repository, so the git-aware
branch never runs there and basename-of-path would pass every assertion while
being wrong in production. Every test below must create real repositories.

- [ ] **Step 1: write the failing tests.** With real `git init` repos:
  (a) cwd `repo-a`, command `cd <repo-b> && git commit -m x`, a `repo-b`
  delegate row in the window with the matching recipe, expect `delegated:true`
  and `project:"repo-b"`;
  (b) same but the `cd` targets `<repo-b>/sub`, expect `project:"repo-b"`;
  (c) same but the `cd` targets a `git worktree add` path, expect the
  repository name and not the worktree directory name;
  (d) `cd /tmp && git commit`, expect the cwd-derived project, NOT `"tmp"`;
  (e) no `cd` prefix, expect today's behaviour byte for byte;
  (f) a delegation recorded under the *cwd* project with an explicit
  `--project`, expect `delegated:true` still (the either-match guard).

- [ ] **Step 2: run them and watch (a), (b), (c) fail.**

- [ ] **Step 3: implement the parse.** Match `^[[:space:]]*cd[[:space:]]+<path>`
  followed by `&&` off the raw command, accepting a single-quoted,
  double-quoted or unquoted path. Never `eval`. Never an unquoted expansion:
  `cd $path` glob-expands and an empty value lands in `$HOME`. Never pass `-`
  through to `cd`. The parse runs on the raw `$cmd` rather than the `scan`
  surface because `scan` blanks quoted spans; note that in the comment, since it
  departs from the doctrine at lines 78-98.

- [ ] **Step 4: implement the derivation.** Resolve the project inside a
  subshell that has chdir'd to the target:
  `cand=$( cd "$p" 2>/dev/null && <the same git-aware derivation as lines 213-220> )`.
  Do NOT reach for `git -C "$p" rev-parse --git-common-dir`: at a repo root that
  returns the relative string `.git`, which then resolves against the hook's own
  cwd and silently reproduces the bug. Accept the candidate only if the
  derivation succeeded, i.e. the path is inside a git repository.

- [ ] **Step 5: widen the lookup to either candidate.** In the jq at lines
  289-295, accept a delegation whose project matches the cd-derived candidate OR
  the cwd-derived one. Use the cd-derived value for the recorded `project` and
  for the nudge text at line 353.

- [ ] **Step 6: run the suite.** `bash tests/test-delegate-boundary-hook.sh`.

- [ ] **Step 7: commit.** `fix: resolve the boundary project across a leading cd`

**Deferred to a follow-up issue:** a `--repo owner/name` arm. Measured on the
audit session's traffic the leading-`cd` rule repairs 62 of 68 boundaries (91%);
the remaining 6 are `gh issue create --repo …` and `gh issue comment --repo …`,
which keeps the issue-create and comment-reply classes misattributed. Worth
doing, but it is a second matcher with its own failure modes and does not belong
in the same PR.

## Task 3: drop the archived Dependabot pip block (#386)

**Files:** modify `.github/dependabot.yml`.

- [ ] **Step 1: confirm the premise.** `git ls-files mcp/` returns nothing.
- [ ] **Step 2: delete the `pip` block**, leaving `github-actions` untouched.
- [ ] **Step 3: commit.** `fix: drop the dependabot pip block for archived /mcp`

## Task 4: re-measure #384 on clean data

- [ ] Once Task 1 has been live long enough to produce fresh `checks_failed`
  rows, recompute the kept-rate split. Record the new n and p on #384 and decide
  the retry question there. Do not implement a retry in this change set.
