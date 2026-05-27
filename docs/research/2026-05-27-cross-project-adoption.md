## Cross-project adoption findings

### Current state

Of 515 delegate calls with a `project` field set (plus 3 rows with `project` unset), 497 (97% of attributed calls) come from `delegate-to-ollama` (the skill's own repo, now renamed `delegate-local`). The remaining 18 calls come from 7 project contexts, all within the last 48 hours (2026-05-25 to 2026-05-27): `github-issue-triage-bot` (3), `delegate-local` (3 — these are calls attributed to the new repo name after the rename, distinct from the 497 under the old name), `triage-bot-test-repo` (2), `enable-update-live` (2), `commit-message-contrastive-anti-padding` (1), `roadmap-rename-stream` (1), and 6 calls from worktree contexts with transient project names.

The user has 15 repos with Claude Code project configs and 17 repos checked out under `~/projects/github/`. Eight of those repos have seen active Claude Code sessions in the past week (teams-for-linux, bonnie-wee-plot, votescot, github-issue-triage-bot, repo-butler, delegate-local, delegate-to-ollama, triage-bot-test-repo). Only 3 of those 8 have any delegation at all, and all cross-project usage started on 2026-05-25 — 13 days after the first delegation on 2026-05-12.

### Why other repos don't delegate

The trigger description in SKILL.md is comprehensive and well-worded. The skill is installed globally at `~/.claude/skills/delegate-local` (symlinked to the repo checkout), so it is available in every session. The blocking factors are not about discoverability or trigger keywords. They are structural:

1. No repo-level CLAUDE.md mentions delegation. Only `delegate-local/CLAUDE.md` itself references the skill. The repos where the user spends the most time (teams-for-linux, repo-butler, bonnie-wee-plot, votescot) have no hint that delegation is available or preferred. The global CLAUDE.md at `~/.claude-home/CLAUDE.md` mentions "delegate to subagents" once but in a discouraging context ("only when the task clearly benefits"), and never mentions Ollama, local models, or the delegate-local skill.

2. Session work in other repos is predominantly code-oriented. teams-for-linux is Electron development, repo-butler is a GitHub Action pipeline, bonnie-wee-plot is Next.js, votescot is Astro. These sessions involve debugging, feature implementation, and architectural decisions — all in the "do NOT delegate" bucket. The prose-heavy tasks that delegation handles well (commit messages, PR descriptions, summaries) exist in those sessions but are incidental, not the primary task shape.

3. No recipe muscle-memory outside the skill repo. The 12 external delegations are all `bare` (no `--recipe` flag) except one `commit-message` recipe call from a worktree. The recipes were developed and tested entirely within the skill's own repo; the user hasn't built the habit of reaching for `--recipe commit-message` when finishing work in teams-for-linux.

### Recommendations

First, add a one-line delegation nudge to the user's global CLAUDE.md: something like "Use the delegate-local skill for commit messages, PR descriptions, and summaries via `--recipe` where a recipe exists." This puts the skill in the decision path for every session without requiring per-repo CLAUDE.md changes.

Second, the commit-message recipe is the highest-leverage cross-project entry point. Every repo produces commits. The skill should be the default path for drafting commit messages in all repos, not just delegate-local. This is a habit/workflow change, not a code change.

Third, track cross-project adoption as a metric. The `project` field is already present in the JSONL; a weekly rollup of unique projects with delegations (excluding the skill's own repo) would surface whether the nudge is working. The current 6-project count is the baseline.
