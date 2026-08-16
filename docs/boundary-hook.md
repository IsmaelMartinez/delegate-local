# Commit / PR / release / comment boundary hook (opt-in)

This hook closes the gap that issue #277 identified: the skill under-triggers not because its description is wrong but because skill selection happens turn-initially, while the highest-volume delegation moments — writing a commit message, a PR body, a release note — are turn-medial, the last sub-step of "implement X, commit, and open a PR". By the time the agent reaches that sub-step it is deep in execution and never re-runs skill selection, so it writes the message inline and the calibrated recipes go unused. No amount of instruction text in `SKILL.md` fixes a control-flow gating gap; a hook can, because it fires at the missed site, inside the harness, regardless of whether the agent reconsidered the skill.

The hook is `scripts/delegate-boundary-hook.sh`. It runs as a `PreToolUse` hook on the `Bash` tool. On every Bash call it cheaply checks whether the command is one of six delegatable boundaries: a `git commit` (that authors a message, i.e. not `--amend`) → `commit-message`; a `gh pr create` / `glab mr create` → `pr-description`; a `gh issue create` with an inline body (`--body` / `-b` / `--body-file` / `-F`, not `--web`) → `github-issue-body`; a `gh release create` → `release-note`; an inline PR review-comment reply (`gh api .../pulls/<n>/comments -X POST`, the `/address-pr-comments` path) → `pr-review-reply`; or a general comment reply (`gh pr comment` / `gh issue comment` / `glab mr note` / `glab issue note`) → `maintainer-reply`. The read-only fetch step `gh api .../comments --jq …` is deliberately not a boundary — only an explicit `POST` counts. If the command is none of these, the hook exits immediately and does nothing. If it is, the hook derives the project the same way `delegate.sh` does, looks in `metrics.jsonl` for a delegation for that project **and this boundary's recipe** within the last few minutes, and records one `source:"opportunity"` row capturing whether the artifact was drafted locally (`delegated:true`) or is about to be written inline (`delegated:false`). The match is recipe-aware on purpose: matching on project alone let a `commit-message` delegation mark a later `gh pr create` or review-comment reply as captured even though the PR body / reply was written inline, which both inflated the trigger rate and suppressed the reminder (a `delegated:true` row skips the nudge). A bare delegation with no recipe no longer counts for any boundary — the calibrated recipe the reminder names is the path. When it was not delegated, the hook surfaces a one-line reminder naming the exact recipe to use.

Classification runs over a sanitised view of the command rather than the raw string. One awk pass drops heredoc bodies (resuming after the terminator, so a `cat > body.md <<'EOF' … EOF` write followed by `gh issue create --body-file body.md` still counts the post), blanks quoted spans, honours backslash escapes, and splits on `;`, `&`, `|`, `(`, `)`, `{`, `}` and newlines so each shell segment is classified on its own. Writing *about* a boundary command — in a heredoc body, a commit message, or any quoted prose — therefore no longer fires the hook, while wrapped forms like `sudo gh pr create`, `timeout 30 gh pr create` and `GIT_AUTHOR_NAME=x git commit` still do. Two cheap guards keep the cost off the common path: a single grep gates everything (an ordinary Bash call mentioning no boundary command costs one grep and exits), and the awk pass reads at most the first 32 KB of the command, because a 200 KB heredoc took ~800 ms to sanitise. The cap means a write-then-post whose heredoc body exceeds 32 KB — a long release note, say — records no opportunity row at all; the sensor goes blind rather than slow, which is the deliberate trade.

Two things affect the recorded row beyond `delegated`. A `gh`/`glab` post whose body comes from a file that already exists (`--body-file`, `--notes-file`, `--file`, `-F`, including `gh api -F body=@draft.md`) is recorded with `state:"pre-drafted"` and does not nudge: the drafting moment was an earlier `Write`, often followed by human review, so re-drafting now would discard approved text and counting it as a miss would deflate the rate. This is scoped to the segment that classified, so a body file named in another segment or inside quoted prose does not mark an inline post as pre-drafted, and `git commit -F` is deliberately excluded — that is an agent committing a message it just composed, which is the drafting moment the hook exists to catch. A recorded delegation inside the window still wins: `delegated:true` supersedes `pre-drafted`, so delegate-then-save-then-post counts as the success it is.

The reminder names a command that runs as printed. Every boundary recipe declares required inputs in its frontmatter and `delegate.sh` exits 2 when one is missing, so a reminder that named only the recipe — as it did until now — handed the agent `delegate.sh --recipe commit-message <tier> "..."`, which fails with `missing required inputs: recent_commits diff_stat why`. The hook fired, the agent tried the command, and the delegation never happened. The reminder now reads the recipe's own `inputs:` block and names each required key as a `--var`, renders `stdin` as an input redirection rather than a `--var`, omits inputs marked optional with a trailing `?`, and names the `prose` tier instead of a `<tier>` stand-in the agent had to guess. Reading the keys from the recipe rather than hardcoding them here keeps the reminder correct when a recipe changes its inputs.

The reminder names `--project <project>` explicitly. `delegate.sh` derives its metrics project from its own cwd, so an agent that `cd`s into the skill checkout to run the command records `project=delegate-local` and never matches this lookup — the nag-despite-compliance loop of issue #342. `delegate.sh --project NAME` and the `DELEGATE_PROJECT` environment variable both set it, and `delegate-feedback.sh` honours the same variable so a verdict lands on the same project as the delegation it references.

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

Each boundary writes one opportunity row, so the denominator the whole problem is about — delegatable opportunities — finally exists. `scripts/metrics-summary.sh` reports it under a "Trigger rate (commit/PR/release/comment boundaries)" section, grouped by project, as `opportunities`, `delegated`, `missed`, and a `rate` percentage. Pre-drafted rows sit outside that ratio entirely — they are neither numerator nor denominator — and are reported as a trailing `pre-drafted=N` count only when some exist, so a metrics file without them prints exactly the line it always did. When every boundary for a project was pre-drafted the rate is omitted rather than printed as `0%`, which would read as total non-compliance. A project sitting at a low rate is one where commit, PR, and comment-reply messages are still being written inline; that is the number to watch fall as the hook does its job. The opportunity rows store only the boundary type, the suggested recipe, the project, the delegated flag and that optional state — never the command or the message text — so nothing sensitive lands in the metrics file.

## Uninstall

Remove the `Bash` matcher block you added to `~/.claude/settings.json`. The opportunity rows already written are harmless and are simply ignored once no more accrue; delete them from `metrics.jsonl` if you want a clean slate.
