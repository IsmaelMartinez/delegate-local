# Commit / PR / release / comment boundary hook (opt-in)

This hook closes the gap that issue #277 identified: the skill under-triggers not because its description is wrong but because skill selection happens turn-initially, while the highest-volume delegation moments — writing a commit message, a PR body, a release note — are turn-medial, the last sub-step of "implement X, commit, and open a PR". By the time the agent reaches that sub-step it is deep in execution and never re-runs skill selection, so it writes the message inline and the calibrated recipes go unused. No amount of instruction text in `SKILL.md` fixes a control-flow gating gap; a hook can, because it fires at the missed site, inside the harness, regardless of whether the agent reconsidered the skill.

The hook is `scripts/delegate-boundary-hook.sh`. It runs as a `PreToolUse` hook on the `Bash` tool. On every Bash call it cheaply checks whether the command is one of five delegatable boundaries: a `git commit` (that authors a message, i.e. not `--amend`) → `commit-message`; a `gh pr create` / `glab mr create` → `pr-description`; a `gh release create` → `release-note`; an inline PR review-comment reply (`gh api .../comments -X POST`, the `/address-pr-comments` path) → `pr-review-reply`; or a general comment reply (`gh pr comment` / `gh issue comment` / `glab mr note` / `glab issue note`) → `maintainer-reply`. The read-only fetch step `gh api .../comments --jq …` is deliberately not a boundary — only an explicit `POST` counts. If the command is none of these, the hook exits immediately and does nothing. If it is, the hook derives the project the same way `delegate.sh` does, looks in `metrics.jsonl` for a delegation for that project **and this boundary's recipe** within the last few minutes, and records one `source:"opportunity"` row capturing whether the artifact was drafted locally (`delegated:true`) or is about to be written inline (`delegated:false`). The match is recipe-aware on purpose: matching on project alone let a `commit-message` delegation mark a later `gh pr create` or review-comment reply as captured even though the PR body / reply was written inline, which both inflated the trigger rate and suppressed the reminder (a `delegated:true` row skips the nudge). A bare delegation with no recipe no longer counts for any boundary — the calibrated recipe the reminder names is the path. When it was not delegated, the hook surfaces a one-line reminder naming the exact recipe to use.

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
