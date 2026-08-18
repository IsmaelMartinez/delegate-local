# Release pipeline publishes tags — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A merged release PR creates its git tag and a published GitHub release, so the three-release stall cannot recur.

**Architecture:** One config flag and one workflow trigger. `release-please-config.json` currently sets `"draft": true`, and a draft GitHub release does not create its git tag; release-please then loses its anchor and regenerates the entire history into the next changelog. Flipping the flag makes releases publish on merge, which creates the tag, which keeps the anchor. `workflow_dispatch` on the release workflow removes the need for an unrelated push to main to regenerate a stale release PR.

**Tech Stack:** GitHub Actions, `googleapis/release-please-action@v5`, `jq`, bash.

**Spec:** `docs/superpowers/specs/2026-08-18-backlog-completion-design.md` (task T1)

## Global Constraints

- Conventional Commit messages. This change is `fix:` (it repairs a broken pipeline), on branch `fix/release-pipeline-publishes-tags`.
- Do not reformat or reorder unrelated lines in config or workflow files.
- `enforce_admins` is `false` on `main`; release PRs are merged with `gh pr merge <n> --squash --admin` because their CI is gated behind manual approval. This is accepted, not fixed here. See #366.
- No new script, no new test harness. This task changes three files.

## File Structure

- `release-please-config.json` — one key flips. Nothing else in the file moves.
- `.github/workflows/release-please.yml` — gains `workflow_dispatch:` under `on:`.
- `CONTRIBUTING.md` — gains a short "Releasing" section stating the actual procedure, including the approval gate and the `--admin` merge.

No test file changes. The verification is the pipeline itself, observed on the next release.

---

### Task 1: Flip the draft flag and add the manual trigger

**Files:**
- Modify: `release-please-config.json` (the `"draft": true` line)
- Modify: `.github/workflows/release-please.yml` (the `on:` block)
- Modify: `CONTRIBUTING.md` (append a "Releasing" section)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a pipeline that, on the next merge to `main`, regenerates the release PR against the now-correct `v0.23.0` tag and, when that PR merges, creates `refs/tags/v0.24.0` and a published release.

- [ ] **Step 1: Record the current state so the change is provable**

```bash
cd "$(git rev-parse --show-toplevel)"
jq -r '.packages["."].draft' release-please-config.json   # expect: true
# grep exits 1 when nothing matches, which aborts the block under `set -e`,
# so assert absence directly instead of counting it.
! grep -q 'workflow_dispatch' .github/workflows/release-please.yml && echo "PASS: absent as expected"
```

- [ ] **Step 2: Create the branch**

```bash
git checkout -b fix/release-pipeline-publishes-tags
```

- [ ] **Step 3: Flip the draft flag**

Change exactly this one line in `release-please-config.json`:

```json
      "draft": true,
```

to:

```json
      "draft": false,
```

- [ ] **Step 4: Verify the flag flipped and nothing else moved**

```bash
jq -r '.packages["."].draft' release-please-config.json   # expect: false
git diff --numstat release-please-config.json             # expect: 1  1  release-please-config.json
```

- [ ] **Step 5: Add the manual trigger to the release workflow**

In `.github/workflows/release-please.yml`, change:

```yaml
on:
  push:
    branches:
      - main
```

to:

```yaml
on:
  push:
    branches:
      - main
  # Lets a stale release PR be regenerated without waiting for an unrelated
  # push to main. Needed on 2026-08-18 when three releases had gone out as
  # drafts, leaving no tags for release-please to anchor on.
  workflow_dispatch:
```

- [ ] **Step 6: Verify the workflow file still parses**

```bash
python3 -c "import yaml,sys; d=yaml.safe_load(open('.github/workflows/release-please.yml')); print(sorted(d[True].keys()) if True in d else sorted(d['on'].keys()))"
```

Expected: a list containing both `push` and `workflow_dispatch`. (PyYAML parses the bare
key `on` as the boolean `True`, hence the fallback.)

- [ ] **Step 7: Document the actual release procedure**

Append to `CONTRIBUTING.md`:

```markdown
## Releasing

Releases are cut by release-please. Merging to `main` opens or updates a PR titled
`chore(main): release X.Y.Z`; merging that PR tags the commit and publishes the
release.

Two things about this repository are worth knowing before you cut one:

Releases publish rather than draft. `release-please-config.json` sets
`"draft": false` deliberately. A draft release does not create its git tag, and
release-please anchors changelog generation on tags, so a drafted release silently
breaks the next one. Three releases (v0.21.0 to v0.23.0) were lost this way before
2026-08-18.

The release PR's CI needs a manual approval. It is authored by
`github-actions[bot]`, and the repository's Actions approval policy is
`first_time_contributors`, so its `ci` run completes as `action_required` with no
jobs until someone clicks "Approve and run". Either approve it, or merge with
`gh pr merge <n> --squash --admin` (`enforce_admins` is `false` on `main`). The
structural fix, a PAT or App token for release-please, is tracked in #366.

If a release PR is stale, re-run the release workflow from the Actions tab
(`Release Please` has a `workflow_dispatch` trigger) rather than pushing a no-op
commit to main.
```

