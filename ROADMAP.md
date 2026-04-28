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

## Out of scope

- Code edits, refactors, or feature implementation. Local models are weak agents and the skill description explicitly rejects these. The local-brain finding stands: "they didn't need Smolagents, they needed `git status | ollama run model`".
- Auto-pulling models without confirmation. Multi-GB downloads stay user-decided; the audit script suggests, never installs.
- A general-purpose router that competes with Claude on routing decisions. This skill picks a model within Ollama; it does not decide whether to call Claude vs Ollama. That decision belongs in the skill description, evaluated by Claude itself.
