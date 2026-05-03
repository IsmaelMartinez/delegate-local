# experiments/lib

Shared helpers for experiment runner scripts under `experiments/sessions/*/runner-*.sh`. Source `run_api_cell.sh` from a runner to get the hardened defaults that the v3-through-v7 experiment chain established as the right shape, instead of re-inventing the same three bugs each time.

## What this exists to prevent

Three bugs were caught one PR at a time across the v3/v4/v6/v7 runners:

1. **`date +%s` precision (caught on PR #26).** Second-level resolution is 50–100% error margin for the 1–2 second cell durations these experiments produce. Switched to `perl -MTime::HiRes=time` for ms precision.
2. **`curl -s` without `--fail` (caught on PR #29).** HTTP errors from the Ollama daemon (404 model-not-found, 500 server hiccup) silently produce empty output that `jq -r '.response // ""'` returns as an empty string. The runner then writes a 0-byte cell file with no signal that anything went wrong. Switched to `curl -sS --fail` so HTTP errors propagate as non-zero exit under `set -euo pipefail`.
3. **`None == None` in score_st1 (caught on PR #27, backported on PR #28).** Not a runner concern but a scorer concern. New scorers paired with new runners should require the id to be a known finding before comparing the answer field, so a malformed `{}` dict doesn't count as a correct match.

## Using the lib

Source the script from your runner:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/run_api_cell.sh"

# ... define your model list, prompt, output dir ...

for model in $models; do
  for rep in 1 2 3; do
    out="my-runs/${model}-r${rep}.txt"
    run_api_cell "$model" "$prompt" "$out"
    echo "  [${model} r${rep}] ${CELL_DUR_MS}ms, ${CELL_BYTES}B"
    # write timing tsv row...
  done
done
```

The lib provides:

- `now_ms` — print Unix epoch milliseconds.
- `run_api_cell <model> <prompt> <out_file> [<extras_json>]` — call Ollama's `/api/generate` with `stream:false`, `think:false`, `temperature:0`, and `curl -sS --fail`. Sets `CELL_DUR_MS` and `CELL_BYTES` after returning.

The optional `extras_json` argument merges into the request payload, so format-schema decoding (v3 pattern) or one-off think/temperature overrides are still expressible:

```bash
schema='{"type":"array","items":{...}}'
run_api_cell "$model" "$prompt" "$out" "{\"format\":$schema}"
```

## What's not in scope

- Scorer scaffolding. Scorers vary per experiment (different ground truths, different output shapes); a shared scorer template would constrain too much. The discipline that scorer-v2/v3/v6 settled on — guard `o.get("id") in GT` before comparing — is documented as a checklist item but each scorer is hand-written.
- Model selection or `ollama stop` orchestration. Each runner picks its own model list and decides whether to stop between models. The lib stays on the per-cell API call.
- Retry logic on HTTP failures. With `--fail`, the runner aborts on the first failure, which is the right behaviour for an experiment session — silent retries hide real issues. If a future use case demands retries, add it as an opt-in.

## Checklist for a new runner

- [ ] Source `run_api_cell.sh` from the lib path
- [ ] `set -euo pipefail` at the top
- [ ] ms timing (use `now_ms` or `CELL_DUR_MS` after `run_api_cell`)
- [ ] `curl -sS --fail` (built in via `run_api_cell`)
- [ ] `ollama stop` between models if cold-load timing matters
- [ ] Pair with a scorer that guards id lookups before comparing answer fields
- [ ] Output one cell file per (model, rep) under `<session>/<runs-dir>/`
- [ ] Append timing TSV row per cell with `duration_ms` (not `seconds`) column
