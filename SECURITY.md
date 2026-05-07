# Security Policy

## Reporting a vulnerability

If you find a security issue in this skill, please report it privately rather than opening a public issue. Email `ismaelmartinez@gmail.com` with the details, or use GitHub's [private vulnerability reporting](https://github.com/IsmaelMartinez/delegate-to-ollama/security/advisories/new) for this repository.

Expect an acknowledgement within a few days. There is no SLA — this is a personal project — but reports are taken seriously and patched as a priority over feature work.

## Scope

The skill itself is two bash scripts and a Python MCP wrapper. It does not store credentials, does not make outbound network calls except to a local Ollama daemon (configurable via `OLLAMA_HOST`, default `http://localhost:11434`), and does not auto-pull models. The audit script is read-only.

In-scope concerns include shell injection in the bash scripts, command injection through tier names or prompts, malicious content in `SKILL.md` that would alter Claude's behaviour in dangerous ways, secrets exfiltration through the metrics JSONL, and supply-chain issues in the optional `mcp/` Python package's dependencies.

Out of scope: vulnerabilities in Ollama itself, in the local models, in `llmfit`, in agent harnesses (Claude Code, Codex, OpenCode, etc.), or in the host operating system. Report those upstream.

## What the validation pipeline catches

`scripts/validate-skill-content.sh` scans `SKILL.md` for eight categories of dangerous content on every PR: instructions disabling auth or verification (`SEC_DISABLE`), permissive flags like trust-all or `0.0.0.0/0` (`SEC_PERMISSIVE`), credential exfiltration patterns (`CRED_EXFIL`), base64 / unicode obfuscation (`OBFUSC_B64`, `OBFUSC_UNICODE`), broad tool grants like `allowed-tools: *` (`TOOL_BROAD`), unresolved merge markers (`CONFLICT_MARKER`), and external URLs outside an allowlist (`URL_EXTERNAL`). The trigger eval (`scripts/eval-skill-triggers.sh`) gates frontmatter `description` changes against a set of positive and negative queries. Both run on every PR; neither is a substitute for human review.

If you spot a content-scan category that should exist but does not, please open an issue or PR. The scanner is bash-3-compatible and uses a newline-delimited allowlist for justified false positives.
