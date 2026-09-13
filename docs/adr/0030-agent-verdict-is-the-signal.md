# ADR 0030: The agent's verdict is the calibration signal

Status: accepted. Supersedes ADR 0015.
Date: 2026-09-13

## Context

ADR 0015 split verdicts into two tiers. A human recording a taste judgment
was the quality signal and the headline hit rate; the agent recording whether
it had used its own draft was tagged `verdict_source:"agent"` and reported as
usage, never quality. The stated reason was honesty: the producing agent
grading its own output skews toward "I used it, so it was good", and a
maintainer's judgment was the anchor that kept that bias out of the number.

ADR 0015's own update three days later found the premise wrong. Of the 619
rows tagged human, 616 had been recorded by the agent within 300 seconds of
the delegation and were retagged; the genuine human sample was three rows. The
corpus was reset on 2026-08-19 (ADR 0028) partly so that a human sample could
be collected from zero, and `verdict-sweep.sh --calibrate` was restored to
offer agent-graded hits back to a person for a second look.

Measured 2026-09-13 on the live corpus since the reset: every feedback row
carries `verdict_source:"agent"`. There are zero human rows. Read as the
signal, the last 14 days say commit-message usable 92% (n=41),
github-issue-body 100% (n=12), pr-review-reply 100% (n=2), maintainer-reply
67% (n=53), maintainer-review-reply 55% (n=60) — numbers the tooling was
printing under "usage, not quality" and refusing to quote as a keep rate.

The maintainer's stated design is that the loop is fully automatic. The agent
that requested a delegation and used or rewrote its output records the
verdict, and no human is in the loop, because a human tier fills at a few
rows a week and the loop then never goes fast enough to calibrate anything.
Every consumer that still modelled the human tier was reporting on a
population that does not exist: `metrics-summary.sh` printed `hits=0
misses=0` beside `agent=115`, `self-improve.sh` said "no human taste judgment
in this window, so there is no keep rate to quote" on every run and carried
an `h=` column that was always 0, the Grafana calibration dashboard split the
same two tiers, and the Stop hook told the agent to leave unrecognised rows
"for the interactive verdict-sweep.sh", which nobody runs.

## Decision

There is one verdict tier, and the agent records it. A verdict is `hit` (the
draft shipped as-is), `scaffold` (discarded but built on) or `miss` (rewritten
or thrown away); `scaffold` and `miss` require a reason, and the stored
draft/final pair (ADR 0029) sits beside it. That triple — verdict, reason,
pair — is the quality signal a recipe edit is calibrated from. The headline
hit rate is computed from every feedback row.

`delegate-feedback.sh` defaults to `--source agent`, still accepts the flag
because every caller passes it, and refuses `--source human` with exit 2 and
a pointer at this ADR. Every row goes on carrying `verdict_source:"agent"`:
the Grafana dashboards and the other consumers filter on it, and a row
without it would be the one kind the reporting cannot place. The
mandatory-reason rule, previously scoped to the agent tier with the human
sweep exempt, now applies to every rejection.

`metrics-summary.sh` reports hits, misses, scaffold and untracked from all
feedback rows in the headline, per-tier, per-project and per-recipe lines; the
"Agent-observed (usage, not quality)" block, the `agent=` column and the
"Agent self-flattery" comparison are gone, because each compared one tier
against another. Coverage and the captured-pair line are unchanged.
`self-improve.sh` quotes one keep rate from every row and drops the `h=`
column. The calibration dashboard shows hit / scaffold / miss from all rows
instead of a human gauge beside an adoption gauge.

The Stop hook drops the hand-off sentence and, with no human sweep behind it,
lists only this session's rows: a delegate row that carries the `session`
field `delegate.sh` writes from `CLAUDE_CODE_SESSION_ID` (#479) is surfaced
only in the session whose `session_id` matches, named project or not. #477 had
scoped only the projectless rows that way, so a named-project row from a
parallel session was still listed, and an agent was asked about a draft it
never saw. Rows with no `session` field keep the project-only match. The
recommended command pins by `--id <otel_span_id>`, read off the row, rather
than `--ts`.

`scripts/verdict-sweep.sh` and `tests/test-verdict-sweep.sh` are archived out
of `main`, the same way commit `22395b2` archived the research and
observability machinery. They existed to record human verdicts and to offer
agent-graded hits back for a human second look; both are populations this ADR
retires. The last `main` commit carrying them is `c7d7a27`, so
`git show c7d7a27:scripts/verdict-sweep.sh` recovers the script and
`git log --diff-filter=D -- scripts/verdict-sweep.sh` names the commit that
removed it. Everything else the sweep did — the untracked-set join, the
window — the Stop hook already does for the session that can answer.

## Consequences

Existing rows need no rewrite. Every feedback row in the live corpus already
carries `verdict_source:"agent"`, and the readers treat an untagged row the
same as a tagged one, so the archived pre-reset corpus (ADR 0028) reads under
the same rule if pointed at.

The self-grading bias ADR 0015 named is real and is not measured any more,
because the tier that measured it never filled. What keeps the number honest
instead is the evidence beside it: the reason, the draft/final pair, and the
deterministic checks (ADR 0014, ADR 0029) that cannot flatter. A hit rate
with thin capture coverage is a weaker claim than the percentage suggests,
and `docs/self-improvement-loop.md` says so where the number is read.

`quality-report.sh --tier human|agent|all` and `experiments/quality-trend.py`
still model two tiers. Both read rows the recorder no longer writes and were
left as they are; they are a follow-up, not part of this change.

## Alternatives considered

*Keep the human tier and feed it.* Rejected. It was the plan of ADR 0028 and
`verdict-sweep.sh --calibrate`, and in the 25 days since the reset it produced
zero rows. A signal nobody supplies is not a signal, and every consumer that
waited for it printed nothing useful in the meantime.

*Merge the tiers in the reporting only, keeping `--source human` writable.*
Rejected. A human row that can still be written would be the one row the
merged reporting could not place, and the flag's continued existence would
keep suggesting a second population that the design says does not exist.

*A local-model judge in place of the human.* Rejected, as ADR 0015 already
rejected it: it trades the producing agent's self-bias for a weak reasoner's
noise, the failure mode SKILL.md is built around.
