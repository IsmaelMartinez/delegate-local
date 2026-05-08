# ADR 0003: Tier preference lists in pick-model.sh

## Status

Accepted.

## Context

Routing a delegated task to a local model requires answering "given this tier, which installed model should run it?" Two designs were considered: a router process that holds a model of hardware, installed set, and historical performance and decides per call (the LiteLLM / OpenRouter shape, scaled down to local), versus a static preference list per tier matched against `ollama list` at call time.

The router optimises for richer decisions — downshifting on short prompts, learning from failures. But none of those degrees of freedom were being used. The four active tiers (`code`, `prose`, `reasoning`, `long-context`) cover every observed delegation, with four more (`vision`, `embedding`, `premium-general`, `reasoning-vision`) scaffolded for capability expansion, and the right model per tier is stable on the order of weeks-to-months. A router would be a long-lived component solving a near-static problem.

## Decision

`scripts/pick-model.sh` holds one substring-matched preference list per tier, ordered highest-capability first. It reads `ollama list`, scans the preferences, and prints the first installed match on stdout. If no preference matches an installed model, it exits 1; it never returns an arbitrary fallback. Routing decisions are data inside this script, not behaviour inside a process.

When the installed model set changes, the user edits the `prefs` arrays in this one file. Tests in `tests/run-tests.sh` assert specific tier-to-model resolutions against mocked `ollama list` output (e.g., that `prose` picks `qwen3.6` ahead of `qwen3-next` when both are installed, encoding the empirical Phase 7 baseline finding).

## Consequences

The routing logic is auditable in 30 lines of bash. The skill has no long-lived processes; every call resolves the model fresh from the current `ollama list`, so installing or removing a model takes effect on the next delegation with no daemon restart.

The cost is that genuinely dynamic routing — "this prompt is small, downshift" — is not possible. That is acceptable: the empirical baseline shows the smallest-sufficient model per tier is the right choice almost always, so a static list converges on the same answer a router would compute. If a future need for per-call dynamic routing emerges, the preference array can become a function without changing call sites. A router would also have introduced a configuration surface (where it lives, how it updates, what it depends on) that bash arrays do not — and that surface is what "premature complexity" looks like for this skill.
