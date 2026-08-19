# Padding recall and `--repo` attribution: design

**Date:** 2026-08-19
**Issues:** #390, plus the `--repo` follow-up deferred from #393

## Task A: recover the dotted-tail recall (#390) — REJECTED after review

### What was proposed

#387 anchored the `no_padding_tail` participial arm to the line tail and
expressed "reaches the end of the line" as `[^.!?]{0,200}`. That treats every
full stop as a sentence end, so a padding tail containing `v2.1`, `Node.js`, a
dotted filename or a URL is missed. The proposal redefined a sentence end as a
dot followed by whitespace:

```
,[[:space:]]+[a-z]{3,}ing([[:space:]]([^.!?]|\.[^[:space:]])*)?[.!?]?[[:space:]]*$
```

It is not going in. Four findings, in descending order of how badly they kill it.

### 1. It is quadratic on the path that actually runs

The benchmark that motivated this spec was invalid. It timed
`", aaaaing x" * N`, a line the proposed expression **matches** at the first
start position, so grep exits early; the shipped expression does not match it
and scans the whole line. It compared an early exit against a full scan.

`no_padding_tail` passes far more often than it fires, so the no-match path is
the common one. Measured there, with `ggrep` and `LC_ALL=C.UTF-8`:

| bytes | shipped | proposed |
|---|---|---|
| 5202 | 10.9ms | 40.9ms |
| 10402 | 8.8ms | 112.7ms |
| 20802 | 10.6ms | 446.4ms |
| 41602 | 14.8ms | 1729.1ms |
| 83202 | 24.4ms | 6880.6ms |

Doubling the input quadruples the time. The mechanism is the change's own
purpose: `{0,200}` is the only thing capping how far a *failing* start position
scans, and letting the star cross intra-token dots means each failure now runs
to end of line. Detection width and per-failure cost are the same knob.

The "determinism of disjoint branches" argument was reasoning about an idealised
engine. The blowup persists with a single candidate start position, and it
vanishes under `LC_ALL=C` and under macOS grep, which is the exact trap the
existing comment in `run_output_checks` warns about and the likely route by
which the author reached "linear".

### 2. Dropping the bound silently widens the auto-strip

`{0,200}` also bounds detection by clause length. Removing it means a filler tail
longer than 200 characters, previously invisible, is now detected, stripped and
adopted: 245 characters of body content deleted from output the shipped script
leaves untouched. `padding_re_adopt` does not stop it, because the stripped
result is genuinely clean under the broad gate. This is the outcome that guard
exists to prevent, arriving through the other door.

### 3. The recovered cases can never be auto-fixed

The perl strip's own class is `[^,.!?]*`, which cannot cross a dot either. Every
shape this task set out to recover therefore ends as FAILED with the output
unchanged. The change cannot improve a single byte of output; it can only make
`checks_failed` fire more often, which is the metric #384 depends on, days after
the work to clean that signal up.

### 4. It reintroduces a narrower version of the #387 false positive

"Dot followed by whitespace" is not what ends an English sentence. A period
before a closing quote or paren, or with the space omitted, ends one too, and
the star walks straight through:

```
the flag is read, allowing the caller to say "no." the rest is unchanged.
… opt out (see below.) the rest is unchanged.
```

Both are load-bearing mid-sentence participials newly flagged as tails, which is
exactly the regression #387 fixed. Over 12,014 prose lines the proposal adds 30
detections, 3 of which cross a sentence boundary this way. One is ADR 0017's own
opening paragraph.

### The decision

Leave `padding_re` alone. The measured recall gain is about one body in 300 (the
corpus of 301 commit bodies with a real prose body contains exactly one dotted
tail), none of it auto-fixable, against a matcher that is 30x slower on the
common path at ordinary sizes and quadratic as output grows. `no_padding_tail`
is warn-only for these shapes, so a missed warning costs nothing.

A linear alternative exists and was measured: normalise intra-token dots with
`sed 's/\.\([^[:space:]]\)/_\1/g'` before the grep, leaving `padding_re`,
the `{0,200}` bound and the auto-strip scope all byte-identical. It is rejected
too, on findings 3 and 4, which apply to it equally. It is recorded here so a
future revisit starts from the measurement rather than rediscovering it.

### A correction to #387's own evidence

While checking this, the corpus claim in #387 turned out to be inflated. It said
"297 hand-written commit bodies, 2 flags before and 0 after". Bash `case` is
case-sensitive, so the filter excluded `Co-Authored-By:` but not GitHub's
squash-merge `Co-authored-by:`, and 278 of those 297 "bodies" were trailer lines
rather than prose.

Measured properly, taking the last prose line after stripping trailers, over 301
commits that have a real body:

