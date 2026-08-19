# Stop the dashboards calling usage telemetry a quality signal: design

**Date:** 2026-08-19
**Context:** found while restoring the Loki stack after a three-week outage
(the containers had exited 127; the sync script was fine).

Every figure below was measured against the live Loki store and cross-checked
with `jq` over `metrics.jsonl`. An adversarial review of the first draft found
eight blockers; where a claim here replaces one that was wrong, the correction
is stated rather than quietly fixed.

## The bug

The Calibration dashboard reports `HIT rate (overall) 72.7%` over
`Verdicts recorded 993`. Both numbers are real. Neither means what the label
says.

`delegate-feedback.sh` writes two different kinds of row into the same
`source:"feedback"` stream:

| row | `verdict_source` | written by | answers |
|---|---|---|---|
| human verdict | absent | a person running `delegate-feedback.sh hit\|miss` | was the output *good* |
| agent-observed | `"agent"` | the agent, via `--source agent` | did the agent *use* the output |

Measured on the live file (4922 rows, 2026-05-03 to 2026-08-19):

```
all feedback rows          993
  verdict_source="agent"   973   (98%)
  human verdicts            20   ( 2%)   10 kept / 10 rejected
```

This is not a new distinction. **ADR 0015 already decided it**, and its wording
is unambiguous: coverage and quality are different axes, and "coverage must
never be bought by faking quality". The ADR enumerates the consumers that must
honour the partition — `metrics-summary.sh`, `experiments/quality-trend.py`,
the MCP server — and even anticipates dashboards, noting that the OTel feedback
span carries the source "so an OTel-backed dashboard can reproduce the
human-only partition rather than re-contaminating the signal one layer
downstream."

The Loki dashboards were never added to that list. `metrics-summary.sh:249`
implements the partition correctly today; all nine calibration panels do not.
So this change is not a new design decision, it is making Grafana conform to an
accepted ADR it was left out of.

The failure hides a dead sensor. The last human verdict was **2026-06-21**. The
`HIT rate trend` panel nonetheless draws an unbroken line through August off
the agent proxy.

Two miscounts ride along:

- `MISS count 271` includes the 21 rows carrying `scaffold:true`. The code that
  writes them says so: *"scaffold is useful, not a miss"*
  (`delegate-feedback.sh:372`). It also counts 240 agent rewrites as quality
  misses.
- `Untracked delegations` is `delegations - all feedback`, so agent rows pay
  down a debt whose description names the human path.

## Decision

One rule: **an agent-observed number never wears a quality label.**

**Adoption** (`verdict_source="agent"`) answers *was the draft usable as-is*.
It is a real signal with the volume to trend — 73.2% over n=973. Panels using
it say "adoption" and say "agent-observed" in the description.

**HIT rate** (`verdict_source` absent) answers *was the draft good*. It is
n=20, split 10/10, and stale. The dashboard's job is to make that impossible to
miss.

### Selecting each population

Use `| verdict_source!="agent"` for human verdicts, **not** `| verdict_source=""`.

Both return 20 on today's data, but they mean different things. `=""` encodes
"the field is absent", while `metrics-summary.sh:249` encodes the intent:
`(.verdict_source // "human") == "human"`. Probing seven synthetic row shapes
showed `=""` also swallows an explicit `null`, and — the real hazard — a row
written as `verdict_source:"human"` would match *neither* population and vanish
from both gauges while `metrics-summary.sh` kept counting it. `delegate-feedback.sh`
cannot emit that shape today, but "the two surfaces cannot disagree" is only
true if the predicate encodes the same rule the script does. Same reasoning
gives `scaffold!="true"` rather than `scaffold=""`.

Every predicate that ships, measured:

| predicate | returns |
|---|---|
| `source="feedback"` | 993 |
| `\| verdict_source="agent"` | 973 |
| `\| verdict_source="agent" \| kept="true"` ÷ above | 0.7318 |
| `\| verdict_source="agent" \| kept="false" \| scaffold!="true"` | 240 |
| `\| verdict_source="agent" \| scaffold="true"` | 21 |
| `\| verdict_source!="agent"` | 20 |
| `\| verdict_source!="agent" \| kept="true"` | 10 |
| human HIT rate | 0.5 |
| calibration debt | 1523 |

