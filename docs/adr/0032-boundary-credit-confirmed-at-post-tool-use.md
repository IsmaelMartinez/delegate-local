# ADR 0032: A boundary credit is provisional until PostToolUse confirms the call ran

Status: accepted.
Date: 2026-09-16

## Context

The boundary hook (`scripts/delegate-boundary-hook.sh`, a `PreToolUse` hook
on Bash) credits a commit, PR, issue or reply to a recorded delegation and
spends that credit by appending a `delegated:true` opportunity row, one per
post, so a single delegation cannot credit a sweep. It does this before the
harness has decided whether the command runs. Two things then routinely stop
the command: Claude Code's worktree-isolation guard refuses a call carrying a
runtime value (`body=@"$CLAUDE_JOB_DIR/tmp/rr.txt"`) after the hook has
allowed it, and a `git commit` whose `git add` ran in a separate, refused
call exits 1 on an empty index. The post never happens, the credit is gone,
the retry seconds later is denied, and the agent delegates a second time for
the same text. Nine such pairs sit in the corpus for 2026-09-15 and 16, each
retried 5 to 13 seconds after the credit; the two shapes are #497 and its
comment.

The hook has no signal that the command did not run. The issue offered two
directions: confirm the spend from a `PostToolUse` hook, or let a denied
retry inside a short window reuse the immediately preceding credit when that
post could not have run, which the hook cannot tell on its own.

What the harness provides, verified against the hooks reference on
2026-09-16: `PostToolUse` fires only when a tool ran and succeeded; a
non-zero exit fires `PostToolUseFailure`; a permission denial fires
`PreToolUse` and then nothing; both `PreToolUse` and `PostToolUse` carry the
call's `tool_use_id`; and non-read-only Bash calls run one at a time (two
`sleep 3` calls issued in one turn ran back to back, measured the same day).

## Decision

A spend is provisional until confirmed. On a credited post the boundary hook
writes a marker, `<data dir>/.boundary-pending/<session>.<boundary>.<project>`, holding
the call's `tool_use_id`, the recorded project, the credited draft's stem and
the attempt's epoch. `scripts/delegate-boundary-confirm-hook.sh`, a new
`PostToolUse` hook on Bash, removes the marker whose id matches the call that
just succeeded; an interrupted call does not confirm. Nothing else fires for
a refused or failed call, so its marker stays.

When the same session reaches the same boundary for the same project while
its marker is still there and less than 300 seconds old, the new call is the
post that did not happen: it is credited on the same delegation, writes no
second opportunity row, stores its own body as the draft's final (replacing
one the hook wrote for the refused attempt, which the marker records as
`captured`; never one it did not write, such as a verdict's explicit
`--final`), and re-arms the marker under its own id, keeping the first
attempt's epoch so a chain of refusals cannot extend the window. The
marker outranks a fresh credit, because a sweep that delegates again before
retrying its refused post would otherwise spend the new delegation on the
retry and be denied on the post it was for.

`PostToolUse` reports the whole call, and its status is the boundary's own
only when the boundary is the call's last segment: `cd x && git commit` and
a wrapper script ending in the commit are, `git commit … && gh pr create`
and `git commit … || true` are not. A marker is written only then. A
boundary followed by anything else spends its credit for good, as before,
and a retry arriving in that shape consumes the marker rather than leaving
it for a further post.

The marker is honoured only once the confirm hook has been seen in the
session: it creates `<session>.seen` on its first call. A `PreToolUse`-only
install never confirms anything, and an unconfirmed marker there would credit
every post after the first, which is the sweep the one-credit-per-post rule
exists to stop. For such an install nothing changes.

The corpus keeps its shape. No new row type, no new field: the refused post
and its retry are one `delegated:true` row, and `metrics-summary.sh`'s
denied-and-retried exclusion now covers only genuine denials.

## Consequences

The pending directory is new per-user state beside the lock and the verdict
markers, pruned opportunistically: markers after a day, `.seen` files after
a week, so a session that outlives a day keeps its confirmation. The install block in
`docs/boundary-hook.md` gains a `PostToolUse` entry, and both hooks must be
installed together; the seen file is per session, so an uninstall takes
effect with the next session.

The confirm hook runs on every Bash call, costing one `jq` parse and one
`stat` on the common path, like the boundary hook's pre-filter.

A marker that is never confirmed and never retried (a refusal the agent
walked away from) expires silently; the `delegated:true` row it left stays
in the corpus as before, since nothing more is known about it.

## Alternatives considered

*Reuse the preceding credit on any denied retry inside a short window,
without confirmation.* Rejected. The hook cannot tell a refused post from a
sweep's next post: the corpus pairs 12 seconds apart include one with body
lengths 598 and 874, which is either a rewritten retry or two replies on one
delegation, and only the harness knows which. A window alone would also have
let a `PreToolUse`-only sweep walk several posts through on one credit, the
#511 failure again.

*Match the retry to the refused post by body text.* Rejected. The issue's own
first shape had no measurable body on the refused attempt (the path went
through a variable the hook cannot resolve), so equality could not have been
tested; the confirmation needs no text.

*Record the confirmation in the corpus as a row or field.* Rejected. It would
be a third row per post for the readers to join, and the marker already
carries the one fact the hook needs at the one moment it needs it.
