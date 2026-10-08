# Environment variables

Every `DELEGATE_*` variable a script under `scripts/` reads, listed once. All are optional: an unset variable takes the default shown. "Data dir" is `DELEGATE_LOCAL_DATA_DIR`, default `~/.local/share/delegate-local`. Where a script also takes a flag for the same setting, the flag wins. The internal include guard `_DELEGATE_OTEL_LIB_LOADED` in `scripts/lib/otel.sh` is not a setting and is left out.

## Providers and dispatch

| Variable | Default | Effect | Read by |
|---|---|---|---|
| `DELEGATE_BASE_URL` | `${MLX_HOST:-http://localhost:8080}/v1 ${DOCKER_MODEL_HOST:-http://localhost:12434}/engines/v1 ${OLLAMA_HOST:-http://localhost:11434}/v1` | Space-separated, ordered list of OpenAI-compatible base URLs; the first reachable one serving a model the tier prefers wins. Entries with `user:pass@` are refused. | `pick-model.sh`, `audit-models.sh` |
| `DELEGATE_PROBE_TIMEOUT` | `1` | Seconds for each `GET {base}/models` probe. | `pick-model.sh`, `audit-models.sh`, `eval-skill-triggers.sh` |
| `DELEGATE_LOCAL_CONFIG` | `<data dir>/config.sh` | Per-user routing overrides sourced after the shipped tier preferences. Prepend to a tier, e.g. `prose) prefs=(gemma-4-26b "${prefs[@]}") ;;`; a tier reassigned to a full list stops following the shipped one, and the audit warns about it. | `pick-model.sh`, `audit-models.sh` |
| `DELEGATE_PREFLIGHT_TIMEOUT` | `10` | Seconds the 1-token canary may take before a recipe call exits 3. | `delegate.sh` |
| `DELEGATE_NO_PREFLIGHT` | unset | `1` skips the canary on recipe calls. | `delegate.sh` |
| `DELEGATE_REQUEST_TIMEOUT` | `600` | `curl --max-time` in seconds for the generation request. | `delegate.sh` |
| `DELEGATE_MAX_TOKENS` | `4096` | `max_tokens` sent with the request; must be a positive integer. | `delegate.sh` |
| `DELEGATE_TEMPERATURE` | unset (greedy, `0`) | Sampling temperature; only an explicit value is recorded on the row. | `delegate.sh` |
| `DELEGATE_THINK` | `false` | `true` sends `enable_thinking: true` through the chat template. | `delegate.sh`, `eval-skill-triggers.sh --local` |
| `DELEGATE_STRIP_THINK` | unset | `1` strips everything up to the first `</think>`; the `reasoning` tier strips by default and `0` turns that off. | `delegate.sh` |

## Recipes and output checks

| Variable | Default | Effect | Read by |
|---|---|---|---|
| `DELEGATE_PROMPTS_DIR` | `<skill>/prompts` | Directory recipes are loaded from. | `delegate.sh`, `delegate-boundary-hook.sh`, `self-improve.sh`, `replay-recipe.sh` |
| `DELEGATE_NO_ECHO_CHECK` | unset | `1` disables `no_example_echo` and `no_context_echo`. | `lib/checks.sh` |
| `DELEGATE_NO_AUTOFIX` | unset | `1` reports the autofixable checks (`no_padding_tail`, `no_title_line`) without changing the output. | `lib/checks.sh` |
| `DELEGATE_NO_RETRY` | unset | `1` skips the single retry spent on a failed declared check. | `delegate.sh` |
| `DELEGATE_LOCAL_PROFILE` | `<data dir>/profile.sh` | The flavor profile loaded into recipe variables and written by onboarding. | `load-flavor.sh`, `onboard.sh` |

## Metrics, drafts and verdicts

