# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This repo *is* a Claude Code skill, not an application that uses one. Editing `SKILL.md` changes how Claude itself behaves whenever the skill is loaded. Treat `SKILL.md` as production prompt content, not documentation: changes to its frontmatter `description` directly affect trigger accuracy across every conversation that has the skill installed.

The skill's job is to route "gather context once, send one prompt, return text" tasks to local Ollama models via shell pipes. It deliberately avoids any framework, router process, or orchestration layer — the entire runtime surface is two bash scripts.

## Commands

Run the unit tests (mocks `ollama` and `llmfit` on a restricted PATH so results are deterministic regardless of what is installed):

```bash
bash tests/run-tests.sh
```

Audit installed models and see tier routing plus llmfit upgrade suggestions (requires `ollama`, `jq`, and optionally `llmfit` on PATH):

```bash
bash scripts/audit-models.sh
```

Resolve a tier to a model name (used internally by `delegate.sh`, also useful for one-off shell pipes):

```bash
bash scripts/pick-model.sh <code|prose|reasoning|long-context|vision|embedding|premium-general|reasoning-vision>
```

Wrap a delegation through the metrics-capturing wrapper (preferred over bare `ollama run`):

```bash
echo "<context>" | bash scripts/delegate.sh prose "<prompt>"
```

Read the metrics roll-up (add `--since YYYY-MM-DD` / `--days N` to window every section to recent rows; the cutoff is resolved in jq so there is no cross-platform `date` math):

```bash
bash scripts/metrics-summary.sh
bash scripts/metrics-summary.sh --days 7        # just the last week
bash scripts/metrics-summary.sh --since 2026-06-15
```

Record a hit/miss verdict against the most recent delegation (the output was kept as-is = hit, or was rewritten / discarded = miss). The verdict appends a `source:"feedback"` row to the same metrics JSONL keyed by `ref_ts` to the delegate event. After a MISS, the script scans historical MISS rows in the rolling 30-day window for token-overlap matches and, on the third or later similar reason, prints a draft `gh issue create` command for filing a `prompt-pattern` issue (advisory only — it never opens the issue itself). Tune via `DELEGATE_FEEDBACK_NUDGE_AT`, `DELEGATE_FEEDBACK_NUDGE_WINDOW_DAYS`, `DELEGATE_FEEDBACK_SIMILAR_THRESHOLD`, or silence with `DELEGATE_FEEDBACK_NO_NUDGE=1`. README "Calibration feedback loop" diagram covers the end-to-end:

```bash
bash scripts/delegate-feedback.sh hit
bash scripts/delegate-feedback.sh miss "bulleted output when prose was wanted"
```

Run the validation pipeline locally (the same gates CI runs on every PR — frontmatter shape, content scan, trigger-eval shape, plus per-script unit tests):

```bash
bash scripts/validate-frontmatter.sh SKILL.md
bash scripts/validate-skill-content.sh SKILL.md
bash scripts/eval-skill-triggers.sh
bash tests/test-validate-frontmatter.sh
bash tests/test-validate-content.sh
bash tests/test-delegate.sh
bash tests/test-metrics-summary.sh
bash tests/test-delegate-feedback.sh
bash tests/test-prompts-library.sh
bash tests/test-onboard.sh
bash tests/test-eval-skill-triggers.sh
```

Run the trigger eval against a local Ollama model (free, on-device; recommended pre-merge gate for any frontmatter `description` edit):

```bash
bash scripts/eval-skill-triggers.sh --ollama                          # default: pick-model.sh code
bash scripts/eval-skill-triggers.sh --ollama qwen3.6:35b-a3b-q8_0     # known-good batched scorer
```

Run the trigger eval against GitHub Models (free up to per-model rate-limit tier; this is what runs in CI on every PR):

```bash
GITHUB_TOKEN=$(gh auth token) bash scripts/eval-skill-triggers.sh --github-models  # default: openai/gpt-4o-mini
```

