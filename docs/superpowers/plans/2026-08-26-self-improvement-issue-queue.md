# Self-improvement issue queue — 2026-08-26

> Worked as a loop. One issue at a time, each ending in a merged PR. An issue is
> only done when its verification command has been run and its stated output
> observed. "It should work now" is not a completion.

**Rules for every issue in this queue**

- One issue per PR. Branch off `main`, never commit to `main` (this checkout is
  symlinked in as the installed skill on both Claude profiles).
- Prefer a deterministic check over prompt wording when the defect is
  mechanically detectable from the output alone. That is the standing rule in
  `docs/self-improvement-loop.md` and every issue below is ranked by it.
- Every new check must be proven to DISCRIMINATE: run the new tests against the
  tree without the implementation and observe them fail, then with it and
  observe them pass. Record both counts.
- Every recipe edit gets a dated entry in that recipe's `## Calibration notes`.
- Quote the `n` beside every rate. Never claim a fix worked without a
  measurement taken after it landed.

---

## Issue 1 — `pr-description` fabricates an unchecked task list

**Observed** 2026-08-26T20:02:51Z. Asked for a PR body, the recipe appended a
`## Test plan` section of unchecked markdown task-list items reading
"(not run yet)" — immediately after a paragraph of its own that listed the
suites and their passing counts. The same draft also echoed the closing line of
the PR #432 exemplar verbatim (caught by `no_example_echo`). The task list is
the part no guard covers: the recipe never asks for one, and an unchecked box is
a claim about work not done, which the model cannot know.

**Fix shape** deterministic check. A markdown task-list line is exact-matchable.

**Status: DONE** — all five goals verified, see the results block below.

**Goals (each independently verifiable)**

1. A `no_invented_task_list` check exists in `scripts/delegate.sh`, warn-only.
   Its frontmatter value is not a boolean like the other declared checks: it
   names the `--var` holding the shape-authority examples, because the
   2026-08-21 calibration entry established that a task list IS correct output
   for a repo whose PR template carries one. Revised from "boolean `no_task_list`"
   after reading that entry.
   *Verify:* `grep -c no_invented_task_list scripts/delegate.sh` returns > 0.
2. It fires on the real captured draft.
   *Verify:* feeding `20260826T200251Z-*.draft.txt` through the wrapper with a
   shape-authority value carrying no checklist reports FAILED and names
   `no_invented_task_list`.
3. It does not fire on a PR body that legitimately contains a bullet list or a
   `[x]`-free checklist heading.
   *Verify:* the pass-case assertions in `tests/test-delegate.sh` are green.
4. The new assertions discriminate.
   *Verify:* the suite fails by exactly the number of new assertions when run
   against `scripts/delegate.sh` without the change, and passes with it.
5. Declared on `prompts/pr-description.md` with a dated calibration entry.
   *Verify:* `tests/test-prompts-library.sh` green; the entry names the date and
   the observed draft.

**Results**

1. `no_invented_task_list` in `scripts/delegate.sh`, warn-only, gated on the
   frontmatter value naming the shape-authority `--var`. It is deliberately not
   a blanket ban: the 2026-08-21 calibration entry established that a
   `- [x] Bug fix` category box is correct output for a repo whose PR template
   asks for one, so the check fires only when the output has a task list and
   the named examples have none.
2. Fired on the real captured draft, `20260826T200251Z-0a3abb42.draft.txt`,
   replayed through the wrapper: `check 'no_invented_task_list' FAILED — output
   carries 2 markdown task-list item(s) but the 'recent_prs' examples carry
   none`. The same draft with an examples value that does carry a checklist:
   silent.
3. Pass cases green: examples-carry-a-checklist, no-task-list-at-all, and
   `- [draft] note` (a bracketed word is not a checkbox).
4. Discriminating: `tests/test-delegate.sh` is 663 passed / 9 failed against the
   tree without the implementation and 672 passed / 0 failed with it.
5. Declared on `prompts/pr-description.md`, dated calibration entry naming the
   draft and the two prompt-text attempts it supersedes.
   `tests/test-prompts-library.sh` 366, `run-tests.sh` 94/94,
   `test-metrics-summary.sh` 157, both validators OK.

**One defect found while building it, worth recording.** The first
implementation passed the pattern to awk with `-v re=...` and did not fire on
the real draft at all. awk performs escape processing on `-v` assignments, so
`\[` collapses to `[`, and `[[ xX]\]` degrades into a bracket expression
followed by a literal `]` that never matches `- [ ]`. The pattern is now the
awk program itself. Goal 2 — "fires on the real captured draft" — is what
caught it; a suite of synthetic assertions written against the same broken
pattern would have looked green.

