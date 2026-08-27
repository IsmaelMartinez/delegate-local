# Commit / PR / release / comment boundary hook (opt-in)

This hook closes the gap that issue #277 identified: the skill under-triggers not because its description is wrong but because skill selection happens turn-initially, while the highest-volume delegation moments — writing a commit message, a PR body, a release note — are turn-medial, the last sub-step of "implement X, commit, and open a PR". By the time the agent reaches that sub-step it is deep in execution and never re-runs skill selection, so it writes the message inline and the calibrated recipes go unused. No amount of instruction text in `SKILL.md` fixes a control-flow gating gap; a hook can, because it fires at the missed site, inside the harness, regardless of whether the agent reconsidered the skill.

The hook is `scripts/delegate-boundary-hook.sh`. It runs as a `PreToolUse` hook on the `Bash` tool. On every Bash call it cheaply checks whether the command is one of seven delegatable boundaries: a `git commit` (that authors a message, i.e. not `--amend`) → `commit-message`; a `gh pr create` / `glab mr create` → `pr-description`; a `gh issue create` with an inline body (`--body` / `-b` / `--body-file` / `-F`, not `--web`) → `github-issue-body`; a `gh release create` → `release-note`; an inline PR review-comment reply (`gh api .../pulls/<n>/comments -X POST`, the `/address-pr-comments` path) → `pr-review-reply`; a maintainer's PR review body (`gh pr review` with an inline body, or a `POST` to `.../pulls/<n>/reviews`) → `maintainer-review-reply`; or a general comment reply (`gh pr comment` / `gh issue comment` / `glab mr note` / `glab issue note`) → `maintainer-reply` for a short body, `maintainer-review-reply` for one at or above `DELEGATE_BOUNDARY_LONG_BODY_CHARS` (600) characters. The two reply boundaries are split because the recipes are: a review body carries a verdict and the anchors behind it at whatever length the evidence needs, while `maintainer-reply` is the closed two-sentence shape for a status comment or a diagnostic one-liner. That is also why the comment boundary routes by size rather than pinning one of them: the choice is between two shapes, and pinning the closed one is how it came to hold 33 of the corpus's delegations at 21% usable while its rejection reasons said the same thing over and over — two sentences returned where four paragraphs of evidence were wanted. The size is measured from the raw command (the scanner blanks quoted runs so a body is never read as live shell, which also means the classified segment carries none of it), from the file when `--body-file` names a readable one, and a measurement that fails leaves the short shape in place rather than promoting the reply on no evidence. `gh pr review` was added on 2026-08-26 after it turned out not to be a boundary at all — it cleared the pre-filter and matched no branch, so the most common way a maintainer posts a judgement produced no row and no reminder, while `maintainer-review-reply` sat at zero calls behind two rounds of prose routing. The review-comment boundary sat at 0/49 delegated until 2026-08-27, and the fault was the recipe rather than the sensor: `pr-review-reply` capped its output at the opener plus one short clause, while the 23 replies actually posted on PRs #440-#452 measure a median of 312 characters and only 4 fall under 100, so the recipe could not have produced 19 of them. The cap was lifted rather than the boundary retired. The read-only fetch step `gh api .../comments --jq …` is deliberately not a boundary — only an explicit `POST` counts. If the command is none of these, the hook exits immediately and does nothing. If it is, the hook derives the project the same way `delegate.sh` does, looks in `metrics.jsonl` for a delegation for that project **and this boundary's recipe** within the last few minutes, and records one `source:"opportunity"` row capturing whether the artifact was drafted locally (`delegated:true`) or is about to be written inline (`delegated:false`). The match is recipe-aware on purpose: matching on project alone let a `commit-message` delegation mark a later `gh pr create` or review-comment reply as captured even though the PR body / reply was written inline, which both inflated the trigger rate and suppressed the reminder (a `delegated:true` row skips the nudge). A bare delegation with no recipe no longer counts for any boundary — the calibrated recipe the reminder names is the path. When it was not delegated, the hook surfaces a one-line reminder naming the exact recipe to use.

