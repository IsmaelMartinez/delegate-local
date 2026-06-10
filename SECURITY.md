# Security Policy

## Reporting a vulnerability

If you find a security issue in this skill, please report it privately rather than opening a public issue. Use GitHub's private vulnerability reporting — "Report a vulnerability" under the Security tab of whichever repository you installed the skill from (for the upstream repo that is [here](https://github.com/IsmaelMartinez/delegate-local/security/advisories/new)). If you need to reach the upstream maintainer directly, email `ismaelmartinez@gmail.com`.

Expect an acknowledgement within a few days. There is no SLA — this is a personal project — but reports are taken seriously and patched as a priority over feature work.

## Scope

The skill itself is two bash scripts and a Python MCP wrapper. It does not store credentials, does not make outbound network calls except to a local Ollama daemon (configurable via `OLLAMA_HOST`, default `http://localhost:11434`) or a local MLX server (configurable via `MLX_HOST`, default `http://localhost:8080`), and does not auto-pull models. The audit script is read-only.

In-scope concerns include shell injection in the bash scripts, command injection through tier names or prompts, malicious content in `SKILL.md` that would alter Claude's behaviour in dangerous ways, secrets exfiltration through the metrics JSONL, and supply-chain issues in the optional `mcp/` Python package's dependencies.

Out of scope: vulnerabilities in Ollama itself, in the local models, in `llmfit`, in agent harnesses (Claude Code, Codex, OpenCode, etc.), or in the host operating system. Report those upstream.

## Trust model: the sourced `config.sh` override

`scripts/pick-model.sh` sources a user-supplied configuration file (default `~/.claude/skills/delegate-local/config.sh`, redirectable via `DELEGATE_LOCAL_CONFIG`), granting arbitrary code execution within the caller's environment to anyone who can write the override path or set the associated environment variable. This design is intentional for single-user developers and mirrors `~/.aiderrc` and `~/.claude/settings.local.json`, but introduces real risk in elevated or shared contexts where the `HOME` directory is not fully controlled — invoked under `sudo`, in a CI runner with a shared `HOME`, or under a service account. Only place an override file you wrote or trust, and do not run the skill under a shared or elevated `HOME` you do not control.

The threat model for this override was analysed in detail during a delegation case study; see [`experiments/sessions/2026-05-03-security-review-delegation/RETROSPECTIVE.md`](experiments/sessions/2026-05-03-security-review-delegation/RETROSPECTIVE.md) (findings F1–F5 enumerate the override-sourcing and `init.sh` generator risks). The decision to keep delegation a plain shell pipe with no orchestration layer — which keeps the runtime surface small enough to audit by reading two scripts — is recorded in [`docs/adr/0001-direct-shell-piping.md`](docs/adr/0001-direct-shell-piping.md).

## What the validation pipeline catches

`scripts/validate-skill-content.sh` scans `SKILL.md` for eight categories of dangerous content on every PR: instructions disabling auth or verification (`SEC_DISABLE`), permissive flags like trust-all or `0.0.0.0/0` (`SEC_PERMISSIVE`), credential exfiltration patterns (`CRED_EXFIL`), base64 / unicode obfuscation (`OBFUSC_B64`, `OBFUSC_UNICODE`), broad tool grants like `allowed-tools: *` (`TOOL_BROAD`), unresolved merge markers (`CONFLICT_MARKER`), and external URLs outside an allowlist (`URL_EXTERNAL`). The trigger eval (`scripts/eval-skill-triggers.sh`) gates frontmatter `description` changes against a set of positive and negative queries. Both run on every PR; neither is a substitute for human review.

If you spot a content-scan category that should exist but does not, please open an issue or PR. The scanner is bash-3-compatible and uses a newline-delimited allowlist for justified false positives.