The first draft claimed "no panel uses a predicate that was not measured" while
three shipped predicates were untested, and the `Rewritten` panel was justified
by `kept="false" | scaffold=""` = 250 — which includes the 10 human misses. The
agent-scoped form is 240. Every row above is now the exact expression the panel
carries.

### An empty result is not zero

This is the correction that most changes the design. Loki returns an **empty
vector**, not 0, when nothing matches, and Grafana renders that as "No data" —
so a threshold at 0 never evaluates.

At the dashboards' default 30-day range, no human verdict exists:

```
$__range = 7d    human verdicts EMPTY    adoption 0.424
$__range = 30d   human verdicts EMPTY    adoption 0.544
$__range = 60d   human verdicts 1        (a 100% HIT rate on n=1)
$__range = 90d   human verdicts 17
```

Without a guard the calibration signal reads as a broken panel beside a healthy
green adoption gauge, and `Calibration debt` — which renders today — goes empty
for the 50 of 55 projects that hold no human verdict at all.

Every human-verdict aggregation therefore ends `or vector(0)`, verified to turn
the empty 7d result into a literal `0`.

A "days since last human verdict" panel stays rejected, but the first draft's
reason for rejecting it was wrong. The real reason: Loki has no `time()`
function (`parse error at line 1, col 1`), so the only implementation is a
client-side transform over the last timestamp, which silently breaks whenever
the range excludes that timestamp. With `or vector(0)` the count reads a red
`0` at 7d and 30d, which is the honest answer to "how many human verdicts in
this window".

### Panel-by-panel

`delegate-calibration.json`, nine panels in, twelve out:

| was | becomes |
|---|---|
| HIT rate (overall) | **Adoption rate** — agent-observed |
| — | **HIT rate (human verdicts)** — new, `or vector(0)` |
| Verdicts recorded | **Adoption observations** — agent-observed |
| — | **Human verdicts** — new, red at 0, amber under 30 |
| MISS count | **Rewritten** — agent-observed, scaffold excluded |
| Verdict volume | **Adoption volume** — used vs rewrote, agent-observed |
| Untracked delegations | **Calibration debt** — minus *human* verdicts |
| HIT rate trend | **Adoption rate trend** — agent-observed |
| HIT rate by recipe | **Adoption by recipe** — agent-observed |
| HIT rate by project | **Adoption by project** — agent-observed |
| Recent MISSes | **Recent rejections** — see below |

`Verdict volume` was missing from the first draft's table, which is how "nine in,
eleven out" failed to reconcile. It queries the unfiltered stream on
`kept="true"`/`kept="false"` and is exactly the panel class the rule forbids.

`Recent rejections` cannot show "human first, agent below": a Grafana logs panel
merges targets and sorts by timestamp, and every agent row is newer than every
human row. It becomes two panels — `Recent human rejections` and `Recent agent
rewrites` — rather than one with an ordering that cannot hold. That split is why
the count is twelve rather than eleven.

The human HIT-rate gauge is the one place `or vector(0)` is deliberately **not**
applied. A rate over zero samples is undefined, and rendering it as 0% would read
as "everything failed" — the opposite of the truth. It keeps the empty result and
sets `noValue` to "no human verdicts in range", so it cannot be mistaken for a
broken query, with the red `0` on `Human verdicts` beside it carrying the
actionable number.

`delegate-overview.json`: the `HIT rate` gauge becomes `Adoption rate` with the
same filter.

### Rejected: a `verdict_kind` label at ingest

Cleaner queries, but it rewrites 993 stored rows and needs a full re-sync.
`verdict_source` already carries the distinction. Rejected as churn.

### Rejected: dropping agent-observed rows entirely

Adoption is the only signal with the volume to trend, and 73.2% over n=973 is
real information. The problem was the label, not the data.

