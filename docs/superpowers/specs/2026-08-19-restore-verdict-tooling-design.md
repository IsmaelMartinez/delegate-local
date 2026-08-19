# Restore the verdict tooling: design

**Date:** 2026-08-19

An adversarial review of the first draft found six blockers. Two inverted the
draft's own reasoning: the silent-divergence mechanism it was built on runs the
opposite way, and it misread the precedent it claimed to follow. Both
corrections are recorded rather than quietly applied.

## What is broken

The last human verdict was **2026-06-21**. Since then, 321 successful
delegations and zero human verdicts.

The first draft blamed commit `22395b2` (2026-06-19, "archive research/
observability machinery out of main"), which removed all four tools below. That
causation is wrong and the review caught it: the last human verdict landed
**two days after** that commit. The archive did not stop the last verdict; it
removed the instruments that would have produced the next ones, and
`verdict-sweep.sh` — the only tool that records a verdict with no `--source`,
which is what makes it human — has been gone ever since.

The current state, measured:

```
last 7d    successful=86   untracked=21  human-verdicted=0
last 30d   successful=312  untracked=75  human-verdicted=0
lifetime   successful=1423 untracked=483 human-verdicted=20
```

(The first draft printed 321 and 87 for the 30d and 7d figures. Both were
transpositions; the lifetime row reproduced exactly.)

## What is restored

Four tools and four test suites from `archive/research-machinery` (tag
`pre-cleanup-2026-06-19`). All four suites pass unmodified — 128 assertions,
verified on the bash 3.2 baseline as well as CI's bash 5.

| tool | produces |
|---|---|
| `scripts/verdict-sweep.sh` | **human** verdicts — `delegate-feedback.sh --ts <ts> hit\|miss`, no `--source` |
| `scripts/delegate-verdict-stop-hook.sh` | agent verdicts (a `Stop` hook) |
| `scripts/quality-report.sh` | ADR 0016 re-review over the `reason` text |
| `experiments/quality-trend.py` | weekly human hit-rate plot |

"The suites pass, so the tools did not rot" is **not** evidence for two of them.
`test-quality-report.sh` and `test-verdict-sweep.sh` contain zero
`verdict_source` references and their fixtures predate the tier split entirely,
so neither can distinguish a healthy tool from one blind to it — which is
exactly the defect below.

## Change 1: repoint the data path

All four defaulted to `~/.claude/skills/delegate-local/metrics.jsonl`. Seven
sites, now on the canonical expression the other twelve sites use.

The first draft justified this with silent divergence: read the stale file,
write to the live one. **That is backwards.** `verdict-sweep.sh:131` forwards
the resolved path to the recorder:

```bash
DELEGATE_METRICS_FILE="$metrics_file" bash "$script_dir/delegate-feedback.sh" --ts "$ts" hit
```

so it writes where it read. Proven by running the pristine archive version in a
sandbox HOME: the legacy copy grew by one row, the live file was byte-identical
afterwards. The real failure is worse in one way and better in another — the
verdicts are internally consistent but land in a file nothing else reads, so the
live history gains nothing at all.

Read/write divergence **does** exist, in the place the first draft never looked.
`delegate-verdict-stop-hook.sh:139` injects a bare recorder invocation with no
path forwarded, so the hook scans the path resolved in *its* environment while
the agent writes to the path resolved in the *agent's*. The injected instruction
now carries the resolved path.

The legacy copy is also not the "June-era fossil" the first draft implied: it is
a strict prefix of the live file, 39 rows and about seven hours behind.

## Change 2: `quality-report.sh` partitions, and stops miscounting

Restored unmodified it prints one pooled figure over 994 verdicts of which 974
are agent-observed. Three separate defects, all measured:

**It does not partition.** Zero `verdict_source` references. The two populations
are not one number wearing a label:

```
human   n= 20  reason 100%   hit 50%   clean-as-is 25%
agent   n=974  reason  66%   hit 73%   clean-as-is  9%
```

The first draft proposed "keep the data, correct the label — #408's fix". It
misread #408, which **partitioned**: adoption and HIT rate became separate
panels, and `tests/test-dashboards.sh` assertion 5e makes every feedback-stream
query commit to a population. A renamed pooled figure would fail the direct
analogue of that assertion. So this partitions too, with its own denominators
throughout, and `--by-recipe` takes the same predicate rather than being left as
a third unpartitioned surface.

**`Clean-as-is` divides by the wrong denominator.** The numerator comes from
reasoned rows only; the denominator is every verdict. So the metric falls as
reason coverage falls, independent of quality — and coverage differs 100% against
66% between the tiers, which is precisely where a side-by-side comparison would
mislead. On classified rows the gap is 25% against 14%, not 25% against 9%. It
now denominates on classified, prints reason coverage per tier, and the caveat
is rewritten: the first draft's text called it an upper bound while the
denominator bias pushes it *down*, so the caveat was wrong in sign.

**Scaffold counts as a miss.** All 21 `scaffold:true` rows land in the 272
misses. `delegate-feedback.sh:372` is explicit that "scaffold is useful, not a
miss" and `metrics-summary.sh` has 29 scaffold references; `quality-report.sh`
has none. It becomes its own outcome.

## Change 3: make them reachable

The first draft registered nothing and documented nothing, which the review
correctly called out as shipping the stated problem unchanged: `grep` for the
four tool names across `SKILL.md`, `README.md`, `CONTRIBUTING.md` and
`CLAUDE.md` returns nothing. A sweep no document mentions is not a recovered
capability.

So: a README entry naming the four tools and when to run them, and restoration
of the `## Install` section for the Stop hook that `22395b2` deleted along with
it — the `~/.claude/settings.json` block and the session-once-guard explanation
— so registering it is an informed choice rather than a research exercise.

Four CI steps, plus `python3` added to the "Verify required tools" check, which
lists `jq`, `perl` and `bash` but not the interpreter `test-quality-trend.sh`
needs at five call sites.

## What this deliberately does not do

**It does not register the Stop hook or schedule the sweep.** A `Stop` hook only
fires when registered in settings; nothing in the repo auto-registers it. That
hook re-engages the agent with `decision:"block"`, and 18 of the 21 currently
untracked rows are ones `metrics-summary.sh` itself labels "verdicts optional",
so an unfiltered hook would pester the agent about work it does not need to
judge. That is a decision to make with the install docs in hand, not a side
effect of a restore.

**It does not revive the signal by itself.** Restoring instruments and reviving
a signal are different things, and the first draft's framing conflated them. The
sweep still counts an agent verdict as tracked, so it offers only genuinely
unjudged rows — 3 in 24h, 21 in 7d, 385 in 90d. ADR 0015's 2026-06-18 update
says what calibration actually needs is "a small periodic human sample used only
to calibrate the verifier", and the rows worth sampling are the ones the agent
graded itself on. The sweep cannot reach those. Filed, not folded in.

**The sweep cannot record `scaffold`.** It offers `h/m/s/q` where `s` is skip,
so a human cannot record the third outcome the recorder supports. Filed.

## Hygiene

`.verdict-stop-markers/` is debris from when metrics lived in the checkout; the
hook derives `marker_dir` from `dirname "$metrics_file"`, so repointing
relocates it. Removed, and gitignored so it cannot return as untracked noise.
`.gitattributes` still carries two `experiments/**` rules for paths that no
longer exist.

`experiments/quality-trend.py` returns a maintainer-only script to a tree that
ships whole as the plugin, which is what `22395b2` set out to stop. Recorded as
a known trade rather than solved here.

## Verification

- Each tool resolves the live metrics file, not the legacy copy.
- `test-paths.sh` catches a regression to the legacy default **in Python too**.
  The existing guard cannot: its pattern is `:-\$HOME/...`, which Python never
  writes, and broadening it to a bare path match false-positives on the two
  deliberate migration hints in `delegate-feedback.sh` and `metrics-summary.sh`.
  A language-specific assertion is required; the first draft's one-line "the
  guard is widened" hid that.
- `quality-report.sh` reports human and agent separately with their own
  denominators, excludes scaffold from misses, and a test pins that it cannot
  silently repool — the restored fixture has no `verdict_source` at all, so the
  fixture is extended rather than trusted.
- The four suites pass and run in CI.
