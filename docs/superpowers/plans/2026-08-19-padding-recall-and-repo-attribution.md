# Padding recall and `--repo` attribution: plan

**Spec:** `docs/superpowers/specs/2026-08-19-padding-recall-and-repo-attribution-design.md`

**Goal:** Recover the padding-tail recall #387 traded away, without reopening
the ReDoS problem it solved, and attribute a boundary that names its repo
explicitly.

**Global constraints:** bash 3.2. Every matcher linear-time, and proven so by
measurement under `ggrep` with `LC_ALL=C.UTF-8`, not by inspection. Do not
reformat unrelated lines. One PR per task, each followed by a release.

---

## Task A: recover the dotted-tail recall (#390) — NOT DOING

Rejected after review; see the spec for the measurements. In short: the
benchmark that motivated it compared an early-exit match against a full scan, and
on the no-match path that production actually takes the proposed expression is
quadratic (41ms to 6881ms as the line grows from 5KB to 83KB). Dropping the
`{0,200}` bound would also silently auto-strip filler tails over 200 characters,
and the recovered shapes can never be auto-fixed anyway because the perl strip's
own class cannot cross a dot either, so the change could only inflate
`checks_failed`.

The one action carried out of this task is a correction, below.

- [x] **Correct #387's corpus claim.** The comment in `scripts/delegate.sh`
  says "297 hand-written commit bodies, 2 false positives before and 0 after".
  Bash `case` is case-sensitive, so the filter caught `Co-Authored-By:` but not
  GitHub's squash `Co-authored-by:`, and 278 of those 297 lines were trailers
  rather than prose. Measured on the last prose line of 301 commits with a real
  body: pre-#387 flags 12 (5 true, 7 false), shipped flags 4 (all true),
  the rejected proposal flags 5 (all true). #387's conclusion holds and is
  stronger than it claimed. Replace the numbers in the comment.

## Task B: widen the delegation lookup with an explicit `--repo` (#393 follow-up)

**Files:** modify `scripts/delegate-boundary-hook.sh`; modify
`tests/test-delegate-boundary-hook.sh`.

Review settled the open question: the `--repo` candidate widens the **lookup**
only and never sets the recorded project. Simulation over the whole metrics file
showed identical recall either way, with the recorded-project variant adding four
`rate=0%` project keys and moving 22 rows off two real projects.

- [ ] **Step 1: write the failing test.** cwd `repo-a`, command
  `gh issue comment 1 --repo owner/repo-b --body x`, a `maintainer-reply`
  delegation recorded under `repo-b` inside the window. Expect `delegated:true`
  AND `project` still `repo-a`.

- [ ] **Step 2: run it and watch it fail.**

- [ ] **Step 3: parse the flag** off `matched_seg`. Accept `--repo <v>`,
  `--repo=<v>` and `-R <v>`. Validate the WHOLE value against
  `^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$` before splitting on `/`, then take the
  final segment; strip a trailing `/` and a `.git` suffix first. This validation
  is security work, not tidiness: it is the only thing rejecting
  `--repo IsmaelMartinez/$1`, `--repo $R` and `` --repo `whoami`/name ``, and a
  last-segment-only check would accept all three. Shell-variable values are 11 of
  534 real invocations.

- [ ] **Step 4: add it to the lookup only.** A third `--arg proj3` joins the
  `or` chain in the jq select. Leave `project` untouched. Note in the comment
  that when there is no `cd`, `$proj` and `$proj2` are already equal, so the
  third argument is load-bearing rather than decorative.

- [ ] **Step 5: comment the quoted-value trade-off.** A legitimately quoted
  `--repo "owner/name"` is blanked by the scan surface and falls back silently.
  That is the opposite trade-off from the `cd` block, which parses the raw
  command precisely so it can read quoted values. Say so, or the next reader
  will assume the two blocks work alike.

- [ ] **Step 6: guard the negatives that actually occur.** Shell-variable value
  (11 of 534 invocations), quoted value (6 of 534), bare `--repo` with no value,
  value with no slash, `--repo` followed by another flag, and a segment carrying
  both a leading `cd` and a `--repo`. The existing `cd` and no-`cd` tests must
  keep their results unchanged.

- [ ] **Step 7: run the suite.** `tests/test-delegate-boundary-hook.sh`.

- [ ] **Step 8: commit.** `fix: match a delegation for a boundary that names its repo`

## Task C: re-measure #384

- [ ] Not yet. Four post-#387 rows exist. Revisit when there are enough to
  recompute the kept-rate split, and record the new n and p on the issue.
