# Commit / PR / release / comment boundary hook (opt-in)

This hook closes the gap that issue #277 identified: the skill under-triggers not because its description is wrong but because skill selection happens turn-initially, while the highest-volume delegation moments — writing a commit message, a PR body, a release note — are turn-medial, the last sub-step of "implement X, commit, and open a PR". By the time the agent reaches that sub-step it is deep in execution and never re-runs skill selection, so it writes the message inline and the calibrated recipes go unused. No amount of instruction text in `SKILL.md` fixes a control-flow gating gap; a hook can, because it fires at the missed site, inside the harness, regardless of whether the agent reconsidered the skill.

The hook is `scripts/delegate-boundary-hook.sh`. It runs as a `PreToolUse` hook on the `Bash` tool. On every Bash call it cheaply checks whether the command is one of six delegatable boundaries: a `git commit` (that authors a message, i.e. not `--amend`) → `commit-message`; a `gh pr create` / `glab mr create` → `pr-description`; a `gh issue create` with an inline body (`--body` / `-b` / `--body-file` / `-F`, not `--web`) → `github-issue-body`; a `gh release create` → `release-note`; an inline PR review-comment reply (`gh api .../pulls/<n>/comments -X POST`, the `/address-pr-comments` path) → `pr-review-reply`; or a general comment reply (`gh pr comment` / `gh issue comment` / `glab mr note` / `glab issue note`) → `maintainer-reply`. The read-only fetch step `gh api .../comments --jq …` is deliberately not a boundary — only an explicit `POST` counts. If the command is none of these, the hook exits immediately and does nothing. If it is, the hook derives the project the same way `delegate.sh` does, looks in `metrics.jsonl` for a delegation for that project **and this boundary's recipe** within the last few minutes, and records one `source:"opportunity"` row capturing whether the artifact was drafted locally (`delegated:true`) or is about to be written inline (`delegated:false`). The match is recipe-aware on purpose: matching on project alone let a `commit-message` delegation mark a later `gh pr create` or review-comment reply as captured even though the PR body / reply was written inline, which both inflated the trigger rate and suppressed the reminder (a `delegated:true` row skips the nudge). A bare delegation with no recipe no longer counts for any boundary — the calibrated recipe the reminder names is the path. When it was not delegated, the hook surfaces a one-line reminder naming the exact recipe to use.

## Install

The hook ships with the skill but is not wired up automatically — enabling a global `PreToolUse` hook is your decision, so it is opt-in. Add the following to your global `~/.claude/settings.json`, merging the `Bash` matcher into your existing `PreToolUse` array if you already have one:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/skills/delegate-local/scripts/delegate-boundary-hook.sh"
          }
        ]
      }
    ]
  }
}
```

The hook needs `jq` on `PATH` (already a skill requirement) and nothing else. It fails open: any error, missing `jq`, or unparseable payload exits zero, so a hook bug can never block a commit. The only path that blocks a tool call is the explicit `enforce` mode below.

## Modes

The default mode is `warn`: the reminder is delivered as non-blocking `additionalContext`, so the agent sees it and the commit still proceeds. This is the measure-first default — it makes the trigger gap visible without getting in the way. Set `DELEGATE_BOUNDARY_MODE=enforce` to have the hook deny the commit and hand the agent the reason, forcing it to route through the recipe before retrying. Set `DELEGATE_BOUNDARY_MODE=off` to keep recording the opportunity metric while silencing the reminder entirely. The look-back window for a prior delegation defaults to ten minutes and is configurable with `DELEGATE_BOUNDARY_WINDOW_MIN`.

## Reading the trigger rate

Each boundary writes one opportunity row, so the denominator the whole problem is about — delegatable opportunities — finally exists. `scripts/metrics-summary.sh` reports it under a "Trigger rate (commit/PR/release/comment boundaries)" section, grouped by project, as `opportunities`, `delegated`, `missed`, and a `rate` percentage. A project sitting at a low rate is one where commit, PR, and comment-reply messages are still being written inline; that is the number to watch fall as the hook does its job. The opportunity rows store only the boundary type, the suggested recipe, the project, and the delegated flag — never the command or the message text — so nothing sensitive lands in the metrics file.

## Uninstall

Remove the `Bash` matcher block you added to `~/.claude/settings.json`. The opportunity rows already written are harmless and are simply ignored once no more accrue; delete them from `metrics.jsonl` if you want a clean slate.