Run the trigger eval against the live Anthropic API (requires `ANTHROPIC_API_KEY`; kept for the rare case Claude-grade scoring is wanted):

```bash
ANTHROPIC_API_KEY=… bash scripts/eval-skill-triggers.sh --api
```

There is no build step, no linter, no package manager. Runtime deps are `bash` (3.2+ — macOS-shipped is fine), `jq`, `awk`, and `perl` (used in one validator because BSD grep on macOS lacks `-P`). `curl` is required by `scripts/delegate.sh` (Ollama HTTP API) and by all three scoring modes of the trigger eval (`--api`, `--ollama`, `--github-models`). Cross-platform portability is a real constraint: avoid associative arrays (bash 4-only), avoid `grep -P` (GNU-only), and prefer `perl -CSD` for unicode-aware regex.

Install for end users is `npx skills add IsmaelMartinez/delegate-local` (Vercel Labs' multi-agent CLI symlinks it into Claude Code, Codex, OpenCode, Cursor, Copilot, etc.) — see `README.md` for the manual `cp -r` fallback.

## Architecture

`scripts/pick-model.sh` is the single source of truth for tier-to-model routing. Each tier holds a substring-matched preference list, highest capability first; the script returns the first installed model whose name contains a preference substring. The four active tiers are `code`, `prose`, `reasoning`, and `long-context`; four more (`vision`, `embedding`, `premium-general`, `reasoning-vision`) are scaffolded — routing is in place but resolution is gated on the relevant model being installed. When the installed model set changes, edit the `prefs` arrays in this script — never hardcode model names in `SKILL.md` or in shell pipes that delegate work. `DELEGATE_BACKEND=auto|ollama|mlx` (default `auto` since 2026-05-13) selects which installed-model registry to query. Ollama via `ollama list`, MLX via a scan of `${HF_HOME:-~/.cache/huggingface}/hub` for `models--<org>--<name>/snapshots/<hash>/` entries with non-empty snapshots. The `auto` mode probes `${MLX_HOST:-http://localhost:8080}/v1/models` with a 1-second timeout (override via `DELEGATE_BACKEND_AUTO_PROBE_TIMEOUT`); 200 → resolves to `mlx`, anything else → `ollama`. Non-Apple-Silicon hosts and Apple Silicon hosts without `mlx_lm.server` running both transparently fall through to Ollama — the auto default is strictly an opt-in upgrade. The same prefs list serves both backends because the matcher is case-insensitive (`grep -iF`) — Ollama tags are lowercase, MLX names follow HuggingFace mixed case, and a single substring like `qwen3.6` matches both. Explicit `DELEGATE_BACKEND=ollama` or `=mlx` skips the probe.

`scripts/delegate.sh` is the wrapper `SKILL.md` teaches Claude to invoke. It calls `pick-model.sh` to resolve the tier, then posts to the backend's completions endpoint with `temperature:0` and `stream:false`. Ollama (`DELEGATE_BACKEND=ollama`, or `auto` when MLX is unreachable) routes through `POST /api/generate` on the Ollama daemon (default `http://localhost:11434`, override via `OLLAMA_HOST`) with `think:false` so reasoning-capable models don't leak chain-of-thought into the response. MLX (`DELEGATE_BACKEND=mlx`) routes through `POST /v1/chat/completions` on the MLX server (default `http://localhost:8080`, override via `MLX_HOST`) — that's `mlx_lm.server`'s OpenAI-compatible chat-completions API; response is parsed from `.choices[0].message.content` rather than `.response`. The payload uses the `messages: [{role:"user", content:...}]` shape plus `chat_template_kwargs: {enable_thinking: <think>}` to mirror Ollama's `think` semantics through the model's chat template (default false; set `DELEGATE_THINK=true` to flip it on). The raw `/v1/completions` endpoint is deliberately avoided because it bypasses `apply_chat_template` and produces whitespace-only output on instruction-tuned models (empirically verified 2026-05-12 against `mlx-community/Qwen3.6-35B-A3B-8bit`). The HTTP body is plain text either way — no ANSI stripping needed, unlike the `ollama run` CLI it replaced (the CLI mixed cursor-rewrites and spinner bytes into stdout). Each call appends one JSON line to `~/.claude/skills/delegate-local/metrics.jsonl` tagged with a `backend` field. Set `DELEGATE_LOCAL_NO_METRICS=1` to opt out for a single call. The metrics file is intentionally outside the repo so it survives `git clean -fdx` and isn't committed by accident. `scripts/metrics-summary.sh` reads that JSONL and prints volume/latency/tokens-avoided rollups, including per-project and per-recipe hit-rate sections (the per-project one gated on 2+ distinct projects, the per-recipe one on at least one `--recipe` row) that join the feedback rows for hit/miss/untracked counts so the maintainer can see which projects and recipes underperform; `--since YYYY-MM-DD` / `--days N` window every section to rows at or after the cutoff (resolved in jq via `now`/`fromdateiso8601` so there is no BSD-vs-GNU `date` epoch split), filtering matching rows once into a temp file that every downstream pass reads; both scripts are idempotent and read-only with respect to the rest of the system. Layer 2 of the training-loop initiative added `--recipe NAME [--var key=value ...]` flags: when set, the wrapper loads `prompts/<NAME>.md`, awk-extracts the first fenced block under `## Prompt template`, substitutes each `{{key}}` placeholder from `--var` (and `{{stdin}}` from piped context), then refuses to send a partly-substituted template to the model — unsubstituted placeholders exit 2 with the missing keys named. The metrics line gains a `recipe` field when the flag is used; `DELEGATE_PROMPTS_DIR` env var overrides the recipe directory for tests. A pre-flight canary fires on every recipe call (issue #110 mitigation): after `pick-model.sh` resolves the tier but before the full templated request is sent, a 1-token probe (`num_predict:1` on Ollama, `max_tokens:1` on MLX) hits the resolved model with `curl --max-time ${DELEGATE_PREFLIGHT_TIMEOUT:-10}`. If the probe doesn't return within the timeout the wrapper exits 3 with an actionable stderr (raise timeout, smaller-parameter model, hand-write, opt out via `DELEGATE_NO_PREFLIGHT=1`) and writes a metrics row tagged `exit_status:3` so stall events stay observable in the metrics rollup. The canary is skipped on bare (non-recipe) calls where input investment is low; the failed-canary metrics row carries the would-be `prompt_chars` so post-hoc analysis can correlate stall events to input size. After generation, recipes that declare a frontmatter `checks:` block run the ADR 0014 deterministic output checks (`subject_max`, `no_padding_tail`, `subject_type`, `body_required`); ADR 0017 then both persists the results (`checks_run` / `checks_failed` / `checks_autofixed` on the metrics row, omitted when no check ran) so structural quality is observable, and makes `no_padding_tail` actionable — it auto-strips the safe trailing participial-comma padding clause (recorded as `checks_autofixed`, surfaced on the meta line, default-on with `DELEGATE_NO_AUTOFIX=1` to restore warn-only). `checks_failed` means "problems shipped", `checks_autofixed` means "problems fixed in place"; the riskier "This-X" and ambiguous multi-comma shapes are never auto-stripped.

The validation pipeline is the gate every PR has to clear. Three scripts plus the unit suite, all wired into `.github/workflows/ci.yml` and runnable locally. `scripts/validate-frontmatter.sh` asserts SKILL.md has the required frontmatter fields, `name` matches the directory and the Claude Skills regex, and `description` ≤ 4096 chars. `scripts/validate-skill-content.sh` scans for eight categories of dangerous content (SEC_DISABLE, SEC_PERMISSIVE, CRED_EXFIL, OBFUSC_B64, OBFUSC_UNICODE, TOOL_BROAD, CONFLICT_MARKER, URL_EXTERNAL) using a bash-3-compatible newline-delimited allowlist (associative arrays unavailable on macOS) and `perl -CSD` for the unicode regex. Justified false positives go in `.content-check-allow` keyed by either repo-relative path-and-line or sha256 of the offending line. `scripts/eval-skill-triggers.sh` validates `evals/eval-set.json` shape by default; with `--ollama [model]` it sends the full eval set as one batched call to a local Ollama model (free) using only the SKILL.md frontmatter description as the trigger surface, scoring recall and negative-precision against the thresholds inside the eval set. With `--github-models [model]` the same batched flow runs against the GitHub Models API (free up to per-model rate-limit tier, default `openai/gpt-4o-mini`) using the auto-provisioned `GITHUB_TOKEN`; this is what runs in CI on every PR. Batching collapses ~23 requests/run into 1 so a normal day of CI iteration stays under the GitHub Models 150 RPD free-tier quota (issue #62) — the per-query mode that preceded it exhausted the bucket after ~6 PR runs. Batching is more discriminating than per-query scoring on paraphrase-edge positives, so model choice matters more, and the passing set drifts as the eval set grows: re-measured 2026-06-21, `deepseek-r1:32b` and `qwen3-coder:30b-a3b-q8_0` both hit 1.000 / 1.000 on the current eval set in batched mode, `qwen3-coder-next:latest` (the current `pick-model.sh code` default) scrapes a 0.909 pass, while `qwen3.6:35b-a3b-q8_0` now drops to 0.864 recall (three positives missed, below the 0.9 gate) — pass `--ollama deepseek-r1:32b` (or `qwen3-coder:30b-a3b-q8_0`) explicitly for a comfortable margin when running the local pre-merge gate. With `--api` and `ANTHROPIC_API_KEY` set, the same flow runs against Claude — kept for the rare case Claude-grade scoring is wanted. The eval-set is the seed for catching trigger drift: 22 gating positive queries (tagged exact / paraphrase) plus 4 non-gating diagnostic queries, and 15 negative queries (adjacent / unrelated). When you change preference order in `pick-model.sh`, expect tests in `tests/run-tests.sh` to need updating; when you change SKILL.md frontmatter, run `--ollama` mode locally before merge — the local hook in `.claude/hooks/post-edit-validate.sh` runs the shape-mode and content checks automatically on save but does not run the trigger-accuracy gate.

`tests/run-tests.sh` covers `pick-model.sh` (including the `DELEGATE_BACKEND=mlx` dispatch, the `DELEGATE_BACKEND=auto` probe-and-resolve path, and HF-hub-scan), `init.sh`, and `audit-models.sh`. Each kept script has its own test file — `test-validate-frontmatter.sh`, `test-validate-content.sh`, `test-delegate.sh`, `test-metrics-summary.sh`, `test-delegate-feedback.sh`, `test-prompts-library.sh`, `test-eval-skill-triggers.sh`, `test-onboard.sh`, and `test-project-name.sh` — using `tests/fixtures/` for both shape variants of SKILL.md and category-specific dangerous-content samples. The whole suite runs on every PR via the single `validate` CI job.

`prompts/` is the calibrated-recipe library introduced 2026-05-09 as layer 1 of the training-loop initiative (see ROADMAP). Each `prompts/<task>.md` ships the proven prompt skeleton + verbatim-example anchoring discipline + explicit anti-hallucination guards drawn from real session HITs. SKILL.md "Recipes" section points the agent at the directory; `tests/test-prompts-library.sh` enforces structural validity (required sections, README cross-reference, SKILL.md pointer) so a recipe can't drift into a broken template. Adding a new recipe is described in `prompts/README.md`: every recurring HIT graduates to a recipe entry, every MISS that names a missing recipe gets one filed.

`scripts/audit-models.sh` is read-only by design and never pulls models. It cross-checks `llmfit recommend --json` output against `ollama list` because llmfit tracks its own HuggingFace GGUF cache rather than Ollama's model store. The `hf_stem` function strips provider prefix and quant/variant suffixes (`-instruct`, `-fp8`, `-q4_K_M`, etc.) so that `Qwen/Qwen3.6-35B-A3B-Instruct-Q8_0` matches an installed `qwen3.6:35b-a3b-q8_0`. Suggestions are filtered to first-party providers (Alibaba/Google/Meta/Microsoft/DeepSeek/Mistral/Zhipu) because third-party fine-tunes rarely appear on the Ollama library under the same name. The 3-point delta threshold for surfacing an upgrade is intentional — anything smaller is noise from llmfit's scoring.

`tests/run-tests.sh` builds an isolated PATH containing only `/usr/bin:/bin:/usr/sbin:/sbin` plus a temp dir holding mock `ollama` and `llmfit` binaries, then asserts specific tier outputs. The MLX cases pass `HF_HOME=$tmp` and construct a fake `$tmp/hub/models--<org>--<name>/snapshots/<hash>/` tree (with a sentinel `weights.safetensors` so the empty-snapshot guard doesn't skip it) — no `mlx-lm` binary needed in the test PATH because `pick-model.sh` only reads the cache directory. The prose-tier ordering test (qwen3.6 ahead of qwen3-next) is intentional and encodes the empirical Phase 7 baseline finding — don't relax it without re-running the baseline.

## Conventions

`SKILL.md` frontmatter `description` field is load-bearing — it is the prompt Claude reads to decide whether to invoke this skill. The Phase 2 trigger evals (`scripts/eval-skill-triggers.sh` against `evals/eval-set.json`) gate changes to this field. The recommended pre-merge gate is `--ollama` mode (free, runs locally in 10–30 s, dogfoods the project's own routing); `--api` mode against Claude stays opt-in via the `ANTHROPIC_API_KEY` repo secret. Run the gate before merging any frontmatter `description` edit and confirm recall ≥ 0.9 and negative-precision ≥ 0.9. Keep the MUST/MUST NOT structure intact when editing.

When reasoning about whether work belongs in this skill, the discriminator is the local-brain insight: local models are strong summarisers and weak agents. If a task needs multi-step reasoning, repo-wide context, or tool-calling, it does not belong here even if the surface looks textual. The "out of scope" section of `ROADMAP.md` enumerates the boundaries; honour them when adding capabilities.

`ROADMAP.md` is the authoritative project plan: what the skill is, where it stands after the 2026-06-19 lean-core reset, and the priority-ordered next steps. Consult it before non-trivial work and honour its "out of scope" boundary.

## Repo Butler

This repo is monitored by [Repo Butler](https://github.com/IsmaelMartinez/repo-butler), a portfolio health agent that observes repo health daily and generates dashboards, governance proposals, and tier classifications.

**Your report:** https://ismaelmartinez.github.io/repo-butler/delegate-local.html
**Portfolio dashboard:** https://ismaelmartinez.github.io/repo-butler/
**Consumer guide:** https://github.com/IsmaelMartinez/repo-butler/blob/main/docs/consumer-guide.md

### Querying Reginald (the butler MCP server)

To query your repo's health tier, governance findings, and portfolio data from any Claude Code session, add the MCP server once (adjust the path to your local repo-butler checkout):

```bash
claude mcp add repo-butler node /path/to/repo-butler/src/mcp.js
```

Available tools: `get_health_tier`, `get_campaign_status`, `query_portfolio`, `get_snapshot_diff`, `get_governance_findings`, `trigger_refresh`.

When working on health improvements, check the per-repo report for the current tier checklist and use the consumer guide for fix instructions.

If this repo deploys a page, set its GitHub repository Homepage URL (the Website field in the repo's About section — not `package.json`'s `homepage`) to the canonical URL. That's how repo-butler surfaces the deployed link in dashboards and agent cards.