| | flags | true positives | false positives |
|---|---|---|---|
| pre-#387 | 12 | 5 | 7 |
| shipped | 4 | 4 | 0 |
| proposed | 5 | 5 | 0 |

#387's conclusion survives intact and is in fact better than it claimed: it
removed 7 false positives and kept every true positive but one. The comment in
`scripts/delegate.sh` should carry these numbers instead.

## Task B: attribute a boundary that names its repo explicitly

### The gap

#393 resolves the boundary's repo from a leading `cd`, which covered 62 of 68
boundaries in the audit traffic. The remaining six are `gh issue create --repo
owner/name` and `gh issue comment --repo owner/name`, which carry no `cd` and
are still filed under the session cwd. That matters more than 9% suggests:
`maintainer-reply` is the single largest behavioural gap in the audit, 2% of 288
August boundaries, and comment-reply is exactly the class this leaves
misattributed.

### The decision, after review: widen the lookup only

Parse `--repo owner/name` (and `-R owner/name`) off the already-sanitised
`matched_seg` and add `name` as a further candidate in the delegation **lookup**
only. Do not let it set the recorded project.

Replaying the whole of `metrics.jsonl` through both options settles it:

| | counted opportunities | delegated | project keys |
|---|---|---|---|
| today | 2128 | 421 | 20 |
| lookup only | 2130 | 428 | 20 |
| recorded too | 2130 | 428 | 24 |

Recall is identical, because the either-match set is the same under both.
Setting the recorded project buys nothing and costs four new project keys, each
holding one to three opportunities and no delegations, so each prints as a
`rate=0%` row in `metrics-summary.sh`. It also moves 15 rows off `repo-butler`
and 7 off `com.github.IsmaelMartinez.teams_for_linux`. That is denominator
fragmentation, which is the harm this task set out to repair.

The driver of that fragmentation is not the renamed-checkout case this spec
originally worried about. That case is real but dormant: of about fifty
checkouts, exactly one derives a name differing from its origin, it is on
GitLab where `gh --repo` does not apply, and it has produced no rows. The actual
driver is hub-repo sweeps, `gh pr comment N --repo IsmaelMartinez/<other>
--body "@dependabot rebase"`, which are 13 of the 34 affected rows.

### Correcting this spec's earlier reasoning

An earlier draft argued that lookup-only "does not fix the denominator, which is
the actual complaint". That is wrong, and the mechanism matters. The hook clears
`state` whenever `delegated` becomes true, and `metrics-summary.sh` excludes
`state:"pre-drafted"` rows from both halves of the ratio. So a lookup-only match
promotes a pre-drafted row out of the excluded set and into the counted set as a
success. Two of the four rows this task is about behave exactly that way, which
is why the two options tie.

The same mechanism inverts the original framing: all four genuinely
misattributed rows carry `state:"pre-drafted"`, so setting the recorded project
could not have fixed their denominator either.

### Correcting the premise

The count is four, not six. Two of the six candidate rows came from a background
job that really did run with `cwd` inside `delegate-local`; the mirrored
transcript rewrites the `cwd` field, and their metrics rows are already correct.
Across every transcript on the machine there are 34 affected rows, of which 6
are correctly rejected because the value is a shell variable, and 6 flip to
`delegated:true` under this change.

### Validation is security work

The value must be validated whole, not just its last segment:
`^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$`, applied before splitting on `/`. That is
the only thing rejecting `--repo IsmaelMartinez/$1`, `--repo $R` and
`` --repo `whoami`/name ``, and a last-segment-only check would accept all
three. Shell-variable values are 11 of 534 real invocations, so this is a live
shape rather than a hypothetical. Nothing is ever expanded or executed either
way, which was confirmed by experiment.

A legitimately quoted `--repo "owner/name"` is blanked by the scan surface and
falls back silently. That is 6 of 534 invocations and it fails safe, but it is
the opposite trade-off from the `cd` block, which parses the raw command
precisely so it can read quoted values. The comment must say so, because the
next reader will assume the two blocks work alike.

### Verification

`gh issue comment 1 --repo owner/repo-b --body x`, run from repo-a with a
matching `maintainer-reply` delegation recorded under `repo-b`, records
`delegated:true` while `project` stays `repo-a`. Negatives that must fall back
cleanly: a shell-variable value, a quoted value, a bare `--repo` with no value,
a value with no slash, and `--repo` followed by another flag. A segment carrying
both a leading `cd` and a `--repo` pins the precedence.

## Non-goals

#384 stays deferred. Only four post-#387 boundary rows exist so far, which is
nowhere near enough to recompute the kept-rate split the issue rests on.
