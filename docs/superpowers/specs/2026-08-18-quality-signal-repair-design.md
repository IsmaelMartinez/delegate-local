# Quality-signal repair: design

**Date:** 2026-08-18
**Issues:** #387, #385, #386 (and #384, deferred)

## Why now

A metrics audit of `metrics.jsonl` (4833 rows) asked a simple question: how often
does the skill actually get used at its own boundaries, and is the output any
good? Both answers turned out to be distorted by defects in the instruments
rather than by the behaviour being measured.

Joining `source:"feedback"` rows to the delegation they reference, output whose
recipe checks all passed was kept 71.8% of the time (n=220); output with a failed
check was kept 29.5% (n=61). Two-proportion z = 6.04, p = 1.5e-9. That looks like
a strong lever, and #384 proposed acting on it. Decoding `checks_run` against the
recipes (only `commit-message` declares more than one check) shows 56 of the 61
failures carry the `no_padding_tail` signature ADR 0024 characterises as
model-dependent and measured-exhausted for prompt fixes.

Before acting on that signal, the signal has to be trustworthy. It is not.

## What is actually broken

### 1. `no_padding_tail` fires mid-line (#387)

The check is named for a tail. Its participial arm is not anchored, so any
`, <gerund>` anywhere in the last line matches, including a load-bearing clause
followed by further sentences. ADR 0017's auto-strip regex *is* anchored, so it
correctly declines to strip these, and the run ends with a FAILED verdict on
output that is fine.

This was reproduced live while drafting #386: a `github-issue-body` delegation
ended `..., leaving the github-actions block unchanged. The fix is verified
when...`, the check failed, and the output was used verbatim and recorded HIT.

The false positives are not merely noisy. They sit inside the 61-row population
whose 29.5% kept rate is the entire argument for #384, and they can only blunt
it, because a false positive by definition lands on output good enough to keep.

### 2. The boundary hook cannot see across a `cd` (#385)

`delegate-boundary-hook.sh` takes the cwd from the harness JSON payload
(`.cwd`, line 69), chdirs to it (line 212), and derives `project` git-aware from
there (lines 213-220, mirroring `delegate_project_name()` in
`scripts/lib/otel.sh`): `git rev-parse --git-common-dir` when inside a repo,
basename of the cwd only as the non-repo fallback. It then requires
`.project == $proj` when looking for a recent delegation. Agents routinely run
`cd <other-repo> && …`, so `delegate.sh`, which runs *after* the `cd`, derives a
different project and the lookup can never match.

On 2026-08-18 the hook logged 66 opportunities under `pr-agent` against 3
delegations there, while 35 delegations were recorded under `delegate-local`
with 0 opportunities. The boundary detection itself is sound: 18 of the 19
`pr-agent` `git-commit` opportunity rows line up to the second with local
`commit:` entries in delegate-local's reflog.

The cleanest single proof is the commit made during this very audit. A
`commit-message` delegation was recorded under `delegate-local` at
`22:03:00Z`; 27 seconds later, well inside the 10-minute window and with the
matching recipe, the hook logged the `git-commit` boundary as
`delegated:false` and printed the nudge.

Recomputing the hook's own rule from raw rows reproduces its recorded flag
exactly for July (17%) and August (12%). Dropping only the project predicate
gives 36% and 20%.

### 3. Dependabot points at an archived directory (#386)

`.github/dependabot.yml` still declares `pip` on `/mcp`; commit `22395b2`
(2026-06-19) archived that subproject and `git ls-files mcp/` now returns
nothing. Every weekly run since has failed with `dependency_file_not_found`.

## Decisions

**Anchor the participial arm only.** The replacement is
`,[[:space:]]+[a-z]{3,}ing([[:space:]][^.!?]{0,200})?[.!?]?[[:space:]]*$`. Every
other arm of the expression stays byte-identical. Detection narrows to the tail;
the auto-strip's own regex and, critically, its adoption gate do not move.

This does not reopen ADR 0024. That ADR rejected further anti-padding *prompt*
iteration and per-recipe model routing; it did not licence flagging text that is
not a padding tail. Recall on genuine trailing padding is preserved by
construction (the clause still matches wherever it ends the line) and is
verified against the recipes' own `Wrong:` examples.

**Resolve the boundary's repo from the command, and match on either
candidate.** Parse an optional `cd <path> &&` prefix off the inspected command.
When the path resolves to a git repository, use it for the recorded `project`
and for the nudge text; otherwise keep today's cwd-derived value. The path is
used only to locate a git root and is never expanded or executed.

