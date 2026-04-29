# Roadmap

The skill works today as a personal tool. To make it dependable for shared use, it needs hardening borrowed from PLG's agent-skills repo, then distribution beyond Claude Code, then capability expansion.

## Phase 1 — Shipped

- `SKILL.md` with YAML frontmatter (`name`, `description`).
- `scripts/pick-model.sh` for tier-based model resolution.
- `scripts/audit-models.sh` with `llmfit`-driven upgrade suggestions filtered to first-party providers.
- `tests/run-tests.sh` covering 14 unit cases against mocked `ollama` and `llmfit`.
- `README.md` and MIT `LICENSE`.

## Phase 2 — Hardening (borrowed from plg-agent-skills)

The plg-agent-skills repo enforces a content-safety and validation pipeline that any shared skill should adopt. The patterns matter regardless of where the skill lives.

- `evals/eval-set.json` with tagged trigger queries: at least 8 positive (`exact`, `paraphrase`) and 8 negative (`adjacent`, `unrelated`) prompts. The 20-query set we already drafted in `delegate-to-ollama-workspace/trigger-eval.json` is the seed.
- `scripts/validate-frontmatter.sh` ported from plg-agent-skills's GitLab CI: assert frontmatter exists, has `name` and `description`, and that `name` matches the skill directory.
- `scripts/validate-skill-content.sh` ported from plg-agent-skills: scans SKILL.md for `SEC_DISABLE` (instructions disabling auth/verification/protection), `SEC_PERMISSIVE` (allow-all, trust-all, no-verify, YOLO, `0.0.0.0/0` ingress), `CRED_EXFIL` (curl/wget/nc paired with token/key/secret), `OBFUSC_B64`/`OBFUSC_UNICODE`/`OBFUSC_HEX` (encoded payloads), `TOOL_BROAD` (`allowed-tools: *`), and `URL_EXTERNAL` (URLs outside an allowlist). Provide a `.content-check-allow` mechanism for justified false positives.
- `scripts/eval-skill-triggers.sh` to run the eval set and assert correct triggering behaviour on each release.
- GitHub Actions workflow that runs frontmatter validation, content scan, unit tests, and trigger evals on every PR. Replaces the GitLab CI used in plg-agent-skills.
- Semantic-release with conventional commits, plus `CHANGELOG.md`.
- `CODEOWNERS` (just me to start; useful pattern if anyone else contributes).
- ADRs in `docs/adr/` documenting key design decisions: why direct shell piping over a framework (the local-brain insight), why first-party provider filtering in the audit script, why per-tier preference lists rather than a router process.

## Phase 3 — Distribution and portability

The skill currently only works for Claude Code users. plg-agent-skills shows how to be tool-agnostic.

- AAIF compliance: add `.agents/skills/delegate-to-ollama` as a symlink to the canonical skill, so Copilot, Codex, and OpenCode discover it through the open standard.
- Publish as a Claude Code plugin: `.claude-plugin/marketplace.json` and `plugin.json` with semver. Lets users install via `claude plugin install delegate-to-ollama`.
- Add an installer script for non-Claude users: shell one-liner that copies the skill into `~/.config/opencode/skills/`, `.github/skills/`, or `.agents/skills/` based on detected agent.
- Document install paths for each tool in `docs/install-claude-code.md`, `docs/install-codex.md`, `docs/install-opencode.md`, etc.

## Phase 4 — Capability expansion

Your M5 Max with 128GB unified memory has headroom for tiers the skill currently ignores. Each new tier needs a `pick-model.sh` preference list and at least one matching local model installed.

