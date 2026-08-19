# Move user data out of the skill directory: plan

**Spec:** `docs/superpowers/specs/2026-08-19-user-data-outside-the-skill-dir-design.md`

**Goal:** the four per-user files default to `$HOME/.local/share/delegate-local`
instead of inside the installer-owned skill directory, with no new shared lib,
no existence-based resolution, and an explicit migration.

**Global constraints:** bash 3.2. Resolution stays a pure parameter expansion so
it remains a function of the environment alone. Do not consult `XDG_DATA_HOME`.
Do not introduce a `scripts/lib/paths.sh`; the spec records why both were
rejected. Do not reformat unrelated lines.

---

## Task 1: change the twelve defaults

**Files:** modify `scripts/delegate.sh`, `delegate-feedback.sh`,
`delegate-boundary-hook.sh`, `embed.sh`, `metrics-summary.sh`,
`observability-doctor.sh`, `sync-metrics-to-loki.sh`, `backfill-otel.sh`,
`pick-model.sh`, `onboard.sh`, `load-flavor.sh`; modify `tests/test-paths.sh`
(new); register the suite in `.github/workflows/ci.yml`.

- [x] **Step 1: write the failing test.** `tests/test-paths.sh` runs each script
  with `--help`-style or dry paths under `env -i` with a temp `HOME`, and
  asserts the resolved default for all four files, plus: `DELEGATE_LOCAL_DATA_DIR`
  redirects all four, each file-specific override still wins, `XDG_DATA_HOME`
  has no effect, and an unset `HOME` under `set -u` still fails loudly.

- [x] **Step 2: run it and watch it fail.**

- [x] **Step 3: substitute.** Every
  `${DELEGATE_METRICS_FILE:-$HOME/.claude/skills/delegate-local/metrics.jsonl}`
  becomes
  `${DELEGATE_METRICS_FILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/metrics.jsonl}`,
  and the same shape for `config.sh` (keeping the `DELEGATE_TO_OLLAMA_CONFIG`
  alias) and `profile.sh`. Nothing else changes; no function, no source, no
  existence test.

- [x] **Step 4: run the tests to green, then every existing suite.** Note that
  the existing suites cannot catch a regression here, because each one either
  passes an explicit path or sandboxes `HOME`; `tests/test-paths.sh` is the only
  thing that can.

- [x] **Step 5: register the suite** in `.github/workflows/ci.yml`.

- [x] **Step 6: commit.** `fix: default user data outside the skill directory`

## Task 2: the migration and the warning

**Files:** modify `scripts/onboard.sh`, `metrics-summary.sh`,
`delegate-feedback.sh`, `observability-doctor.sh`; modify
`tests/test-onboard.sh`, `tests/test-metrics-summary.sh`; modify `.gitignore`.

- [x] **Step 1: write the failing tests.** For `--migrate-data`: copies each
  legacy file that exists, leaves it in place, carries `metrics.loki-sync`,
  refuses to overwrite an existing target with a non-zero exit and a clear
  message, is idempotent, does nothing when no legacy file exists, and FAILS
  LOUDLY when the legacy directory exists but holds no `metrics.jsonl`. For the
  warning: it fires only when the new file is absent and the legacy one exists,
  names the real row count, and does NOT fire when both or neither exist.

- [x] **Step 2: run them and watch them fail.**

- [x] **Step 3: implement `--migrate-data`.** Copy, never move. Print each
  action.

- [x] **Step 4: implement the warning** in the three read paths that already
  print a "no metrics file" error. One extra line, naming the legacy path, its
  row count, and the migrate command.

- [x] **Step 5: add `metrics.loki-sync` to `.gitignore`.** The existing
  `metrics.jsonl.*` pattern does not match it, which is why it shows as
  untracked today.

- [x] **Step 6: run the suites.**

- [x] **Step 7: commit.** `feat: add onboard.sh --migrate-data`

## Task 3: the documentation sweep

**Files:** `prompts/miss-theme-cluster.md`, `SKILL.md`, `README.md`,
`CLAUDE.md`, `CONTRIBUTING.md`, `SECURITY.md`, `docs/install-claude-code.md`,
`docs/install-codex.md`, `docs/install-opencode.md`, `docs/otel-schema.md`,
`docs/observability/grafana-local.md`, `.github/ISSUE_TEMPLATE/bug_report.md`,
`.github/ISSUE_TEMPLATE/prompt-pattern.md`.

