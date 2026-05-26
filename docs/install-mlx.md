# Install — MLX backend (Apple Silicon)

The skill defaults to `DELEGATE_BACKEND=auto` (since 2026-05-13): on every invocation it probes `${MLX_HOST:-http://localhost:8080}/v1/models` with a 1-second timeout, picks MLX if reachable, and falls back to Ollama otherwise. Non-Apple-Silicon hosts and Apple Silicon hosts without `mlx_lm.server` running both fall through to Ollama transparently — the auto default is strictly an opt-in upgrade, not a behaviour change. To force one backend regardless of probe state, set `DELEGATE_BACKEND=ollama` or `DELEGATE_BACKEND=mlx` explicitly.

On Apple Silicon, `mlx-lm` is an alternative inference runtime that uses Apple's native Metal kernels and unified-memory-aware KV cache. For the same Q8 model, MLX is typically 10–30% lighter on memory and faster on prefill than Ollama's llama.cpp backend (measured: 2× faster wall-clock, 25% lighter peak memory on `Qwen3.6-35B-A3B-8bit` — see `experiments/results/2026-05-12-mlx-vs-ollama-v2.md`). This guide covers the install steps plus the lifecycle differences vs Ollama.

## Requirements

- Apple Silicon Mac (M1 or later). MLX has no CUDA path.
- `pipx` (`brew install pipx`) or a Python venv — either keeps `mlx-lm` isolated from your system Python.
- Enough disk space for the model weights. Q8 35B models are ~35 GB; 4-bit equivalents are ~18 GB.

The skill itself doesn't need a separate install — the existing `npx skills add` flow already lands the bash scripts. Only the MLX runtime is an additional dependency.

## Install `mlx-lm`

Via `pipx` (single command, globally available):

```bash
pipx install mlx-lm
```

Or via a Python venv (useful on systems where `pipx` is unavailable or when you want to pin the Python version):

```bash
python3 -m venv ~/venvs/mlx-lm
~/venvs/mlx-lm/bin/pip install mlx-lm
```

With the venv approach, binaries land under `~/venvs/mlx-lm/bin/` (e.g. `~/venvs/mlx-lm/bin/mlx_lm.server`) rather than on PATH. The launchd plist in the auto-start section below uses the full path, so either install method works.

Both give you `mlx_lm.generate` (one-shot CLI), `mlx_lm.server` (OpenAI-compatible HTTP server), `mlx_lm.manage` (cache management), and others. The skill uses the server.

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

### Manual (per-session)

```bash
mlx_lm.server --port 8080 &
```

Leave it running in the background. The first request triggers model load (5–15 s for a 35B model); subsequent requests use the warm cache. Pass `--model mlx-community/Qwen3.6-35B-A3B-8bit` to pin a specific model at startup; without it, the server loads whichever model name arrives in the first POST body.

### Auto-start via launchd (recommended on macOS)

Create a launchd agent so `mlx_lm.server` starts at login and restarts if it crashes. Adjust the `ProgramArguments` path to match your install method. Launchd does not inherit your shell PATH, so always use the absolute path to the binary — `pipx` typically puts it in `~/.local/bin/`, venv in `~/venvs/mlx-lm/bin/`.

Save to `~/Library/LaunchAgents/com.local.mlx-lm-server.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.local.mlx-lm-server</string>
	<key>ProgramArguments</key>
	<array>
		<!-- pipx: use the absolute path, e.g. /Users/YOU/.local/bin/mlx_lm.server -->
		<!-- venv: use the full path, e.g. /Users/YOU/venvs/mlx-lm/bin/mlx_lm.server -->
		<string>/Users/YOU/venvs/mlx-lm/bin/mlx_lm.server</string>
		<string>--model</string>
		<string>mlx-community/Qwen3.6-35B-A3B-8bit</string>
		<string>--port</string>
		<string>8080</string>
		<string>--host</string>
		<string>127.0.0.1</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>/Users/YOU/Library/Logs/mlx-lm-server.log</string>
	<key>StandardErrorPath</key>
	<string>/Users/YOU/Library/Logs/mlx-lm-server.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>HOME</key>
		<string>/Users/YOU</string>
		<key>HF_HOME</key>
		<string>/Users/YOU/.cache/huggingface</string>
	</dict>
</dict>
</plist>
```

Replace `/Users/YOU` with your actual home directory. Then load the agent:

```bash
launchctl load ~/Library/LaunchAgents/com.local.mlx-lm-server.plist
```

Verify it came up:

```bash
curl -s http://localhost:8080/v1/models | jq -r '.data[0].id'
```

To stop it temporarily (e.g. to reclaim memory), unload and reload later:

