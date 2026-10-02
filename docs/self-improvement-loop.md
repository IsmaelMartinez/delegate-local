# The self-improvement loop

The recipe library is supposed to accumulate calibration: every rejected draft
names a defect, and the defect becomes a guard so the next draft does not carry
it. In practice that only happened when a human asked "how are we doing", which
on 2026-08-26 meant a full day of twenty delegations, zero kept, and a defect
(a recipe returning its own example instead of an answer) that had been sitting
in the recorded reasons since the first call that morning.

This document is the procedure that closes the gap on a schedule. It is written
for the headless session `scripts/self-improve-daily.sh` starts once a day (see
"Run it on a schedule" below), but it is equally the checklist to follow by
hand.

## Run the gate first

```bash
bash scripts/self-improve.sh
```

Exit 10 means nothing has happened since the last run. **Stop. Say nothing, do
not summarise, do not open a PR.** A loop that reports "no change" every two
hours is noise, and the quiet path deliberately prints nothing to stdout.

Exit 0 means there are new delegations and the evidence bundle is on stdout.
Exit 2 is a real error (no metrics file, no `jq`) and is worth surfacing.

Running it advances a watermark, so the next run sees only what is new. Use
`--peek` when you want to look without consuming the window. The watermark is
the newest `ts` in the file, verdicts included, and every since-watermark
section counts a delegation once under its latest verdict and reads that
verdict's own `ts`, so a verdict recorded after a run on a delegation that run
already saw, or on a delegate row appended out of `ts` order (a row is stamped
when its call starts), still reaches the next bundle (#553). A verdict that
names no final is paired with the hook-written `<stem>.final.txt` beside its
draft unless `suspect-finals.tsv` lists it (see "Quarantined finals" below),
and `--ritual` judges that adopted final for ritual as it does a named one.

## What the bundle gives you

Six sections, in the order you should read them.

The **verdict tally** is the headline: how many of the verdicts recorded since
the watermark were kept, edited and shipped (scaffold), or rewritten, and the usable rate
over all of them, each delegation counted once under its latest verdict.
Every verdict is the agent's own record of what it did with its draft, and
that is the one tier there is (ADR 0030): the agent that used or rewrote the
output is the judge, and the reason plus the draft/final pair is what turns a
verdict into evidence. A draft that shipped with only caller-fixed lines added
(a trailer, a `Refs` or `Closes` line, the Claude Code footer, a session URL)
is a hit, not a scaffold: those lines are the caller's to add whatever the
draft said, and such pairs were labelled kept on 6 rows on 2026-09-16 and
scaffold on 13 from 2026-09-23 (#589). The
bundle's `SHAPE` and `DROPPED` lines and the replay's `dropped` read the
shipped body without those lines for the same reason (`body_only` in
`scripts/lib/pair-score.sh`).

The **per-recipe outcomes** section ranks recipes by usable rate — kept plus
scaffold — over a rolling window, worst first, so the recipe worth your
attention is the top line with a meaningful `n`. Usable rather than kept alone,
because a draft the agent edited and shipped did most of its job, while a
recipe whose drafts are all thrown away is a different and worse problem, and
a kept-only rate cannot tell the two apart. `commit-message` read 0% kept and
80% usable on the same 25 rows the day this changed. Ignore a 0% on `n=1`; one
delegation is not a signal. The window is on the delegation's own time and the
verdict join is `scripts/lib/pair.jq`, so these counts are the ones
`metrics-summary.sh --days N` prints for the same N (#564). A ritual verdict
(`ritual=`, the caller posted text it already had) is the tag stored on the
verdict or, for one recorded before the tag existed, the measurement
`self-improve.sh --ritual` wrote to `ritual-verdicts.tsv`; rerun `--ritual`
without `--peek` after the corpus gains such verdicts, since the rates never
measure on their own.

The **per-template outcomes** section appears only for a recipe that ran
under more than one template in the window: one line per template, newest
first, with the hash, the first row's timestamp and the same counts. Rows
from before the hash was recorded are their own `(unhashed)` line. This is
the post-merge read for an edit that landed, and the revert signal (see
"Revert when the online read disagrees" below); when no recipe changed
template there is nothing to read and the section is absent.

The **deterministic check failures** section needs no interpretation. The
wrapper already decided the output broke a constraint the recipe declared, so
anything clustered here is the cheapest fix available.

The **rejected drafts** section is the substance. Each entry carries the
agent's free-text reason, and where both were captured, the draft the model
produced and the text that actually shipped, plus three objective signals:

- `DROPPED` — salient tokens (paths, backticked spans, hashes, issue refs,
  numbers) present in the shipped text and absent from the draft. These are
  the specific facts a human had to put back. A recipe edit aimed at these is
  calibrated; one aimed at "dropped every load-bearing fact" is a guess.
- `INVENTED` — present in the draft, absent from the shipped text, on a
  rejection where the human ALSO put tokens back. Something in the draft was
  substituted, so this is the hallucination signal.
- `CUT` — present in the draft, absent from the shipped text, on a rejection
  where the human put nothing back. Material was removed and nothing was
  substituted for it, usually a length edit. It says nothing about whether the
  draft was true, so do not read a `CUT` list as invention. Five of the seven
  pairs in the window to 2026-08-27 were this, every one of them a
  `commit-message` body trimmed to the profile's word cap.
- `SHAPE` — a list-vs-prose mismatch between the draft and what shipped.

Where the delegation was a recipe call made after #516, the rendered input the
model saw sits beside the draft as `<stem>.input.txt`, the bundle names it, and
the signals are scored against what the caller actually supplied rather than
against the draft alone:

- `DROPPED` narrows to anchors the input supplied: present in the input and
  the shipped text, absent from the draft. That is the model losing a fact it
  was given, which is what a recipe guard can be aimed at.
- `ADDED` — anchors in the shipped text that neither the input nor the draft
  had. The human brought them from outside the delegation, so they say
  nothing about the recipe; without the input they would have counted as
  `DROPPED`.
- `UNUSED` — salient tokens present in the input and absent from the shipped
  text: the anchors the caller handed over that ended up nowhere, which for
  the reply recipes is the "handed the input back" family measured directly.
- `ECHOED` — input sentences the draft reproduced as written, with the count.
  It is `no_context_echo`'s comparison (sentence unit, `echo_normalise`
  rules, 40-character floor) run after the fact, so a rejection that says
  "restated the facts" carries the sentences it means.

The recipe's own pre-substitution template is read from `prompts/`
(`DELEGATE_PROMPTS_DIR` overrides) and its lines are subtracted from the input,
as exact whole lines (`grep -Fxv`, with none of the normalisation
`no_example_echo` applies), before either signal is
computed, so `commit-message`'s example `#73` and `delegate.sh` are never
reported as supplied anchors. A line that carried a placeholder differs from
its template line and survives, which is the caller's value on it. Rows from
before #516 have no input and print as they always did.

The **capture coverage** line says how much of that you actually have. Drafts
and inputs are captured automatically. The shipped text arrives either because
a caller passed `--final` to `delegate-feedback.sh`, or because the boundary hook saw
the post: when a `gh`/`glab` post is credited to a delegation, that post is
that delegation's shipped form, so the hook stores it under the draft's own
stem and the verdict adopts it. A final that arrived that way is marked
`captured from the post` in the bundle. Since #587 it is stored by the
`PostToolUse` confirm hook once the post has succeeded, so it is what shipped
rather than what was about to; `docs/boundary-hook.md` has the capture rules.
The line counts `with input=` between the draft and final counts, so the
rejections with no stored input are visible. If coverage is low, raising it is
a more valuable fix than any recipe edit, because everything downstream
depends on it.

## Quarantined finals

`bash scripts/self-improve.sh --quarantine` lists the finals that are not
their draft's shipped text in `suspect-finals.tsv` beside the metrics file
(`--peek` prints the list without writing it): an empty final, one
byte-identical to an earlier stem's, or one sharing under a fifth of its
words with its own draft and more with the draft of the delegation before or
after it in the same recipe, project and session. The bundle and
`replay-recipe.sh` skip the listed pairs, and nothing is deleted (#587); on
2026-09-30 it listed 125 of 1299 finals.

## Choose one fix

One per run. A run that changes four recipes cannot tell you which change
moved the number.

Rank candidates by evidence, not by how annoying the defect looks:

1. A defect a deterministic check already flags, clustered on one recipe.
2. A defect named in two or more rejection reasons for the same recipe.
3. A single rejection that carries a draft/final pair showing a mechanical
   defect — a dropped anchor, an invented value, a list where prose shipped,
   a supplied sentence handed back.

A single rejection with only a prose reason and no pair is **not** enough to
edit a recipe on. Note it and wait for the second one.

Then pick the shape of the fix, in this order of preference:

- **A deterministic check**, when the defect is mechanically detectable from
  the output alone. Prompt text asks the model to comply; a check knows whether
  it did. `no_example_echo`, `no_padding_tail` and `subject_max` all started as
  prompt instructions that did not hold.
- **A named guard in the recipe**, when the defect is about content the model
  can only get from the input. Give it a shouty name (`ANCHOR-PRESERVATION`,
  `NO-FACT-DROP`) and state the failure it prevents, because an unnamed rule
  buried in a list of ten gets ignored first.
- **A new recipe**, when the reasons say the recipe is being asked for a shape
  it explicitly excludes. Widening a closed shape usually costs the shape
  without buying the new one.
- **Nothing yet**, when the evidence is thin. This is a real option and the
  most common correct answer on a quiet day.

Two hard stops on thrash. Do not re-edit a recipe you edited in the previous
24 hours unless new evidence contradicts that edit — give the change time to
be measured. And if the same defect survives two prompt-text fixes, stop
rewording: the third attempt is a check, a new recipe, or a report saying the
prose tier cannot do this.

## Gate the fix with a replay

A fix chosen on the evidence above is a hypothesis until it has been
measured, and the online read is too slow to be the measurement: at eight to
ten calls a day on a reply recipe, telling a fifteen-point lift from noise
takes weeks per edit. The replay is the measurement. Every recipe call since
2026-09-19 stores its structured inputs (stdin, each `--var`, the prompt) as
`<stem>.inputs.json` beside the draft, and every row carries `template_sha`,
so a stored case can be rendered again under another template.
`replay-recipe.sh` does that for the template that is live and the one you
edited, sends both through `delegate.sh` (so the checks and the retry are
production's, on the tier the case was made on), and scores each output the
way the bundle scores a pair: the wrapper's failed checks, the supplied
anchors the shipped text carried and the output dropped, the supplied
anchors the output carries that the shipped text does not (`over`: the
facts handed back in the model's own sentences, the supplied subset of
what the bundle lists as `CUT` or `INVENTED`, which nothing else
measures), the anchors the output carries that neither the inputs nor the
shipped text do, the piped sentences the output hands back beyond those
the shipped text itself carries, a list-versus-prose mismatch, and a
length flag for an output under a quarter or over four times the shipped
text's word count. A kept delegation is a case too, with its draft as the
reference, and the scoring is symmetric on it: an edit that disturbs an
output the agent shipped unedited, by dropping or by adding, loses that
case. `over` is there because the first pass to use the gate (2026-09-20)
found six rejected `maintainer-review-reply` drafts scoring zero on the
five measures that then existed: they carried 40-100% of the facts'
anchors against shipped replies carrying a median 6%, echoed no sentence
verbatim and matched the shape, and the maintainer had rejected all six
for describing the contributor's own change back to them. Without it the
gate could not see the reply recipes' dominant defect and charged its cure
as `dropped`. The length flag came with it: `over` is unbounded and
`dropped` is bounded by the reference's own anchors, so against
anchor-poor replies an output that says nothing sits at zero anchor
distance and wins every case, and a rise in length flags holds the
verdict at INCONCLUSIVE exactly as a rise in failed checks does.

The champion is the recipe as committed on `main`, read out of git into a
temp dir, not the file in your checkout: you edit on a branch in this same
checkout, so the working file is the candidate. Pass `--champion DIR` to
compare against something else, or set `DELEGATE_REPLAY_BASE` to read the
champion from another ref.

What a case is, and how the arms run (ADR 0031 as amended 2026-09-19):

- The stored inputs are `<stem>.inputs.json`: the piped stdin, each `--var` as
  passed (a key passed twice keeps its first value, the one the substitution
  used), the resolved tier and the positional prompt, named on the row as
  `inputs_file`. They share the draft's retention, byte cap and
  `DELEGATE_NO_DRAFT_CAPTURE=1` opt-out, except that over the cap the JSON is
  not written at all rather than cut, because a cut JSON is unreadable. The
  rendered `input.txt` cannot be un-rendered, which is why this exists: the
  2026-09-16 spike could not replay its 18 `maintainer-reply` cases under the
  post-#517 template because their `lead` values were never stored.
- `template_sha` is a 12-character sha256 of the recipe's frontmatter
  (without its `input_quality:` block, which judges the caller's inputs and
  not the template) and prompt block, computed by `recipe_template_sha` in
  `scripts/lib/recipe.sh` and stamped on every recipe row whether or not
  capture is on, so a dated calibration note does not start a new bucket.
  Where `shasum` is not installed the function returns empty and the row
  carries no `template_sha`. `tests/test-recipe-lib.sh` pins it for every
  recipe (#559).
- A case is a successful recipe row with a valid `inputs_file` and a verdict
  pinned by `ref_id`; a verdict pinned only by `ts` is never a case, kept or
  not, since two delegations can share a second. The reference is the stored
  final, or the draft itself when the verdict is kept. `--seed FILE` adds cases in the spike's JSON schema.
  Ritual verdicts and quarantined finals are skipped.
- Each case runs through `delegate.sh` on its own tier with metrics, canary
  and nudge off. The model is resolved once from the recipe's tier
  (`DELEGATE_REPLAY_MODEL` overrides that expected model; it does not
  select one, and a case the wrapper ran on a different model fails). A candidate whose frontmatter and prompt
  block equal the champion's is reported without a run.
- Scoring uses the bundle's own `salient` and `sentences` helpers
  (`scripts/lib/pair-score.sh`, with the verdict join in `scripts/lib/pair.jq`),
  and the shipped text is read through `body_only`, so trailer lines count
  toward no column.
- Outputs are cached under `<data dir>/replay/<id>.<sha>.<model>.out.txt`
  (umask 077, pruned on `DELEGATE_DRAFT_RETENTION_DAYS`), written beside a
  checks sidecar so an interrupted run leaves nothing that reads as a result.
  A case whose row hash and model equal the champion's is scored from its
  stored draft without a call unless that draft was cut at the byte cap.

```bash
bash scripts/replay-recipe.sh --recipe maintainer-reply --candidate /path/to/worktree/prompts
```

Read the verdict line. `ACCEPT` is more wins than losses at p < 0.05 on a
one-sided sign test with no rise in failed checks: six wins to none, eight to
one, ten to two. `REJECT` is the mirror. `INCONCLUSIVE` is everything else,
including any run where a case failed to run. It means the edit did
not separate the arms on the cases there are, and the right response is
usually to leave the recipe alone: the edit is not wrong, it is unmeasured,
and the commonest cause is that it targets a defect the cases do not carry.
The "newest third" line is the overfitting check: a candidate that wins only
on the older cases the reasons were read from has learned those cases, not
the defect.

Greedy decoding is deterministic on this backend, so one pass per arm is the
whole measurement. Outputs are cached by case and template hash, so a re-run
against the same edit sends nothing, and a case whose stored template hash
matches the champion's is scored from its stored draft without a call.
Expect three to eight seconds per case per arm otherwise; `--limit` caps the
case count (default 40, newest first).

Quote the replay's summary and verdict lines in the PR body, with the n. A
recipe edit with no replay line, or an inconclusive one, is a proposal, not a
fix, and the PR should say so.

## Apply it

Work on a branch, never on `main`. The installed skill on both Claude profiles
is the separate live clone at `~/.local/share/delegate-local-live`, not this
checkout, so a merged fix reaches other sessions only after
`git -C ~/.local/share/delegate-local-live pull --ff-only`.

Every recipe edit gets a dated entry in that recipe's calibration history,
`docs/calibration/<recipe>.md`, saying what was observed, how many times, and
what changed; the recipe's own `## Calibration notes` is a one-line pointer to
that file and stays one (#569). That history is how the next session knows a
defect has already been attacked and with what, so a `REJECT` belongs in it
too: revert the recipe, record what was tried with the replay's summary and
verdict lines, and open that entry alone as the PR. Otherwise the next pass,
reading the same reasons, tries the same edit again.

Run the suites the change touches (`tests/test-delegate.sh`,
`tests/test-prompts-library.sh`, `tests/test-self-improve.sh`), open a PR, and
stop. **Never merge.** Opening a PR is a request for review. Report the PR
number and the one-line reason it exists.

## Revert when the online read disagrees

The replay is the pre-merge gate; the online read is the post-merge one.
Once an edit has landed, every row the recipe writes carries the new
template hash, and the bundle's per-template section prints the recipe's
outcomes under the new hash beside the previous one, with the n on each.
Read it once the new template has thirty tracked rows, not before: below
that a rate is a rumour, and the thrash rule already forbids a second edit
inside 24 hours.

If the new template's usable rate sits below the previous one's by more than
the margin that n can resolve (at thirty rows a side, roughly twenty-five
points; the replay's sign test was the fine instrument, this is the coarse
one), open a revert PR, and write the failure into the recipe's
`docs/calibration/<recipe>.md` as a dated entry naming both hashes, the n on each side and the rates,
so the next session does not try the same edit again. A revert is a normal
outcome of the loop, not an incident. When the online read agrees with the
replay, say so in the next bundle and move on.

## Do not fake progress

Quote the `n` beside every rate. At this corpus size one delegation moves a
percentage by several points, and a rate over `n=3` is a rumour. The rate is
the producing agent grading its own output, which skews toward "I used it, so
it was good"; the reason and the draft/final pair are what keep it honest, so
a hit rate with thin capture coverage is a weaker claim than the number
suggests.

Never claim a fix worked without a measurement taken after it landed. The
honest form is "this landed on <date>, re-measure after ~10 more calls on that
recipe". A previous era of this corpus was polluted by exactly this kind of
optimism, which is why it was reset (ADR 0028).

If the loop finds nothing to fix on a run, that is a successful run.

## Run it on a schedule

Until 2026-09-30 the loop was two crons inside a Claude session, and a cron
dies with its session: the watermark sat at 2026-09-22 for over a week with
nobody noticing (#558). The pass now runs under launchd, which outlives any
session and starts a run missed while the Mac slept as soon as it wakes.

`scripts/self-improve-daily.sh` is the runner. It runs the gate with `--peek`;
exit 10 is a quiet, successful run and no model is called. Otherwise it
starts one headless `claude -p` session in a detached worktree of the live
clone at `origin/main`, with the bundle on stdin and this document as its
instructions, and advances the watermark to the bundle's `Newest row` only
when that session exits 0. A failed session leaves the window for the next
day, and the session's own commit and PR delegations land after the
watermark, so the next bundle judges them. A lock under the data dir (a
symlink whose target is the owner's pid) keeps two runs from overlapping, and
a lock whose owner has died is taken over.
Everything the runner and the session print goes to
`<data dir>/self-improve-daily.log`.

The session runs with `--permission-mode dontAsk`, so any tool outside its
allowlist is refused rather than prompted: read files, edit only under
`prompts/`, run the gate with `--peek`, `replay-recipe.sh`,
`metrics-summary.sh`, `delegate.sh`, `delegate-feedback.sh`, the three suites
named under "Apply it" and `shellcheck`, read-only git,
branch as `loop/<date>-<slug>`, add, commit, push that branch, and
`gh pr create`/`list`/`view` and `gh issue view`. `gh pr merge`,
`gh release`, `npm publish` and any push naming `main` are denied outright.
The list is a boundary only because nothing it runs can be rewritten from
inside it: with an unscoped `Write` and `bash tests/*`, the session could
write a script that merges and run it. For the same reason the session
loads project settings only (`--setting-sources project`), so the profile's
own allow rules cannot widen the list, and the profile's hooks do not run.

Install it from the live clone, after the change that added the runner has
been pulled into it:

```bash
sed "s|__HOME__|$HOME|g" ~/.local/share/delegate-local-live/docs/launchd/com.delegate-local.self-improve.plist > ~/Library/LaunchAgents/com.delegate-local.self-improve.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.delegate-local.self-improve.plist
launchctl kickstart gui/$(id -u)/com.delegate-local.self-improve   # optional: one run now
```

The template runs at 10:07 local time. Its `PATH` covers `~/.local/bin`
(where the `claude` installer puts the binary) and Homebrew; edit it if
`claude`, `gh` or `jq` live elsewhere, because launchd reads no shell
profile and the runner exits 2 with `claude not found on PATH` rather than
guess.

Check it with the job's state and last exit code, the log, and the age of
the watermark, which should never be more than about 26 hours behind on a
day with delegations:

```bash
launchctl print gui/$(id -u)/com.delegate-local.self-improve | grep -E 'state|last exit code'
tail -n 20 ~/.local/share/delegate-local/self-improve-daily.log
cat ~/.local/share/delegate-local/self-improve.state
```

Stop it with:

```bash
launchctl bootout gui/$(id -u)/com.delegate-local.self-improve
rm ~/Library/LaunchAgents/com.delegate-local.self-improve.plist
```

## Reference: recording a verdict

`scripts/delegate-feedback.sh` records what happened to a draft: `hit` (kept
as-is), `scaffold "<reason>"` (edited and shipped) or `miss "<reason>"`
(rewritten or discarded). Cutover 2026-10-01 (#624, ADR 0030): On 2026-10-01 (#624) the verdict definitions were unified: `scaffold` means the draft was edited and shipped, and a rewritten or discarded draft is a `miss` however useful it was. Before that date a scaffold verdict on any recipe may mean discarded-but-useful, because the `delegate-feedback.sh` usage text defined it that way globally, and nothing is migrated. Measured read-only since the 2026-08-19 reset, about 12 of 1160 scaffold reasons mention a discard (a keyword estimate, so the upper bound) and 0 came from `code-draft` or `fix-with-test`. The agent that used or rewrote the draft records it,
and that is the only verdict tier (ADR 0030): every feedback row carries
`verdict_source:"agent"`, `--source agent` is the default, `--source human` is
refused, and a miss or scaffold needs a reason.

Pin the verdict with `--id`, the value the `delegate-meta:` line printed as
`id="..."`: the row's `otel_span_id`, the one key two delegations cannot
share. `--ts` is kept for older callers and refuses when two rows share that
second. Without a pin the verdict attaches to the one delegate row inside the
last 5 minutes (`DELEGATE_FEEDBACK_STALE_SECONDS`, default 300), and the
script refuses when there is none or more than one (#474). The verdict
appends a `source:"feedback"` row to the same metrics JSONL, keyed by `ref_ts`
and `ref_id` to the delegate event and carrying that row's `project`.

`--final <path|->` stores the text that actually shipped beside the draft
(ADR 0029). `delegate.sh` already stores the generated draft as
`<data dir>/drafts/<stem>.draft.txt` and names it on the row; without the
final a rejection carries only a prose description of a draft nobody can look
at again, which is the ceiling the loop hit on 2026-08-26. Since #516 a recipe
call also stores the rendered input the model saw (the template with every
placeholder substituted, the piped context inside it, and the retry notice
when a retry produced the draft) as `<stem>.input.txt`, named on the row as
`input_file`. A bare call stores no input, because there is no recipe for the
pair to calibrate. ADR 0029 had declined this as too large and too sensitive;
the 2026-09-16 spike then spent twenty minutes and 220k tokens mining 42 of
135 inputs back out of session transcripts and could not recover the other
93. Draft, input and inputs share `DELEGATE_DRAFT_MAX_BYTES`,
`DELEGATE_DRAFT_RETENTION_DAYS` and the `DELEGATE_NO_DRAFT_CAPTURE=1` opt-out;
the input inherits the sensitivity of everything piped in, so a host with
sensitive traffic tunes the retention or opts out. When no `--final` is
passed, a final the boundary hook captured from the post is adopted; the
adoption, numbering and ritual rules are in `docs/boundary-hook.md`.

`--id`, `--ts` and `--final` may appear anywhere on the line, including after
the reason words; parsing used to stop at the verdict, so three rejections in
the corpus recorded a reason ending `--final /path` and stored nothing. Put
`--` before the verdict when the reason itself has to name a flag.

After a miss, the script scans earlier miss rows in a rolling 30-day window
for token-overlap matches and, on the third or later similar reason, prints a
draft `gh issue create` command for a `prompt-pattern` issue; it never opens
the issue itself (README "Calibration feedback loop" has the diagram and the
defaults of `DELEGATE_FEEDBACK_NUDGE_AT`, `DELEGATE_FEEDBACK_NUDGE_WINDOW_DAYS`
and `DELEGATE_FEEDBACK_SIMILAR_THRESHOLD`; `DELEGATE_FEEDBACK_NO_NUDGE=1`
silences it). A miss or scaffold whose reason is byte-identical to another
rejection's on a different delegation inside the last 10 minutes
(`DELEGATE_FEEDBACK_REPEAT_WINDOW_SECONDS`, default 600, `0` switches it off)
is warned about on stderr with the count and still written, because a sweep
pasting one verdict across 16 rows taught the loop one fact on 2026-09-13 and
a refused verdict would teach it none (#487).

## Reference: the metrics rollup

`scripts/metrics-summary.sh` reads the metrics JSONL and prints volume,
latency and tokens-avoided rollups, the boundary trigger rate
(`docs/boundary-hook.md` "Reading the trigger rate"), and per-project and
per-recipe hit-rate sections (the per-project one only with two or more
distinct projects, the per-recipe one only with at least one recipe row),
listing projectless rows on one `(no project)` line after the per-project
ones. The verdict join, one latest verdict per delegation whether pinned by
id or by ts, and its outcome are `scripts/lib/pair.jq`, loaded with `jq -L` on
an absolute path by `metrics-summary.sh`, `self-improve.sh` and
`replay-recipe.sh` alike, so the per-recipe counts `metrics-summary.sh --days
N` and `self-improve.sh --days N` print agree (`tests/test-verdict-model.sh`,
#564). `--since YYYY-MM-DD` and `--days N` window every section to rows at or
after the cutoff, resolved in jq via `now`/`fromdateiso8601` so there is no
BSD-versus-GNU `date` split, and the matching rows are filtered once into a
temp file every later pass reads. The script is read-only.

The feedback block carries a captured-pair line that splits the rejections
that stored their shipped half into `inferred` (the verdict adopted the final
the boundary hook wrote, `final_source:"posted"`) and `by-hand` (the caller
passed `--final`), beside `hook-captured`, the rejections whose draft has a
hook-written `<stem>.final.txt` in the drafts dir (#552). `inferred` measures
adoption, not capture: callers now pass `--final`, so it sits near 0 while
the hook keeps writing finals, and `hook-captured=0` is what a capture that
never fires looks like. An absent field on every row looks the same as having
no reply traffic at all, which is how #457 stayed broken for eleven days.