- [x] **Step 1: fix the two that are live behaviour first.**
  `prompts/miss-theme-cluster.md` hardcodes the legacy path in a shipped recipe
  the agent copies and runs, and `SKILL.md` is production prompt content. Both
  would instruct the tool to read a path that no longer holds the data.

- [x] **Step 2: sweep the rest.** Only paths to the four DATA files change.
  Script paths (`~/.claude/skills/delegate-local/scripts/…`) stay as they are.

- [x] **Step 3: document the sequence in `README.md`:** where data lives, the
  resolution order, that an existing install keeps working, and that the order
  is migrate, verify, prune worktrees, repoint last.

- [x] **Step 4: run `tests/test-prompts-library.sh` and
  `tests/test-validate-content.sh`,** which gate the shipped prompt surface.

- [x] **Step 5: commit.** `docs: point user-data paths at the new default`

## Task 4: close the loop on #360

- [x] Comment on #360 with what shipped and what is still the user's call.

## Explicitly not in this plan

A performance measurement of the boundary hook. The earlier plan had a whole
step for it. Measured, sourcing costs 62 microseconds against a hook that costs
about 35ms per Bash call, dominated by two `jq` spawns before the pre-filter, so
the difference is 0.18% and roughly 500 times smaller than run-to-run variance.
There is also nothing left to source. Any number reported would be noise.

---

## Outcome

Shipped as v0.27.9 (#404). The maintainer's data was migrated before the PR:
4902 rows readable at the new path with the full 2026-05-03 range intact,
originals untouched, fresh timestamped backup taken first. Post-merge the new
file is authoritative and growing while the legacy copy stays frozen at the
migration snapshot, which is the intended end state.

### What review changed

The plan that entered review is not the one that shipped. Three designs were
rejected on measurement:

A shared `scripts/lib/paths.sh` looked like the obvious DRY move. Three of the
eleven callers have no `script_dir` at all, `delegate-feedback.sh` derives one
109 lines after its metrics line, `observability-doctor.sh` calls it `REPO`, and
`delegate-boundary-hook.sh` can legitimately hold the empty string, at which
point it fails to source, loses the opportunity row the whole boundary feature
exists to produce, and still exits 0. The decisive finding was subtler: moving
the default into a function turns a loud failure silent, because an unset `HOME`
under `set -u` dies inside the command substitution, the substitution yields
empty, and the caller gets `RC=0` with a path of `/metrics.jsonl`. Today that is
`exit 127`.

An existence-based legacy fallback also looked obviously right, and it never
disarms: losing the new file at any later date silently reverts every consumer
to the migration-day snapshot, measured as 9 rows becoming 3 with exit 0 and no
warning. Compatibility became a message instead.

Consulting `XDG_DATA_HOME` was rejected too, because it is commonly set in a
shell rc file and absent in GUI-launched processes. Measured with the real
`delegate-feedback.sh`, a verdict recorded in one environment silently attaches
to the wrong parent delegation in the other.

### What the second reviewer found that the first did not

That the two options were order-sensitive and that the dangerous order fails
silently. Repointing the symlink before migrating orphans the history in place
while the migration reports success having copied nothing. `--migrate-data` now
refuses that case outright, and the README documents the sequence.

Also that `metrics.loki-sync` is a fourth per-user file, that it was not covered
by `.gitignore` at all, and that a loaded launchd job runs the sync script by
absolute path into the primary checkout regardless of where the symlink points.

### Caught in review of the implementation

Copilot found that the standalone redirect examples would fail on a fresh
machine. The old default lived inside the installed skill directory, which
always existed; the data directory does not. `onboard.sh` already created it,
but nothing exercised a missing parent, which test M0 now does.

CI also caught an environment-dependent assertion: `onboard.sh` only prints the
config candidate when the environment probe finds installed models, so the test
passed locally and failed on a runner with none.

### Still open on #360

The symlink repoint. It needs no code and is two `ln -sfn` commands to reverse.