## Three smaller defects fixed in the same pass

**Split project identity.** `delegate-to-ollama` and `delegate-local` are one
repository, renamed 2026-05-26 in #230, holding 472 and 390 delegate rows. Every
per-project panel splits the most-delegated project in two.

`label_replace` alone does **not** fix it. Loki tolerates duplicate label sets
and returns both series, so the naive form renders two bars both labelled
`delegate-local`:

```
label_replace(sum by (project)(...), "project","delegate-local","project","delegate-to-ollama")
  -> [{project=delegate-local} 472, {project=delegate-local} 390]
sum by (project) (label_replace(sum by (project)(...), ...))
  -> [{project=delegate-local} 862]
```

The outer re-aggregation is mandatory. On the ratio panel the fold applies to
numerator and denominator separately: folding the divided result yields two
different ratios under one name (0.727 and 0.798) instead of the pooled 0.764.
`Projects` needs it too — the naive form does not fold at all and still counts
55.

The two `teams-for-linux` entries are **not** the same case and are left alone:
`com.github.IsmaelMartinez.teams_for_linux` is the flatpak packaging repo with
its own remote.

**Junk in the tier and backend legends.** `Delegations over time by tier` and
`Tier distribution` show `--file`, `--project`, `--tier`, `--print-model`,
`--ts`, `small`, `fast`, `medium`, `mlx` and five more non-tiers. These are not
corrupt rows: all 44 exit 1 or 2 with `model=(none)` and `output_chars=0`, so
`delegate.sh` rejected them correctly. The panels simply do not filter to
successful delegations. `| exit_status="0"` leaves exactly `prose 1248`,
`reasoning 152`, `code 12`, `long-context 9`, `premium-general 1`.

`Delegations over time by backend` has the same defect (one junk `provider`
value among 121 failed rows) and takes the same filter.

**Phantom bars.** `Tokens avoided by project` shows an unlabelled 4.42 K bar:
querying it directly returns a series with an entirely empty label set
(`metric={}`) from the three delegate rows carrying no `project`. `HIT rate by
project` has a phantom too, but from a *different* cause — three **feedback**
rows lacking `project`. `Errors by project` has none, because all three
project-less delegate rows exited 0. `Projects` is inflated by the same
empty-label series (55 with, 54 without, 53 once folded). `| project!=""` on
each of the affected panels; `Errors by project` is left alone.

## Where `exit_status="0"` does and does not belong

Eleven overview panels omit the filter. Applied only where a failed call makes
the number say something false:

| panel | filter | why |
|---|---|---|
| Delegations over time by tier | add | junk legend |
| Tier distribution | add | junk legend |
| Delegations over time by backend | add | junk `provider` value |
| Tokens avoided (3 panels) | add | 235,514 tokens (7.7%) from calls that produced no output |
| Calls by recipe | add | a rejected call did not exercise the recipe |
| every latency panel | **add** | see below |
| Delegations (headline count) | no | "we attempted 1543" is the honest denominator for the error rate beside it |
| Projects | no | see phantom-bar fix instead |
| Error rate | no | it exists to count failures |

The first draft asserted the opposite for latency, claiming failures are fast
and would understate p95, and proposed filtering only the `generation_ms`
panels. **Both were wrong.** Measured:

```
generation_ms  FAILED  n=118   p50=376   p95=10725
generation_ms  OK      n=1090  p50=528   p95=5032
```

The median failed call is fast, but the tail is not: all 42 `exit_status=3`
rows are preflight canary stalls running up to 60 s. Including them nearly
doubles reported decode p95 (9466 vs 4979 through the real panel query),
attributing canary wall-time to model decode.

All five latency panels take the filter, not just the `generation_ms` ones. The
`duration_ms` p99 and `queue_wait_ms` p95 move only marginally (77,760 vs 79,673;
39,833 vs 41,253), which argues the filter is harmless there, not that it is
wrong. Leaving them unfiltered would also split `Queue wait vs generation (p95)`
across two different row populations inside one comparison panel.

