# ADR 0002: First-party provider filtering in audit-models.sh

## Status

Accepted.

## Context

`scripts/audit-models.sh` cross-checks installed Ollama models against `llmfit recommend --json` output and surfaces uninstalled models that beat the installed leader by 3+ llmfit points. `llmfit` itself indexes the HuggingFace GGUF catalogue, which is much broader than the Ollama library: it contains every community fine-tune, merge, quantisation variant, and provider rebrand that anyone has uploaded.

Early versions of the audit returned the raw recommendation list, which was dominated by third-party fine-tunes (`TheBloke/`, `bartowski/`, `mradermacher/` variants). Those entries are real on HuggingFace but almost never appear on the Ollama library under the same name, so an "upgrade" suggestion is unactionable — `ollama pull` will not find it. The signal the user actually wants is: among models reachable through `ollama pull <name>`, which beats what I have installed?

## Decision

`audit-models.sh` filters llmfit suggestions to first-party providers only. The current allowlist (see `FIRST_PARTY_FILTER` in the script) is Alibaba (Qwen), Google (Gemma), Meta (Llama), Microsoft (Phi), DeepSeek, Mistral, Zhipu (GLM), and OpenAI. These are the providers whose model names propagate to the Ollama library predictably and where the suggested upgrade can be acted on with a single `ollama pull`.

The 3-point delta threshold for surfacing an upgrade is also intentional. Below that, the difference is noise from llmfit's composite scoring across quality, speed, fit, and context, and would generate suggestions the user would correctly ignore.

## Consequences

The audit's output is shorter and every line is actionable. False negatives are accepted: a community fine-tune that genuinely beats the first-party leader on this hardware would be hidden. That is a smaller cost than the noise it would introduce, and the user can always run `llmfit recommend` directly when they want the unfiltered view.

The filter is a hardcoded list in the script. When a new first-party provider becomes Ollama-library-relevant, the list needs editing — there is no auto-discovery. That is fine: the cadence of new first-party providers is slow, and an over-broad allowlist would defeat the filter's purpose. The `hf_stem` normalisation that strips quant/variant suffixes (`-instruct`, `-fp8`, `-q4_K_M`) supports the same goal independently: actionable suggestions.
