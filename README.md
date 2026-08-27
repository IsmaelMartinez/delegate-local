# delegate-local

An agent skill that routes summarisation, triage, and bulk-text tasks to locally-installed models (Ollama or MLX) instead of the cloud API. Keeps content on-device, preserves the agent's context window, and uses `llmfit` to keep the model set current.

## 30-second quickstart

One linear path from nothing to a first delegated call:

```bash
# 1. Install the whole skill (SKILL.md + scripts/) into Claude Code, user-scoped
npx skills add IsmaelMartinez/delegate-local -a claude-code -g

# 2. Confirm at least one local model is installed and see how tiers route
bash ~/.claude/skills/delegate-local/scripts/audit-models.sh

# 3. (optional) Personalise routing + commit style to this machine: it derives a
#    profile from your own git history, has you confirm or edit each value, and
#    writes nothing without confirmation. Run it from a repo that reflects your style.
bash ~/.claude/skills/delegate-local/scripts/onboard.sh

# 4. Make your first delegated call
git diff | bash ~/.claude/skills/delegate-local/scripts/delegate.sh prose "Summarise this diff in 3 bullets."
```

Step 2 requires [Ollama](https://ollama.com) (or [`mlx-lm`](https://github.com/ml-explore/mlx-lm) on Apple Silicon) with a model pulled — see [Requirements](#requirements) and [Backends](#backends). Step 3 is optional but recommended on a new machine; the rest of this README covers install options, backend selection, and the routing internals. After install, the skill auto-delegates matching tasks inside your agent — the raw `delegate.sh` call in step 4 is just to confirm the backend works end-to-end.

## What it does

When a task fits the "gather context once, send one prompt, return text" pattern — log and PR/issue summarisation, commit-message and changelog drafting, batch triage and classification, structured field extraction, and prose rewriting — the agent delegates to a local model via `delegate.sh` instead of handling it itself. Reasoning, tool-calling, and repo-wide tasks still go to the cloud model.

The skill auto-delegates by default. Saying "delegate where it fits" or "auto-delegate" once locks that behaviour for the rest of the conversation.

Core pattern (from [local-brain](https://github.com/IsmaelMartinez/local-brain)) — resolve a tier to the best installed model, pipe context in, get text back:

```bash
git diff HEAD~5 | bash scripts/delegate.sh prose "Summarise in 3 bullets."
```

`delegate.sh` handles backend selection (Ollama or MLX via auto-probe), model resolution, metrics logging, and returns clean text with no ANSI artifacts.

## Requirements

- At least one OpenAI-compatible model server running locally: [Ollama](https://ollama.com) with a model pulled, [`mlx-lm`](https://github.com/ml-explore/mlx-lm) on Apple Silicon, or Docker Model Runner (see [Providers](#providers) below)
- `jq` (for `audit-models.sh`)
- `llmfit` (optional, enables upgrade suggestions based on your hardware)

## Providers

Every call goes to an OpenAI-compatible `POST {base}/chat/completions`. `DELEGATE_BASE_URL` is an ordered list of base URLs, and the first provider that is both reachable and serving a model the tier prefers takes the call. The default list is built from the host variables, so a non-default port or a remote daemon keeps working:

```
${MLX_HOST:-http://localhost:8080}/v1
${DOCKER_MODEL_HOST:-http://localhost:12434}/engines/v1
${OLLAMA_HOST:-http://localhost:11434}/v1
```

MLX leads because [ADR 0022](docs/adr/0022-mlx-primary-backend-rationale.md) measured it at roughly an order of magnitude lower latency than Ollama on identical weights. A provider that is down costs one refused connection and is skipped; a host running only Ollama routes there with no configuration.

On Apple Silicon, MLX is the recommended provider. Install and auto-start via launchd are documented in [docs/install-mlx.md](docs/install-mlx.md). The quick version:

```bash
python3 -m venv ~/venvs/mlx-lm && ~/venvs/mlx-lm/bin/pip install mlx-lm
~/venvs/mlx-lm/bin/huggingface-cli download mlx-community/Qwen3.6-35B-A3B-8bit
~/venvs/mlx-lm/bin/mlx_lm.server --model mlx-community/Qwen3.6-35B-A3B-8bit --port 8080 &
```

Pin a single provider by setting `DELEGATE_BASE_URL` yourself, for example `DELEGATE_BASE_URL=http://localhost:11434/v1`. The metrics JSONL tags each call with a `backend` field derived from the winning URL (`mlx` / `docker` / `ollama`, else `host:port`) so `scripts/metrics-summary.sh` can break down latency per provider.

## Install

### Universal (recommended)

Use [Vercel Labs' `skills` CLI](https://github.com/vercel-labs/skills). It clones the repo and installs the whole skill directory — `SKILL.md` plus `scripts/`, `prompts/`, and `docs/` — into every detected agent tool (Claude Code, Codex, OpenCode, Cursor, Copilot, and many others) at once, so the `scripts/…` commands below work straight after install and updates propagate everywhere:

```bash
npx skills add IsmaelMartinez/delegate-local
```

Pass `-g` to install user-scoped (`~/<agent>/skills/`) instead of per-project, `--copy` to make independent copies on systems without symlink support, or `-a claude-code` to limit to a specific agent.

### Per-tool guides

When the universal install is the wrong fit (per-machine routing, MCP-only consumers), the per-tool docs cover the specifics:

- [Claude Code](docs/install-claude-code.md)
- [Codex](docs/install-codex.md)
- [OpenCode](docs/install-opencode.md)
- [MLX backend (Apple Silicon, optional)](docs/install-mlx.md)

### Manual copy

The skill is conformant with the [Agent Skills standard](https://agentskills.io/specification) — `SKILL.md` at the directory root with `name` and `description` frontmatter — so any tool that reads that format can use it. To install without the `skills` CLI, clone the repo and drop the directory into the tool's expected skills path:

```bash
git clone https://github.com/IsmaelMartinez/delegate-local
cp -r delegate-local ~/.claude/skills/   # or your tool's skills dir
```

### Confirm routing

After install, run the audit from wherever the skill landed:

```bash
bash <install-path>/scripts/audit-models.sh
```

### Personalising routing (recommended)

The shipped `pick-model.sh` is one preference list for everyone. To override the order on a specific machine without forking the repo, drop a bash file at `~/.local/share/delegate-local/config.sh`. `pick-model.sh` sources it after the shipped defaults are set, so any tier the file touches wins. Untouched tiers fall through to shipped defaults; an absent file changes nothing.

> **Trust note:** `config.sh` is sourced as bash by `pick-model.sh` (and `profile.sh` by `load-flavor.sh`), meaning their contents execute with your environment and privileges. This is arbitrary code execution by design, similar to `~/.aiderrc` or `~/.claude/settings.local.json`. Only place a `config.sh` or `profile.sh` you wrote yourself or fully trust at those paths; never paste one from an untrusted source. `load-flavor.sh` additionally skips a profile that isn't owned by you or is group/world-writable. See [SECURITY.md](SECURITY.md) for the full trust model.

```bash
# ~/.local/share/delegate-local/config.sh
case "$tier" in
  prose) prefs=("gemma4" "qwen3.6" "qwen3-next") ;;
esac
```

Recommended first step on any new machine or user: the onboarding wizard probes your environment (`init.sh`) and derives your commit-style flavor from your own git history (`derive-flavor.sh`), presents each value for confirm-or-edit, and writes both override files only on explicit confirmation (timestamped `.bak` before any overwrite). Run it from a repo whose history reflects your style:

```bash
bash <install-path>/scripts/onboard.sh
```

Without a terminal it degrades to print-only and writes nothing. The two probes also work standalone — each is read-only and prints to stdout, never auto-writes:

```bash
mkdir -p ~/.local/share/delegate-local
bash <install-path>/scripts/init.sh > ~/.local/share/delegate-local/config.sh
bash <install-path>/scripts/derive-flavor.sh > ~/.local/share/delegate-local/profile.sh
```

Set `DELEGATE_LOCAL_CONFIG=/some/other/path.sh` to redirect the routing-override path, and `DELEGATE_LOCAL_PROFILE=/some/other/profile.sh` to redirect the flavor-profile path (useful for testing or per-project overrides — `onboard.sh`, `pick-model.sh`, and `load-flavor.sh` all honour them).

## Where per-user data lives

Metrics, the routing override and the flavour profile live in a data directory,
not inside the installed skill:

```
~/.local/share/delegate-local/
  metrics.jsonl        every call, one JSON line
  metrics.loki-sync    Loki watermark, if you use the sync job
  config.sh            routing override
  profile.sh           flavour profile
```

They used to default to `~/.claude/skills/delegate-local/`, which is the
directory the skill installer owns, so `npx skills add ... update` could delete
your accumulated calibration history.

Resolution per file, highest first: the file-specific variable
(`DELEGATE_METRICS_FILE`, `DELEGATE_LOCAL_CONFIG`, `DELEGATE_LOCAL_PROFILE`),
then `DELEGATE_LOCAL_DATA_DIR`, then the default above. `XDG_DATA_HOME` is
deliberately not consulted: it is commonly set in a shell rc file and absent in
GUI-launched processes, so honouring it would make a verdict recorded in your
terminal attach to a different metrics file than one recorded by an agent.

### Moving an existing install

```bash
bash <install-path>/scripts/onboard.sh --migrate-data
```

It copies, never moves, so it cannot destroy anything, and it refuses to
overwrite a target that already exists with different content.

If you also plan to stop symlinking the skill at a dev checkout, the order
matters and the wrong one fails silently:

1. migrate the data
2. verify with `metrics-summary.sh` that the totals match
3. prune any stale git worktrees holding older copies of the scripts
4. repoint the skill symlink **last**

Repointing before migrating leaves the history stranded where nothing can read
it, and the migration then reports success having copied nothing.


## Forking / adopting this skill

The mechanisms are fork-friendly out of the box — routing, metrics, and the feedback loop are all driven by env vars and the per-user `config.sh` above. What needs repointing is a handful of author-specific defaults:

1. **Run the onboarding wizard.** First step on any new machine or user (see [Personalising routing](#personalising-routing-recommended)) — it derives both your routing override and your commit-style flavor profile from what is actually installed and your own git history:

   ```bash
   bash <install-path>/scripts/onboard.sh
   ```

2. **Repoint the author-specific defaults** via env vars where they don't suit you:

   | Variable | Default | What it repoints |
   |----------|---------|------------------|
   | `DELEGATE_GITHUB_REPO` | `IsmaelMartinez/delegate-local` | Repo targeted by the drafted `gh issue create` command (`delegate-feedback.sh`) |
   | `DELEGATE_CONTENT_ALLOW_ORG` | `IsmaelMartinez` | GitHub org/user allowed by the content-scan URL allowlist (`validate-skill-content.sh`) |
   | `DELEGATE_METRICS_FILE` | `~/.local/share/delegate-local/metrics.jsonl` | Metrics JSONL location |
   | `DELEGATE_PROMPTS_DIR` | `<install-path>/prompts` | Recipe directory |
   | `OLLAMA_HOST` / `MLX_HOST` | `http://localhost:11434` / `http://localhost:8080` | Backend endpoints |

3. **Install from your fork** the same way as upstream:

   ```bash
   npx skills add <your-user>/delegate-local
   ```

4. **Re-calibrate triggering for your models.** `evals/eval-set.json` carries the trigger queries from the upstream project. Routing works without touching it, but a fork keeps the SKILL.md description calibrated by re-running the trigger eval against its own installed models:

   ```bash
   bash scripts/eval-skill-triggers.sh --local
   ```

5. **Update `CODEOWNERS`** to point `*` at your own handle so review requests go to you, not the upstream author.

## Files

- `SKILL.md` — triggering description and usage patterns the agent reads.
- `scripts/delegate.sh <tier> "<prompt>"` (or `--recipe NAME ["<prompt>"]`, which takes its tier from the recipe and makes the prompt optional) — wraps `pick-model.sh` + the backend's HTTP API (Ollama or MLX, auto-selected) with `think:false` and `temperature:0` defaults. Appends one JSON line per call to `~/.local/share/delegate-local/metrics.jsonl`. Use this instead of bare `ollama run` or hand-rolled `curl` calls.
- `scripts/pick-model.sh <tier>` — resolves a tier to the best installed model via substring preference lists. Tiers are `code`, `prose`, `reasoning`, and `long-context` (active), plus `vision`, `embedding`, `premium-general`, and `reasoning-vision` (scaffolded). Edit this file (not the skill body) when your installed set changes.
- `scripts/audit-models.sh` — prints installed models, tier routing, and llmfit-driven upgrade suggestions filtered to first-party providers. Read-only; never pulls.
- `scripts/metrics-summary.sh` — reads the metrics JSONL and prints volume per tier, p50/p95 latency, total tokens-avoided, top models by frequency, and per-project / per-recipe hit-rate. Pass `--since YYYY-MM-DD` or `--days N` to window every section to recent rows. Read-only.
- `scripts/delegate-feedback.sh [--final <path|->] hit|miss|scaffold [reason]` — records whether you used a delegation's output as-is (hit), rewrote or discarded it (miss), or discarded it but built on it (scaffold), appending a `feedback` row to the metrics JSONL. This is the calibration signal `metrics-summary.sh` rolls up. `--final` stores the text that actually shipped beside the draft `delegate.sh` already captured, which is what turns a rejection from a prose description into a diffable pair (ADR 0029). Flags may appear anywhere on the line, including after the reason; `--` before the verdict ends flag parsing so a reason can name one verbatim.
- `scripts/self-improve.sh` — the gate and evidence bundle for the recurring calibration session. Exits 10 in silence when nothing has been delegated since its watermark, and 0 with the bundle when something has: verdict tally, per-recipe keep rates worst-first, clustered deterministic check failures, and for every rejection the reason plus, where the pair was captured, `DROPPED` (anchors the human had to put back), `INVENTED` (values the model made up, where the human put something in their place) or `CUT` (material removed, where they put nothing back), and `SHAPE` (list where prose shipped). The procedure a session follows is [`docs/self-improvement-loop.md`](docs/self-improvement-loop.md).
- `scripts/verdict-sweep.sh` — interactive sweep over delegations that carry no verdict yet, recording each as hit/miss. It records **human** verdicts (it passes no `--source`), which is what `delegate-feedback.sh`'s inline path, tagged `--source agent`, cannot produce. Run it in a terminal; without a tty it reports the backlog and no-ops. `DELEGATE_SWEEP_WINDOW_HOURS` sets the look-back (default 24). `--calibrate [--sample N]` switches it to the second-look sample: instead of unjudged rows it offers ones the agent graded itself a **hit** on, so a human verdict can measure the self-flattery ADR 0015 warns about. `metrics-summary.sh` then reports that rate directly.
- `scripts/delegate-verdict-stop-hook.sh` — opt-in `Stop` hook that hands the session's untracked delegations back to the agent for an agent-tier verdict before it stops. Not wired up by default; see [`docs/boundary-hook.md`](docs/boundary-hook.md) for the `settings.json` block, the session-once loop guard, and why there is no enforce mode.
- `scripts/quality-report.sh` — re-derives quality from the recorded `reason` text rather than trusting the binary verdict, splitting hits into "used as-is" and "used after fixing" (ADR 0016). Reports one verdict tier at a time (`--tier human|agent|all`, default `agent`) so a usage figure can never be read as a quality one. `--classify` sends each reason to a local model for a sharper breakdown.
- `experiments/quality-trend.py` — weekly plot of the **human** hit-rate. Maintainer-facing; it is the quickest way to see whether the calibration signal is being fed at all.
- `docs/observability/` — opt-in OTLP exporter for visibility. Set `DELEGATE_OTEL_ENDPOINT=<url>` and every `delegate.sh` call POSTs an OTLP span (off by default, zero overhead when unset). Content is redacted by default; only metadata (tier, model, recipe, char counts, durations, verdict) travels to the collector. Three backends documented: [Grafana Cloud](docs/observability/grafana-cloud.md), [Langfuse](docs/observability/langfuse-self-host.md), and [Phoenix](docs/observability/phoenix.md). See [`docs/otel-schema.md`](docs/otel-schema.md) for the wire format. `scripts/sync-metrics-to-loki.sh` and `scripts/backfill-otel.sh` push the metrics JSONL to Loki / an OTLP collector for the Grafana dashboards under `dashboards/`; `scripts/observability-doctor.sh` diagnoses the setup.
- `tests/` — unit tests for every script. Run with `bash tests/run-tests.sh` (and the per-script `bash tests/test-*.sh`).

## Troubleshooting

The wrapper's failure modes map onto its exit codes, and every hard failure prints recovery options on stderr.

Exit 1 (`pick-model failed for tier`) means no installed model matches the tier's preference list. Run `bash scripts/audit-models.sh` to see what is installed and how tiers currently route, then either pull a model from the tier's preference list in `scripts/pick-model.sh` or edit that list to match your hardware. `pick-model.sh` distinguishes the two causes: "no provider is reachable" means start a daemon, "no provider holds a model for tier X" means pull a model or edit the preference list.

Exit 3 (`pre-flight canary`) means the resolved model did not answer a 1-token probe within `DELEGATE_PREFLIGHT_TIMEOUT` (default 10 s). The stderr message distinguishes a cold-load timeout (retry with a larger timeout), a connection refusal (start the provider daemon — `mlx_lm.server`, Docker Model Runner or `ollama serve` — and confirm `MLX_HOST` / `DOCKER_MODEL_HOST` / `OLLAMA_HOST`, or the `DELEGATE_BASE_URL` you pinned), and an HTTP error (usually a bad model name).

A non-zero curl exit on the dispatch itself (commonly 7, connection refused) means the resolved provider went away between the canary and the full request, or no canary ran (bare non-recipe calls skip it). `bash scripts/pick-model.sh --print-providers` shows which URLs are in play; the same daemon/host checks apply.

Empty or whitespace-only output from an MLX model usually means a raw completions endpoint was hit instead of chat-completions — `delegate.sh` always uses the right one, so this points at a hand-rolled `curl` bypassing the wrapper.

If a failure persists after the suggested recovery, [file a bug](https://github.com/IsmaelMartinez/delegate-local/issues/new?template=bug_report.md) with the verbatim stderr and your `bash scripts/audit-models.sh` output. For quality problems (the model answered, but badly) use the hit/miss loop below instead — recurring misses graduate into [`prompt-pattern` issues](#calibration-feedback-loop), not bug reports.

## Validation

Three scripts gate every PR via GitHub Actions:

- `scripts/validate-frontmatter.sh SKILL.md` — asserts the SKILL.md frontmatter has required fields, the `name` matches the directory, and `name` matches the Claude Skills regex.
- `scripts/validate-skill-content.sh SKILL.md` — scans for eight categories of dangerous content (auth-disable, permissive flags, credential exfiltration, base64 obfuscation, zero-width / bidi unicode, broad tool grants, unresolved merge markers, external URLs). Justified false positives go in `.content-check-allow`.
- `scripts/eval-skill-triggers.sh` — validates `evals/eval-set.json` shape by default; with `--local [model]` runs each tagged query through a local provider from `DELEGATE_BASE_URL` (free, on-device; defaults to `pick-model.sh code`, which baselines at 1.000 / 1.000 against the current eval set on the reference host); with `--github-models [model]` runs against GitHub Models (free up to the per-model rate-limit tier; defaults to `openai/gpt-4o-mini` which baselines at 0.900 / 1.000); with `--api` and `ANTHROPIC_API_KEY` set, runs against Claude — kept for the rare case Claude-grade scoring is wanted. All three modes use only the SKILL.md frontmatter description as the trigger surface and assert recall + negative-precision thresholds.

The `--local` mode is the recommended pre-merge gate (10–30 s on a mid-tier machine, dogfoods the project's own routing). The `--github-models` mode is the recommended CI gate — uses the auto-provisioned `GITHUB_TOKEN` so there is no secret to configure; the workflow declares `permissions: models: read` to grant scope. The `--api` mode is opt-in via the `ANTHROPIC_API_KEY` repo secret (Settings → Secrets and variables → Actions); without the secret the CI step is skipped, not failed.

## Calibration feedback loop

Recipes evolve from real session feedback. The loop is end-to-end on-device until you decide to share a finding:

```
delegate.sh run                metrics.jsonl                delegate-feedback.sh
  ↓                              (append-only,                miss "<reason>"
  appends one row                 gitignored)                   ↓
  per call                                                    appends one row
                                                              ↓
                                                              matches reason
                                                              against historical
                                                              MISS rows (Jaccard
                                                              over content tokens)
                                                                ↓
                                                              if N≥3 similars in
                                                              last 30d → nudge
                                                              prints draft gh
                                                              issue command
                                                                ↓
                                                          you decide whether to
                                                          file a prompt-pattern
                                                          issue → maintainer
                                                          graduates it into
                                                          prompts/<new>.md
```

The single-machine metrics JSONL has no scheduled job behind it; the nudge is the runtime signal. After the third similar MISS in the rolling window, `delegate-feedback.sh` prints the matched reasons and a draft `gh issue create` command pre-targeted at the `prompt-pattern` label. The nudge is advisory — it never opens the issue on its own — so each filing stays a deliberate call. Silence one invocation with `DELEGATE_FEEDBACK_NO_NUDGE=1`; tune the trigger via `DELEGATE_FEEDBACK_NUDGE_AT` (default 3), `DELEGATE_FEEDBACK_NUDGE_WINDOW_DAYS` (default 30), and `DELEGATE_FEEDBACK_SIMILAR_THRESHOLD` (default 0.4 Jaccard over stopword-stripped content tokens).

A `prompt-pattern` issue captures the task shape, tier and resolved model, verbatim prompt and model output, and (when known) the prompt that turned the MISS into a HIT. `prompts/README.md` documents how the maintainer graduates an issue into a `prompts/<new>.md` recipe paired with an `evals/eval-set.json` positive — closing the loop empirically rather than evaporating after one conversation.

## What you actually save

Worth being explicit about this because the skill could easily be oversold.

The delegated call is where the savings live — the local model writes the summary, classification, or patch instead of Claude. That's real and measurable: the metrics rollup (`scripts/metrics-summary.sh`) reports a "tokens avoided" headline computed from real Ollama `prompt_eval_count` + `eval_count` counts. The 2026-05-04 v8 probe's "~250× cheaper than Opus" number is also real for the specific workload it measured — 18 minimal-patch code cells scored by pytest.

But a realistic delegation flow costs more Anthropic tokens than just "the delegated call minus zero." In a typical turn, Claude still spends tokens to:

- read the user's request and decide a local model fits,
- frame the delegation prompt,
- read the local model's response back,
- verify the response against the actual files (for correctness-critical work — see SKILL.md's Discipline subsection on running the test when delegating code, and the gather-delegate-verify pattern throughout).

For small tasks — a 3-bullet diff summary, a one-line commit message — the verification overhead can eat most of the headline saving. The shape where this skill actually pays off is bulk or repeated work: triage 50 TODOs, classify 40 findings against an allowlist, draft release notes from a 200-line changelog. There the per-item Anthropic cost is dominated by the delegated generation, which is the part that moves to local.

Rough annual estimates (char-count tokens, ~1.5 KTok per round-trip that would otherwise go to the API):

| Usage profile                         | Delegations/year | Haiku-equiv save | Sonnet-equiv save | Opus-equiv save |
|---------------------------------------|------------------|------------------|-------------------|-----------------|
| Subscription user (Claude Max/Pro)    | any              | $0 (marginal)    | $0                | $0              |
| Casual API user (~10/hour × 20 h/wk)  | ~10k             | $25–40           | $75–115           | $375–560        |
| Heavy/team (~500/day × every day)     | ~180k            | $450–700         | $1.4k–2k          | $6.8k–10k       |

The subscription row is the honest one for individual developers: inside a Claude Max or Pro plan the marginal API cost of a delegation is zero, so the direct-dollar saving is zero. The real benefit in that case is different: **context-window preservation** (those tokens don't bloat Claude's active context, so long conversations stay focused) and **privacy** (sensitive logs, configs, and credentials never leave the machine).

More capable local models will shift these numbers but probably not by an order of magnitude. "250× cheaper than Opus" is a headline for one measured shape, not a general claim.

## Design notes

The skill intentionally avoids frameworks. Local models are good summarisers and weak agents; delegation is a shell pipe, not an orchestration layer. The `pick-model.sh` preference lists are the single point of truth for routing — no hardcoded model names in the skill body.

`audit-models.sh` cross-checks llmfit's `installed` flag against `ollama list` because llmfit tracks its own HuggingFace GGUF cache rather than Ollama's model store. It filters suggestions to Alibaba/Google/Meta/Microsoft/DeepSeek/Mistral/Zhipu so third-party fine-tunes that Ollama won't have under the same name don't pollute the output.

## Related projects

This skill sits at the intersection of three personal projects, and is observed by a fourth. These are the upstream author's portfolio infrastructure — useful context for the design decisions, but none of them is required to use or fork the skill (`llmfit` remains an optional PATH check either way).

[`local-brain`](https://github.com/IsmaelMartinez/local-brain) is the source of the framing this skill operationalises. The core finding — local models are strong summarisers and weak agents, so delegation is a shell pipe rather than an orchestration layer — comes directly from that work, and is why this skill is implemented as bash scripts rather than a framework.

[`ai-model-advisor`](https://github.com/IsmaelMartinez/ai-model-advisor) supplies the tier classification (`code` / `prose` / `reasoning` / `long-context`) and the "smallest model sufficient" environmental philosophy that `pick-model.sh` encodes. When you change the preference order in that script, the rationale you are applying is the one ai-model-advisor argues for: bigger is not better when a 9GB model handles the prompt in half the time.

[`llmfit`](https://github.com/IsmaelMartinez/llmfit) is an optional dependency that enables hardware-aware upgrade suggestions in `audit-models.sh`. When llmfit is not on PATH the audit prints routing only and skips the upgrade-check section with a hint. When it is present, the audit feeds llmfit's hardware-scored recommendations through a first-party-provider filter and surfaces upgrades that beat the installed leader by 3+ points. Patterns the audit script learns about Ollama-vs-HuggingFace name mappings (`hf_stem` normalisation) flow back to llmfit when worth generalising.

[`repo-butler`](https://github.com/IsmaelMartinez/repo-butler) tracks repo health across the portfolio. No integration work is needed here — repo-butler picks up new repos automatically once they exist on GitHub, and this one is now visible to it. It monitors the upstream repo only; forks are not observed and lose nothing by it.

## Maintenance

A monthly reminder to re-run `scripts/audit-models.sh` is automated via [`.github/workflows/monthly-audit-reminder.yml`](.github/workflows/monthly-audit-reminder.yml). The workflow opens a tracking issue on the 1st of each month (idempotent — skips when one is already open) because the audit needs a local `ollama list` and can't run on the hosted runner; `workflow_dispatch` is the manual escape hatch.

## License

MIT — reuse freely.
