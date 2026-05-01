# ADR 0001: Direct shell piping over a framework

## Status

Accepted.

## Context

When this skill was first prototyped, the tempting design was an orchestration layer: a router process that owned the conversation between the agent and the local model, with retries, timeouts, structured prompts, response parsing, and routing-decision telemetry. The reference points for that design were Smolagents-style frameworks where a model and a set of tools are stitched together by a controlling loop.

The empirical finding from `local-brain` cut against that. Local models below the frontier are strong at "summarise this thing in front of you" and weak at the agentic tasks (multi-step reasoning, tool calling, deciding what to do next) that frameworks exist to coordinate. A controlling loop around a weak agent produces confident-sounding but wrong outputs faster — it does not fix them. The discriminator was: every successful local-model use observed in practice fit the shape `gather context once, send one prompt, return text`, with no second turn.

A framework optimises for repeated turns and tool dispatch. None of those degrees of freedom were being used.

## Decision

Delegation in this skill is `context | ollama run model`. There is no router process, no retry loop, no structured-prompt abstraction, and no response parser beyond stripping spinner ANSI bytes. The runtime surface is two bash scripts: `pick-model.sh` resolves a tier to a model name, and `delegate.sh` wraps `ollama run` with metrics capture. `SKILL.md` teaches the calling agent (Claude) the pattern; the agent itself is the controller.

A consequence is that the skill cannot do anything `ollama run` cannot do. That is the point. If a task needs more than one prompt, it does not fit and should not be delegated.

## Consequences

The skill is debuggable by reading two short shell scripts. Any user can substitute their own pipeline (different ANSI stripping, a different metrics destination, a different model resolver) without working around abstractions. New tiers are a one-line edit to `pick-model.sh`.

The cost is that capabilities that genuinely need orchestration — multi-step reasoning, tool calling, retry-with-feedback — are explicitly out of scope and remain Claude's responsibility. The "Out of scope" list in `ROADMAP.md` enumerates these. If the local-model capability gap closes enough that frontier-class agentic behaviour runs locally, this decision should be revisited; until then, a framework would be premature complexity.
