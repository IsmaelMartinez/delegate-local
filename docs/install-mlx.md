# Install — MLX backend (Apple Silicon)

The skill routes through Ollama by default. On Apple Silicon, `mlx-lm` is an alternative inference runtime that uses Apple's native Metal kernels and unified-memory-aware KV cache. For the same Q8 model, MLX is typically 10–30 % lighter on memory and faster on prefill than Ollama's llama.cpp backend. This guide covers the install steps plus the lifecycle differences vs Ollama.

## Requirements

- Apple Silicon Mac (M1 or later). MLX has no CUDA path.
- `pipx` (`brew install pipx` if you don't have it) — installs `mlx-lm` as an isolated CLI tool rather than polluting your system Python.
- Enough disk space for the model weights. Q8 35B models are ~35 GB; 4-bit equivalents are ~18 GB.

The skill itself doesn't need a separate install — the existing `npx skills add` flow already lands the bash scripts. Only the MLX runtime is an additional dependency.

## Install `mlx-lm`

```bash
pipx install mlx-lm
```

This gives you `mlx_lm.generate` (one-shot CLI), `mlx_lm.server` (OpenAI-compatible HTTP server), `mlx_lm.manage` (cache management), and others. The skill uses the server.

## Pull a model

MLX models live on HuggingFace under the `mlx-community` org. Pull a model that matches one of the tier preferences (run `bash scripts/pick-model.sh --dry-run prose` to see the prefs list). For the prose tier on the reference host:

```bash
# 8-bit Q8 — matches the Ollama qwen3.6:35b-a3b-q8_0 in precision
huggingface-cli download mlx-community/Qwen3.6-35B-A3B-Instruct-8bit

# Or 4-bit — roughly half the size, slightly lower accuracy
huggingface-cli download mlx-community/Qwen3.6-35B-A3B-Instruct-4bit
```

`huggingface-cli` lands the weights under `~/.cache/huggingface/hub/models--mlx-community--<name>/snapshots/<hash>/`. `pick-model.sh` scans that directory when `DELEGATE_BACKEND=mlx` is set, so the model is discoverable immediately after the download finishes.

## Start the server

Unlike `ollama serve`, `mlx_lm.server` doesn't run as a system daemon — you start it manually for your session:

```bash
mlx_lm.server --port 8080 &
```

Leave it running in the background. The first request triggers model load (5–15 s for a 35B model); subsequent requests use the warm cache.

If you want a specific model pinned at startup pass `--model mlx-community/Qwen3.6-35B-A3B-Instruct-8bit`. Without `--model`, the server loads whichever model name arrives in the first POST body — useful when the tier you pick varies across calls.

## Route a delegation through MLX

```bash
DELEGATE_BACKEND=mlx bash scripts/delegate.sh prose "Summarise this paragraph in two sentences." </path/to/some.txt
```

`pick-model.sh` resolves the tier against the MLX hub cache; `delegate.sh` posts to `http://localhost:8080/v1/chat/completions` (override via `MLX_HOST`) and parses `.choices[0].message.content`. The payload includes `chat_template_kwargs: {enable_thinking: false}` so reasoning-capable models like Qwen3.6 emit their answer in `content` rather than the reasoning trace (set `DELEGATE_THINK=true` to flip it on per-call). The raw `/v1/completions` endpoint is deliberately avoided — it bypasses the model's chat template and produces whitespace-only output on instruction-tuned models. Every call appends a metrics row tagged `"backend":"mlx"` so `scripts/metrics-summary.sh` can break latency and token totals down per backend.

## Per-tier override

The default `max_tokens` for MLX delegations is 4096. Raise it for the `long-context` tier or for verbose models:

```bash
DELEGATE_BACKEND=mlx DELEGATE_MAX_TOKENS=16384 bash scripts/delegate.sh long-context "..."
```

## Verify

After install, the dry-run trace confirms routing:

```bash
DELEGATE_BACKEND=mlx bash scripts/pick-model.sh --dry-run prose
```

The trace shows the backend, the prefs list, the scanned hub directory, and which model matched. If "no preference matched any installed model" comes back, the model name doesn't contain any of the prefs substrings (case-insensitive) — check `huggingface-cli` finished the download and the snapshot directory has weight files.

## Uninstall

```bash
pipx uninstall mlx-lm
rm -rf ~/.cache/huggingface/hub/models--mlx-community--*
```

The skill keeps working — `DELEGATE_BACKEND` defaults back to `ollama` and the existing Ollama path is untouched.