```bash
launchctl unload ~/Library/LaunchAgents/com.local.mlx-lm-server.plist   # stop
launchctl load   ~/Library/LaunchAgents/com.local.mlx-lm-server.plist   # restart
```

Logs go to `~/Library/Logs/mlx-lm-server.log`. The `KeepAlive` key restarts the server if it crashes; `RunAtLoad` starts it at login. The auto-probe in `delegate.sh` picks it up transparently — no env-var changes needed.

## Route a delegation through MLX

With the auto default in place, simply starting `mlx_lm.server` is enough — the next `delegate.sh` call will probe the server, find it reachable, and route through MLX without any env-var changes:

```bash
mlx_lm.server --port 8080 --model mlx-community/Qwen3.6-35B-A3B-Instruct-8bit &
bash scripts/delegate.sh prose "Summarise this paragraph in two sentences." </path/to/some.txt
```

To force MLX even if the probe would have picked Ollama (e.g. for testing), pass `DELEGATE_BACKEND=mlx` explicitly:

```bash
DELEGATE_BACKEND=mlx bash scripts/delegate.sh prose "Summarise this paragraph in two sentences." </path/to/some.txt
```

`pick-model.sh` resolves the tier against the MLX hub cache; `delegate.sh` posts to `http://localhost:8080/v1/chat/completions` (override via `MLX_HOST`) and parses `.choices[0].message.content`. The payload includes `chat_template_kwargs: {enable_thinking: false}` so reasoning-capable models like Qwen3.6 emit their answer in `content` rather than the reasoning trace (set `DELEGATE_THINK=true` to flip it on per-call). The raw `/v1/completions` endpoint is deliberately avoided — it bypasses the model's chat template and produces whitespace-only output on instruction-tuned models. Every call appends a metrics row tagged `"backend":"mlx"` so `scripts/metrics-summary.sh` can break latency and token totals down per backend.

## Per-tier override

The default `max_tokens` for MLX delegations is 4096. Raise it for the `long-context` tier or for verbose models:

```bash
DELEGATE_BACKEND=mlx DELEGATE_MAX_TOKENS=16384 bash scripts/delegate.sh long-context "..."
```

## What happens on a cross-tier request

`mlx_lm.server` holds one model resident at a time. The first request after install or restart pays a cold-load cost (~4 s for a 35B 8-bit model on the reference M5 Max, measured 2026-05-14). Same-model follow-up requests are warm (~0.2 s setup + completion time). A request that names a different model triggers an eviction-and-reload: the resident model is dropped, the new one is loaded from disk. KV cache does NOT survive a swap.

The reload is partly amortised by the macOS file cache. On the reference hardware, the second time a model is reloaded after eviction it costs roughly 1.6 s, down from ~4 s on the first cold-load. After that the cost stays in the ~1.6 s window as long as the OS file cache is not under pressure from other workloads. In practice this means a mixed-tier session pays a one-time ~4 s wait the first time it crosses each tier boundary, and ~1.6 s on every subsequent crossing. Linux MLX builds may produce different numbers — the file-cache amortisation observed here is macOS-specific.

If your workload mixes tiers in fast succession and the cumulative wait is noticeable, the rationale for not running a second `mlx_lm.server` instance per tier (which would eliminate the swap cost entirely at the cost of holding two models in unified memory simultaneously) is in [`docs/adr/0006-defer-multi-tier-resident-mlx.md`](adr/0006-defer-multi-tier-resident-mlx.md). The numbers above are the empirical reason the multi-resident design was deferred; if your numbers differ materially on different hardware, the ADR names the conditions under which to revisit.

## Verify

After install, the dry-run trace confirms routing:

```bash
DELEGATE_BACKEND=mlx bash scripts/pick-model.sh --dry-run prose
```

The trace shows the backend, the prefs list, the scanned hub directory, and which model matched. If "no preference matched any installed model" comes back, the model name doesn't contain any of the prefs substrings (case-insensitive) — check `huggingface-cli` finished the download and the snapshot directory has weight files.

## Stop the server (reclaim memory)

`mlx_lm.server` keeps the model weights resident in unified memory between requests — that is what makes the second-request latency a fraction of the first. For a 35B 8-bit model that's ~36 GB held resident. For occasional users with other memory-hungry apps running, stop the server between sessions.

If running via launchd:

```bash
launchctl unload ~/Library/LaunchAgents/com.local.mlx-lm-server.plist
```

If running manually:

```bash
pkill -f "mlx_lm.server"
```

The auto default will then probe, find nothing reachable, and route the next `delegate.sh` call through Ollama transparently. No env-var changes needed.

## Uninstall

```bash
pipx uninstall mlx-lm
rm -rf ~/.cache/huggingface/hub/models--mlx-community--*
```

The skill keeps working — auto-probing finds no MLX server, falls back to Ollama, and the existing Ollama path is untouched.