---

## Issue 2 — release PRs can never clear the `copilot_code_review` gate

**Observed** 2026-08-26. `#409` sat `BLOCKED` with `mergeable=MERGEABLE`, no
required status checks, and no bypass actors on the only ruleset
(`repo-butler/copilot-code-review`, `review_on_push: true`). Copilot does not
review release-please PRs on its own. Requesting the review by API produced a
review on the current head sha whose body said "Approval recommended" with zero
findings, and the base branch policy still refused the merge. 0.28.0 shipped
only under `--admin`.

**Fix shape** unknown until the mechanism is established. Investigate first;
this is the one issue in the queue that may end in a filed report rather than a
code change.

**Goals**

1. The mechanism is established from evidence, not inference — specifically
   whether the rule requires a review state of `APPROVED` (Copilot emits
   `COMMENTED`) and why `#432`/`#433` cleared it with the same state.
   *Verify:* a written finding citing the API responses it rests on.
2. Either the gate clears for a release PR without `--admin`, or a GitHub issue
   is filed on this repo recording the finding and the exact override command.
   *Verify:* a merged release PR with no admin override, or an issue URL.

**Status: PARTLY DONE** — the general mechanism is established and verified;
the release-PR case specifically is not, and is filed rather than guessed at.

**Results**

Verified, from PR #434. The gate blocks while any Copilot review thread is
unresolved, *including threads GitHub itself marks `isOutdated`* because a later
push already addressed them. #434 sat `BLOCKED` with both suites green, Copilot
having reviewed the current head sha, and two threads whose GraphQL state was
`isOutdated: true, isResolved: false`. Resolving both with
`resolveReviewThread` flipped `mergeStateStatus` from `BLOCKED` to `CLEAN`
immediately, and the merge went through with no override. Replying to a thread
does not resolve it; that is the trap, because replying is what the
address-pr-comments contract asks for.

That also explains #432 and #433, which had zero threads and merged first time.

NOT verified: why #409 blocked. Its shape matches #432/#433 exactly — one
Copilot review, state `COMMENTED`, on the current head sha `70477019`, and
`reviewThreads.totalCount` of 0 — and it still refused to merge, at least
through the four minutes I re-tested before moving on. The one structural
difference is that #409 is authored by `github-actions[bot]` and its review was
requested by hand through the API rather than fired by `review_on_push`. The
plausible mechanism is that the ruleset tracks its own automatic run rather than
the presence of a review, so a manually requested one never satisfies it. That
is a hypothesis, not a finding: it was not tested against a second release PR,
and I did not re-check the state in the ninety minutes before merging under
`--admin`.

