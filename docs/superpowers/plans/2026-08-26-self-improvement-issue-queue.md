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

1. A `no_task_list` check exists in `scripts/delegate.sh`, warn-only, gated on a
   frontmatter boolean like every other declared check.
   *Verify:* `grep -c no_task_list scripts/delegate.sh` returns > 0.
2. It fires on the real captured draft.
   *Verify:* feeding `20260826T200251Z-*.draft.txt` through the check reports
   FAILED and names `no_task_list`.
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
| agent-a4e531689d9d089e2 | `feat/mlx-reasoning-preference` | 2 | no | TBD |
| agent-a738e3359b282d41f | `docs/phase-18-expansion-research` | 2 | no | TBD |
| agent-a86add48de6671015 | `docs/expansion-use-cases` | 2 | no | TBD |
| agent-af21c596344fe9522 | `docs/contributor-readiness` | 3 | no | TBD |
| grafana-tempo-local | `fix/dashboard-bargauge-instant` | 3 | no | TBD |
| npx-install-fix | `docs/cheap-first-economics` | 1 | YES | TBD |

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