- Vision tier: route image-bearing tasks (screenshot OCR, photo description, visual triage) to `qwen3-vl:30b-a3b-thinking` or the vision-capable Qwen3.6. Add a `vision` tier to `pick-model.sh`.
- Embedding tier: `nomic-embed-text-v1.5` (137M) or `bge-large-en-v1.5` (335M) for local semantic search. Useful for "find the runbook that talks about X" patterns over docs and code.
- Premium-general tier: `Qwen3.5-122B-A10B` for prose tasks where you want more depth than the 80B Qwen3-Next, still at MoE speed.
- Reasoning-with-vision: `phi4-reasoning-vision-15B` for the small slice of tasks that need both.
- A `--dry-run` mode in `pick-model.sh` and helper invocations that prints what would happen without spending GPU cycles, useful for debugging routing.

## Phase 5 — Ecosystem integration

Tying delegate-to-ollama into the rest of your portfolio compounds its value.

- Cross-link with `local-brain`: it identified the "summariser, not agent" framing this skill operationalises. README should credit and link.
- Cross-link with `ai-model-advisor`: tier classification and "smaller is better" environmental philosophy come from there.
- Cross-link with `llmfit`: the audit script depends on it; surface that prominently and feed back any patterns the audit script learns about Ollama vs HuggingFace name mappings.
- Repo-butler integration: have repo-butler track this repo on the same dashboard as the others. Should pick it up automatically once the GitHub repo exists.
- Optional MCP server wrapping the audit and pick-model scripts so non-Claude tools can query them programmatically rather than shelling out.

## Phase 6 — Recurring maintenance

- Monthly scheduled run of `audit-models.sh` to surface new first-party model options and PR a `pick-model.sh` update if anything beats the installed leader by 3+ llmfit points.
- Quarterly trigger-eval re-run to catch description drift if the skill set changes around it.
- llmfit database refresh tracked: `llmfit update` should run before any audit pass so the catalogue reflects the latest HuggingFace state.

## Phase 7 — Empirical accuracy benchmarking

`llmfit` predicts what *should* fit your hardware. It does not measure what each model is actually good at on your real tasks. The experiments framework closes that gap.

- `experiments/runner.sh` runs a fixed set of fixture tasks against any installed Ollama model and writes raw outputs plus timing to `experiments/results/raw/<model-slug>.txt`. Reproducible across model upgrades.
- `experiments/fixtures/` holds the task inputs (currently three: structured doc-drift compare, party-config structural variance, open-ended merge-pattern review). Add more fixtures as new task patterns emerge in real use.
- `experiments/results/<date>-baseline.md` records human-scored accuracy and timing per (model, task) pair against ground truth. The first baseline (2026-04-28) tested phi4-reasoning:plus, qwen3.6:35b-a3b-q8_0, qwen3-next:80b-a3b-instruct-q8_0, and gemma4:31b-it-q8_0.
- Re-run the baseline whenever `pick-model.sh` preferences change so the tier ordering is empirical, not just llmfit-predicted. A model that scores in the top tier on llmfit but invents findings on the open-ended fixture should be demoted regardless of its predicted score.
- Future fixtures worth adding: structured field extraction from free-form text (resumes, PR descriptions), commit-message drafting against a known-good reference, JSON shape validation, regex generation with concrete acceptance tests.

### Phase 7 follow-ups (from PR #1 review)

The first baseline shipped at N=1 per cell. The findings are directionally useful but several rigour gaps should be closed before the next baseline.

