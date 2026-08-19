# Move user data out of the skill directory: design

**Date:** 2026-08-19
**Issue:** #360 (the product half; the symlink repoint stays open there)

## The bug

Four per-user files default to paths inside the directory the skill installer
owns: `metrics.jsonl` (8 scripts), `config.sh` (2), `profile.sh` (2), and
`metrics.loki-sync`, which is derived as `${metrics_file%.jsonl}.loki-sync` and
follows whatever metrics resolves to.

For anyone who installed with `npx skills add`, `~/.claude/skills/delegate-local`
resolves into the shared store at `~/.agents/skills/delegate-local`, which
`skills update` replaces. Calibration history, routing overrides and flavour
values all sit where a package manager can delete them.

On this machine the symlink points at the git checkout instead, which is the
only reason 4898 rows and 1.24 MB have survived since 2026-05-03. That is an
accident of the dev setup, not a design.

## Decision

```
${DELEGATE_METRICS_FILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/metrics.jsonl}
```

A plain parameter expansion, substituted at all twelve existing definition
sites. No new file, no sourcing dependency, no existence checks. The
file-specific overrides keep their names and precedence exactly, including the
`DELEGATE_TO_OLLAMA_CONFIG` legacy alias.

Two earlier designs were reviewed and rejected. Both rejections are recorded
because each looked obviously right beforehand.

### Rejected: a shared `scripts/lib/paths.sh`

The DRY argument does not survive contact with the callers.

Three of the eleven target scripts (`metrics-summary.sh`,
`sync-metrics-to-loki.sh`, `pick-model.sh`) have no `script_dir` at all,
`delegate-feedback.sh` derives one 109 lines *after* its metrics line,
`observability-doctor.sh` calls it `REPO`, and `delegate-boundary-hook.sh` can
legitimately hold the empty string. That last case was measured: with
`script_dir=""` the hook fails to source, loses the opportunity row that the
whole boundary feature exists to produce, and emits three stderr lines per
boundary command, while still exiting 0.

Worse, moving the default into a function changes a loud failure into a silent
one. Today an unset `HOME` under `set -u` kills the script. Inside a command
substitution the subshell dies, the substitution yields empty, and the function
returns 0 with a path of `/metrics.jsonl`. Measured: `outer_rc=127` today
against `RC=0 PATH=[/metrics.jsonl]` through a lib.

`pick-model.sh` is also the only caller running `set -euo pipefail`, so it would
be the one script a stray trailing test in the lib could kill, and it sits on
`delegate.sh`'s critical path.

### Rejected: an existence-based legacy fallback

The first design resolved to the legacy path whenever the new file was absent
and the legacy one present. It has three defects.

It never disarms. Resolution is a pure function of filesystem state with no
staleness check, so losing the new file at any later date silently reverts every
consumer to the migration-day snapshot: measured as 9 rows becoming 3, exit 0,
no warning.

It splits the data directory per file. On this machine `metrics.jsonl` and
`profile.sh` would resolve to the legacy root while `config.sh`, which does not
exist here, would resolve to the new one. A "data directory" that is really a
per-file lottery is hard to reason about, and it made the spec's own claim that
"nothing changes for an existing install" false.

It cannot be expressed as a parameter expansion, which is the only reason the
lib was needed at all.

### Rejected: consulting `XDG_DATA_HOME`

`XDG_DATA_HOME` is commonly set in a shell rc file and absent in GUI-launched
processes, which is exactly the split between an interactive terminal and the
agent harness that runs these hooks. Resolution would stop being a pure function
of `$HOME`.

That was measured with the real `delegate-feedback.sh`: a verdict recorded in
one environment for a row written in the other fails with "does not match any
delegate row", and the implicit no-`--ts` path is worse, silently attaching the
verdict to a different parent so `metrics-summary.sh` computes two disjoint hit
rates.

`$HOME/.local/share/delegate-local` is the conventional location and is what the
XDG default resolves to anyway. `DELEGATE_LOCAL_DATA_DIR` remains the escape
hatch for anyone who genuinely wants it elsewhere.

## Compatibility, as a message rather than a path switch

The read paths that already print a "no metrics file" error gain one extra line
when the new path is absent and the legacy one exists:

```
no metrics file at <new>
  <legacy> exists with N rows — run: bash scripts/onboard.sh --migrate-data
```

This gives the same protection the fallback was reaching for, but it is a
message the user acts on rather than a silent path switch, and it cannot
resurrect a stale snapshot six months later.

`onboard.sh --migrate-data` copies rather than moves, carries
`metrics.loki-sync` alongside the three data files, refuses to overwrite an
existing target, is idempotent, and fails loudly when the legacy directory
exists but holds no `metrics.jsonl`, because on a machine that ever had one that
state means the symlink has already moved.

## Ordering, which the change must document

| order | outcome |
|---|---|
| migrate, then repoint | safe |
| repoint, then migrate | history orphaned in place; the migration finds nothing and reports success |
| repoint, never migrate | same, history restarts at zero |
| migrate, never repoint | fine for data, but any pre-change script still on the old default keeps appending to the legacy file |

The last row is not hypothetical: seven git worktrees under `.claude/worktrees/`
hold pre-change copies of `scripts/delegate.sh`, and a loaded launchd job
(`com.delegate-local.loki-sync.plist`, every 600s) runs the sync script by
absolute path into the primary checkout. Documented sequence: migrate, verify
the totals match, prune the stale worktrees, repoint last.

## Documentation surface

Larger than it looks, and some of it is live behaviour rather than prose.
`prompts/miss-theme-cluster.md` hardcodes the legacy path inside a shipped
recipe that the agent copies and runs, and `SKILL.md` is production prompt
content telling Claude where the file is. Both must change or the tool will
instruct itself to read a path that no longer holds the data. Beyond those:
`README.md` (six places), `CLAUDE.md`, `CONTRIBUTING.md`, `SECURITY.md`,
`docs/install-claude-code.md`, `install-codex.md`, `install-opencode.md`,
`otel-schema.md`, `observability/grafana-local.md`, and two issue templates that
ask reporters for a path that would be wrong.

## What does not change

Script paths. The nudge text and every install doc keep pointing at
`~/.claude/skills/delegate-local/scripts/…`, because the scripts are still
installer-owned. Only user data moves.

`.gitignore` keeps ignoring `metrics.jsonl`, `/config.sh` and `/profile.sh` at
the repo root, and gains `metrics.loki-sync`, which its `metrics.jsonl.*`
pattern does not currently match.

## Verification

- with nothing set, every script resolves to `$HOME/.local/share/delegate-local/…`
- `DELEGATE_LOCAL_DATA_DIR` set redirects all four files together
- each file-specific override still wins over it
- `XDG_DATA_HOME` set has no effect
- unset `HOME` under `set -u` still fails loudly, as it does today
- the warning fires only when the new file is absent and the legacy one exists,
  and names the real row count
- `--migrate-data` copies, leaves legacy intact, carries `metrics.loki-sync`,
  refuses to clobber, is idempotent, and fails loudly on a legacy directory with
  no `metrics.jsonl`