| Variable | Default | Effect | Read by |
|---|---|---|---|
| `DELEGATE_LOCAL_DATA_DIR` | `~/.local/share/delegate-local` | Per-user data dir: metrics, drafts, `config.sh`, `profile.sh`, watermarks. | most scripts |
| `DELEGATE_METRICS_FILE` | `<data dir>/metrics.jsonl` | The metrics JSONL every script reads and appends to. | most scripts, `lib/hook.sh` |
| `DELEGATE_LOCAL_NO_METRICS` | unset | `1` writes no metrics row (and so no draft, no boundary row, no credit). | `delegate.sh`, `embed.sh`, both boundary hooks |
| `DELEGATE_LOCAL_NO_META` | unset | `1` suppresses the `delegate-meta:` stderr line and skips the output checks. | `delegate.sh`, `lib/checks.sh` |
| `DELEGATE_LOCAL_NO_VERDICT_NUDGE` | unset | `1` suppresses the post-call verdict nudge. | `delegate.sh` |
| `DELEGATE_LOCAL_VERDICT_NUDGE_FD` | `2` | File descriptor (1-9) the verdict nudge is written to. | `delegate.sh` |
| `DELEGATE_PROJECT` | main repository basename | Project name recorded on rows; `--project` sets it. | `lib/otel.sh`, `delegate.sh`, `delegate-boundary-hook.sh` |
| `DELEGATE_NO_DRAFT_CAPTURE` | unset | `1` stores no draft, rendered input or `inputs.json`. | `delegate.sh` |
| `DELEGATE_DRAFT_MAX_BYTES` | `65536` | Byte cap on stored drafts, inputs and hook-captured finals. | `delegate.sh`, both boundary hooks |
| `DELEGATE_DRAFT_RETENTION_DAYS` | `14` | Age at which stored drafts and replay outputs are pruned. | `delegate.sh`, `replay-recipe.sh` |
| `DELEGATE_FEEDBACK_STALE_SECONDS` | `300` | Window an unpinned verdict searches for its delegation; `0` disables the check. | `delegate-feedback.sh` |
| `DELEGATE_FEEDBACK_REPEAT_WINDOW_SECONDS` | `600` | Window for the warning on a reason repeated across delegations; `0` disables it. | `delegate-feedback.sh` |
| `DELEGATE_FEEDBACK_NO_NUDGE` | unset | `1` silences the similar-miss issue nudge. | `delegate-feedback.sh` |
| `DELEGATE_FEEDBACK_NUDGE_AT` | `3` | Similar misses needed before the issue nudge prints. | `delegate-feedback.sh` |
| `DELEGATE_FEEDBACK_NUDGE_WINDOW_DAYS` | `30` | Look-back window for similar misses. | `delegate-feedback.sh` |
| `DELEGATE_FEEDBACK_SIMILAR_THRESHOLD` | `0.4` | Token-overlap ratio at which two miss reasons count as similar. | `delegate-feedback.sh` |
| `DELEGATE_GITHUB_REPO` | `IsmaelMartinez/delegate-local` | Repository named in the drafted `gh issue create` and bug-report links. | `delegate-feedback.sh`, `delegate.sh` |

## Boundary and Stop hooks

| Variable | Default | Effect | Read by |
|---|---|---|---|
| `DELEGATE_BOUNDARY_MODE` | unset | `off`, `warn` or `enforce` for every boundary; unset enforces the set below and warns elsewhere; any other value is `warn`. | `delegate-boundary-hook.sh` |
| `DELEGATE_BOUNDARY_ENFORCE` | `git-commit,issue-create,comment-reply,pr-review-comment,pr-review-body` | Boundaries enforced when the mode is unset; an explicitly empty value enforces none. | `delegate-boundary-hook.sh` |
| `DELEGATE_BOUNDARY_MIN_CHARS` | `20` for `git-commit`, `120` elsewhere | Body length below which no delegation is asked for. | `delegate-boundary-hook.sh`, `metrics-summary.sh` |
| `DELEGATE_BOUNDARY_LONG_BODY_CHARS` | `600` | Reply length at or above which a comment routes to `maintainer-review-reply` rather than `maintainer-reply`. | `delegate-boundary-hook.sh` |
| `DELEGATE_BOUNDARY_WINDOW_MIN` | `480` | Minutes a delegation stays available to credit a boundary. | `delegate-boundary-hook.sh`, `metrics-summary.sh` |
| `DELEGATE_BOUNDARY_TRANSCRIPT_TAIL_BYTES` | `8388608` (8 MB) | How much of the session transcript's tail the hook reads, on the deny path only, to find text the human was already shown and answered (#607). | `delegate-boundary-hook.sh` |
| `DELEGATE_BOUNDARY_WRAPPER_DIRS` | `$CLAUDE_JOB_DIR:$TMPDIR:/tmp:/private/tmp:/var/folders` | Colon-separated dirs whose wrapper scripts the hook reads and classifies. | `delegate-boundary-hook.sh` |
| `DELEGATE_BOUNDARY_LOCK_STALE_SEC` | `5` | Age at which the hook's lock is treated as stale. | `delegate-boundary-hook.sh` |
| `DELEGATE_BOUNDARY_LOCK_WAIT_MS` | `2000` | How long the hook waits for the lock. | `delegate-boundary-hook.sh` |
| `DELEGATE_VERDICT_STOP_MODE` | `warn` | `off` silences the Stop-hook verdict prompt. | `delegate-verdict-stop-hook.sh` |
| `DELEGATE_SWEEP_WINDOW_HOURS` | `24` | Look-back window for unverdicted delegations at Stop. | `delegate-verdict-stop-hook.sh` |

## Calibration and replay