## What is deferred, and why

`Tokens avoided` overstates the saving. Bucketing every delegation by its
last verdict, over the same 1543 rows and 3,043,892 tokens `metrics-summary.sh`
reports:

```
kept          1,495,984   49.1%   n=691
rewritten       571,954   18.8%   n=240
scaffold         37,613    1.2%   n=21
no verdict      938,341   30.8%   n=591
  (of the total, failed calls: 235,514 = 7.7%)
```

The first draft reported 636,579 rewritten and a split summing to 98%. That was
wrong twice: it iterated feedback rows rather than delegations, so the 46
delegations carrying more than one verdict (up to 5) were counted repeatedly,
and it silently dropped scaffold. The figures above sum to the total exactly.

The first draft also claimed this "cannot be expressed in LogQL — there is no
join". **False.** Loki supports vector matching, and the `ref_ts` join runs:

```logql
sum(label_replace(sum by (ts) (sum_over_time({...source="delegate"} | json
      | unwrap estimated_tokens_avoided [7d])), "ref_ts","$1","ts","(.+)")
    * on (ref_ts) group_left
    max by (ref_ts) (count_over_time({...source="feedback"} | json
      | verdict_source="agent" | kept="true" [7d])))
```

It returns 97,682 against a Python cross-check of 97,682 on the same window.

It is still deferred, for an honest reason rather than a false one: the
decomposition is a four-way bucketing with last-verdict-wins semantics that
`metrics-summary.sh` already implements. A second implementation in LogQL is
two copies of the same semantics free to drift, which is the failure this whole
change exists to remove. The panel description says what the number does and
does not account for; the decomposition is filed against `metrics-summary.sh`.

## Scope

Dashboard JSON only, all three files under `dashboards/grafana/`. No change to
what is written to `metrics.jsonl`, so no re-sync and no migration.

All three files round-trip byte-identically through Python `json` at
`indent=2` — `ensure_ascii=True` for calibration and overview, `False` for
errors, which uses literal em-dashes where the others use `—`. Edits are
applied programmatically on that basis so the diff carries no formatting noise.

Deliberately out of scope, filed separately: the `metrics-summary.sh`
decomposition; recording why a boundary was not delegated; and the far larger
finding that the tools which *produce* human verdicts (`verdict-sweep.sh`,
`delegate-verdict-stop-hook.sh`, `quality-report.sh`, `quality-trend.py`) were
all removed in `22395b2` on 2026-06-19 and never restored, which is why the
signal this dashboard reports has been dead since 2026-06-21.

## Verification

Every changed panel's query is run against live Loki and compared to a `jq`
computation over `metrics.jsonl`. They must agree exactly.

`tests/test-dashboards.sh` (35 assertions) needs:

- `verdict_source` and `scaffold` added to `KNOWN_FIELDS`. The extraction regex
  was run over every proposed expression and yields exactly
  `exit_status, kept, project, reason, recipe, scaffold, tier, verdict_source`;
  `label_replace`'s quoted arguments leak nothing. Note the regex requires a
  space after the pipe, so `|verdict_source=""` would bypass the allowlist
  silently — the panels are written with the space, and this is worth a comment.
- assertion 5's comment updated: it matches `by (recipe)` and `kept=`, which
  `Adoption by recipe` still satisfies.
- a new assertion keyed on the **stream, not the title**: any target selecting
  `source="feedback"` must carry a `verdict_source` predicate. A title-keyed
  assertion (the first draft's proposal) would have missed three of the nine
  conflated panels, including `Verdicts recorded`, and would guard nothing at
  all once the renames land.

### Rejected: `| __error__=""` after every `| json`

A single malformed line turns a panel into `pipeline error: JSONParserErr`
rather than a number, and the review proposed guarding all 42 targets. Rejected:
`sync-metrics-to-loki.sh` only pushes rows that already parsed as JSON, so this
guards a state that cannot occur through the supported path, at the cost of
touching every panel in the repo. It is worth revisiting only if a second writer
ever pushes to this stream.
