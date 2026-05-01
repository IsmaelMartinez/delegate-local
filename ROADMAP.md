# Roadmap

The skill works today as a personal tool. To make it dependable for shared use, it needs hardening borrowed from PLG's agent-skills repo, then distribution beyond Claude Code, then capability expansion.

## Phase 1 — Shipped

- [done] `SKILL.md` with YAML frontmatter (`name`, `description`).
- [done] `scripts/pick-model.sh` for tier-based model resolution.
- [done] `scripts/audit-models.sh` with `llmfit`-driven upgrade suggestions filtered to first-party providers.
- [done] `tests/run-tests.sh` covering 14 unit cases against mocked `ollama` and `llmfit`. (Now 15 cases after the prose-ordering follow-up landed in #8.)
- [done] `README.md` and MIT `LICENSE`.

## Phase 2 — Hardening (borrowed from plg-agent-skills)

The plg-agent-skills repo enforces a content-safety and validation pipeline that any shared skill should adopt. The patterns matter regardless of where the skill lives.

- [done] `evals/eval-set.json` with tagged trigger queries: at least 8 positive (`exact`, `paraphrase`) and 8 negative (`adjacent`, `unrelated`) prompts. The 20-query set we already drafted in `delegate-to-ollama-workspace/trigger-eval.json` is the seed. (Landed in #8 with 10 positive / 13 negative.)
- [done] `scripts/validate-frontmatter.sh` ported from plg-agent-skills's GitLab CI: assert frontmatter exists, has `name` and `description`, and that `name` matches the skill directory. (Landed in #8.)
- [done] `scripts/validate-skill-content.sh` ported from plg-agent-skills: scans SKILL.md for `SEC_DISABLE` (instructions disabling auth/verification/protection), `SEC_PERMISSIVE` (allow-all, trust-all, no-verify, YOLO, `0.0.0.0/0` ingress), `CRED_EXFIL` (curl/wget/nc paired with token/key/secret), `OBFUSC_B64`/`OBFUSC_UNICODE`/`OBFUSC_HEX` (encoded payloads), `TOOL_BROAD` (`allowed-tools: *`), and `URL_EXTERNAL` (URLs outside an allowlist). Provide a `.content-check-allow` mechanism for justified false positives. (Landed in #8; OBFUSC_HEX intentionally omitted as noted in the script.)
- [done] `scripts/eval-skill-triggers.sh` to run the eval set and assert correct triggering behaviour on each release. (Landed in #8: shape mode by default, `--api` mode gated on `ANTHROPIC_API_KEY`.)
- [done] GitHub Actions workflow that runs frontmatter validation, content scan, unit tests, and trigger evals on every PR. Replaces the GitLab CI used in plg-agent-skills. (Landed in #8 as `.github/workflows/ci.yml`.)
- Semantic-release with conventional commits, plus `CHANGELOG.md`. *(Still open — conventional-commit prefixes are in use but no automated release pipeline yet.)*
- [done] `CODEOWNERS` (just me to start; useful pattern if anyone else contributes). (Landed in #11.)
- [done] ADRs in `docs/adr/` documenting key design decisions: why direct shell piping over a framework (the local-brain insight), why first-party provider filtering in the audit script, why per-tier preference lists rather than a router process.

## Phase 3 — Distribution and portability

The skill currently only works for Claude Code users. plg-agent-skills shows how to be tool-agnostic.

- AAIF compliance: add `.agents/skills/delegate-to-ollama` as a symlink to the canonical skill, so Copilot, Codex, and OpenCode discover it through the open standard. *(Still open — currently relying on the universal `npx skills add` path documented in README, which symlinks per-agent rather than via AAIF directly.)*
- [done] Publish as a Claude Code plugin: `.claude-plugin/marketplace.json` and `plugin.json` with semver. Lets users install via `claude plugin install delegate-to-ollama`. (Landed in #11.)
- Add an installer script for non-Claude users: shell one-liner that copies the skill into `~/.config/opencode/skills/`, `.github/skills/`, or `.agents/skills/` based on detected agent. *(Superseded by `npx skills add IsmaelMartinez/delegate-to-ollama`, which covers Claude Code, Codex, OpenCode, Cursor, Copilot, and others — see README "Universal" install section.)*
- Document install paths for each tool in `docs/install-claude-code.md`, `docs/install-codex.md`, `docs/install-opencode.md`, etc. *(Still open — README currently covers the universal and manual-copy paths; per-tool dedicated docs not yet written.)*

## Phase 4 — Capability expansion

Your M5 Max with 128GB unified memory has headroom for tiers the skill currently ignores. Each new tier needs a `pick-model.sh` preference list and at least one matching local model installed.

- [scaffolded] Vision tier: route image-bearing tasks (screenshot OCR, photo description, visual triage) to `qwen3-vl:30b-a3b-thinking` or the vision-capable Qwen3.6. Add a `vision` tier to `pick-model.sh`. *(Routing in `pick-model.sh` landed; resolution gated on `ollama pull qwen3-vl:30b-a3b-thinking`. Vision uses `POST /api/generate` with a base64 `images` array — Ollama 0.21's CLI has no `--image` flag, so vision bypasses `delegate.sh` and a wrapper-side image path is deferred until there's a use case to design against.)*
- [scaffolded] Embedding tier: `nomic-embed-text-v1.5` (137M) or `bge-large-en-v1.5` (335M) for local semantic search. Useful for "find the runbook that talks about X" patterns over docs and code. *(Routing landed; `nomic-embed-text` pulled and resolution verified. Uses `POST /api/embed` — `ollama` CLI has no `embed` subcommand — so it bypasses `delegate.sh`.)*
- [scaffolded] Premium-general tier: `Qwen3.5-122B-A10B` for prose tasks where you want more depth than the 80B Qwen3-Next, still at MoE speed. *(Routing landed; resolution gated on `ollama pull qwen3.5:122b-a10b-q4_K_M`. Q4_K_M fits the 128GB headroom; Q8_0 would not. Same call shape as `prose` tier — works through `delegate.sh`.)*
- [scaffolded] Reasoning-with-vision: `phi4-reasoning-vision-15B` for the small slice of tasks that need both. *(Routing landed; resolution gated on `ollama pull phi4-reasoning-vision:15b`. Falls back to `qwen3-vl:30b-a3b-thinking` if available. Same API-only call shape as `vision`.)*
- [done] A `--dry-run` mode in `pick-model.sh` and helper invocations that prints what would happen without spending GPU cycles, useful for debugging routing. (Landed in #16.)

## Phase 5 — Ecosystem integration

Tying delegate-to-ollama into the rest of your portfolio compounds its value.

- [done] Cross-link with `local-brain`: it identified the "summariser, not agent" framing this skill operationalises. README should credit and link. (README "Related projects" paragraph 1 — links to the repo and credits the framing.)
- [done] Cross-link with `ai-model-advisor`: tier classification and "smaller is better" environmental philosophy come from there. (README "Related projects" paragraph 2 — credits tier vocabulary and the smallest-sufficient principle.)
- [done] Cross-link with `llmfit`: the audit script depends on it; surface that prominently and feed back any patterns the audit script learns about Ollama vs HuggingFace name mappings. (README "Related projects" paragraph 3 — describes the optional dependency and the `hf_stem` feedback loop.)
- [done] Repo-butler integration: have repo-butler track this repo on the same dashboard as the others. Should pick it up automatically once the GitHub repo exists. (README "Related projects" paragraph 4 — confirms repo-butler picks it up automatically; no integration code required here.)
- [done] Optional MCP server wrapping the audit and pick-model scripts so non-Claude tools can query them programmatically rather than shelling out. *(Python package under `mcp/`, exposes `pick_model` / `audit_models` / `list_tiers` via the official `mcp` SDK; thin `subprocess.run` wrapper, no reimplemented logic. CI gains a `mcp-server` job running `pytest mcp/tests/` independently of the bash validate job. Rationale in `docs/adr/0004-optional-mcp-server.md`.)*

## Phase 6 — Recurring maintenance

- Monthly scheduled run of `audit-models.sh` to surface new first-party model options and PR a `pick-model.sh` update if anything beats the installed leader by 3+ llmfit points.
- Quarterly trigger-eval re-run to catch description drift if the skill set changes around it.
- llmfit database refresh tracked: `llmfit update` should run before any audit pass so the catalogue reflects the latest HuggingFace state.

## Phase 7 — Empirical accuracy benchmarking

`llmfit` predicts what *should* fit your hardware. It does not measure what each model is actually good at on your real tasks. The experiments framework closes that gap.

- [done] `experiments/runner.sh` runs a fixed set of fixture tasks against any installed Ollama model and writes raw outputs plus timing to `experiments/results/raw/<model-slug>.txt`. Reproducible across model upgrades. (Landed in #1, polished in #10.)
- [done] `experiments/fixtures/` holds the task inputs (currently three: structured doc-drift compare, party-config structural variance, open-ended merge-pattern review). Add more fixtures as new task patterns emerge in real use.
- [done] `experiments/results/<date>-baseline.md` records human-scored accuracy and timing per (model, task) pair against ground truth. The first baseline (2026-04-28) tested phi4-reasoning:plus, qwen3.6:35b-a3b-q8_0, qwen3-next:80b-a3b-instruct-q8_0, and gemma4:31b-it-q8_0.
- Re-run the baseline whenever `pick-model.sh` preferences change so the tier ordering is empirical, not just llmfit-predicted. A model that scores in the top tier on llmfit but invents findings on the open-ended fixture should be demoted regardless of its predicted score. *(Recurring discipline — applies whenever preferences change.)*
- Future fixtures worth adding: structured field extraction from free-form text (resumes, PR descriptions), commit-message drafting against a known-good reference, JSON shape validation, regex generation with concrete acceptance tests. *(Still open — listed for future fixture additions.)*

### Phase 7 follow-ups (from PR #1 review)

The first baseline shipped at N=1 per cell. The findings are directionally useful but several rigour gaps should be closed before the next baseline.

- [done] **Repeat each cell 3–5×** and report mean ± stdev. Local model output is non-deterministic and a single sample is not enough to make routing decisions confidently. With 4 models × 3 tasks that is 36 runs total; affordable. *(Tooling: `runner.sh --reps N` + `experiments/run-baseline.sh`. Baseline `experiments/results/2026-05-01-baseline.md` ran 5 models × 3 tasks × 3 reps = 45 cells with mean ± stdev per cell.)*
- [done] **Mechanical T3 scoring.** Replace the human "real / plausible / hallucinated" judgement with a deterministic check: for each concern raised, run the suggested grep/path-existence check and count whether the claim is supported by evidence. Removes the author-bias that the current 0.56 vs 0.06 numbers depend on. *(`experiments/score-t3.sh` deterministic citation-rate scorer; applied in the 2026-05-01 baseline. Major finding: phi4-reasoning's T3 score is wide-variance (0.08–0.77, stdev 0.31), and the 2026-04-28 single-shot value of 0.06 sampled the bad end of the distribution.)*
- [done] **Single regime per baseline.** The 2026-04-28 run mixed parallel-with-memory-contention and sequential timings. Future baselines should run all cells under the same regime (sequential, identical FS cache state) so timing comparisons are trustworthy. *(`experiments/run-baseline.sh` enforces sequential with `ollama stop` between models. 2026-05-01 baseline ran under this regime; per-task timings are now trustworthy.)*
- [done] **Ordering test in tests/run-tests.sh.** Add an explicit case that asserts `prose` picks `qwen3.6` ahead of `qwen3-next` when both are installed, so a future preference edit cannot silently re-promote without updating the test. (Landed in #8 as test 7b.)
- [done] **Skill description (frontmatter) update.** The trigger description still lists the same fits and not-fits. Add a not-fit line for open-ended "find anything interesting / suggest improvements / what should we worry about" prompts so Claude reads the warning at trigger time, not just buried in the body. (Landed in #10.)
- [done] **Decouple T3 fixture from a specific repo.** Currently a snapshot of votescot's commit log on 28 April. Re-running the baseline three months later tests "what do these models do on this stale log" instead of "what do they do on a current log". Either snapshot per baseline (with a date in the filename) or generate the T3 fixture dynamically from any local repo at runner time. *(Fixture renamed to `task-3-merge-patterns-2026-04-28.txt`; both `runner.sh` and `score-t3.sh` accept `--t3-snapshot DATE`. 2026-05-01 baseline reused the 2026-04-28 snapshot deliberately so the comparison-to-prior-baseline is apples-to-apples; the next baseline can ship its own dated snapshot. Dynamic generation deferred.)*
- [done] **Suppress raw-output diffs.** Each baseline adds ~2,500 lines of model output. Either `.gitattributes` with `linguist-generated` to suppress diff display, or move raw outputs out of git and keep only the scored markdown. (Landed in #10 via `.gitattributes`.)
- [done] **Better runner failure handling.** `body=$(ollama run … || echo "<RUN FAILED>")` swallows real errors silently. Surface a non-zero exit alongside the marker so a downstream scoring step can detect it. (Landed in #10 via PIPESTATUS / `RUN_STATUS` line.)
- [done] **Cosmetic output cleanup.** After the perl ANSI strip, raw outputs still have a leading whitespace block from where the spinner sat. Add `sed -E 's/^[[:space:]]+//' | grep -v '^$'` after the perl filter so checked-in outputs are cleanly readable. (Landed in #10 — implemented as `awk 'NF || seen { seen=1; print }'`.)

## Phase 8 — Observability and feedback

The skill currently runs blind: there is no record of how often it fires, which tier was picked, how long the local model took, or whether the output was usable. Before the skill can claim it saves tokens or routes correctly, it needs data. The four failure modes (wrong tier picked, hallucinated output, delegated when it shouldn't, didn't delegate when it should) split across two layers.

Runtime telemetry — automatic, no agent cooperation required:

- [done] A `scripts/delegate.sh` wrapper that `SKILL.md` teaches Claude to invoke instead of bare `ollama run`. Captures tier, resolved model, prompt size, output size, wall-time, and exit status, then appends one JSON line to `~/.claude/skills/delegate-to-ollama/metrics.jsonl`. Append-only, on by default, opt-out via env var. Estimating tokens-not-sent-to-Anthropic from prompt+output sizes gives a defensible "tokens saved" headline. (Landed in #9.)
- [done] A `scripts/metrics-summary.sh` that reads the JSONL and prints volume per tier, p50/p95 latency, total tokens-avoided, and a frequency-by-model breakdown. Read-only. (Landed in #9.)

Correctness signals — gated in CI or scheduled, not realtime:

- [done] Trigger-accuracy belongs in the Phase 2 `evals/eval-set.json` and `scripts/eval-skill-triggers.sh` runner. That answers "did the skill fire when it should have" and "did it fire when it shouldn't have." (Landed in #8.)
- [done] Output accuracy belongs in the Phase 7 `experiments/` framework. That answers "is the picked model still good enough" per fixture. Rerun whenever `pick-model.sh` preferences change materially. (Landed in #1.)

Explicitly deferred until evidence demands it:

- Agent-supplied verdict (worked/wrong/partial) appended after delegation. Hard to enforce across agents, easy to skip; only worth building if the experiments rerun cadence proves too slow to catch quality regressions. *(Still deferred.)*
- Centralised metrics aggregation across machines. Single-machine JSONL is enough until there is a second machine running the skill. *(Still deferred.)*

Sequence: build the wrapper + JSONL after Phase 2 CI exists (so trigger-eval correctness is gated first), before Phase 4 capability expansion (so new tiers ship with telemetry from day one).

## Out of scope

- Code edits, refactors, or feature implementation. Local models are weak agents and the skill description explicitly rejects these. The local-brain finding stands: "they didn't need Smolagents, they needed `git status | ollama run model`".
- Auto-pulling models without confirmation. Multi-GB downloads stay user-decided; the audit script suggests, never installs.
- A general-purpose router that competes with Claude on routing decisions. This skill picks a model within Ollama; it does not decide whether to call Claude vs Ollama. That decision belongs in the skill description, evaluated by Claude itself.