Classification runs over a sanitised view of the command rather than the raw string. One awk pass drops heredoc bodies (resuming after the terminator, so a `cat > body.md <<'EOF' … EOF` write followed by `gh issue create --body-file body.md` still counts the post), blanks quoted spans, honours backslash escapes, and splits on `;`, `&`, `|`, `(`, `)`, `{`, `}` and newlines so each shell segment is classified on its own. Writing *about* a boundary command — in a heredoc body, a commit message, or any quoted prose — therefore no longer fires the hook, while wrapped forms like `sudo gh pr create`, `timeout 30 gh pr create` and `GIT_AUTHOR_NAME=x git commit` still do. Two cheap guards keep the cost off the common path: a single grep gates everything (an ordinary Bash call mentioning no boundary command costs one grep and exits), and the awk pass reads at most the first 32 KB of the command, because a 200 KB heredoc took ~800 ms to sanitise. The cap means a write-then-post whose heredoc body exceeds 32 KB — a long release note, say — records no opportunity row at all; the sensor goes blind rather than slow, which is the deliberate trade.

Two things affect the recorded row beyond `delegated`. A `gh`/`glab` post whose body comes from a file that already exists (`--body-file`, `--notes-file`, `--file`, `-F`, including `gh api -F body=@draft.md`) is recorded with `state:"pre-drafted"` and does not nudge: the drafting moment was an earlier `Write`, often followed by human review, so re-drafting now would discard approved text and counting it as a miss would deflate the rate. This is scoped to the segment that classified, so a body file named in another segment or inside quoted prose does not mark an inline post as pre-drafted, and `git commit -F` is deliberately excluded — that is an agent committing a message it just composed, which is the drafting moment the hook exists to catch. A recorded delegation inside the window still wins: `delegated:true` supersedes `pre-drafted`, so delegate-then-save-then-post counts as the success it is.

A credited post is also where the shipped half of the ADR 0029 pair comes from for the reply recipes. `maintainer-reply` was the weakest recipe with any volume — 21% usable over n=33 — and the only one whose 32 rejections carried no captured final at all, because its output goes out inline inside `gh pr comment --body "..."` and never reaches a file `delegate-feedback.sh --final` could name. A commit message reaches one before `git commit -F` reads it; a reply does not. When a post is credited (`delegated:true`) it is by definition that delegation's shipped form, so the hook stores the body at `<data dir>/drafts/<stem>.final.txt` under the credited draft's own stem — oldest-unspent-first, matching the order a sweep posts in, so a whole afternoon of replies is not filed against one draft. `delegate-feedback.sh` adopts the file when the caller passed no `--final` and records `final_source:"posted"`; an explicit `--final` overwrites it and is never relabelled. An existing file is never clobbered by the hook. The capture is pre-post, so a post that then fails leaves a final for text that never shipped, which is what the marker is for. `DELEGATE_LOCAL_NO_METRICS=1` suppresses the capture along with the row.

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

The default mode is `warn`: the reminder is delivered as non-blocking `additionalContext`, so the agent sees it and the commit still proceeds. This is the measure-first default — it makes the trigger gap visible without getting in the way. Set `DELEGATE_BOUNDARY_MODE=enforce` to have the hook deny the commit and hand the agent the reason, forcing it to route through the recipe before retrying. Set `DELEGATE_BOUNDARY_MODE=off` to keep recording the opportunity metric while silencing the reminder entirely. The look-back window for a prior delegation defaults to 480 minutes and is configurable with `DELEGATE_BOUNDARY_WINDOW_MIN`. The wide default exists for the batch flow, where a session delegates a sweep of drafts, waits for human approval, and posts hours later; a 10-minute window recorded every such post as a missed delegation and fired a spurious nudge at the compliant session. It is safe because credits are consumed: each `delegated:true` opportunity row spends one delegate row for that project and recipe, so one delegation credits one post rather than suppressing nudges for the rest of the window.

## Reading the trigger rate

Each boundary writes one opportunity row, so the denominator the whole problem is about — delegatable opportunities — finally exists. `scripts/metrics-summary.sh` reports it under a "Trigger rate (commit/PR/release/comment boundaries)" section, grouped by project, as `opportunities`, `delegated`, `missed`, and a `rate` percentage. Pre-drafted rows sit outside that ratio entirely — they are neither numerator nor denominator — and are reported as a trailing `pre-drafted=N` count only when some exist, so a metrics file without them prints exactly the line it always did. When every boundary for a project was pre-drafted the rate is omitted rather than printed as `0%`, which would read as total non-compliance. A project sitting at a low rate is one where commit, PR, and comment-reply messages are still being written inline; that is the number to watch fall as the hook does its job. The opportunity rows store only the boundary type, the suggested recipe, the project, the delegated flag and that optional state — never the command or the message text — so nothing sensitive lands in the metrics file.

## Uninstall

Remove the `Bash` matcher block you added to `~/.claude/settings.json`. The opportunity rows already written are harmless and are simply ignored once no more accrue; delete them from `metrics.jsonl` if you want a clean slate.