The delegation lookup then matches if *either* candidate matches, rather than
replacing one with the other. Replacement would move a real case from working to
broken: `--project` exists (#342) so a caller can attribute a delegation to a
repo other than the one it is cd'd into, and those pairings match today. Either-
match cannot regress anything that currently works.

Three details that a naive implementation gets wrong, each verified:

- `git -C <path> rev-parse --git-common-dir` returns the *relative* string
  `.git` at a repo root, which then resolves against the hook's process cwd and
  yields the old wrong answer from code that looks correct. The derivation must
  run inside a subshell that has chdir'd to the target.
- the acceptance condition is "resolves to a git repository", not "the path
  exists". `cd /tmp && … git commit` must not record `project: "tmp"`, which
  would fragment the denominator across scratch keys.
- git-awareness is required, not optional: a repo subdirectory must still yield
  the repo, and a worktree under `.claude/worktrees/<name>` must yield the
  repository, not `<name>`. Basename-of-path gets both wrong, and the existing
  test tmpdir is not a git repo, so tests must create real ones or they pin
  nothing.

**Delete the pip block.** No replacement: there is no Python in the tree.

**Defer #384.** The retry/repair question is re-measured after the anchor fix
has produced a clean `checks_failed` population. Acting first would be tuning
against a signal known to contain false positives, and ADR 0024's zero-variance
finding means a blind re-roll at temperature 0 is a no-op regardless.

## Non-goals

Widening the auto-strip allowlist. ADR 0017 deliberately keeps it narrow so a
meaningful participial stays a warning rather than being silently deleted, and
nothing in this audit contradicts that.

Changing the `maintainer-reply` trigger rate (2% of 288 August boundaries). It
is the largest behavioural gap found, but it is a prompting-and-habit problem,
not a defect, and it is not fixable in this change set.

## How each change is verified

| Change | Verification |
|---|---|
| #387 anchor | Fixture suite: 8 genuine-padding examples still FAIL, 4 measured false positives now PASS, and the last line of 296 hand-written commit bodies produces 0 flags where the shipped expression produces 2. |
| #385 hook | A hook invocation whose command is `cd <repo-b> && git commit …`, run from repo-a with a matching recent delegation recorded under repo-b, records `delegated:true`. Run from repo-a with no such delegation, it still records `delegated:false`. |
| #386 dependabot | `git ls-files mcp/` is empty, and the config no longer names a directory that does not exist. |

## Correction, 2026-08-18: the character class must permit internal commas

The first candidate for the anchored arm used `[^,.!?]*`, which forbids a comma
inside the clause. That is wrong in both directions and was caught before
implementation:

- it misses a genuine padding tail that itself contains a comma, e.g.
  `…, ensuring the cache, the limiter and the queue stay in sync.`
- it breaks the existing assertions 33c and 33d in `tests/test-delegate.sh`,
  whose fixture `the list is built, ensuring order, then returned to the caller`
  is detected today and must stay detected

The shipped form is therefore `[^.!?]*`: the clause may contain commas but may
not cross a sentence boundary, which is precisely the distinction between a tail
and a mid-sentence participial. Re-verified over 16 fixtures with zero failures,
and 0 flags against 297 hand-written commit bodies where the current expression
raises 2.


## Adversarial review, 2026-08-18: three defects caught before merge

The first anchored candidate was reviewed against the running code rather than
on paper, and it was wrong in three ways. All three are now fixed and pinned by
tests; they are recorded here because each is an easy mistake to reintroduce.

**The word boundary was load-bearing.** The shipped arm ends
`ing([[:space:]]|[.!?,]|$)`, which forces `ing` to end a word. Dropping that
group turns `[a-z]{3,}ing` into a prefix match, so every `-ings` plural fires:
`settings`, `warnings`, `findings`, `strings`, `mappings`. Sixteen of sixteen
constructed cases flipped from clean to FAILED. A change whose entire purpose is
removing false positives had introduced a new family of them. Pinned by test 33h.

**The unbounded class was quadratic.** Permitting commas inside the clause lets
each comma position rescan the rest of the line. Under GNU grep in a UTF-8
locale, which is what CI and the Docker image run, a 72KB line measured 6336ms
against 3ms for the shipped expression; macOS grep and `LC_ALL=C` both hide it.
The `{0,200}` bound restores flat time (10ms at 72KB). "No nested quantifiers"
was not sufficient here: the blowup came from two sequential quantifiers over
overlapping classes.

**Anchoring detection silently widened the strip.** `padding_re` gates the
auto-strip twice: once to fire, and again on the post-strip re-check that decides
whether the result is clean enough to adopt. Relaxing the second gate made
`adds a cache, improving latency. also fixes the lock, ensuring parity.` newly
adoptable, mutating output ADR 0017 deliberately leaves alone with a warning. The
adoption gate is therefore pinned to the pre-anchor expression in
`padding_re_adopt`. Pinned by test 33i.

The verification set also had no discriminating power: the eight recipe `Wrong:`
examples and the 296-body corpus give identical verdicts under every candidate,
so a green suite proved nothing about any of the above. The fixtures added in
this change are chosen to separate the candidates, not merely to pass.

### Accepted limitation

A padding tail containing a non-terminal full stop is no longer detected:
`…, ensuring parity with Node.js consumers.`, a version number, a dotted
filename, a URL. Recovering it requires treating `.` as a sentence end only when
whitespace follows, whose natural formulation is an alternation inside a star,
the shape this repo bans for ReDoS. Tracked as #390 rather than bolted on.