Filed as [#436](https://github.com/IsmaelMartinez/delegate-local/issues/436)
so the next release measures it instead of re-deriving it. The override, when it
is needed, is `gh pr merge <n> --squash --admin`.

---

## Issue 3 — six stale worktrees holding unmerged branches

**Observed** 2026-08-26. `.claude/worktrees/` holds six worktrees dating from
May and June, each on a branch carrying one to three commits absent from `main`,
one with an uncommitted change. `git worktree prune` does not remove them
because the directories still exist. The standing instruction is to prune
worktrees when a task finishes; nothing here has been touched in two months.

**Fix shape** triage then cleanup. Removing a worktree keeps its branch, so the
commits survive; the uncommitted change does not.

**Goals**

1. Every one of the six branches has a written verdict: already in `main` by
   content, still wanted (issue filed), or abandoned.
   *Verify:* the triage table in this file is filled in.
2. The uncommitted change in `npx-install-fix` is captured before anything is
   removed.
   *Verify:* its diff is recorded here or committed to its branch.
3. `git worktree list` shows only the primary checkout.
   *Verify:* `git worktree list | wc -l` prints 1.

**Status: DONE.**

**Results**

1. All six branches map to MERGED PRs. The "commits ahead of main" reading was
   an artefact, not unmerged work: every one of those PRs was squash-merged,
   which writes a new commit, so the original branch commits are never
   ancestors of `main` and `git log main..branch` counts them forever. Nothing
   was at risk.
2. One file was genuinely only in a worktree: `docs/delegation-overview.html`,
   23 KB, last written 2026-06-19, untracked in `npx-install-fix` and present in
   no branch. Copied to
   `~/.local/share/delegate-local/archive/2026-08-26-worktree-salvage/` with a
   README explaining where it came from. Whether it belongs in the repo is not a
   cleanup decision, so it was not committed.
3. `git worktree list | wc -l` prints 1.

The six branches themselves still exist locally and were left alone; they cost
nothing and deleting merged branches was not part of this.

---

## Issue 4 — `maintainer-review-reply` has never been called

**Observed** 2026-08-26. Created at 15:09 for the evidence-led review-reply
workload, pointed at from `SKILL.md` and (since `#433`) from both scope
paragraphs of `maintainer-reply.md`. Still `n=0` while `maintainer-reply` took
14 verdicted calls the same day and kept none. Routing by prose has now been
tried twice and has not moved it.

**Fix shape** make the routing mechanical rather than advisory. The boundary
hook already inspects the outbound action and names a recipe; it can name the
right one.

**Goals**

1. The boundary hook names `maintainer-review-reply` for a PR-review-body
   context and `maintainer-reply` for a short status/diagnostic comment.
   *Verify:* `tests/test-delegate-boundary-hook.sh` green with new assertions
   covering both branches, and the assertions proven to discriminate.
2. No change to either recipe's prompt template.
   *Verify:* `git diff` on the PR touches no text inside a
   `## Prompt template` fence.

---

## Issue 5 — the live corpus contains no human verdicts at all

**Observed** 2026-08-26. All 70 feedback rows since the 2026-08-19 reset carry
`verdict_source: "agent"`. ADR 0015 separates the agent's usage judgment from
the human taste judgment precisely so the headline hit-rate is the latter, and
the headline currently has a sample size of zero. `metrics-summary.sh` reports a
blended rate that reads as a quality number and is not one.

**Fix shape** make the gap visible in the rollup rather than inferable from it.

**Goals**

1. `metrics-summary.sh` reports the human/agent split, and says explicitly when
   the human sample is zero.
   *Verify:* running it on the live corpus prints the split with `n=0` on the
   human side.
2. Covered by `tests/test-metrics-summary.sh`, discriminating.
   *Verify:* new assertions fail without the change and pass with it.

---

## Triage table for Issue 3

| worktree | branch | commits ahead | dirty | verdict |
| --- | --- | --- | --- | --- |
| agent-a4e531689d9d089e2 | `feat/mlx-reasoning-preference` | 2 | no | PR #237 merged — squash artefact, removed |
| agent-a738e3359b282d41f | `docs/phase-18-expansion-research` | 2 | no | PR #235 merged — squash artefact, removed |
| agent-a86add48de6671015 | `docs/expansion-use-cases` | 2 | no | PR #240 merged — squash artefact, removed |
| agent-af21c596344fe9522 | `docs/contributor-readiness` | 3 | no | PR #242 merged — squash artefact, removed |
| grafana-tempo-local | `fix/dashboard-bargauge-instant` | 3 | no | PR #249 merged — squash artefact, removed |
| npx-install-fix | `docs/cheap-first-economics` | 1 | untracked file | PR #322 merged; `docs/delegation-overview.html` salvaged to the archive, then removed |

## Issue 6 — reference trailers invent identifiers

**Observed** and written up by the repo itself, in the 2026-08-21 calibration
entry of `prompts/pr-description.md`. When the anchor examples end in
`Refs: AI-812` / `Refs: AI-806` and the Context names no ticket, the model emits
`Refs: AI-813`, continuing the numbering. Four prompt-side attempts were made
and all reverted; one made things actively worse, because its `Wrong:` example
contained a literal `AI-815` and the model then emitted exactly `AI-815`,
copying the value out of the prohibition. The entry's own conclusion: "This
needs a deterministic post-generation check, not more prompt text: a trailer
whose identifier does not appear in the inputs should be stripped or fail the
call, in the manner of the ADR 0014 checks."

**Fix shape** deterministic check, already specified by the entry above.

**Goals**

1. A check exists that fails when a trailer identifier in the output appears in
   none of the recipe's inputs.
   *Verify:* it fires on a synthetic `Refs: AI-813` with inputs naming only
   AI-812 and AI-806, and stays silent when the Context does name AI-813.
2. It cannot be satisfied by fabricating a plausible-looking value, which is the
   trap the 2026-08-21 entry describes.
   *Verify:* the guard text carries no literal identifier a model could copy.
3. Discriminating tests, and a dated calibration entry.
   *Verify:* the fail-then-pass counts are recorded here.

---

## Findings log

New defects found while working the queue are appended here with the evidence
that established them, then promoted to their own numbered issue.

- **2026-08-26, while building Issue 1.** `awk -v` escape processing silently
  breaks a bracket-expression pattern. Recorded in the Issue 1 results block
  rather than promoted, because it was a defect in the fix under construction
  and never shipped. The general lesson is in the queue rules: a goal that
  replays real captured evidence catches what synthetic assertions cannot.