---

# Verdict-sweep Stop hook (opt-in, Phase E)

The boundary hook above makes delegation more automatic, which is half the loop. The other half — recording whether the delegated output was actually used — stayed manual, so verdict coverage slips as auto-delegation rises: the session-end sweep meant to catch the backlog (`scripts/verdict-sweep.sh`) is interactive and never runs on background jobs. The decisive observation is that auto-delegation moved the decision-maker from the human to the agent, and the agent is the only party that knows whether it used an output — and only while it is still running. A `Stop` hook fits exactly there: it fires when the main agent finishes a turn, the agent is still alive, and the hook can hand the just-finished session's untracked delegations back to it for a verdict before it stops.

The hook is `scripts/delegate-verdict-stop-hook.sh`. On every `Stop` event it derives the current project (the same rule `delegate.sh` and the boundary hook use) and scans `metrics.jsonl` for that project's successful delegations inside the look-back window that carry no verdict — `verdict-sweep.sh`'s base join (delegate rows with `exit_status == 0` and no referencing feedback row) plus a `.project` filter and minus the tty prompt. When the set is empty it exits immediately and does nothing. When it is non-empty it lists the batch (each delegation's `ts`, `recipe`, and `tier`) and re-engages the agent with `{"decision":"block","reason":…}` — `decision:"block"` is what makes a stopping agent continue; plain `additionalContext` does not reliably re-engage it. The instruction asks the agent, for each delegation it recognises from the current session, to record whether it *used* the output as-is (hit) or rewrote/discarded it (miss) with `delegate-feedback.sh --ts <ts> --source agent hit|miss`, and to leave any `ts` it does not recognise for the interactive sweep.

These verdicts are tagged `verdict_source:"agent"` and live in a separate tier from human verdicts (ADR 0015): the agent can honestly report a fact about its own behaviour ("I used it" / "I rewrote it"), but not the maintainer's taste judgment ("it was good"). The headline hit-rate counts human verdicts only; coverage counts both. `metrics-summary.sh` and `experiments/quality-trend.py` surface the agent tier as its own usage figure, never folded into the quality number.

Update (2026-06-18): the inline verdict path SKILL.md teaches — `delegate-feedback.sh` run right after a delegation — was found to be agent-operated too, but had been defaulting to the human tier because the inline command carried no `--source`. It now passes `--source agent`, and the historical inline rows were backfilled, so this Stop hook is the backstop for verdicts the agent did not record inline rather than the only agent-tier source. See ADR 0015's 2026-06-18 update for the evidence and the backfill heuristic.

## Install

Like the boundary hook, this is opt-in. Add a `Stop` entry to your global `~/.claude/settings.json` (alongside the `PreToolUse` boundary-hook entry if you use it):

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/skills/delegate-local/scripts/delegate-verdict-stop-hook.sh"
          }
        ]
      }
    ]
  }
}
```

The hook needs `jq` and `perl` on `PATH` (both already skill requirements). It fails open: any error, missing `jq`, unparseable payload, or an unwritable marker exits zero, so a verdict sweep can never wedge a session.

## The session-once loop guard

Because `decision:"block"` re-engages the agent, an unguarded hook would loop: if the agent declines or ignores the prompt, the next `Stop` sees the same untracked rows and blocks again, up to the turn limit. The guard is a session-once marker. The `Stop` payload carries a `session_id`; the first time the hook surfaces a batch it writes a marker file keyed by that id under `metrics.jsonl`'s directory (`.verdict-stop-markers/`). Every later `Stop` in the same session sees the marker and exits zero without re-injecting, so the agent always stops cleanly — even if it recorded nothing. The marker is written only when a batch is actually surfaced, so a session that delegated nothing leaves no marker and a later delegation in the same session can still be swept. Idempotency across sessions still holds: a recorded verdict drops its `ts` from the next scan, and per-session markers are pruned after seven days so they don't accumulate.

## Modes

The default mode is `warn`: the batch is surfaced once per session. Set `DELEGATE_VERDICT_STOP_MODE=off` to disable the hook entirely. There is deliberately no `enforce` mode — coercing a verdict is both hostile and dishonest, and a forced verdict is not a fact. The look-back window defaults to 24 hours and shares `DELEGATE_SWEEP_WINDOW_HOURS` with `verdict-sweep.sh`.

## Uninstall

Remove the `Stop` block from `~/.claude/settings.json`. The marker directory (`.verdict-stop-markers/` next to `metrics.jsonl`) and any agent-tagged feedback rows are harmless; delete the directory if you want a clean slate.
