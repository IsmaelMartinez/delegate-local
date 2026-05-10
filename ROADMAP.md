# Roadmap

The skill works today as a personal tool. To make it dependable for shared use, it needs hardening borrowed from PLG's agent-skills repo, then distribution beyond Claude Code, then capability expansion.

## Next session — priority-ordered

Going-public completed in May 2026 (trigger-eval gate enforced on every PR, community-health files, release-please pipeline, doc-drift cleanup). See `git log`, the GitHub releases page, the per-phase summaries below, and the ADRs under `docs/adr/` for the full PR-by-PR history.

CI trigger-eval quota issue ([#62](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/62)) closed 2026-05-09 by batching all 23 scoring queries into one API call (#66) plus making the step advisory with a 5-minute timeout (#65). Per-run requests went from 23 to 1; the 150 RPD `low`-tier bucket now covers ~150 PR runs/day instead of ~6.

### Training-loop initiative (2026-05-09)

The 2026-05-09 session surfaced the central calibration finding: small/local models need much more handholding than Opus-class — abstract style descriptors yield bullets when the project style is prose, while verbatim-example anchoring + explicit anti-hallucination guards turn that same task into a verbatim-usable HIT. The `delegate-feedback.sh hit|miss` infrastructure (#70) tracks calibration empirically; what's missing is the path from "we learned something" to "future sessions inherit it". Four layers, ordered cheapest-first:

1. **Layer 1 — `prompts/` library + SKILL.md Recipes section.** *Shipped via #72.* One markdown file per recurring task type. Each ships the proven prompt skeleton, the canonical anchors, and the explicit anti-hallucination guards drawn from real session HITs. SKILL.md `## Recipes` section points the agent at the directory; `tests/test-prompts-library.sh` enforces structural validity. Initial recipes: `prompts/commit-message.md`, `prompts/pr-description.md`. Discipline going forward: every recurring HIT graduates to a recipe; every MISS that names a missing recipe gets one filed.

2. **Layer 2 — `delegate.sh --recipe NAME` flag.** *Shipped.* The wrapper takes `--recipe NAME [--var key=value ...]`, loads `prompts/<NAME>.md`, extracts the first fenced block under `## Prompt template`, substitutes each `{{key}}` placeholder from the matching `--var`, and refuses to send a partly-substituted template (unsubstituted placeholders are an exit-2 error listing the missing keys). The implicit `{{stdin}}` placeholder consumes piped context when present. Recipes gain `## Variables` and `## Invocation` sections documenting each placeholder and a copy-pasteable invocation example; `tests/test-prompts-library.sh` enforces every `{{name}}` in a template is documented and that no legacy `<paste ... here>` markers survive. The metrics line carries a `recipe` field for layer-3 telemetry. `DELEGATE_PROMPTS_DIR` env var overrides the recipe directory for tests.

3. **Layer 3 — MCP `recommend_prompt(task)` tool.** The existing `mcp/` server gains a tool that reads the local hit/miss metrics + the prompts library and returns the best-known template for a given task type, optionally inlining recent local-machine HIT examples as live anchors. This is the mechanism that turns the hit/miss log from a passive scoreboard into active training signal — recent successful templates get reinforced. Codex, Cursor, OpenCode all benefit since they speak MCP. Worth building once layer 1 has 6+ recipes and per-recipe hit-rate spread is visible. *Gate reached 2026-05-11: 6 recipes shipped (commit-message, pr-description, summarise-diff, pr-review-reply, release-note, summarise-issue); per-recipe HIT/MISS provenance lives in each recipe's calibration notes. Layer 3 is the next unblocked priority.*

4. **Layer 4 — Cross-machine signal via tagged issues.** A `prompt-pattern` issue label captures recurring MISS patterns the prompts library doesn't cover (task shape, model used, failed output). Issues become the public review surface; a maintainer (or a future PR-bot) graduates an issue into a `prompts/<new>.md` entry once a fix is validated, paired with an eval-set positive that asserts the recipe still produces HIT-class outputs against a pinned model snapshot. Closes the loop empirically — every recurring miss becomes a test case AND a fix instead of evaporating after one conversation.

The deeper insight underneath all four layers: small/local models default to whatever shape is most common in their training (bullets when asked for "concise commit message"); they don't fill in the user's stylistic gaps the way larger models do. The training discipline is to write prompts as if for a junior who needs every detail spelled out, then capture what worked.

### Other open priorities

- **Dogfooding gap probe** continues empirically — eval-set additions p11–p14 shipped (#68), this session's metrics show 7 delegations × 5 HIT / 2 MISS, and the layer-1 recipe library is the concrete fix for the framing-not-eval-set hypothesis. No further explicit action until the next session shows whether recipes plus their SKILL.md pointer change real-session invocation rates.

### Recently shipped from the priority list

- **Director-side test-runner helper** — `scripts/apply-and-test.sh` (44 unit tests, cross-validated against `scorer-v8.py` on all 18 cells of the v8 run matrix). Operationalises the apply-and-test loop the v8 + adversarial scorers all open-coded; emits machine-parseable `VERDICT: PASS|FAIL|PARSE|APPLY|TIMEOUT|REFUSE` (#69).
- **Delegation hit/miss feedback** — `scripts/delegate-feedback.sh` (23 unit tests) plus a `Delegation feedback (hit/miss):` rollup in `metrics-summary.sh`. Append-only feedback rows keyed by `ref_ts`; `reduce`-built lookup with latest-wins on duplicate verdicts. Surfaces calibration over time so prompt anchoring can be measured rather than asserted (#70).
- **Skip-when-unchanged on the CI trigger-eval steps** — the GitHub Models and Anthropic trigger-eval steps in `.github/workflows/ci.yml` short-circuit when neither `SKILL.md` nor `evals/eval-set.json` changed vs the PR base (pull_request) or previous push commit. Most PRs (docs, scripts, tests, ROADMAP, ADRs) touch neither file and now hit zero GitHub Models requests, leaving the 150 RPD bucket entirely free for actual trigger-surface edits (#71).
- **Prompts library** — `prompts/commit-message.md` and `prompts/pr-description.md` calibrated recipes plus `tests/test-prompts-library.sh` (19 assertions) structural-validity gate. Layer 1 of the training-loop initiative (#72).
- **`delegate.sh --recipe NAME [--var k=v ...]`** — wrapper learns to load `prompts/<NAME>.md`, extract the first fenced block under `## Prompt template`, substitute `{{key}}` placeholders from `--var` flags (and `{{stdin}}` from piped context), and exit 2 with a clear error rather than silently sending a partly-substituted template to the model. Recipes pick up `## Variables` and `## Invocation` sections; `tests/test-delegate.sh` gains 20 new assertions (45 total) and `tests/test-prompts-library.sh` gains 8 (27 total). Layer 2 of the training-loop initiative (#73).
- **Recipe library expansion** — `prompts/summarise-diff.md` and `prompts/pr-review-reply.md` added; `prompts/pr-description.md` cut to a single-example default after the 2026-05-10 timeout on the 2-example anchor (with `long-context` tier documented as the escape hatch). Each new recipe was dogfooded against `qwen3.6:35b-a3b-q8_0` and reached HIT status (summarise-diff after a one-revision iteration on closed-verb-list and bullet-padding; pr-review-reply verbatim on first attempt). Library at 4 of 6 recipes after this batch (#80).
- **Layer 3 gate met** — `prompts/release-note.md` and `prompts/summarise-issue.md` added on 2026-05-11. release-note HIT verbatim against PR #80 on first attempt. summarise-issue HIT-with-edits against issue #75: the OMIT-empty-section rule resisted three iterations on `deepseek-r1:32b` (reasoning tier) — v5/v7 directive-rule + contrastive-example pattern that closed the severity-capping gap did NOT fully bind on output-structure conditional rules. Empirical finding logged in the recipe's calibration notes for the next iteration to try a string-level prohibition. Library is now 6 recipes; Layer 3 (MCP `recommend_prompt`) is the next unblocked priority.

Deferred (not in the priority list, pending a concrete trigger): see Phase 10's "Director-side severity reweighting pattern" bullet for the calibration-fallback rationale; monthly scheduled `audit-models.sh` automation (Phase 6 recurring maintenance — no cadence yet).


## Phase 1 — Shipped

All shipped: `SKILL.md` with `name`/`description` frontmatter, `scripts/pick-model.sh` for tier-based model resolution, `scripts/audit-models.sh` with `llmfit`-driven upgrade suggestions filtered to first-party providers, `tests/run-tests.sh` covering unit cases against mocked `ollama` and `llmfit`, `README.md`, and an MIT `LICENSE`.

## Phase 2 — Hardening (borrowed from plg-agent-skills)

All shipped. The validation pipeline runs on every PR via `.github/workflows/ci.yml`. `validate-frontmatter.sh` asserts SKILL.md frontmatter shape. `validate-skill-content.sh` scans for eight categories of dangerous content (`SEC_DISABLE`, `SEC_PERMISSIVE`, `CRED_EXFIL`, `OBFUSC_B64`, `OBFUSC_UNICODE`, `TOOL_BROAD`, `CONFLICT_MARKER`, `URL_EXTERNAL`) with a bash-3-compatible `.content-check-allow` mechanism for justified false positives. `eval-skill-triggers.sh` validates `evals/eval-set.json` shape by default and provides `--ollama` / `--github-models` / `--api` modes for trigger-accuracy scoring against real models. `release-please` drives versioning and CHANGELOG generation per the portfolio convention (also used in `teams-for-linux`). CODEOWNERS, the Claude Code plugin manifest, and ADRs `0001`–`0005` (direct shell piping, first-party-provider filtering, tier preference lists, optional MCP server, reasoning-tier ordering) all shipped here.

## Phase 3 — Distribution and portability

The skill currently only works for Claude Code users. plg-agent-skills shows how to be tool-agnostic.

- [done] AAIF compliance: add `.agents/skills/delegate-to-ollama` as a symlink to the canonical skill, so Copilot, Codex, and OpenCode discover it through the open standard. *(Symlink at `.agents/skills/delegate-to-ollama -> ../..` lands the repo root under the AAIF layout. Verified: `.agents/skills/delegate-to-ollama/SKILL.md` resolves to the canonical `SKILL.md`; `npx skills add` per-agent symlinking remains the fallback for tools that don't speak AAIF.)*
- [done] Publish as a Claude Code plugin: `.claude-plugin/marketplace.json` and `plugin.json` with semver. Lets users install via `claude plugin install delegate-to-ollama`. (Landed in #11.)
- Add an installer script for non-Claude users: shell one-liner that copies the skill into `~/.config/opencode/skills/`, `.github/skills/`, or `.agents/skills/` based on detected agent. *(Superseded by `npx skills add IsmaelMartinez/delegate-to-ollama`, which covers Claude Code, Codex, OpenCode, Cursor, Copilot, and others — see README "Universal" install section.)*
- [done] Document install paths for each tool in `docs/install-claude-code.md`, `docs/install-codex.md`, `docs/install-opencode.md`. (Landed in #46 — three focused guides covering per-agent paths, the per-machine routing override redirect (`DELEGATE_TO_OLLAMA_CONFIG`), the metrics file redirect (`DELEGATE_METRICS_FILE`), and a verification step. README "Per-tool guides" subsection links to all three.)

## Phase 4 — Capability expansion

Your M5 Max with 128GB unified memory has headroom for tiers the skill currently ignores. Each new tier needs a `pick-model.sh` preference list and at least one matching local model installed.

- [scaffolded] Vision tier: route image-bearing tasks (screenshot OCR, photo description, visual triage) to `qwen3-vl:30b-a3b-thinking` or the vision-capable Qwen3.6. Add a `vision` tier to `pick-model.sh`. *(Routing in `pick-model.sh` landed; resolution gated on `ollama pull qwen3-vl:30b-a3b-thinking`. Vision uses `POST /api/generate` with a base64 `images` array — Ollama 0.21's CLI has no `--image` flag, so vision bypasses `delegate.sh` and a wrapper-side image path is deferred until there's a use case to design against.)*
- [scaffolded] Embedding tier: `nomic-embed-text-v1.5` (137M) or `bge-large-en-v1.5` (335M) for local semantic search. Useful for "find the runbook that talks about X" patterns over docs and code. *(Routing landed; `nomic-embed-text` pulled and resolution verified. Uses `POST /api/embed` — `ollama` CLI has no `embed` subcommand — so it bypasses `delegate.sh`.)*
- [scaffolded] Premium-general tier: `Qwen3.5-122B-A10B` for prose tasks where you want more depth than the 80B Qwen3-Next, still at MoE speed. *(Routing landed; resolution gated on `ollama pull qwen3.5:122b-a10b-q4_K_M`. Q4_K_M fits the 128GB headroom; Q8_0 would not. Same call shape as `prose` tier — works through `delegate.sh`.)*
- [scaffolded] Reasoning-with-vision: `phi4-reasoning-vision-15B` for the small slice of tasks that need both. *(Routing landed; resolution gated on `ollama pull phi4-reasoning-vision:15b`. Falls back to `qwen3-vl:30b-a3b-thinking` if available. Same API-only call shape as `vision`.)*
- [done] A `--dry-run` mode in `pick-model.sh` and helper invocations that prints what would happen without spending GPU cycles, useful for debugging routing. (Landed in #16.)

## Phase 5 — Ecosystem integration

All shipped. README "Related projects" cross-links the four sibling repos: `local-brain` (the source of the summariser-not-agent framing this skill operationalises), `ai-model-advisor` (tier vocabulary and the smallest-sufficient principle), `llmfit` (the optional dependency that drives audit-script upgrade suggestions), and `repo-butler` (the portfolio-health observer that tracks this repo automatically once public). The optional Python MCP server lives under `mcp/` exposing `pick_model`, `audit_models`, `list_tiers`, and `list_related_projects` as thin `subprocess.run` wrappers — no reimplemented logic, single source of truth stays in the bash scripts. CI runs `pytest mcp/tests/` independently of the bash validate job. Rationale in `docs/adr/0004-optional-mcp-server.md`.

## Phase 6 — Recurring maintenance

- Monthly scheduled run of `audit-models.sh` to surface new first-party model options and PR a `pick-model.sh` update if anything beats the installed leader by 3+ llmfit points.
- Quarterly trigger-eval re-run to catch description drift if the skill set changes around it.
- llmfit database refresh tracked: `llmfit update` should run before any audit pass so the catalogue reflects the latest HuggingFace state.

## Phase 7 — Empirical accuracy benchmarking

`llmfit` predicts what *should* fit your hardware. It does not measure what each model is actually good at on your real tasks. The experiments framework closes that gap.

- [done] `experiments/runner.sh` runs a fixed set of fixture tasks against any installed Ollama model and writes raw outputs plus timing to `experiments/results/raw/<model-slug>.txt`. Reproducible across model upgrades. (Landed in #1, polished in #10.)
- [done] `experiments/fixtures/` holds the task inputs (currently three: structured doc-drift compare, party-config structural variance, open-ended merge-pattern review). Add more fixtures as new task patterns emerge in real use.
- [done] `experiments/results/<date>-baseline.md` records human-scored accuracy and timing per (model, task) pair against ground truth. The first baseline (2026-04-28) tested phi4-reasoning:plus, qwen3.6:35b-a3b-q8_0, qwen3-next:80b-a3b-instruct-q8_0, and gemma4:31b-it-q8_0. The 2026-05-01 baseline added 3-rep sampling, mechanical T3 scoring, and single-regime timing — all eight rigour gaps from the PR #1 review were closed in that cycle.
- Re-run the baseline whenever `pick-model.sh` preferences change so the tier ordering is empirical, not just llmfit-predicted. A model that scores in the top tier on llmfit but invents findings on the open-ended fixture should be demoted regardless of its predicted score. *(Recurring discipline — applies whenever preferences change.)*
- Future fixtures worth adding: structured field extraction from free-form text (resumes, PR descriptions), commit-message drafting against a known-good reference, JSON shape validation, regex generation with concrete acceptance tests. *(Still open — listed for future fixture additions.)*

## Phase 8 — Observability and feedback

The skill currently runs blind: there is no record of how often it fires, which tier was picked, how long the local model took, or whether the output was usable. Before the skill can claim it saves tokens or routes correctly, it needs data. The four failure modes (wrong tier picked, hallucinated output, delegated when it shouldn't, didn't delegate when it should) split across two layers.

Runtime telemetry — automatic, no agent cooperation required:

- [done] A `scripts/delegate.sh` wrapper that `SKILL.md` teaches Claude to invoke instead of bare `ollama run`. Captures tier, resolved model, prompt size, output size, wall-time, and exit status, then appends one JSON line to `~/.claude/skills/delegate-to-ollama/metrics.jsonl`. Append-only, on by default, opt-out via env var. Estimating tokens-not-sent-to-Anthropic from prompt+output sizes gives a defensible "tokens saved" headline. (Landed in #9.)
- [done] A `scripts/metrics-summary.sh` that reads the JSONL and prints volume per tier, p50/p95 latency, total tokens-avoided, and a frequency-by-model breakdown. Read-only. (Landed in #9.)
- [done] **Experiment-runner telemetry.** `experiments/lib/run_api_cell.sh` now appends one line per cell to the same metrics JSONL (source:"experiment", session=<leaf dir>) with real Ollama token counts from `prompt_eval_count` + `eval_count` rather than char-based estimates. `metrics-summary.sh` groups by `source`, shows per-session rollup for experiment rows, and falls back to `source:"delegate"` for lines written before the field existed. Closes the observability gap where experiment traffic (~18 cells per v-session) was the single biggest consumer of local inference but invisible to the Phase 8 rollup.

Correctness signals — gated in CI or scheduled, not realtime:

- [done] Trigger-accuracy belongs in the Phase 2 `evals/eval-set.json` and `scripts/eval-skill-triggers.sh` runner. That answers "did the skill fire when it should have" and "did it fire when it shouldn't have." (Landed in #8.)
- [done] Output accuracy belongs in the Phase 7 `experiments/` framework. That answers "is the picked model still good enough" per fixture. Rerun whenever `pick-model.sh` preferences change materially. (Landed in #1.)

Explicitly deferred until evidence demands it:

- Agent-supplied verdict (worked/wrong/partial) appended after delegation. Hard to enforce across agents, easy to skip; only worth building if the experiments rerun cadence proves too slow to catch quality regressions. *(Still deferred.)*
- Centralised metrics aggregation across machines. Single-machine JSONL is enough until there is a second machine running the skill. *(Still deferred.)*

## Phase 9 — First-run personalisation

The skill ships one set of `pick-model.sh` preferences and assumes the user's installed model set roughly aligns with the shipped order. In practice every machine has a different mix; the skill should adapt itself to the host without forcing a repo fork. Prior art (aider's `~/.aider.model.settings.yml` layered config, Continue.dev's `model: AUTODETECT`, SmarterRouter's `setup` wizard, Claude Code's `.claude/settings.local.json` per-user override) all point at the same shape: ship a community default, let users drop a personal override on top, keep the override outside the repo so `git clean` can't eat it.

- [done] **v1: per-user override hook + read-only init script.** `pick-model.sh` sources `${DELEGATE_TO_OLLAMA_CONFIG:-$HOME/.claude/skills/delegate-to-ollama/config.sh}` after the shipped defaults populate `prefs`; the override is plain bash that may reassign `prefs` per tier. Untouched tiers fall through to shipped defaults; an absent override changes nothing. `scripts/init.sh` reads `ollama list`, parses the shipped prefs from `pick-model.sh`'s case statement (single source of truth), and emits a starter override to stdout with installed-first ordering — never auto-writes. README "Personalising routing" subsection documents the flow. 13 new tests cover override-replaces, override-leaves-others-alone, override-absent-defaults-win, dry-run-trace-surfaces-override, and init.sh round-trip.
- llmfit-driven re-ranking. The v1 init.sh preserves shipped order and only promotes installed models; it doesn't yet consult `llmfit recommend --json` to re-rank by hardware fit-score. Worth adding once a user reports that the shipped order is materially wrong for their hardware.
- Metrics-driven size-aware routing. Today `prose` resolves to the same model (`qwen3.6:35b` on the reference host) for a 40-word commit-message body and a 200-word runbook paragraph alike — the field-notes pass on plg-tech-cloudfront-waf flagged that the smallest tasks burn power without a matching quality requirement. The metrics JSONL already records `prompt_chars`, `output_chars`, `duration_ms`, and `exit_status` per call; a small post-processor inside `pick-model.sh` could demote calls below an input/output size threshold to the next-smaller candidate within the same tier when the rolling success rate is at 100%. Out of scope until there is evidence the demotion would not hurt quality on a measurable fixture (Phase 7 framework can answer this); listed here so the idea isn't lost. Pairs naturally with the `delegate.sh` `"still waiting at 30 s…"` diagnostic — both come out of the same field-notes pass.
- Empirical micro-benchmark step. A one-shot run of a tiny fixture per tier (≤200 tokens) against each top-2 candidate would surface per-machine timing so the order is empirical not just llmfit-predicted. Reuses the Phase 7 runner shape with a much smaller fixture set. Deferred until there's evidence that the shipped order needs per-machine tuning beyond promote-installed.
- Auto-invocation on first delegate. v1 requires explicit `bash scripts/init.sh` invocation. The alternative (zero-touch first-run) trades transparency for friction reduction; revisit if telemetry shows users never run init.
- Out of scope for this phase: pulling models the user doesn't already have. Phase 1 audit script never auto-pulls and that property holds for `init` too — it suggests, never installs.

## Phase 10 — Delegation discipline (from 2026-05-03 retrospective)

The 2026-05-03 director-with-worker experiment moved the local model from 1.5/4 to 3.6/4 — within 9% of Haiku 4.5 — by applying four discipline practices: atomic per call, one-shot example, explicit qualifier rules, thinking off. The chain of follow-up probes (v3 through v8 plus a size-floor and an adversarial-test sequence) is logged under `experiments/sessions/2026-05-03-*` and `2026-05-04-*` with per-session `RETROSPECTIVE.md` files. v5 confirmed the directive-rule pattern as a fifth discipline practice; v7 confirmed it is task-shape rather than task-content discipline. v6 found that reasoning architecture beats parameter count and promoted `deepseek-r1:32b` ahead of `phi4-reasoning` in the reasoning tier (rationale captured in `docs/adr/0005-reasoning-tier-ordering.md`); the size-floor probe placed the directive-rule threshold between 9 and 19 GB within the deepseek-r1 family. v8 demonstrated minimal-patch code delegation under SEARCH/REPLACE format at ~250× lower per-cell cost than Opus, and the adversarial chain surfaced the REFUSE-hatch pattern as a sixth discipline-bullet candidate. The chain also disconfirmed two hypotheses: format-schema constrained decoding does not close the calibration gap (v3), and a single counterintuitive example does not move the model's prior (v4).

Skill changes shipped from this chain: `delegate.sh` (`--think=false` default, HTTP-API switch from `ollama run` CLI), `SKILL.md` (Fits / Discipline / tier-routing edits, REFUSE-hatch language, prose/code-contradiction failure mode), `pick-model.sh` (reasoning-tier order with `:32b` substring tightening), and `tests/run-tests.sh` (regression assertion encoding the v6 baseline finding). Upstream contribution to Ollama issue #14645 (format-ignored-when-thinking-disabled) logged on 2026-05-04 with disambiguated negative reproduction.

Still open — **Director-side severity reweighting pattern (fallback).** When calibration is genuinely subjective and shouldn't be hardcoded, the alternative to a directive rule is for the calling agent to accept the model's raw severity and apply qualifier-aware adjustments itself. Document in `SKILL.md` if/when a real consumer reports a calibration disagreement that the directive-rule pattern can't capture.

## Out of scope

- Code edits, refactors, or feature implementation. Local models are weak agents and the skill description explicitly rejects these. The local-brain finding stands: "they didn't need Smolagents, they needed `git status | ollama run model`".
- Auto-pulling models without confirmation. Multi-GB downloads stay user-decided; the audit script suggests, never installs.
- A general-purpose router that competes with Claude on routing decisions. This skill picks a model within Ollama; it does not decide whether to call Claude vs Ollama. That decision belongs in the skill description, evaluated by Claude itself.