| Variable | Default | Effect | Read by |
|---|---|---|---|
| `DELEGATE_SELF_IMPROVE_STATE` | `<data dir>/self-improve.state` | Watermark file for the calibration gate. | `self-improve.sh`, `self-improve-daily.sh` |
| `DELEGATE_REPLAY_BASE` | `main` | Git ref the champion recipe is materialised from. | `replay-recipe.sh` |
| `DELEGATE_REPLAY_MODEL` | resolved from the recipe's tier | The model replay expects and keys its cache on; it does not select the model, and a case whose wrapper ran on a different one fails. | `replay-recipe.sh` |
| `DELEGATE_REPLAY_DELEGATE_SH` | `scripts/delegate.sh` | The wrapper replay invokes (a test seam). | `replay-recipe.sh` |
| `DELEGATE_GPU_GATE` | `1` | `0` turns off the heat gate (`lib/gpu-gate.sh`, #646) that batch callers run before each item. | `replay-recipe.sh` |
| `DELEGATE_GPU_MAX_THERMAL` | `2` | Wait while macOS's thermal state (0 nominal, 1 fair, 2 serious, 3 critical) is at or above this. | `replay-recipe.sh` |
| `DELEGATE_GPU_MAX_UTIL` | `90` | Before a batch's first model call, wait while an accelerator's `Device Utilization %` is above this; later calls are not gated on it, since the load is then the batch's own (#657). | `replay-recipe.sh` |
| `DELEGATE_GPU_POLL` | `15` | Seconds between checks while waiting. | `replay-recipe.sh` |
| `DELEGATE_GPU_WAIT_MAX` | `600` | Seconds to wait before giving up with exit 75; the run resumes from its cache. | `replay-recipe.sh` |
| `DELEGATE_GPU_COOLDOWN` | `0` | Seconds to rest between items. | `replay-recipe.sh` |

## Decisions (`decide.sh`, ADR 0033)

`decide.sh` answers on the resident tier model's logprobs unless `--backend clef` is passed; the first two variables matter only to that backend.

| Variable | Default | Effect | Read by |
|---|---|---|---|
| `DELEGATE_CLEF_URL` | `http://127.0.0.1:8765` | Base URL of a SystemOne endpoint (`POST /v1/systemone`), such as Clef served locally from the data dir's `spikes/clef/`. | `decide.sh` |
| `DELEGATE_CLEF_MODEL` | `clef-flash` | The `model` sent when the request names none. | `decide.sh` |
| `DELEGATE_DECIDE_TIMEOUT` | `120` | Seconds for each decision request, on either backend. | `decide.sh` |
| `DELEGATE_VERIFY_THRESHOLD` | the resolved model's line in `<data dir>/verify-thresholds.tsv`, else `0.5` | p(supported) at or above which `verify-draft.sh` passes a draft (0-1); overrides the threshold `--calibrate` recorded. | `verify-draft.sh` |

## Embeddings

| Variable | Default | Effect | Read by |
|---|---|---|---|
| `DELEGATE_EMBED_MAX_CHARS` | `6000` | Input is truncated to this many characters. | `embed.sh` |
| `DELEGATE_EMBED_TIMEOUT` | `60` | `curl --max-time` for the embedding request. | `embed.sh` |

## Observability

| Variable | Default | Effect | Read by |
|---|---|---|---|
| `DELEGATE_OTEL_ENDPOINT` | unset (off) | OTLP/HTTP traces endpoint; set it to emit spans. | `lib/otel.sh`, `backfill-otel.sh` |
| `DELEGATE_OTEL_HEADERS` | unset | Comma-separated `name:value` headers for the OTLP request. | `lib/otel.sh` |
| `DELEGATE_OTEL_TIMEOUT` | `5` | `curl --max-time` for the OTLP post. | `lib/otel.sh` |
| `DELEGATE_OTEL_INCLUDE_CONTENT` | `0` | `1` puts prompt and output text on spans. | `lib/otel.sh` |
| `DELEGATE_OTEL_VERBOSE` | unset | `1` shows OTLP post errors. | `lib/otel.sh` |
| `DELEGATE_LOKI_URL` | `http://localhost:3100` | Loki base URL. | `sync-metrics-to-loki.sh`, `observability-doctor.sh` |
| `DELEGATE_LOKI_STATE` | `<metrics file minus .jsonl>.loki-sync` | Loki sync watermark file. | `sync-metrics-to-loki.sh`, `observability-doctor.sh` |
| `DELEGATE_LOKI_TIMEOUT` | `30` | `curl --max-time` for the Loki push. | `sync-metrics-to-loki.sh` |
| `DELEGATE_GRAFANA_URL` | `http://localhost:3001` | Grafana URL the doctor checks. | `observability-doctor.sh` |
| `DELEGATE_TEMPO_URL` | `http://localhost:3200` | Tempo URL the doctor checks. | `observability-doctor.sh` |
| `DELEGATE_COMPOSE_FILE` | `observability/docker-compose.yml` | Compose file the doctor inspects. | `observability-doctor.sh` |
| `DELEGATE_DOCTOR_STALE_SECONDS` | `1800` | Seconds beyond which the doctor treats the metrics file as idle or Loki as lagging. | `observability-doctor.sh` |

## Onboarding and validation

| Variable | Default | Effect | Read by |
|---|---|---|---|
| `DELEGATE_ONBOARD_ASSUME_TTY` | unset | `1` runs the wizard interactively without a terminal. | `onboard.sh` |
| `DELEGATE_ONBOARD_SETTINGS` | `~/.claude/settings.json` | Settings file checked for the hook entries. | `onboard.sh` |
| `DELEGATE_CONTENT_ALLOW_ORG` | `IsmaelMartinez` | GitHub org whose URLs the content scan allows. | `validate-skill-content.sh` |