- [ ] **Step 8: Run the full suite to confirm nothing regressed**

```bash
bash tests/run-tests.sh
bash tests/test-delegate.sh
```

Expected: both pass at their current counts. Neither touches the release config, so
this is a smoke check, not a targeted test.

- [ ] **Step 9: Commit**

```bash
git add release-please-config.json .github/workflows/release-please.yml CONTRIBUTING.md
git commit -m "fix: publish releases instead of drafting them so tags are created

Refs: #366"
```

- [ ] **Step 10: Push and open the PR**

```bash
git push -u origin fix/release-pipeline-publishes-tags
gh pr create --title "fix: publish releases instead of drafting them so tags are created" --body "..."
```

- [ ] **Step 11: Wait for CI and the Copilot review, address every comment, then merge**

The repository ruleset `repo-butler/copilot-code-review` posts a review one to five
minutes after the push, and branch protection has `required_conversation_resolution:
true`, so each thread must be resolved via the GraphQL `resolveReviewThread` mutation
after replying. Merge with `gh pr merge <n> --squash --delete-branch`.

- [ ] **Step 12: Verify the pipeline end to end**

After the merge lands on main, release-please re-runs on the push event. Then:

```bash
# Resolve the PR rather than hardcoding 352: release-please normally updates
# its PR in place, but if the computed version changes it can close and reopen
# with a new number, and this step would then verify a stale PR.
pr=$(gh pr list --state open --json number,title \
      --jq '.[]|select(.title|startswith("chore(main): release "))|.number')
# `|| true` because grep -c prints 0 but exits 1 on no match, aborting `set -e`.
bullets=$(gh pr diff "$pr" --patch | grep -c '^+\* ' || true)
expected=$(git log --format=%s v0.23.0..origin/main \
            | grep -cE '^(feat|fix|perf|security|deps|refactor|docs|ci|test|chore)(\(.+\))?!?: ' || true)
breaking=$(git log --format=%B v0.23.0..origin/main | grep -c '^BREAKING CHANGE' || true)
echo "pr=$pr bullets=$bullets expected=$((expected + breaking))"
test "$bullets" -eq $((expected + breaking))
```

Bullets must equal the count of commits release-please is *configured to render*,
which is not the same as the raw commit count. `changelog-sections` lists ten types,
so a commit outside them produces no bullet; a breaking change produces a bullet with
no extra commit; and once the release commit itself is on `main`, `v0.23.0..main`
includes a `chore(main): release` commit that release-please omits from its own
changelog. Measured across the repository's history, bullets equal commits minus one
in 13 of 22 releases and are exactly equal in one, so a naive equality would be wrong
most of the time. That the check passes is what proves release-please recovered its
anchor.

- [ ] **Step 13: Merge the release PR and confirm the tag exists**

```bash
gh pr merge 352 --squash --admin
git fetch --tags
git rev-parse -q --verify refs/tags/v0.24.0        # expect: a sha, exit 0
gh release view v0.24.0 --json isDraft --jq .isDraft # expect: false
```

If `isDraft` reports `true`, the flag did not take effect and the task has failed;
stop and re-read `release-please-config.json` on `main` before doing anything else.

---

## Self-Review

**Spec coverage.** T1 in the spec asks for three things: the draft flag, the
`workflow_dispatch` trigger, and documentation of the `--admin` step and the approval
gate. Steps 3, 5 and 7 cover them in order. T1's verification command
(`jq -r '.packages["."].draft'`) is Step 4; T1's post-merge verification is Step 13.

**Placeholder scan.** Step 10's `--body "..."` is the one deliberate placeholder: the
PR body is generated from the diff at the time, per the repository's delegation rule.
Every other step carries its literal content.

**Type consistency.** No types. The one cross-step dependency is the branch name,
`fix/release-pipeline-publishes-tags`, used identically in Steps 2 and 10.

**Risk.** The failure mode worth naming: if release-please does *not* regenerate #352
after this merges, Step 12's counts will disagree, and the cause is almost certainly
that the workflow ran before the tags were visible. The recovery is the
`workflow_dispatch` trigger added in Step 5, which is why it is in this PR rather
than a later one.
