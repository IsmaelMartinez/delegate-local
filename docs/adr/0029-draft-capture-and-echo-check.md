# ADR 0029: Capture the draft, capture what shipped, and reject prompt echo

Status: accepted
Date: 2026-08-26

## Context

Two things happened on 2026-08-26. Delegation volume jumped roughly tenfold
after the drafting skills started routing maintainer replies through recipes
(two to four a day became thirteen, then twenty). Over the same two days the
keep rate collapsed from 14/24 to 1/33.

Reading the rejection reasons showed one hard defect and one soft one.

The hard one: two `pr-agent` calls minutes apart, carrying 7,689 and 7,317
characters of piped context, both returned exactly 96 characters — the length,
and the content, of `maintainer-reply.md`'s own `Correct:` example line. A
third opened with the same example's "the regression is" framing for something
that was not a regression. The contrastive-anchor pattern (ADR 0011) that makes
these recipes work also hands the model a fluent, on-topic, grammatically
complete sentence to fall back on when the real input gets long. The AI-815
leak in `pr-description` was the same shape. Prompt text cannot close it: the
guards telling the model not to copy are themselves lines it can copy.

The soft one could not be diagnosed at all, and that was the more important
finding. `quality-report.sh` says so in its own header: it re-reviews past
verdicts "from data already on disk — it does not need the original model
output (which is never stored)". A rejection recorded the agent's prose
description of a draft nobody could ever look at again. "Dropped every
load-bearing fact" does not say which facts, or what the model wrote instead,
so every recipe edit downstream of it was a guess.

## Decision

Three changes, and a script that consumes them.

**Capture the draft.** `delegate.sh` writes the generated output to
`<data dir>/drafts/<ts>.draft.txt` and names it on the metrics row as
`draft_file`. Local file beside `metrics.jsonl`, outside the repo, never
transmitted; opt out per call with `DELEGATE_NO_DRAFT_CAPTURE=1`, skipped
entirely when metrics are off, size-capped by `DELEGATE_DRAFT_MAX_BYTES`
(default 64 KiB) and pruned after `DELEGATE_DRAFT_RETENTION_DAYS` (default 14).

The draft filename leads with the row timestamp and carries the call's span id
as a suffix. The timestamp alone is not safe: it has second precision and
parallel callers share it — the archived corpus holds 14 timestamps used by
more than one delegation, one of them by eight — so a ts-derived name would let
two drafts clobber each other and leave two metrics rows pointing at a single
file, destroying the pairing this exists to create.

**Capture what shipped.** `delegate-feedback.sh --final <path|->` stores the
text that actually went out as `<ref_ts>.final.txt` and names it as
`final_file`. A rejection then carries a concrete (generated, shipped) pair.
From that pair `self-improve.sh` computes the salient tokens present in one and
absent from the other: `DROPPED` is what a human had to put back, `INVENTED` is
what the model made up. Those two lists are the calibration signal the free-text
reason could only gesture at.

**Reject prompt echo.** `no_example_echo` is a deterministic post-generation
check that fails when any output line reproduces a line of the recipe's own
prompt. Unlike every other check in ADR 0014 it is on by default for every
recipe call rather than declared per-recipe, because echoing the prompt is
never a correct outcome for any recipe. Comparison is whole-line and literal
(`grep -F`, so linear time, no regex) against the PRE-substitution template, so
reproducing a caller-supplied fact never flags; a 40-character floor keeps short
shared lines from colliding; `Wrong:` / `Correct:` labels are stripped before
comparing so both arms of an anchor pair are covered. Opt out with
`no_example_echo: false` in a recipe's frontmatter or `DELEGATE_NO_ECHO_CHECK=1`
for one call.

The shipped text is named after the delegate row's `draft_file`, not after
`ref_ts`, for the same reason and with the added property that the two halves
are then provably the same delegation's. Where a second-precision timestamp is
genuinely shared, a feedback row's `ref_ts` cannot say which delegation it
scored; `self-improve.sh` reports that ambiguity rather than presenting the
attribution `INDEX(.ts)` happened to keep, and resolves the draft from the
feedback row's own `final_file` so the pair stays exact regardless.

`scripts/self-improve.sh` gates the recurring calibration session (exit 10 and
silence when nothing has happened since its watermark) and emits the evidence
bundle when something has. `docs/self-improvement-loop.md` is the procedure.

## Consequences

`checks_run` is now at least 1 on every recipe row, where recipes with no
`checks:` block previously emitted no check fields at all. Nothing reads
`checks_run` today (`metrics-summary.sh` does not), and the change is honest —
a check does run.

The echo check stays warn-only, consistent with ADR 0014, so a leak still
reaches stdout and still exits 0. The stderr line says REJECT and the failure
lands in `checks_failed_names`, which is what an agent reads and what the loop
counts. Hard-failing on it is the obvious escalation once there is data on the
false-positive rate; it was not taken on day one because a check with no
production history should not be able to break every caller.

The captured drafts hold whatever context was piped in, so they inherit its
sensitivity. The directory is forced to 700 and every file to 600, written
under `umask 077` so there is no permissive window between create and chmod;
inheriting the caller's umask would have left them world-readable on a host
with a loose one. They never leave the machine, but a host with sensitive
delegation traffic should still set `DELEGATE_DRAFT_RETENTION_DAYS` low or
`DELEGATE_NO_DRAFT_CAPTURE=1`.

Coverage of the pair depends on callers passing `--final`, which is the one
part of this that cannot be enforced by the wrapper. `self-improve.sh` reports
its own coverage for exactly that reason: a loop that cannot see its blind spot
optimises the half it can see.

## Alternatives considered

*Fix the leak by rewording the recipe.* Done as well, not instead: both
contrastive pairs in `maintainer-reply.md` became angle-bracket skeletons, so a
leak now surfaces as literal `<the cause>` rather than a plausible fabrication.
That is the same principle that killed the reference-trailer guard in
`pr-description`, where turning visibly-wrong output into a believable fake was
worse than no guard. But wording is per-recipe and the failure is library-wide,
which is why the check exists too.

*Store the prompt and context alongside the draft.* Rejected for now. The draft
and the shipped text are what a recipe edit is calibrated against; the input is
much larger, much more sensitive, and adds little the reason does not already
carry.

*A structured defect taxonomy on the verdict (`--defect <tag>`).* Rejected as
the primary mechanism. It needs every caller to classify honestly and
consistently, which is exactly the discipline that was already failing. The
draft/final diff is objective and needs no agent cooperation beyond passing the
text it already has in hand.
