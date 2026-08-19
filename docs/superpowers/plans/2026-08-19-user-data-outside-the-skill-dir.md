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

- [ ] **Step 1: write the failing test.** `tests/test-paths.sh` runs each script
  with `--help`-style or dry paths under `env -i` with a temp `HOME`, and
  asserts the resolved default for all four files, plus: `DELEGATE_LOCAL_DATA_DIR`
  redirects all four, each file-specific override still wins, `XDG_DATA_HOME`
  has no effect, and an unset `HOME` under `set -u` still fails loudly.

- [ ] **Step 2: run it and watch it fail.**

- [ ] **Step 3: substitute.** Every
  `${DELEGATE_METRICS_FILE:-$HOME/.claude/skills/delegate-local/metrics.jsonl}`
  becomes
  `${DELEGATE_METRICS_FILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/metrics.jsonl}`,
  and the same shape for `config.sh` (keeping the `DELEGATE_TO_OLLAMA_CONFIG`
  alias) and `profile.sh`. Nothing else changes; no function, no source, no
  existence test.

- [ ] **Step 4: run the tests to green, then every existing suite.** Note that
  the existing suites cannot catch a regression here, because each one either
  passes an explicit path or sandboxes `HOME`; `tests/test-paths.sh` is the only
  thing that can.

- [ ] **Step 5: register the suite** in `.github/workflows/ci.yml`.

- [ ] **Step 6: commit.** `fix: default user data outside the skill directory`

## Task 2: the migration and the warning

**Files:** modify `scripts/onboard.sh`, `metrics-summary.sh`,
`delegate-feedback.sh`, `observability-doctor.sh`; modify
`tests/test-onboard.sh`, `tests/test-metrics-summary.sh`; modify `.gitignore`.

- [ ] **Step 1: write the failing tests.** For `--migrate-data`: copies each
  legacy file that exists, leaves it in place, carries `metrics.loki-sync`,
  refuses to overwrite an existing target with a non-zero exit and a clear
  message, is idempotent, does nothing when no legacy file exists, and FAILS
  LOUDLY when the legacy directory exists but holds no `metrics.jsonl`. For the
  warning: it fires only when the new file is absent and the legacy one exists,
  names the real row count, and does NOT fire when both or neither exist.

- [ ] **Step 2: run them and watch them fail.**

- [ ] **Step 3: implement `--migrate-data`.** Copy, never move. Print each
  action.

- [ ] **Step 4: implement the warning** in the three read paths that already
  print a "no metrics file" error. One extra line, naming the legacy path, its
  row count, and the migrate command.

- [ ] **Step 5: add `metrics.loki-sync` to `.gitignore`.** The existing
  `metrics.jsonl.*` pattern does not match it, which is why it shows as
  untracked today.

- [ ] **Step 6: run the suites.**

- [ ] **Step 7: commit.** `feat: add onboard.sh --migrate-data`

## Task 3: the documentation sweep

**Files:** `prompts/miss-theme-cluster.md`, `SKILL.md`, `README.md`,
`CLAUDE.md`, `CONTRIBUTING.md`, `SECURITY.md`, `docs/install-claude-code.md`,
`docs/install-codex.md`, `docs/install-opencode.md`, `docs/otel-schema.md`,
`docs/observability/grafana-local.md`, `.github/ISSUE_TEMPLATE/bug_report.md`,
`.github/ISSUE_TEMPLATE/prompt-pattern.md`.

- [ ] **Step 1: fix the two that are live behaviour first.**
  `prompts/miss-theme-cluster.md` hardcodes the legacy path in a shipped recipe
  the agent copies and runs, and `SKILL.md` is production prompt content. Both
  would instruct the tool to read a path that no longer holds the data.

- [ ] **Step 2: sweep the rest.** Only paths to the four DATA files change.
  Script paths (`~/.claude/skills/delegate-local/scripts/…`) stay as they are.

- [ ] **Step 3: document the sequence in `README.md`:** where data lives, the
  resolution order, that an existing install keeps working, and that the order
  is migrate, verify, prune worktrees, repoint last.

- [ ] **Step 4: run `tests/test-prompts-library.sh` and
  `tests/test-validate-content.sh`,** which gate the shipped prompt surface.

- [ ] **Step 5: commit.** `docs: point user-data paths at the new default`

## Task 4: close the loop on #360

- [ ] Comment on #360 with what shipped and what is still the user's call.

## Explicitly not in this plan

A performance measurement of the boundary hook. The earlier plan had a whole
step for it. Measured, sourcing costs 62 microseconds against a hook that costs
about 35ms per Bash call, dominated by two `jq` spawns before the pre-filter, so
the difference is 0.18% and roughly 500 times smaller than run-to-run variance.
There is also nothing left to source. Any number reported would be noise.