- **Repeat each cell 3–5×** and report mean ± stdev. Local model output is non-deterministic and a single sample is not enough to make routing decisions confidently. With 4 models × 3 tasks that is 36 runs total; affordable.
- **Mechanical T3 scoring.** Replace the human "real / plausible / hallucinated" judgement with a deterministic check: for each concern raised, run the suggested grep/path-existence check and count whether the claim is supported by evidence. Removes the author-bias that the current 0.56 vs 0.06 numbers depend on.
- **Single regime per baseline.** The 2026-04-28 run mixed parallel-with-memory-contention and sequential timings. Future baselines should run all cells under the same regime (sequential, identical FS cache state) so timing comparisons are trustworthy.
- **Ordering test in tests/run-tests.sh.** Add an explicit case that asserts `prose` picks `qwen3.6` ahead of `qwen3-next` when both are installed, so a future preference edit cannot silently re-promote without updating the test.
- **Skill description (frontmatter) update.** The trigger description still lists the same fits and not-fits. Add a not-fit line for open-ended "find anything interesting / suggest improvements / what should we worry about" prompts so Claude reads the warning at trigger time, not just buried in the body.
- **Decouple T3 fixture from a specific repo.** Currently a snapshot of votescot's commit log on 28 April. Re-running the baseline three months later tests "what do these models do on this stale log" instead of "what do they do on a current log". Either snapshot per baseline (with a date in the filename) or generate the T3 fixture dynamically from any local repo at runner time.
- **Suppress raw-output diffs.** Each baseline adds ~2,500 lines of model output. Either `.gitattributes` with `linguist-generated` to suppress diff display, or move raw outputs out of git and keep only the scored markdown.
- **Better runner failure handling.** `body=$(ollama run … || echo "<RUN FAILED>")` swallows real errors silently. Surface a non-zero exit alongside the marker so a downstream scoring step can detect it.
- **Cosmetic output cleanup.** After the perl ANSI strip, raw outputs still have a leading whitespace block from where the spinner sat. Add `sed -E 's/^[[:space:]]+//' | grep -v '^$'` after the perl filter so checked-in outputs are cleanly readable.

## Phase 8 — Observability and feedback

The skill currently runs blind: there is no record of how often it fires, which tier was picked, how long the local model took, or whether the output was usable. Before the skill can claim it saves tokens or routes correctly, it needs data. The four failure modes (wrong tier picked, hallucinated output, delegated when it shouldn't, didn't delegate when it should) split across two layers.

Runtime telemetry — automatic, no agent cooperation required:

- A `scripts/delegate.sh` wrapper that `SKILL.md` teaches Claude to invoke instead of bare `ollama run`. Captures tier, resolved model, prompt size, output size, wall-time, and exit status, then appends one JSON line to `~/.claude/skills/delegate-to-ollama/metrics.jsonl`. Append-only, on by default, opt-out via env var. Estimating tokens-not-sent-to-Anthropic from prompt+output sizes gives a defensible "tokens saved" headline.
- A `scripts/metrics-summary.sh` that reads the JSONL and prints volume per tier, p50/p95 latency, total tokens-avoided, and a frequency-by-model breakdown. Read-only.

Correctness signals — gated in CI or scheduled, not realtime:

- Trigger-accuracy belongs in the Phase 2 `evals/eval-set.json` and `scripts/eval-skill-triggers.sh` runner. That answers "did the skill fire when it should have" and "did it fire when it shouldn't have."
- Output accuracy belongs in the Phase 7 `experiments/` framework. That answers "is the picked model still good enough" per fixture. Rerun whenever `pick-model.sh` preferences change materially.

Explicitly deferred until evidence demands it:

- Agent-supplied verdict (worked/wrong/partial) appended after delegation. Hard to enforce across agents, easy to skip; only worth building if the experiments rerun cadence proves too slow to catch quality regressions.
- Centralised metrics aggregation across machines. Single-machine JSONL is enough until there is a second machine running the skill.

Sequence: build the wrapper + JSONL after Phase 2 CI exists (so trigger-eval correctness is gated first), before Phase 4 capability expansion (so new tiers ship with telemetry from day one).

## Out of scope

- Code edits, refactors, or feature implementation. Local models are weak agents and the skill description explicitly rejects these. The local-brain finding stands: "they didn't need Smolagents, they needed `git status | ollama run model`".
- Auto-pulling models without confirmation. Multi-GB downloads stay user-decided; the audit script suggests, never installs.
- A general-purpose router that competes with Claude on routing decisions. This skill picks a model within Ollama; it does not decide whether to call Claude vs Ollama. That decision belongs in the skill description, evaluated by Claude itself.
