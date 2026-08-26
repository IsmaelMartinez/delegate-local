#!/usr/bin/env bash
# Wrap a local-LLM HTTP endpoint (Ollama by default, MLX optional) with
# tier-based model selection and per-invocation metrics. Use this instead of
# bare `ollama run` so every delegation is observable and the response is
# parser-clean (no CLI cursor rewrites or spinner ANSI mixed into stdout).
#
# Usage:
#   delegate.sh <tier> "<prompt>"                            # context comes from stdin
#   echo "..." | delegate.sh prose "..."                     # explicit pipe
#   delegate.sh --recipe NAME [--var k=v ...] ["<prompt>"]
#                                # prepend prompts/NAME.md template with {{k}} subs.
#                                # The tier comes from the recipe's frontmatter
#                                # `tier:`; pass --tier NAME to override it.
#
# Tiers: code | prose | reasoning | long-context | vision | embedding |
#        premium-general | reasoning-vision  (scripts/pick-model.sh is the source
#        of truth — this list was four names short, so a valid --tier value looked
#        invalid to anyone reading the header)
#
# Recipe flag (layer 2 of the training-loop initiative):
#   --recipe NAME            load prompts/<NAME>.md, extract its '## Prompt
#                            template' fenced block, prepend it to the input.
#   --recipe auto            infer the recipe from the piped context (#277):
#                            a unified diff on stdin -> commit-message, with
#                            diff_stat computed from the piped diff and
#                            recent_commits backfilled from git log when not
#                            passed. Errors (exit 2) if the context is not a
#                            recognised diff — never a silent guess.
#   --var key=value          substitute {{key}} placeholders inside the
#                            recipe template. Repeat for multiple variables.
#                            Values may contain newlines and special chars.
#                            A {{stdin}} placeholder is auto-substituted with
#                            stdin content when stdin is piped in.
#   Without --recipe both positionals are required. With one, the tier comes
#   from the recipe's frontmatter `tier:` and <prompt> is optional (the recipe
#   carries the instruction). A lone positional on a recipe call is read as the
#   tier only when it exactly matches a known tier name, otherwise as the
#   prompt — 17 of 20 recipes pass a trailing reinforcement prompt (#411).
#
#   Optional frontmatter `inputs:` block (Phase 12 Track B, issue #161) lets
#   a recipe declare flat `key: type` pairs that get validated pre-flight.
#   Supported types: integer, string, integer?, string? (the `?` suffix means
#   optional). Recipes without a frontmatter inputs: block skip the check
#   (lazy migration). Undeclared --var keys pass through untouched (strict
#   mode deferred). Type-check failure or a missing required input exits 2
#   with a clear error before the model is contacted.
#
# Env:
#   DELEGATE_LOCAL_NO_METRICS=1              # opt out of metrics logging
#                                           #   (back-compat: DELEGATE_TO_OLLAMA_NO_METRICS
#                                           #   is accepted if the new name is unset)
#   DELEGATE_LOCAL_NO_VERDICT_NUDGE=1        # silence the one-line stderr
#                                           #   (back-compat: DELEGATE_TO_OLLAMA_NO_VERDICT_NUDGE
#                                           #   is accepted if the new name is unset)
#                                           #   reminder printed after each
#                                           #   successful call pointing at
#                                           #   delegate-feedback.sh. Off-by-
#                                           #   default; the nudge fires
#                                           #   unconditionally on success
#                                           #   when metrics are on,
#                                           #   regardless of stdin/stdout
#                                           #   shape (Agent SDK tool calls,
#                                           #   CI scripts, and other non-
#                                           #   TTY callers are the highest-
#                                           #   volume users and their
#                                           #   verdicts are what closes the
#                                           #   training-loop gap — see
#                                           #   issue #149). Three escape
#                                           #   hatches: this env var (opt
#                                           #   out per call), NO_METRICS
#                                           #   (no row to verdict against),
#                                           #   non-zero exit (failure has
#                                           #   no output to judge).
#   DELEGATE_LOCAL_VERDICT_NUDGE_FD=<N>      # redirect the verdict-nudge line
#                                           #   (back-compat: DELEGATE_TO_OLLAMA_VERDICT_NUDGE_FD
#                                           #   is accepted if the new name is unset)
#                                           #   to file descriptor N instead
#                                           #   of fd 2 (stderr). Default
#                                           #   unset → fd 2, preserving the
#                                           #   unconditional-fire behaviour
#                                           #   the #149 reversal pinned. The
#                                           #   escape hatch for parallel-
#                                           #   capture callers (issue #139)
#                                           #   that want clean stdout AND
#                                           #   coverage tracking: redirect
#                                           #   stdout+stderr together into a
#                                           #   single output file and route
#                                           #   the nudge to a separate fd,
#                                           #   e.g.
#                                           #     DELEGATE_LOCAL_VERDICT_NUDGE_FD=3 \
#                                           #     bash delegate.sh prose "X" \
#                                           #     > out.txt 2>&1 3>>nudge.log
#                                           #   GOTCHA: the caller must
#                                           #   redirect fd N to somewhere
#                                           #   (file, pipe, or another fd).
#                                           #   If fd N is closed when the
#                                           #   nudge fires, the write fails
#                                           #   silently — the call still
#                                           #   succeeds but no nudge lands
#                                           #   anywhere. Suppression rules
#                                           #   still apply: NO_VERDICT_NUDGE
#                                           #   wins (no nudge written),
#                                           #   NO_METRICS wins (no row to
#                                           #   verdict), non-zero exit wins
#                                           #   (no output to judge). Valid
#                                           #   values: single-digit positive
#                                           #   integer 1-9. Multi-digit FDs
#                                           #   are rejected because bash 3.2
#                                           #   (the project's portability
#                                           #   floor) does not support the
#                                           #   `{var}>file` form for high
#                                           #   FDs and `>&$N` with N>=10
#                                           #   can silently fail; tightening
#                                           #   validation makes the failure
#                                           #   mode loud. 0 (stdin), negative
#                                           #   numbers, and non-numeric
#                                           #   values exit 2 with a clear
#                                           #   error before the model is
#                                           #   contacted. 1 (stdout) and 2
#                                           #   (stderr / the default) are
#                                           #   both accepted.
#   DELEGATE_PREFLIGHT_TIMEOUT=<s>          # default 10. Only consulted when
#                                           #   --recipe is set. A 1-token
#                                           #   canary probe hits the resolved
#                                           #   model with --max-time S; if
#                                           #   the probe does not return,
#                                           #   exit 3 with a stderr message
#                                           #   listing recovery options
#                                           #   (raise timeout, smaller model,
#                                           #   hand-write) before the full
#                                           #   recipe-shaped request is sent.
#                                           #   Set 0 to disable the canary.
#                                           #   Closes the recipe-stall gap
#                                           #   in issue #110.
#   DELEGATE_REQUEST_TIMEOUT=<s>            # default 600. curl --max-time on
#                                           #   the dispatch POST, paired with
#                                           #   --connect-timeout 5. Bounds the
#                                           #   whole request including cold
#                                           #   model load, not just
#                                           #   generation: 600 preserves
#                                           #   every genuine call in recorded
#                                           #   history (largest: 505 s, of
#                                           #   which 504.6 s was load) while
#                                           #   killing the 3.2-hour runaway.
#   DELEGATE_BASE_URL=<urls>                # space-separated ordered list of
#                                           #   OpenAI-compatible base URLs.
#                                           #   pick-model.sh walks the list
#                                           #   and dispatch posts to {base}/
#                                           #   chat/completions. Defaults to
#                                           #   MLX, Docker Model Runner and
#                                           #   Ollama on their standard ports
#                                           #   — see pick-model.sh, which
#                                           #   owns the default. The metrics
#                                           #   backend label is derived from
#                                           #   the winning URL (mlx / docker /
#                                           #   ollama, else host:port).
#   DELEGATE_NO_PREFLIGHT=1                 # alternate disable for the canary
#                                           #   (equivalent to TIMEOUT=0).
#   DELEGATE_FORCE_FLAKY=1                  # override the recipe-level flaky-
#                                           #   on-model gate (Phase 16 Track
#                                           #   A). When a recipe declares
#                                           #   `flaky_on_models:` in its
#                                           #   frontmatter and the resolved
#                                           #   model matches any listed
#                                           #   substring (case-insensitive),
#                                           #   delegate.sh exits 4 with a
#                                           #   stderr message naming the
#                                           #   recipe's documented mitigation
#                                           #   (typically hand-writing). Set
#                                           #   this env var to send the
#                                           #   request anyway — useful for
#                                           #   capturing fresh evidence the
#                                           #   flaky-class behaviour has
#                                           #   changed across model upgrades.
#   DELEGATE_LOCAL_NO_META=1                 # silence the structured
#                                           #   (back-compat: DELEGATE_TO_OLLAMA_NO_META
#                                           #   is accepted if the new name is unset)
#                                           #   `delegate-meta:` summary line
#                                           #   printed to stderr after each
#                                           #   successful call. SKILL.md
#                                           #   teaches the assistant to read
#                                           #   that line and surface the
#                                           #   model + tokens_local count to
#                                           #   the user, so the line is the
#                                           #   contract surface for "this is
#                                           #   how much we kept local." Off-
#                                           #   by-default; opt out for clean
#                                           #   stderr in batch runs.
#   DELEGATE_LOCAL_DATA_DIR     where per-user data lives
#                               (default ~/.local/share/delegate-local)
#   DELEGATE_METRICS_FILE=<path>            # override metrics destination
#   DELEGATE_PROJECT=<name>                 # state the project the delegation
#                                           #   is FOR, instead of deriving it
#                                           #   from this process's cwd (#342).
#                                           #   Delegating on behalf of repo X
#                                           #   while cd'd into the skill
#                                           #   checkout would otherwise record
#                                           #   project=delegate-local, which
#                                           #   never matches the boundary
#                                           #   hook's own (correct) derivation.
#                                           #   --project NAME wins over this.
#   DELEGATE_PROMPTS_DIR=<path>             # override prompts/ directory
#                                           #   (default: <script_dir>/../prompts)
#   DELEGATE_THINK=true|false               # default false; set true if the
#                                           #   model's chain-of-thought
#                                           #   genuinely helps for the task.
#                                           #   Maps to Ollama's `think` field
#                                           #   and to MLX's
#                                           #   `chat_template_kwargs.enable_thinking`.
#   DELEGATE_STRIP_THINK=1|0                # Strip a leading <think>...</think>
#                                           #   reasoning trace from the response
#                                           #   (drop everything up to and
#                                           #   including the first </think>,
#                                           #   trim leading whitespace) so
#                                           #   structured-output recipes still
#                                           #   parse when a trace-emitting model
#                                           #   leaks the trace into the answer
#                                           #   under think:false. ON by default
#                                           #   for the reasoning tier (which
#                                           #   routes trace-emitting models);
#                                           #   =1 forces it on for any tier; =0
#                                           #   force-disables it even on the
#                                           #   reasoning tier, for a reasoning
#                                           #   recipe whose own output may
#                                           #   contain </think>.
#   MLX_HOST=<url>                          # default http://localhost:8080
#   DOCKER_MODEL_HOST=<url>                 # default http://localhost:12434
#   OLLAMA_HOST=<url>                       # default http://localhost:11434
#                                           #   The three feed the default
#                                           #   DELEGATE_BASE_URL list; see
#                                           #   pick-model.sh, which owns it.
#   DELEGATE_MAX_TOKENS=<int>               # default 4096. The OpenAI
#                                           #   completions shape requires
#                                           #   max_tokens. Raise
#                                           #   for long-context tier or
#                                           #   verbose models.
#   DELEGATE_TEMPERATURE=<float>            # override sampler temperature.
#                                           #   Default for all models is 0
#                                           #   (greedy). Set to opt INTO
#                                           #   non-greedy sampling per-call;
#                                           #   the Alibaba-recommended Qwen
#                                           #   instruct profile is
#                                           #   DELEGATE_TEMPERATURE=0.7
#                                           #   DELEGATE_TOP_P=0.8
#                                           #   DELEGATE_TOP_K=20
#                                           #   DELEGATE_PRESENCE_PENALTY=1.3.
#                                           #   Non-numeric value exits 2.
#   DELEGATE_TOP_P=<float>                  # override top_p. Default unset (no
#                                           #   top_p key sent in payload).
#                                           #   Non-numeric exits 2.
#   DELEGATE_TOP_K=<int>                    # override top_k. Default unset.
#                                           #   Non-numeric exits 2.
#   DELEGATE_PRESENCE_PENALTY=<float>       # override presence_penalty.
#                                           #   Default unset. Non-numeric
#                                           #   exits 2.
#   DELEGATE_OTEL_ENDPOINT=<url>            # Phase 11 Track A (#134). When
#                                           #   set, POST one OTLP/HTTP span
#                                           #   per invocation to this URL
#                                           #   (e.g. https://otlp.example
#                                           #   /v1/traces) after the metrics
#                                           #   row is written. Off when
#                                           #   unset — zero overhead. The
#                                           #   POST is SYNCHRONOUS: a hung
#                                           #   collector adds up to
#                                           #   DELEGATE_OTEL_TIMEOUT seconds
#                                           #   of user-visible latency per
#                                           #   call. If delegations feel
#                                           #   sluggish, set DELEGATE_OTEL
#                                           #   _VERBOSE=1 to see export
#                                           #   failures or unset the
#                                           #   endpoint to disable.
#   DELEGATE_OTEL_TIMEOUT=<s>               # default 5. curl --max-time on
#                                           #   the OTLP POST so a hung
#                                           #   collector cannot block the
#                                           #   caller's pipeline.
#   DELEGATE_OTEL_VERBOSE=1                 # log exporter failures to stderr.
#                                           #   Default silent — a misconfigured
#                                           #   endpoint must not spam the
#                                           #   caller's tool output. Use this
#                                           #   to diagnose suspected exporter
#                                           #   failures (timeouts, auth, DNS).
#   DELEGATE_OTEL_HEADERS=<H: v,H: v>       # optional. Comma-separated
#                                           #   Header: value pairs (matches
#                                           #   OpenTelemetry SDK convention).
#                                           #   Used for collector auth on
#                                           #   Grafana Cloud, Langfuse, etc.
#                                           #   Per OTel SDK convention, header
#                                           #   values containing commas (or
#                                           #   any reserved char) MUST be
#                                           #   url-encoded — the script
#                                           #   url-decodes each value before
#                                           #   emitting -H flags so the on-
#                                           #   wire header is the literal
#                                           #   original (e.g. `a%2Cb` →
#                                           #   `a,b`).
#   DELEGATE_OTEL_INCLUDE_CONTENT=1         # Phase 11 Track F (#158). When =1,
#                                           #   include prompt / context /
#                                           #   output content in the OTel span
#                                           #   as attribute values
#                                           #   (delegate.prompt,
#                                           #   delegate.context,
#                                           #   delegate.output). Default unset
#                                           #   = redact those fields entirely
#                                           #   — only metadata (tier, model,
#                                           #   recipe, char counts, durations)
#                                           #   leaves the host. WARNING:
#                                           #   content fields may carry PII,
#                                           #   API keys, or internal URLs;
#                                           #   only enable this against
#                                           #   trusted collectors (a local
#                                           #   Phoenix instance, a vetted
#                                           #   private OTel backend, etc.).
#                                           #   See ADR 0007 + docs/otel-
#                                           #   schema.md for the field-by-
#                                           #   field split.
#
# Output:  model response on stdout (no ANSI; HTTP body is plain text)
# Errors:  pick-model failures and HTTP errors propagate as non-zero exit.
#          A metrics line is still appended with exit_status set. OTLP-export
#          failures NEVER change exit status — telemetry is non-fatal.

set -uo pipefail

usage() {
  echo 'usage: delegate.sh [--recipe NAME [--var key=value ...]] [--project NAME] [--tier NAME] <tier> ["<prompt>"]' >&2
  echo '       (context piped via stdin; prompt optional when --recipe is set)' >&2
  echo '       --tier NAME is equivalent to the positional <tier> and wins over it;' >&2
  echo '       with --tier the first positional is the prompt.' >&2
}

recipe=""
project_override=""
tier_flag=""
recipe_vars=()
positional=()
while (($# > 0)); do
  case "$1" in
    --recipe)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == -* ]]; then
        echo 'delegate: --recipe requires a value' >&2; exit 2
      fi
      recipe="$2"; shift 2;;
    --recipe=*)
      recipe="${1#--recipe=}"; shift;;
    --var)
      # As with --recipe/--project, a following flag is the next option rather
      # than this one's value; accepting it would swallow the flag silently.
      if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == -* ]]; then
        echo 'delegate: --var requires key=value' >&2; exit 2
      fi
      recipe_vars+=("$2"); shift 2;;
    --var=*)
      recipe_vars+=("${1#--var=}"); shift;;
    --project)
      # A next token starting with '-' is the next flag, not the value:
      # `--project --recipe foo` would otherwise set the project to "--recipe"
      # and silently swallow the recipe flag.
      if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == -* ]]; then
        echo 'delegate: --project requires a value' >&2; exit 2
      fi
      project_override="$2"; shift 2;;
    --project=*)
      project_override="${1#--project=}"; shift;;
    # `--tier` is not a new spelling invented here: the flaky-gate refusal below
    # already tells callers to "route to a different tier (e.g. --tier code)",
    # as does ADR 0012, and the argument catch-all was swallowing it as the
    # positional tier — one live metrics row is literally `tier="--tier"`. Same
    # following-flag guard as the options above.
    --tier)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == -* ]]; then
        echo 'delegate: --tier requires a value' >&2; exit 2
      fi
      tier_flag="$2"; shift 2;;
    --tier=*)
      tier_flag="${1#--tier=}"; shift;;
    --)
      shift
      while (($# > 0)); do positional+=("$1"); shift; done
      ;;
    -h|--help)
      usage; exit 0;;
    *)
      positional+=("$1"); shift;;
  esac
done

# Backwards compat: old env var names (rename delegate-to-ollama → delegate-local).
DELEGATE_LOCAL_NO_METRICS="${DELEGATE_LOCAL_NO_METRICS:-${DELEGATE_TO_OLLAMA_NO_METRICS:-}}"
DELEGATE_LOCAL_NO_VERDICT_NUDGE="${DELEGATE_LOCAL_NO_VERDICT_NUDGE:-${DELEGATE_TO_OLLAMA_NO_VERDICT_NUDGE:-}}"
DELEGATE_LOCAL_VERDICT_NUDGE_FD="${DELEGATE_LOCAL_VERDICT_NUDGE_FD:-${DELEGATE_TO_OLLAMA_VERDICT_NUDGE_FD:-}}"
DELEGATE_LOCAL_NO_META="${DELEGATE_LOCAL_NO_META:-${DELEGATE_TO_OLLAMA_NO_META:-}}"

# Validate the verdict-nudge FD env var up-front so a bad value fails fast,
# before model resolution or the canary probe — a caller who fat-fingers
# `DELEGATE_LOCAL_VERDICT_NUDGE_FD=foo` shouldn't pay the cold-load cost
# before discovering the typo. Default 2 (stderr) keeps the back-compat
# behaviour the #149 reversal pinned. The accepted range is 1-9 (single-
# digit shell FDs): bash 3.2 — the project's portability floor, macOS-
# shipped /bin/bash — only supports the `{var}>file` syntax for high FDs
# from bash 4 onward, so multi-digit FDs via the `>&$N` form are unreliable
# on the target platform. Restricting validation to 1-9 makes the failure
# mode loud (clear error here) rather than silent (write-failure at nudge
# time absorbed by the 2>/dev/null guard below). 0 (stdin) is rejected as
# nonsense; 1 (stdout) is allowed for callers who genuinely want the nudge
# inline with the model output.
nudge_fd="${DELEGATE_LOCAL_VERDICT_NUDGE_FD:-2}"
if ! [[ "$nudge_fd" =~ ^[1-9]$ ]]; then
  echo "delegate: DELEGATE_LOCAL_VERDICT_NUDGE_FD='${DELEGATE_LOCAL_VERDICT_NUDGE_FD:-}' is not a single-digit positive file descriptor (valid: 1-9; 0 is stdin and is rejected, multi-digit FDs are unreliable on bash 3.2)" >&2
  exit 2
fi

# Reject a --var value that is nothing but an unreplaced angle-bracket
# stand-in (`--var why='<why this changed>'`). Callers copy these verbatim from
# a recipe's ## Invocation block; the model then summarises the placeholder
# instead of the real content, and the metrics row records an ordinary
# successful delegation, so the failure is invisible (#356). Validated here
# with the other fail-fast checks, before the cold-load cost.
#
# Only a whole-value single bracket token is rejected. Values that merely
# contain brackets are the common case and must pass: --var diff= carries real
# hunks, so HTML, C++ generics, `a < b` and shell redirection all have to
# survive. Glob matching, not a regex engine, so there is nothing to backtrack.
for kv in ${recipe_vars[@]+"${recipe_vars[@]}"}; do
  [[ "$kv" == *"="* ]] || continue
  placeholder_value="${kv#*=}"
  placeholder_value="${placeholder_value#"${placeholder_value%%[![:space:]]*}"}"
  placeholder_value="${placeholder_value%"${placeholder_value##*[![:space:]]}"}"
  if [[ "$placeholder_value" == "<"*">" ]]; then
    placeholder_inner="${placeholder_value:1:${#placeholder_value}-2}"
    if [[ "$placeholder_inner" != *"<"* && "$placeholder_inner" != *">"* ]]; then
      echo "delegate: --var ${kv%%=*} is an unreplaced placeholder: '$placeholder_value'" >&2
      echo "         substitute the real content before delegating" >&2
      exit 2
    fi
  fi
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pick="$script_dir/pick-model.sh"
prompts_dir="${DELEGATE_PROMPTS_DIR:-$script_dir/../prompts}"

# Positional resolution runs here rather than beside the argument loop because
# it needs $pick: the tier vocabulary is read from pick-model.sh's own TIERS
# line so there is exactly one source of truth for it. Nothing between the loop
# and this point reads $tier or $prompt.
#
# The grammar is `[<tier>] ["<prompt>"]` and both are optional, which is
# ambiguous for a lone positional. 17 of the 20 recipes carry a trailing
# reinforcement prompt (commit-message.md calls it load-bearing), so reading a
# lone positional as the tier would make every documented recipe call fail with
# "unknown tier: Match the example messages...". A lone positional is therefore
# the tier only when it EXACTLY matches a known tier name; otherwise it is the
# prompt and the tier comes from the recipe's frontmatter. Two positionals keep
# the historical order, so every existing invocation is unchanged.
known_tiers=$(sed -n 's/^TIERS="\(.*\)"$/\1/p' "$pick" 2>/dev/null | tr '|' ' ')
is_known_tier() {
  local candidate="$1" t
  [[ -z "$known_tiers" ]] && return 1
  for t in $known_tiers; do [[ "$t" == "$candidate" ]] && return 0; done
  return 1
}

if [[ -n "$tier_flag" ]]; then
  tier="$tier_flag"
  prompt="${positional[0]:-}"
elif [[ -n "$recipe" && ${#positional[@]} -eq 1 ]] && ! is_known_tier "${positional[0]}"; then
  tier=""
  prompt="${positional[0]}"
else
  tier="${positional[0]:-}"
  prompt="${positional[1]:-}"
fi

# Without a recipe both are still required. With one, an absent tier is resolved
# from the recipe frontmatter further down, once the recipe file is known.
if [[ -z "$recipe" ]] && { [[ -z "$tier" ]] || [[ -z "$prompt" ]]; }; then
  usage; exit 2
fi

metrics_file="${DELEGATE_METRICS_FILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/metrics.jsonl}"
# delegate_project is derived after lib/otel.sh is sourced (it provides
# delegate_project_name); first used in the metric/span emission near the end.
# Which base URL wins is not known until the tier is resolved (a provider can
# be reachable yet hold no model for this tier), so nothing is decided here:
# both the URL and the metrics label come back from the pick-model call below.
# This placeholder label only ever reaches a metrics row for a failure that
# happened before resolution.
resolved_base=""
backend="provider"

# Normalise DELEGATE_THINK to a strict JSON boolean ("true"/"false") before
# it reaches jq --argjson, so a stray value like "yes" / "True" / " true "
# doesn't cause a jq parse error that kills the whole delegation.
if [[ "${DELEGATE_THINK:-false}" == "true" ]]; then
  think="true"
else
  think="false"
fi

# Single source of truth for the local-tokenizer estimate: total chars in +
# out divided by 4. Both the JSONL metrics row (estimated_tokens_avoided)
# and the delegate-meta stderr line (tokens_local) call this helper, so the
# two surfaces cannot drift on the formula — see gemini-code-assist's PR
# #133 review concern that the divisor was previously duplicated in two
# code paths. Bash integer division of a sum of `${#...}` lengths has no
# zero-divide risk.
compute_tokens_local() {
  local pchars=$1 cchars=$2 ochars=$3
  echo $(( (pchars + cchars + ochars) / 4 ))
}

# capture_draft — persist the generated draft next to the metrics row that
# scores it, and echo the basename for that row's `draft_file` field.
#
# Why this exists: until 2026-08-26 the output was never stored, so a MISS
# recorded only the agent's PROSE DESCRIPTION of what was wrong with a draft
# nobody could look at again. quality-report.sh says so in its own header —
# "it does not need the original model output (which is never stored)" — and
# that is precisely the ceiling on the calibration loop: you cannot fix a
# recipe from "dropped every load-bearing fact" without seeing which facts and
# what the draft said instead. With the draft on disk, and the shipped text
# captured by `delegate-feedback.sh --final`, a MISS becomes a concrete
# (generated, shipped) pair — the one artefact that makes a recipe edit
# evidence-driven rather than a guess.
#
# Local-only by construction: the files sit beside metrics.jsonl under
# DELEGATE_LOCAL_DATA_DIR, outside the repo, and nothing ships them anywhere.
# They hold whatever the model was given, so they inherit the sensitivity of
# the context you piped in. Opt out per call with DELEGATE_NO_DRAFT_CAPTURE=1;
# capture is skipped entirely when metrics are off, because without the row
# there is nothing to join the file to.
capture_draft() {
  local text="$1" ts="$2" stem dir max bytes
  [[ "${DELEGATE_LOCAL_NO_METRICS:-}" == "1" ]] && return 0
  [[ "${DELEGATE_NO_DRAFT_CAPTURE:-}" == "1" ]] && return 0
  [[ -n "$text" ]] || return 0
  dir="$(dirname "$metrics_file")/drafts"
  mkdir -p "$dir" 2>/dev/null || return 0
  # A draft is the model's rendering of whatever context was piped in, so the
  # directory inherits that content's sensitivity and must not inherit a
  # permissive umask. 700 on the directory, 600 on the files, and the writes
  # happen under `umask 077` so there is no window between create and chmod.
  chmod 700 "$dir" 2>/dev/null || true
  # Colons are legal in POSIX filenames but awkward in shell globs and in
  # Finder, so the ts goes in compacted — but the ts ALONE is not a safe name.
  # It has second precision, and parallel callers collide: the archived corpus
  # holds 14 timestamps shared by more than one delegation, one of them by
  # eight. Two drafts landing on one filename would clobber each other and
  # leave two metrics rows pointing at a single artefact, which is exactly the
  # pairing this capture exists to create. The span id (generated
  # unconditionally for every call, 16 random hex) makes the name unique; the
  # ts stays in front so the directory still sorts chronologically.
  stem=$(printf '%s' "$ts" | tr -d ':-')
  if [[ -n "${otel_span_id:-}" ]]; then
    stem="$stem-${otel_span_id:0:8}"
  else
    stem="$stem-$$"
  fi
  max="${DELEGATE_DRAFT_MAX_BYTES:-65536}"
  if ! [[ "$max" =~ ^[1-9][0-9]*$ ]]; then
    echo "delegate: DELEGATE_DRAFT_MAX_BYTES='$max' is not a positive integer — using 65536" >&2
    max=65536
  fi
  # Measured in bytes, because the cap is in bytes: ${#text} counts CHARACTERS
  # under a UTF-8 locale, so a draft of multi-byte text could sail past a byte
  # cap it had already exceeded several times over.
  bytes=$(printf '%s' "$text" | wc -c | tr -d '[:space:]')
  # head -c bounds a runaway generation without failing the call. The marker
  # keeps a truncated file from being read later as a complete draft.
  if [[ "$bytes" =~ ^[0-9]+$ ]] && (( bytes > max )); then
    ( umask 077
      { printf '%s' "$text" | head -c "$max"; printf '\n[truncated at %s bytes by DELEGATE_DRAFT_MAX_BYTES]\n' "$max"; } \
        > "$dir/$stem.draft.txt" ) 2>/dev/null || return 0
  else
    ( umask 077; printf '%s' "$text" > "$dir/$stem.draft.txt" ) 2>/dev/null || return 0
  fi
  chmod 600 "$dir/$stem.draft.txt" 2>/dev/null || true
  # Retention prune. Cheap enough to run inline (a few hundred small files at
  # steady state) and self-limiting, so there is no cron dependency for it.
  # 0 disables. -mtime +N is POSIX and behaves the same on BSD and GNU find.
  local keep="${DELEGATE_DRAFT_RETENTION_DAYS:-14}"
  if [[ "$keep" =~ ^[0-9]+$ ]] && (( keep > 0 )); then
    find "$dir" -type f -name '*.txt' -mtime "+$keep" -exec rm -f {} + 2>/dev/null || true
  fi
  printf '%s' "$stem.draft.txt"
}

log_metric() {
  [[ "${DELEGATE_LOCAL_NO_METRICS:-}" == "1" ]] && return 0
  local ts="$1" tier="$2" model="$3" pchars="$4" cchars="$5" ochars="$6" dur_ms="$7" status="$8" recipe_name="${9:-}" qwait_ms="${10:-0}" gen_ms="${11:-0}" trace_id="${12:-}" span_id="${13:-}" \
    s_temp="${14:-}" s_top_p="${15:-}" s_top_k="${16:-}" s_pp="${17:-}" project="${18:-}" \
    checks_run="${19:-}" checks_failed="${20:-}" checks_autofixed="${21:-}" checks_failed_names="${22:-}" \
    draft_file="${23:-}"
  local tokens_avoided
  tokens_avoided=$(compute_tokens_local "$pchars" "$cchars" "$ochars")
  mkdir -p "$(dirname "$metrics_file")" 2>/dev/null || true
  # source:"delegate" discriminates this from experiment-runner traffic that
  # writes to the same file via experiments/lib/run_api_cell.sh. backend
  # discriminates ollama vs mlx traffic — pre-2026-05 rows lack the field and
  # metrics-summary.sh treats their absence as backend=ollama for back-compat.
  # duration_ms remains the inclusive total (invoke → response complete) so
  # downstream consumers (metrics-summary.sh rollups, audit-metrics) keep
  # seeing the same field they did before #170. queue_wait_ms (invoke →
  # first byte from the model server) and generation_ms (first byte →
  # response complete) are emitted alongside so Phase 11 OTel can split the
  # span into queue-wait and generation attributes, and so parallel-caller
  # contention shows up in metrics instead of being hidden inside the
  # generation phase. The two new fields always sum to duration_ms within
  # rounding.
  # otel_trace_id / otel_span_id (#134) carry the trace and span identifiers
  # the OTLP exporter generates so delegate-feedback.sh can join its later
  # feedback-as-linked-span back to the parent delegation without a second
  # lookup. They are always written when the exporter generated them (we
  # generate them unconditionally — the cost is two perl invocations — so
  # historical backfill (Track E #157) and the feedback-span linkage both
  # have a stable identifier even when the exporter endpoint is unset).
  # sampling_temperature / sampling_top_p / sampling_top_k /
  # sampling_presence_penalty (Track A of #193) record the dispatch sampler
  # profile so audit-metrics can pivot on greedy-vs-Qwen-profile runs.
  # Non-Qwen models emit only sampling_temperature (always 0); Qwen models
  # emit all four; env-var overrides surface as whatever the caller set.
  # jq builds the line so any quote, backslash, or newline in $model or
  # $recipe_name (recipe names are filename-safe today but model ids come
  # from whatever a provider reports and are not under our control) escapes
  # correctly rather than producing invalid JSON.
  # recipe joins the other optional fields as a conditional append, so the row
  # shape (recipe present iff this was a --recipe call) holds without a second
  # jq block.
  jq -nc \
    --arg ts "$ts" --arg backend "$backend" --arg tier "$tier" --arg model "$model" \
    --arg recipe "$recipe_name" --arg project "$project" \
    --arg trace_id "$trace_id" --arg span_id "$span_id" \
    --arg s_temp "$s_temp" --arg s_top_p "$s_top_p" --arg s_top_k "$s_top_k" --arg s_pp "$s_pp" \
    --argjson pchars "$pchars" --argjson cchars "$cchars" --argjson ochars "$ochars" \
    --argjson dur_ms "$dur_ms" --argjson qwait_ms "$qwait_ms" --argjson gen_ms "$gen_ms" \
    --argjson status "$status" --argjson tokens_avoided "$tokens_avoided" \
    --arg crun "$checks_run" --arg cfail "$checks_failed" --arg cfix "$checks_autofixed" \
    --arg cnames "$checks_failed_names" --arg draft "$draft_file" \
    '{ts:$ts, source:"delegate", backend:$backend, tier:$tier, model:$model, prompt_chars:$pchars, context_chars:$cchars, output_chars:$ochars, duration_ms:$dur_ms, queue_wait_ms:$qwait_ms, generation_ms:$gen_ms, exit_status:$status, estimated_tokens_avoided:$tokens_avoided}
     + (if $recipe != "" then {recipe:$recipe} else {} end)
     + (if $project != "" then {project:$project} else {} end)
     + (if $trace_id != "" then {otel_trace_id:$trace_id} else {} end)
     + (if $span_id != "" then {otel_span_id:$span_id} else {} end)
     + (if $s_temp != "" then {sampling_temperature:($s_temp|tonumber)} else {} end)
     + (if $s_top_p != "" then {sampling_top_p:($s_top_p|tonumber)} else {} end)
     + (if $s_top_k != "" then {sampling_top_k:($s_top_k|tonumber)} else {} end)
     + (if $s_pp != "" then {sampling_presence_penalty:($s_pp|tonumber)} else {} end)
     + (if ($crun != "" and ($crun|tonumber) > 0) then {checks_run:($crun|tonumber), checks_failed:($cfail|tonumber), checks_autofixed:($cfix|tonumber)} else {} end)
     + (if $cnames != "" then {checks_failed_names:($cnames|split(","))} else {} end)
     + (if $draft != "" then {draft_file:$draft} else {} end)' \
    >> "$metrics_file" 2>/dev/null || true
}

# OTel ID generation and OTLP/HTTP span emission live in scripts/lib/otel.sh —
# shared with delegate-feedback.sh and backfill-otel.sh (Track E, #157). The
# lib defines otel_gen_id, otel_deterministic_ids, emit_otel_span, and
# emit_otel_feedback_span. emit_otel_span carries the Track F redaction
# behaviour (DELEGATE_OTEL_INCLUDE_CONTENT=1 to include content; default
# omits prompt/context/output entirely). Sourcing has no side effects.
# shellcheck source=lib/otel.sh
. "$script_dir/lib/otel.sh"

# Resolve the project name (main repo basename, even inside a git worktree).
# The caller can state it outright — `--project NAME`, or DELEGATE_PROJECT —
# because the cwd derivation is only right when delegate.sh runs inside the repo
# the delegation is FOR. Delegating on behalf of repo X from inside the skill
# checkout recorded project=delegate-local, so the boundary hook (which derives
# the project from the *hook's* cwd, i.e. the real repo) never matched the row
# and nudged despite compliance (#342). Explicit flag beats env beats cwd.
# The flag is exported rather than kept local so delegate_project_name resolves
# it, and so a delegate-feedback.sh run in the same shell inherits it.
[[ -n "$project_override" ]] && export DELEGATE_PROJECT="$project_override"
delegate_project=$(delegate_project_name)

ts_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_epoch_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')

# Generate trace_id (32 hex / 128 bits) and span_id (16 hex / 64 bits) for
# the OTel exporter and for the delegate-feedback.sh linkage. We generate
# them unconditionally — the cost is two short perl invocations — so the
# JSONL row always carries the identifiers even when the exporter is
# disabled. That means historical backfill (Track E #157) and feedback-
# as-linked-span (delegate-feedback.sh) both work without a second pass.
otel_trace_id=$(otel_gen_id 32)
otel_span_id=$(otel_gen_id 16)

# Emit the metrics row + OTel span for an early-exit failure (pick-model,
# flaky-gate, canary). All three share the same shape — zero output chars,
# the whole elapsed time attributed to generation_ms — so the char/duration/
# token computation and the long log_metric + emit_otel_span argument lists
# live here once instead of being copy-pasted at each exit. The optional
# sampling args default to empty for the early paths that fail before the
# sampler profile is resolved; the canary passes its resolved metric_sampling_*.
emit_failure() {
  local fstatus="$1" fmodel="$2" fs_temp="${3:-}" fs_top_p="${4:-}" fs_top_k="${5:-}" fs_pp="${6:-}"
  local fend fdur fp fc ftoks
  fend=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
  fdur=$((fend - start_epoch_ms))
  fp=$(( ${#recipe_template} + ${#prompt} ))
  fc=${#context}
  ftoks=$(compute_tokens_local "$fp" "$fc" 0)
  log_metric "$ts_start" "$tier" "$fmodel" "$fp" "$fc" 0 "$fdur" "$fstatus" "$recipe" 0 "$fdur" "$otel_trace_id" "$otel_span_id" "$fs_temp" "$fs_top_p" "$fs_top_k" "$fs_pp" "$delegate_project"
  emit_otel_span "$start_epoch_ms" "$fdur" "$fstatus" "$otel_trace_id" "$otel_span_id" "$fmodel" "$backend" "$tier" "$recipe" "$fp" "$fc" 0 0 "$fdur" "$ftoks" "${recipe_template}${prompt}" "$context" "" "$delegate_project"
}

# Read stdin into a variable if anything is piped in (needed early so {{stdin}}
# substitution can run before the model resolution, and so the recipe-driven
# error paths still surface with a clean metric line). The probe is
# `-p /dev/stdin || -s /dev/stdin` rather than the more obvious `! -t 0`
# because the latter returns true for unix sockets and FIFOs that hold no
# data, and `cat` on such an FD then blocks forever waiting for EOF that
# never arrives — the failure mode hit by Agent SDK `run_in_background`
# callers on 2026-05-22 (#169). `-p` covers ordinary pipes (so the
# `echo data | delegate.sh ...` flow works whether or not bytes have landed
# yet), `-s` covers regular files and heredocs that have content, and both
# are bash 3.2 compatible (the issue's suggested `read -t 0 -N 0` is bash
# 4+ only — verified on macOS-shipped /bin/bash 3.2.57).
context=""
if [[ -p /dev/stdin || -s /dev/stdin ]]; then
  context=$(cat)
fi

# --recipe auto (#277 dir 5): infer the recipe from the piped context so the
# agent reaches for one call instead of choosing the recipe and assembling
# every --var by hand. One high-confidence mapping today: a unified diff on
# stdin → commit-message. diff_stat is computed FROM the piped diff (the source
# of truth the caller handed us) rather than re-derived from `git diff`, so the
# summary always matches what was piped and the path works even when the index
# / working tree is clean (a diff piped from `git show <sha>`, a stash, a
# `.patch`, or another branch). recent_commits IS genuine repo state, so it is
# backfilled from `git log` (delegate.sh already shells out to git for project
# attribution, so this adds no new dependency); outside a repo it stays empty
# and the normal unsubstituted-placeholder guard surfaces the gap. intent
# (`why`) is never inferable from a diff, so it stays a required --var. Anything
# that is not a recognised diff is an explicit error, never a silent guess.
if [[ "$recipe" == "auto" ]]; then
  if [[ -z "$context" ]]; then
    echo "delegate: --recipe auto needs context on stdin to infer a recipe (none piped). Pass --recipe NAME explicitly; see prompts/README.md." >&2
    exit 2
  fi
  if printf '%s' "$context" | grep -Eq '^diff --git |^@@ '; then
    recipe="commit-message"
    _auto_have_var() { local k="$1" v; for v in ${recipe_vars[@]+"${recipe_vars[@]}"}; do [[ "$v" == "$k="* ]] && return 0; done; return 1; }
    if ! _auto_have_var diff_stat; then
      # Derive a per-file +added/-deleted summary from the piped unified diff.
      # awk, not `git diff --stat`, so the summary reflects exactly what was
      # piped (not the repo's current index, which may differ or be empty).
      _auto_ds=$(printf '%s\n' "$context" | awk '
        /^diff --git / { if (f != "") printf " %s | +%d -%d\n", f, a, d; f=$3; sub(/^a\//,"",f); a=0; d=0; next }
        /^\+\+\+ / || /^--- / { next }
        /^\+/ { a++ }
        /^-/  { d++ }
        END { if (f != "") printf " %s | +%d -%d\n", f, a, d }')
      [[ -n "$_auto_ds" ]] && recipe_vars+=("diff_stat=$_auto_ds")
    fi
    if ! _auto_have_var recent_commits; then
      _auto_rc=$(git log -3 --pretty=fuller 2>/dev/null || true)
      [[ -n "$_auto_rc" ]] && recipe_vars+=("recent_commits=$_auto_rc")
    fi
    echo "delegate: --recipe auto inferred commit-message from the piped diff" >&2
  else
    echo "delegate: --recipe auto could not infer a recipe from the piped context (expected a unified diff for commit-message). Pass --recipe NAME explicitly; see prompts/README.md." >&2
    exit 2
  fi
fi

# Resolve recipe template (if any) and substitute {{key}} placeholders.
recipe_template=""
recipe_had_stdin_marker=0
declared_inputs_present=0
if [[ -n "$recipe" ]]; then
  recipe_file="$prompts_dir/${recipe}.md"
  if [[ ! -f "$recipe_file" ]]; then
    echo "delegate: recipe '$recipe' not found at $recipe_file" >&2
    exit 2
  fi

  # Optional frontmatter `tier:` (#411). 39 of the 44 recorded bad-tier calls
  # supplied a --recipe, and every recipe's production traffic routes to one
  # dominant tier, so the caller was being asked for a value the recipe already
  # implies. An explicit tier — positional or --tier — still wins, which is what
  # keeps the deliberate `commit-message` on `code` runs working. Read with the
  # same independent single-key awk scan as inputs:/checks:/flaky_on_models:,
  # so it cannot disturb them and recipes without it still work.
  if [[ -z "$tier" ]]; then
    tier=$(awk '
      BEGIN { in_fm=0 }
      NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
      in_fm && /^---[[:space:]]*$/ { exit }
      in_fm && /^tier:[[:space:]]*[a-z-]+[[:space:]]*$/ {
        sub(/^tier:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit
      }
    ' "$recipe_file")
    if [[ -z "$tier" ]]; then
      {
        echo "delegate: recipe '$recipe' declares no tier and none was given"
        echo "         add a frontmatter 'tier: <name>' to $recipe_file,"
        echo "         or pass one: delegate.sh --recipe $recipe --tier <name> ..."
      } >&2
      exit 2
    fi
  fi

  # Optional frontmatter `inputs:` block (Phase 12 Track B, issue #161).
  # Extracts flat `key: type` pairs only — no nesting, no anchors, no flow
  # style — so `awk` parses it without `yq` and the "two bash scripts" rule
  # holds. Supported types: integer, string, integer?, string? (the `?`
  # suffix means optional). Anything richer is deferred until needed.
  # Pre-flight type-validation runs BEFORE placeholder substitution so the
  # caller gets a clear type error rather than an opaque "missing placeholder"
  # downstream message. Recipes without a frontmatter block (today's
  # majority) skip the validation entirely — full back-compat.
  inputs_block=$(awk '
    BEGIN { in_fm=0; in_inputs=0 }
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm && /^inputs:[[:space:]]*$/ { in_inputs=1; next }
    in_fm && in_inputs && /^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*[a-zA-Z?]+[[:space:]]*$/ { print; next }
    in_fm && in_inputs && /^[a-zA-Z_]/ { in_inputs=0 }
  ' "$recipe_file")

  if [[ -n "$inputs_block" ]]; then
    # Build parallel arrays: declared_keys[i] / declared_types[i] / declared_optional[i].
    # Bash 3.2 has no associative arrays, so we use indexed arrays and a
    # linear scan — recipes have at most a handful of inputs so O(n*m) is
    # fine. The `?` suffix is parsed off the type into a separate optional
    # flag so the type-check itself stays a clean enum (integer | string).
    declared_keys=()
    declared_types=()
    declared_optional=()
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      # Trim leading whitespace and split on colon.
      trimmed="${line#"${line%%[![:space:]]*}"}"
      ikey="${trimmed%%:*}"
      itype_raw="${trimmed#*:}"
      # Trim whitespace around the type token.
      itype_raw="${itype_raw#"${itype_raw%%[![:space:]]*}"}"
      itype_raw="${itype_raw%"${itype_raw##*[![:space:]]}"}"
      iopt=0
      if [[ "$itype_raw" == *"?" ]]; then
        iopt=1
        itype="${itype_raw%?}"
      else
        itype="$itype_raw"
      fi
      case "$itype" in
        integer|string) ;;
        *)
          echo "delegate: recipe '$recipe' inputs:$ikey declares unsupported type '$itype_raw'" >&2
          echo "         supported types: integer, string, integer?, string?" >&2
          exit 2
          ;;
      esac
      declared_keys+=("$ikey")
      declared_types+=("$itype")
      declared_optional+=("$iopt")
    done <<< "$inputs_block"
    declared_inputs_present=1

    # Build a map of provided --var keys (and {{stdin}} when stdin is piped)
    # so we can both type-check each value and detect missing required inputs.
    # provided_keys is a newline-delimited list; matching uses grep -Fxq for
    # an exact-line match so a key like `pr` doesn't accidentally match `pr_number`.
    provided_keys=""
    for kv in ${recipe_vars[@]+"${recipe_vars[@]}"}; do
      if [[ "$kv" != *"="* ]]; then
        echo "delegate: --var must be key=value, got '$kv'" >&2
        exit 2
      fi
      pkey="${kv%%=*}"
      pvalue="${kv#*=}"
      if [[ -z "$pkey" ]]; then
        echo "delegate: --var has empty key in '$kv'" >&2
        exit 2
      fi
      # Type-check against the declared inputs (if any). Undeclared --var
      # keys pass through untouched — lazy migration means most recipes
      # don't declare types yet, and a strict-mode rejection would break
      # them. Strict mode is deferred until migration is more complete.
      idx=0
      for dk in "${declared_keys[@]}"; do
        if [[ "$dk" == "$pkey" ]]; then
          dtype="${declared_types[$idx]}"
          case "$dtype" in
            integer)
              if ! [[ "$pvalue" =~ ^-?[0-9]+$ ]]; then
                echo "delegate: --var $pkey expected type 'integer', got '$pvalue'" >&2
                exit 2
              fi
              ;;
            string)
              # Any value is a valid string. Empty string is permitted so
              # callers can pass `--var name=` for an intentional blank.
              :
              ;;
          esac
          break
        fi
        idx=$((idx + 1))
      done
      provided_keys="${provided_keys}${pkey}"$'\n'
    done

    # `{{stdin}}` satisfies a declared `stdin: string` input when piped, so
    # a recipe can require stdin via the typed surface without forcing the
    # caller to pass it twice (once as --var, once piped). If the recipe
    # declares a non-string type for stdin (e.g. `stdin: integer`), the
    # piped value is type-checked against that declaration here so the
    # pre-flight covers stdin the same way it covers --var inputs.
    if [[ -n "$context" ]]; then
      provided_keys="${provided_keys}stdin"$'\n'
      sidx=0
      for dk in "${declared_keys[@]}"; do
        if [[ "$dk" == "stdin" ]]; then
          stype="${declared_types[$sidx]}"
          case "$stype" in
            integer)
              if ! [[ "$context" =~ ^-?[0-9]+$ ]]; then
                echo "delegate: piped stdin expected type 'integer' (declared by recipe '$recipe'), got non-integer value" >&2
                exit 2
              fi
              ;;
            string)
              :
              ;;
          esac
          break
        fi
        sidx=$((sidx + 1))
      done
    fi

    # Required-input check: any declared input without the `?` optional
    # marker MUST be provided. List every missing key in one error so the
    # caller can fix them in one pass rather than discovering them one at
    # a time.
    missing_required=""
    idx=0
    for dk in "${declared_keys[@]}"; do
      if (( declared_optional[idx] == 0 )); then
        if ! printf '%s' "$provided_keys" | grep -Fxq "$dk"; then
          missing_required="${missing_required}${dk} "
        fi
      fi
      idx=$((idx + 1))
    done
    if [[ -n "${missing_required// /}" ]]; then
      echo "delegate: recipe '$recipe' missing required inputs: ${missing_required% }" >&2
      echo "         pass them via --var key=value" >&2
      exit 2
    fi
  fi

  # Extract the first ``` fenced code block under the '## Prompt template'
  # heading. awk-based — bash 3 / BSD awk safe. The section-end check
  # `/^## /` is gated on `!in_block` so a markdown heading inside the
  # fenced block (legitimate prompt content) doesn't prematurely close the
  # section before the closing ``` is reached.
  recipe_template=$(awk '
    /^## Prompt template[[:space:]]*$/ { in_section=1; next }
    /^## / && in_section && !in_block { in_section=0 }
    in_section && /^```/ {
      if (in_block) { exit }
      in_block=1; next
    }
    in_section && in_block { print }
  ' "$recipe_file")
  if [[ -z "$recipe_template" ]]; then
    echo "delegate: recipe '$recipe' has empty or missing '## Prompt template' fenced block" >&2
    exit 2
  fi
  # Keep the PRE-substitution template. Every later assignment to
  # $recipe_template folds caller-supplied values into it ({{stdin}}, each
  # --var, the flavor keys), so by check time it contains the user's own
  # context and is useless as an "is this line recipe-authored?" oracle. The
  # raw copy contains only text the recipe author wrote, which is exactly what
  # the no_example_echo check needs to compare against.
  recipe_template_raw="$recipe_template"

  # Optional frontmatter `checks:` block (ADR 0014, deterministic output
  # constraints). Each indented `name: value` line declares a check that runs
  # on the finalised output (warn-only). Extracted here so it rides the same
  # {{key}} substitution as the template below — a check value may reference a
  # flavor placeholder (e.g. `subject_max: {{flavor_commit_subject_max}}`) and
  # stay consistent with the prompt. Recipes with no checks: block are untouched.
  recipe_checks=$(awk '
    BEGIN { in_fm=0; in_checks=0 }
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm && /^checks:[[:space:]]*$/ { in_checks=1; next }
    in_fm && in_checks && /^[[:space:]]+[a-zA-Z_]/ { print; next }
    in_fm && in_checks && /^[a-zA-Z_]/ { in_checks=0 }
  ' "$recipe_file")

  # Optional frontmatter `echo_guard_vars:` — a comma-separated list of --var
  # names whose values are EXEMPLARS (shape anchors) rather than content. Their
  # text is shown to the model to teach a shape, and must never come back in
  # the output. `no_example_echo` covers the recipe's own prompt; this covers
  # the exemplars the caller supplies, which is where the failure that
  # motivated it actually happened (issue #428).
  recipe_echo_guard_vars=$(awk '
    BEGIN { in_fm=0 }
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm && /^echo_guard_vars:[[:space:]]*/ {
      sub(/^echo_guard_vars:[[:space:]]*/, ""); print; exit
    }
  ' "$recipe_file")

  # Identify the placeholders the *original* template requires. Validating
  # against this list — not the post-substitution string — means substituted
  # values that legitimately contain `{{...}}` (Vue/Angular bindings, Go
  # templates, logs with curly braces) don't trigger a false positive.
  required_placeholders=$(printf '%s' "$recipe_template" | grep -oE '\{\{[a-zA-Z_][a-zA-Z0-9_]*\}\}' | sort -u)

  # Substitute --var key=value pairs into {{key}} placeholders. Bash
  # parameter substitution handles the literal {{ }} braces fine since they
  # are not glob metacharacters; values may contain newlines and arbitrary
  # punctuation because they came in via argv (no shell re-evaluation).
  satisfied_keys=""
  for kv in ${recipe_vars[@]+"${recipe_vars[@]}"}; do
    if [[ "$kv" != *"="* ]]; then
      echo "delegate: --var must be key=value, got '$kv'" >&2
      exit 2
    fi
    key="${kv%%=*}"
    value="${kv#*=}"
    if [[ -z "$key" ]]; then
      echo "delegate: --var has empty key in '$kv'" >&2
      exit 2
    fi
    # The key is interpolated into a bash pattern replacement below, so glob
    # metacharacters (* ? [ ]) in a key would produce a malformed/overbroad
    # substitution instead of a literal {{key}} match. Reject anything that
    # isn't a plain identifier — the same shape the placeholder scan accepts.
    if ! [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
      echo "delegate: --var has invalid key '$key' in '$kv'" >&2
      echo "         keys must match ^[a-zA-Z_][a-zA-Z0-9_]*$ (letters, digits, underscore)" >&2
      exit 2
    fi
    recipe_template="${recipe_template//\{\{$key\}\}/$value}"
    recipe_checks="${recipe_checks//\{\{$key\}\}/$value}"
    satisfied_keys="${satisfied_keys}{{${key}}}"$'\n'
  done

  # Per-user flavor profile (ADR 0013): shipped defaults plus an optional user
  # override, resolved by load-flavor.sh and injected as {{flavor_*}} placeholders.
  # Runs AFTER the --var loop and only fills placeholders --var didn't already
  # satisfy, so an explicit --var flavor_x=… still wins. With no profile installed
  # the defaults reproduce the pre-split prompt verbatim (back-compat). Gated on
  # the template actually using a {{flavor_*}} placeholder, so recipes that don't
  # opt in skip the loader subprocess entirely (no cost, zero behaviour change).
  # Process substitution (not a pipe) so the substitutions land in this shell.
  if [[ "$recipe_template$recipe_checks" == *'{{flavor_'* ]]; then
    while IFS='=' read -r fkey fval; do
      # Defence-in-depth: only act on flavor_* keys, so a stray line (e.g. a
      # value with an embedded newline) can't substitute a non-flavor placeholder.
      [[ "$fkey" != flavor_* ]] && continue
      # The checks block always resolves flavor refs (independent of the
      # template's --var satisfaction state) so e.g. subject_max stays in sync
      # with the prompt's flavor cap.
      recipe_checks="${recipe_checks//\{\{$fkey\}\}/$fval}"
      if ! printf '%s' "$satisfied_keys" | grep -Fxq "{{${fkey}}}"; then
        recipe_template="${recipe_template//\{\{$fkey\}\}/$fval}"
        satisfied_keys="${satisfied_keys}{{${fkey}}}"$'\n'
      fi
    done < <(bash "$script_dir/load-flavor.sh" 2>/dev/null)
  fi

  # Declared-optional inputs (the `?` suffix) the caller did NOT supply have
  # their {{key}} placeholder collapsed to empty here, BEFORE the unsubstituted-
  # placeholder guard below. Without this, an optional input whose placeholder
  # appears in the template body would trip that guard (exit 2) the moment a
  # caller omitted it — forcing every optional placeholder to be all-or-nothing.
  # Blanking lets a recipe expose a genuine override (e.g. commit-message
  # `type`) that most callers leave off, with the template's surrounding prose
  # handling the empty case. Guarded on declared_inputs_present so recipes with
  # no inputs: block (today's majority) are untouched, and so "${declared_keys[@]}"
  # is only expanded when the array was actually built (bash 3.2 + set -u safe).
  if (( declared_inputs_present == 1 )); then
    oidx=0
    for dk in "${declared_keys[@]}"; do
      if (( declared_optional[oidx] == 1 )) \
         && ! printf '%s' "$satisfied_keys" | grep -Fxq "{{${dk}}}"; then
        recipe_template="${recipe_template//\{\{$dk\}\}/}"
        recipe_checks="${recipe_checks//\{\{$dk\}\}/}"
        satisfied_keys="${satisfied_keys}{{${dk}}}"$'\n'
      fi
      oidx=$((oidx + 1))
    done
  fi

  # {{stdin}} is the implicit placeholder for the piped context.
  if printf '%s' "$required_placeholders" | grep -qx '{{stdin}}'; then
    recipe_had_stdin_marker=1
    recipe_template="${recipe_template//\{\{stdin\}\}/$context}"
    satisfied_keys="${satisfied_keys}{{stdin}}"$'\n'
  fi

  # Refuse to invoke the model with required placeholders the caller didn't
  # supply — the partly-substituted template almost certainly isn't what
  # they meant. Compare against the original-template placeholder set, not
  # the post-substitution string, so legit `{{...}}` content survives.
  missing=""
  while IFS= read -r ph; do
    [[ -z "$ph" ]] && continue
    if ! printf '%s' "$satisfied_keys" | grep -Fxq "$ph"; then
      missing="${missing}${ph} "
    fi
  done <<< "$required_placeholders"
  if [[ -n "${missing// /}" ]]; then
    echo "delegate: recipe '$recipe' has unsubstituted placeholders: $missing" >&2
    echo "         pass them via --var key=value (or {{stdin}} via piped context)" >&2
    exit 2
  fi
fi

# pick-model.sh separates two failures that need opposite remedies: exit 2 is
# "that tier does not exist" (the caller mistyped or invented a name) and exit
# 1 is "the tier is real but no installed model matches it". Swallowing its
# stderr and reporting both as the latter sent callers off to install a model
# for a tier that cannot exist — 23 such calls across four projects before this
# was fixed, several of which concluded the skill itself was broken. The
# valid-tier list is echoed from pick-model's own message rather than restated
# here, so there is exactly one source of truth for it.
pick_err=$(mktemp)
# One call, not two: --print-resolution returns "<base>\t<model>" so a dead
# provider in the list is probed once rather than once per question.
_resolved=$(bash "$pick" --print-resolution "$tier" 2>"$pick_err")
pick_rc=$?
if [[ $pick_rc -eq 0 ]]; then
  resolved_base="${_resolved%%	*}"
  model="${_resolved#*	}"
  # Derive a short metrics label from the base URL. lib/otel.sh maps this to
  # gen_ai.provider.name and the Grafana overview does sum by (backend), so
  # emitting the URL would split every historical series and emitting a flat
  # "provider" would merge every runtime into one. Never falls back to
  # "openai": that is a registered SemConv value meaning OpenAI, so labelling
  # a local llama.cpp endpoint with it would be conformant-looking and false.
  case "$resolved_base" in
    *:8080*)  backend="mlx" ;;
    *:12434*) backend="docker" ;;
    *:11434*) backend="ollama" ;;
    *) backend=$(printf '%s' "$resolved_base" | sed -E 's|^[a-z]+://||; s|/.*$||') ;;
  esac
else
  model=""
fi
pick_msg=$(cat "$pick_err" 2>/dev/null)
rm -f "$pick_err"
if [[ $pick_rc -ne 0 ]]; then
  if [[ $pick_rc -eq 2 ]]; then
    emit_failure 2 "(none)"
    {
      echo "delegate: ${pick_msg:-unknown tier: $tier}"
      if [[ "$tier" == -* ]]; then
        echo "         '$tier' is not a flag delegate.sh knows, so it was read as the positional tier."
        echo "         the tier is positional: delegate.sh [options] <tier> [\"<prompt>\"] — or pass --tier $tier."
      else
        echo "         '$tier' is not a tier — pick one from the valid list above."
      fi
      echo "         tiers name the TASK, not the model size: there is no small/fast/medium/light/standard tier."
      echo "         prose = commit messages, PR descriptions, replies, summaries; code = code drafts;"
      echo "         long-context = big logs and many-file diffs; reasoning = genuine multi-step reasoning."
      echo "         nothing needs installing — re-run with a valid tier."
    } >&2
    exit 2
  fi
  emit_failure 1 "(none)"
  {
    echo "delegate: pick-model failed for tier '$tier'"
    [[ -n "$pick_msg" ]] && echo "         $pick_msg"
    echo "         no installed model matches this tier — run scripts/audit-models.sh to see routing, or pull a model from the tier's preference list in scripts/pick-model.sh"
    echo "         still broken? file a bug: https://github.com/${DELEGATE_GITHUB_REPO:-IsmaelMartinez/delegate-local}/issues/new?template=bug_report.md"
  } >&2
  exit 1
fi

# Recipe-level flaky-on-model gate (Phase 16 Track A). Recipes that have a
# documented flaky-on-class can declare a frontmatter `flaky_on_models:`
# list of case-insensitive substrings; when the resolved model matches any
# of them, the wrapper refuses (exit 4) with a stderr message naming the
# recipe's documented mitigation. Opt-out via DELEGATE_FORCE_FLAKY=1 for
# callers who want to capture fresh evidence that the flaky-class behaviour
# has changed across model upgrades. Backwards-compat: recipes without a
# `flaky_on_models:` frontmatter block skip the check entirely. Sits before
# the pre-flight canary because the gate is structural ("this recipe won't
# work reliably on this model class") while the canary is dynamic ("the
# model isn't responding right now") — no point probing a model the recipe
# already classifies as unreliable.
if [[ -n "$recipe" ]] && [[ "${DELEGATE_FORCE_FLAKY:-}" != "1" ]]; then
  flaky_list=$(awk '
    BEGIN { in_fm=0; in_flaky=0 }
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm && /^flaky_on_models:[[:space:]]*$/ { in_flaky=1; next }
    in_fm && in_flaky && /^[[:space:]]+-[[:space:]]+[^[:space:]]/ {
      sub(/^[[:space:]]+-[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
      print
      next
    }
    in_fm && in_flaky && /^[a-zA-Z_]/ { in_flaky=0 }
  ' "$recipe_file")
  if [[ -n "$flaky_list" ]]; then
    model_lower=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
    matched_pat=""
    while IFS= read -r pat; do
      [[ -z "$pat" ]] && continue
      pat_lower=$(printf '%s' "$pat" | tr '[:upper:]' '[:lower:]')
      if [[ "$model_lower" == *"$pat_lower"* ]]; then
        matched_pat="$pat"
        break
      fi
    done <<< "$flaky_list"
    if [[ -n "$matched_pat" ]]; then
      emit_failure 4 "$model"
      {
        echo "delegate: recipe '$recipe' is flagged as flaky on model '$model'"
        echo "         (matched frontmatter pattern '$matched_pat'; see prompts/$recipe.md calibration notes)"
        echo "         Options:"
        echo "         - hand-write the output (recommended — the recipe documents this as the active mitigation)"
        echo "         - route to a different tier (e.g. --tier code) and retry"
        echo "         - override with DELEGATE_FORCE_FLAKY=1 (sends the request; expect known-flaky behaviour)"
      } >&2
      exit 4
    fi
  fi
fi

# Resolve the sampler profile for the dispatch call. Default for all models
# is greedy (temperature=0, no top_p/top_k/presence_penalty in the payload).
# Per-call overrides via DELEGATE_TEMPERATURE / DELEGATE_TOP_P / DELEGATE_TOP_K
# / DELEGATE_PRESENCE_PENALTY let callers opt INTO non-greedy sampling — the
# Alibaba-recommended Qwen3 instruct profile is `DELEGATE_TEMPERATURE=0.7
# DELEGATE_TOP_P=0.8 DELEGATE_TOP_K=20 DELEGATE_PRESENCE_PENALTY=1.3`. An
# earlier iteration of this code path auto-applied the Qwen profile on
# Qwen3-family models, but the T4 A/B (see experiments/results/2026-05-22-
# track-a-qwen-sampling-ab.md) found that profile regresses commit-message
# output: temperature=0.7 reintroduces lexical variety that lands on the
# participial-padding tails the commit-message recipe's guards explicitly
# reject. Greedy is the empirically-validated default; the env-vars stay so
# callers can experiment with non-greedy sampling on prose-shaped tasks
# where temperature-induced variety helps. Qwen-family detection still runs
# and sets a `model_family` variable as a hook for future audit-metrics
# work — the field is NOT currently emitted into the JSONL row; a follow-up
# will wire it in once the calibration backlog needs the pivot.
#
# All overrides are validated as numeric (bash 3.2 case-pattern, no
# associative arrays). Numeric pattern: optional leading minus, digits,
# optional decimal point and more digits — covers 0, 0.7, 1.3, -42, .5, 1.
# (top_k is sent as int but the same pattern is used for the validation
# surface so the error message shape stays consistent across all four
# overrides).
model_family=""
model_lc=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
case "$model_lc" in
  *qwen3.6*|*qwen3-coder*|*qwen3-next*|*qwen3.5*)
    model_family="qwen3"
    ;;
esac

# Dispatch-side defaults: greedy. The variables holding what actually goes
# into the wire payload are populated below; the parallel `metric_*` set
# captures only what the caller explicitly opted into, so a bare greedy
# invocation writes no sampling_* keys to the JSONL row (back-compat with
# pre-Phase-13 rows). When an env var is set, both surfaces carry it.
sampling_temperature="0"
sampling_top_p=""
sampling_top_k=""
sampling_presence_penalty=""
metric_sampling_temperature=""
metric_sampling_top_p=""
metric_sampling_top_k=""
metric_sampling_presence_penalty=""

validate_numeric() {
  # Bash 3.2 =~ POSIX ERE — same idiom as the canary's preflight_timeout
  # check at line 711. Accepts: optional leading minus, then digits, or
  # digits.digits, or digits., or .digits. Rejects strings like `1-2`,
  # `5-`, `.-` that an earlier permissive `case` pattern passed through
  # and pushed to jq as garbage --argjson input (the failure surfaced as
  # an obscure 'invalid JSON text' rather than the script's own clean error).
  local name="$1" value="$2"
  if ! [[ "$value" =~ ^-?([0-9]+(\.[0-9]*)?|\.[0-9]+)$ ]]; then
    echo "delegate: $name='$value' is not numeric" >&2
    exit 2
  fi
}

if [[ -n "${DELEGATE_TEMPERATURE:-}" ]]; then
  validate_numeric "DELEGATE_TEMPERATURE" "$DELEGATE_TEMPERATURE"
  sampling_temperature="$DELEGATE_TEMPERATURE"
  metric_sampling_temperature="$DELEGATE_TEMPERATURE"
fi
if [[ -n "${DELEGATE_TOP_P:-}" ]]; then
  validate_numeric "DELEGATE_TOP_P" "$DELEGATE_TOP_P"
  sampling_top_p="$DELEGATE_TOP_P"
  metric_sampling_top_p="$DELEGATE_TOP_P"
fi
if [[ -n "${DELEGATE_TOP_K:-}" ]]; then
  validate_numeric "DELEGATE_TOP_K" "$DELEGATE_TOP_K"
  sampling_top_k="$DELEGATE_TOP_K"
  metric_sampling_top_k="$DELEGATE_TOP_K"
fi
if [[ -n "${DELEGATE_PRESENCE_PENALTY:-}" ]]; then
  validate_numeric "DELEGATE_PRESENCE_PENALTY" "$DELEGATE_PRESENCE_PENALTY"
  sampling_presence_penalty="$DELEGATE_PRESENCE_PENALTY"
  metric_sampling_presence_penalty="$DELEGATE_PRESENCE_PENALTY"
fi

# Pre-flight canary — only fires when --recipe is set. Issue #110 documented
# recipe stalls of 6–10 minutes when a 35B-class prose-tier model was hit
# with a recipe-shaped prompt; a 1-token probe with a bounded timeout
# catches that case before the caller's input investment is sunk. The probe
# uses the same backend, model, and think setting as the real dispatch will
# — if the model can't return one token to "hi" within the timeout, the
# real recipe-shaped call definitely won't succeed either. Skipped on bare
# (non-recipe) calls, where the caller hasn't gathered inputs and the
# probe overhead doesn't pay off.
preflight_timeout="${DELEGATE_PREFLIGHT_TIMEOUT:-10}"
if [[ -n "$recipe" ]] \
   && [[ "${DELEGATE_NO_PREFLIGHT:-}" != "1" ]] \
   && [[ "$preflight_timeout" =~ ^[0-9]+$ ]] \
   && (( preflight_timeout > 0 )); then
  # The canary is a 1-token probe — "did the model respond at all" is the
  # only signal we want. Keep it at temperature:0 / greedy so a single fast
  # deterministic token comes back regardless of the dispatch profile. The
  # Qwen sampler overrides (top_p, top_k, presence_penalty) are pointless
  # at num_predict:1 / max_tokens:1 and would only add JSON noise to the
  # smallest-possible health check.
  canary_payload=$(jq -nc --arg m "$model" --argjson et "$think" \
    '{model:$m, messages:[{role:"user", content:"hi"}], stream:false, temperature:0, max_tokens:1, chat_template_kwargs:{enable_thinking:$et}}')
  canary_url="$resolved_base/chat/completions"
  curl -sS --fail --max-time "$preflight_timeout" -X POST "$canary_url" -d @- >/dev/null 2>&1 <<< "$canary_payload"
  canary_status=$?
  if (( canary_status != 0 )); then
    emit_failure 3 "$model" "$metric_sampling_temperature" "$metric_sampling_top_p" "$metric_sampling_top_k" "$metric_sampling_presence_penalty"
    # Distinguish curl exit codes so the recovery advice points at the
    # right knob. 28 is the --max-time-fired timeout (the case the canary
    # was designed for); 7 is "can't reach host" (the provider daemon is
    # down, or a host variable points somewhere else); 22 is curl --fail on
    # a non-2xx response
    # (e.g. an unknown model name returning 404). Anything else falls
    # through to a generic curl-exit-N message that names the code so the
    # caller can look it up.
    case "$canary_status" in
      28) canary_cause="did not return within ${preflight_timeout}s (curl --max-time fired)" ;;
      7)  canary_cause="could not reach $canary_url (connection refused; backend daemon may be down)" ;;
      22) canary_cause="received an HTTP error response (curl --fail; likely a bad model name or invalid payload)" ;;
      *)  canary_cause="failed with curl exit $canary_status" ;;
    esac
    {
      echo "delegate: pre-flight canary $canary_cause"
      echo "         recipe='$recipe' tier='$tier' model='$model' backend='$backend'"
      echo "         Options:"
      echo "         - retry with DELEGATE_PREFLIGHT_TIMEOUT=30 if cold-load is suspected"
      echo "         - start the provider daemon (mlx_lm.server, Docker Model Runner or ollama serve) and confirm MLX_HOST / DOCKER_MODEL_HOST / OLLAMA_HOST"
      echo "         - re-route to a smaller-parameter model on this host"
      echo "         - hand-write the output (recommended for 35B-class prose tiers on recipe-shaped prompts — see prompts/$recipe.md)"
      echo "         - silence the probe with DELEGATE_NO_PREFLIGHT=1 (sends the full request and inherits the failure)"
      echo "         still broken? file a bug: https://github.com/${DELEGATE_GITHUB_REPO:-IsmaelMartinez/delegate-local}/issues/new?template=bug_report.md"
    } >&2
    exit 3
  fi
fi

# Compose the input. The recipe template (if any) carries its own
# instruction structure, so it goes first; piped context follows unless it
# was already absorbed via the {{stdin}} marker; the user's prompt arg is
# the trailing instruction (often a one-line "match the example shape and
# tone." reinforcement). The leading-instruction-vs-prompt-last debate is
# settled empirically by the recipe authors — placeholder content lands
# inside the template, the prompt arg lands after.
parts=()
if [[ -n "$recipe_template" ]]; then
  parts+=("$recipe_template")
  if [[ -n "$context" ]] && (( recipe_had_stdin_marker == 0 )); then
    parts+=("$context")
  fi
  if [[ -n "$prompt" ]]; then
    parts+=("$prompt")
  fi
else
  if [[ -n "$context" ]]; then
    parts+=("$context")
  fi
  parts+=("$prompt")
fi

# Join with a blank line between parts.
full_input=""
for p in "${parts[@]}"; do
  if [[ -z "$full_input" ]]; then
    full_input="$p"
  else
    full_input="${full_input}

${p}"
  fi
done

# Build the JSON payload via jq so prompts containing quotes / backslashes /
# newlines are escaped correctly. Every provider speaks the same envelope:
# POST {base}/chat/completions, answer at .choices[0].message.content.
#
# curl -w "%{time_starttransfer}" reports seconds-from-curl-start until the
# first response byte arrived. This is the closest measurable proxy for
# "time the Ollama/MLX daemon spent queuing this request plus connecting
# plus model cold-load" — issue #170. We capture body and TTFB separately
# (-o body_file plus -w on stdout) so the response stays parser-clean and
# the timing flows into queue_wait_ms / generation_ms without disturbing
# the existing response-handling path.
body_file=$(mktemp)
trap 'rm -f "$body_file"' EXIT

# Sentinel for "the call succeeded but the model returned nothing". Deliberately
# above curl's exit-code range (curl tops out at 99) so it can never be confused
# with a transport failure: overloading a real curl code made the dispatch-
# failure block below print "curl exit 1" and advise restarting the daemon,
# which is the wrong diagnosis for an exhausted token budget. It also surfaces
# in the metrics row as exit_status:100, so the miss is visible to
# metrics-summary instead of looking like an ordinary short answer.
EMPTY_RESPONSE_STATUS=100
# Set alongside the sentinel; read by the failure block. Initialised here
# because delegate.sh runs under `set -u`.
empty_finish_reason=""

# dispatch_to_model <model> — build the backend request, POST it, parse the
# response into $output, and strip any leading reasoning trace. Sets the
# globals $output, $status, $ttfb_s, $payload. Strip-think is folded in here so
# a trace-emitting reasoning model has its chain-of-thought removed the same way
# every other model's output is.
dispatch_to_model() {
local _model="$1"
# Bounds the whole request including cold model load. Deliberately not
# validated: a non-numeric value makes curl exit 2 with its own clear
# "expected a proper numerical parameter" message, which is a better error
# than anything a hand-rolled check would print. Not local — the dispatch-
# failure guidance below reads it from the caller's scope, the same way it
# reads $status.
request_timeout="${DELEGATE_REQUEST_TIMEOUT:-600}"
# Every provider is reached the same way: POST {base}/chat/completions with the
# OpenAI chat shape. /v1/completions is the raw-prompt endpoint — it bypasses
# the model's chat template, so instruction-tuned models emit whitespace until
# max_tokens. /chat/completions wraps the input via apply_chat_template and
# produces real instruction-following output. The response carries
# .choices[0].message.content (and .choices[0].message.reasoning when thinking
# is on — chat_template_kwargs.enable_thinking is passed so the content field
# carries the answer rather than the reasoning trace).
max_tokens="${DELEGATE_MAX_TOKENS:-4096}"
# $think is already the normalised "true"/"false" string from the top of the
# script. Providers honour top_p / top_k / presence_penalty on the top-level
# options, so the sampler-profile overlay is built via jq additions and the
# payload carries only the keys the caller opted into via env vars; with no
# overrides it is the bare {temperature:0} greedy shape regardless of model
# family.
payload=$(jq -nc --arg m "$_model" --arg p "$full_input" --argjson mt "$max_tokens" --argjson et "$think" \
  --argjson temp "$sampling_temperature" \
  --arg top_p "$sampling_top_p" --arg top_k "$sampling_top_k" --arg pp "$sampling_presence_penalty" \
  '{model:$m, messages:[{role:"user", content:$p}], stream:false, temperature:$temp, max_tokens:$mt, chat_template_kwargs:{enable_thinking:$et}}
    + (if $top_p != "" then {top_p:($top_p|tonumber)} else {} end)
    + (if $top_k != "" then {top_k:($top_k|tonumber)} else {} end)
    + (if $pp != "" then {presence_penalty:($pp|tonumber)} else {} end)')
# resolved_base already had one trailing slash stripped by pick-model.sh, so
# the join cannot double up.
chat_url="$resolved_base/chat/completions"
ttfb_s=$(curl -sS --fail --max-time "$request_timeout" --connect-timeout 5 \
  -X POST "$chat_url" -d @- \
  -o "$body_file" -w "%{time_starttransfer}" <<< "$payload")
status=$?
if [[ "$status" -eq 0 ]]; then
  output=$(jq -r '.choices[0].message.content // ""' < "$body_file")
  # A well-formed response with empty content is a real failure, not a short
  # answer. Providers that ignore chat_template_kwargs.enable_thinking spend
  # the whole budget on reasoning — which lands in a separate `reasoning`
  # field, so `content` is genuinely empty — and return finish_reason
  # "length". Measured on Ollama 2026-08-18: at max_tokens 16 the answer is
  # "" while MLX and Docker Model Runner both return the real answer.
  if [[ -z "$output" ]]; then
    empty_finish_reason=$(jq -r '.choices[0].finish_reason // "unknown"' < "$body_file")
    status=$EMPTY_RESPONSE_STATUS
  fi
else
  output=""
fi

# Reasoning-trace strip, folded into dispatch so any trace-emitting reasoning
# model is stripped. Drops everything up to and
# including the first </think> and trims leading whitespace. Applies when
# DELEGATE_STRIP_THINK=1, or for the reasoning tier by default
# (DELEGATE_STRIP_THINK=0 force-disables even there). No-op when the response
# has no </think> or the call failed (empty output).
local _strip=0
if [[ "${DELEGATE_STRIP_THINK:-}" == "1" ]]; then
  _strip=1
elif [[ "$tier" == "reasoning" && "${DELEGATE_STRIP_THINK:-}" != "0" ]]; then
  _strip=1
fi
if (( _strip == 1 )) && [[ "$output" == *"</think>"* ]]; then
  output="${output#*</think>}"
  output="${output#"${output%%[![:space:]]*}"}"
fi
}

dispatch_to_model "$model"

# Dispatch-failure guidance. curl -sS already printed its own error line
# (e.g. "curl: (7) Failed to connect"); this adds the delegate-branded
# context and routes persistent breakage toward the bug template instead
# of leaving the caller with a bare non-zero exit.
if (( status == EMPTY_RESPONSE_STATUS )); then
  {
    echo "delegate: model returned an empty response — model=\"$model\" tier=\"$tier\" backend=\"$backend\""
    echo "         finish_reason=$empty_finish_reason"
    if [[ "$empty_finish_reason" == "length" ]]; then
      echo "         the budget was spent before any answer was emitted, which happens"
      echo "         when a thinking-capable model ignores the think:false hint"
      echo "         - raise DELEGATE_MAX_TOKENS (currently $max_tokens)"
      echo "         - or route this tier to a provider that honours enable_thinking"
    fi
    echo "         still broken? file a bug: https://github.com/${DELEGATE_GITHUB_REPO:-IsmaelMartinez/delegate-local}/issues/new?template=bug_report.md"
  } >&2
elif (( status != 0 )); then
  {
    echo "delegate: dispatch failed (curl exit $status) — model=\"$model\" tier=\"$tier\" backend=\"$backend\""
    if (( status == 28 )); then
      echo "         the request did not return within ${request_timeout}s (curl --max-time fired)"
      echo "         - raise DELEGATE_REQUEST_TIMEOUT if a cold model load is suspected"
      echo "         - or pick a smaller model for this tier"
    fi
    echo "         check the provider daemon (mlx_lm.server / Docker Model Runner / ollama serve) and MLX_HOST / DOCKER_MODEL_HOST / OLLAMA_HOST — see the README Troubleshooting section"
    echo "         still broken? file a bug: https://github.com/${DELEGATE_GITHUB_REPO:-IsmaelMartinez/delegate-local}/issues/new?template=bug_report.md"
  } >&2
fi

# (reasoning-trace strip now happens inside dispatch_to_model, above)

# Deterministic output checks (ADR 0014, extended by ADR 0017): a recipe's
# frontmatter `checks:` block declares constraints that run on the finalised
# output. Most are warn-only — a failure flags on stderr and never changes the
# exit status. The one exception is no_padding_tail, which ADR 0017 makes
# actionable: it AUTO-STRIPS the safe trailing participial-comma padding clause
# (recorded as checks_autofixed; still never touches the exit status). The value
# is converting a failure the prompt cannot reliably prevent under greedy
# decoding (an over-long subject, a trailing padding clause) from "the caller
# might notice" into "the wrapper always flags it, and fixes it where safe".
# Gated on the same clean-stderr conditions as the meta line so batch runs
# (NO_META) and failed calls stay quiet. The counts ride the delegate-meta line
# below (checks_failed=N / checks_autofixed=N) and persist to the metrics row.
# run_output_checks — run the recipe's declared deterministic checks on the
# current $output, setting $checks_run / $checks_failed / $checks_autofixed.
# $capability_failed counts only the non-style checks (subject_max / subject_type
# / body_required) and excludes the style check no_padding_tail (the auto-strip
# owns it). It is retained as an observable counter; nothing currently reads it.
run_output_checks() {
# Locals keep the per-call scratch state out of the global scope now that this
# is a function (it ran at top level before the refactor). The result and the
# counters — output, checks_run/failed/autofixed, capability_failed — are
# deliberately NOT local: they are the function's outputs.
local padding_re padding_re_adopt check_first_line check_last_line cline ckey cval stripped new_output new_last subj_type body_lines body_words echoed_line echo_exemplars _egv _kv list_items
checks_failed=0
checks_failed_names=""
checks_run=0
checks_autofixed=0
capability_failed=0

# no_example_echo — the one check that is ON by default for every recipe call
# rather than declared per-recipe, because "the model copied a line out of the
# prompt instead of writing one" is never a correct outcome for any recipe.
# Measured 2026-08-26: two `maintainer-reply` calls carrying 7.7k and 7.3k
# chars of piped context each returned 96 characters, byte-identical, and
# 96 characters is exactly the recipe's own `Correct:` example line. The
# contrastive-anchor pattern (ADR 0011) that makes these recipes work is the
# same pattern that hands the model a fluent, on-topic sentence to fall back
# on when the real input is long; the earlier AI-815 leak in pr-description
# was the same shape. Prompt text alone cannot close this — the guards telling
# the model not to copy are themselves lines it can copy — so it becomes a
# deterministic post-generation check.
#
# Comparison is against $recipe_template_raw (pre-substitution) so only
# recipe-AUTHORED text is a pattern; the substituted template contains the
# caller's own context, and legitimately reproducing a supplied fact must
# never flag. Matching is whole-line, literal (grep -F, no regex, so linear
# time), after trimming surrounding whitespace and any `Wrong:` / `Correct:`
# label from the anchor lines. The 40-char floor keeps short shared lines
# (a heading, a sign-off, a fence) from colliding by coincidence.
#
# Opt out per recipe with `no_example_echo: false` in the frontmatter checks
# block — for a recipe whose output is genuinely supposed to reproduce a long
# boilerplate line from its own template — or for one call with
# DELEGATE_NO_ECHO_CHECK=1.
if [[ "${DELEGATE_LOCAL_NO_META:-}" != "1" ]] && (( status == 0 )) \
   && [[ -n "${recipe_template_raw:-}" ]] \
   && [[ "${DELEGATE_NO_ECHO_CHECK:-}" != "1" ]] \
   && [[ "${recipe_checks:-}" != *"no_example_echo: false"* ]]; then
  checks_run=$((checks_run + 1))
  # Exemplar --var values join the template as forbidden-output patterns when
  # the recipe declares them (issue #428). Verified case: `commit-message` was
  # handed three real recent commits as shape anchors and returned one of them
  # as its subject, so the message named v4.37.6 — the version the change was
  # bumping AWAY from — and dropped half the change. The exemplar reads to the
  # model as something to copy rather than as background.
  #
  # Two normalisations make that catchable. The conventional-commit type
  # prefix and a trailing ` (#123)` are stripped from both sides, because the
  # echo arrived as `ci: <copied subject>` against an anchor of
  # `chore(deps): <same subject> (#253)` — a whole-line compare without them
  # misses the most common shape of the bug. And a line that appears in MORE
  # than one exemplar is dropped from the pattern set: repeated across the
  # anchors means convention or boilerplate (a trailer, a generated-by line, a
  # section heading), which the output is supposed to reproduce. Only a line
  # unique to a single exemplar is that exemplar's own content.
  echo_exemplars=""
  if [[ -n "${recipe_echo_guard_vars:-}" ]]; then
    for _egv in $(printf '%s' "$recipe_echo_guard_vars" | tr ',' ' '); do
      for _kv in ${recipe_vars[@]+"${recipe_vars[@]}"}; do
        if [[ "${_kv%%=*}" == "$_egv" ]]; then
          echo_exemplars="${echo_exemplars}${_kv#*=}
"
        fi
      done
    done
  fi
  # The same normalisation runs on BOTH sides. Stripping the label only from
  # the template side left a false negative: a model that copies the whole
  # line, label included, produces "Correct: <sentence>" which no longer
  # matches the stripped "<sentence>" pattern, so the most literal possible
  # echo was the one that got through.
  # ONE normalisation, applied identically to every pattern source and to the
  # output. Asymmetry is how this check has failed twice: first the
  # `Wrong:`/`Correct:` label was stripped from the template side only, so an
  # echo that kept its label slipped through; then the conventional-commit
  # prefix was stripped from the output side only, so an echoed template
  # example that began `fix:` stopped matching the pattern it came from. Any
  # future rule added here must go in echo_normalise and nowhere else.
  #
  # sed -E: making the `(scope)` of a conventional-commit prefix optional needs
  # an ERE group, which BRE cannot express in one pass. BSD and GNU both take
  # -E. Order matters — the label comes off before the type prefix, so a
  # `Correct: fix: X` example reduces all the way to `X`.
  echo_normalise() {
    sed -E -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
           -e 's/^[Ww]rong:[[:space:]]*//' -e 's/^[Cc]orrect:[[:space:]]*//' \
           -e 's/^[a-z]+(\([^)]*\))?!?:[[:space:]]*//' \
           -e 's/[[:space:]]*\(#[0-9]+\)$//'
  }
  echoed_line=$( { printf '%s\n' "$recipe_template_raw" | echo_normalise
    if [[ -n "$echo_exemplars" ]]; then
      # uniq -u keeps only lines appearing exactly once across the exemplars;
      # anything repeated is convention the output is meant to reproduce.
      printf '%s' "$echo_exemplars" | echo_normalise | sort | uniq -u
    fi; } \
    | awk 'length($0) >= 40' \
    | grep -Fxf - <(printf '%s\n' "$output" | echo_normalise) \
    | head -n 1)
  if [[ -n "$echoed_line" ]]; then
    echo "delegate: check 'no_example_echo' FAILED — REJECT this draft. The model" >&2
    echo "  reproduced a line from its own prompt (the recipe's example, or one of the" >&2
    echo "  exemplars you passed as a shape anchor) instead of writing one from your" >&2
    echo "  content: \"${echoed_line:0:120}\"" >&2
    echo "  The draft is not grounded in the input. Re-run or hand-write; do not ship it." >&2
    checks_failed=$((checks_failed + 1))
    checks_failed_names="${checks_failed_names:+$checks_failed_names,}no_example_echo"
    capability_failed=$((capability_failed + 1))
  fi
fi

if [[ "${DELEGATE_LOCAL_NO_META:-}" != "1" ]] && (( status == 0 )) && [[ -n "${recipe_checks:-}" ]]; then
  # Signatures of the recurring BODY_NO_PADDING failure: a trailing participial
  # clause, a "This-X" declarative rephrase, or a known restating phrase. The
  # participial arm is STRUCTURAL — `, <word>ing` matches any gerund tail rather
  # than an enumerated verb list, because the 2026-06-07 MISS-cluster analysis
  # showed ~3/4 of cited padding verbs (confirming, lifting, undermining,
  # preserving, documenting…) were unenumerated: per-verb enumeration is a
  # treadmill the model walks off by reaching for the next unlisted verb. This
  # mirrors the proven matcher in experiments/score-t4.sh (`[a-z]{3,}ing`, whose
  # {3,} floor carries the same trade-off, documented there). The participial arm
  # is anchored to the end of the line: the check is named for a TAIL, and an
  # unanchored arm flagged load-bearing mid-sentence clauses as padding.
  #
  # Measured 2026-08-19 over the last PROSE line of 301 commits that have a real
  # body: the unanchored form raises 12 flags, of which 7 are false positives,
  # and this arm raises 4 flags, all of them genuine padding tails. Git trailers
  # are stripped before taking that line; an earlier count of "297 bodies" was
  # 93% trailers, because bash `case` is case-sensitive and so missed GitHub's
  # squash-merge `Co-authored-by:`.
  #
  # Three details below are load-bearing and each was measured, so do not
  # "simplify" them away:
  #   - the `([[:space:]]…)?` keeps `ing` a WORD ending. Dropping it makes
  #     `[a-z]{3,}ing` a prefix match and every `-ings` plural (settings,
  #     warnings, findings, strings, mappings) becomes a false positive.
  #   - the class permits commas, so a genuine tail may contain them
  #     (`, ensuring the cache, the limiter and the queue stay in sync`); what it
  #     may not do is cross a sentence boundary.
  #   - the `{0,200}` bound keeps the match linear. Unbounded, the comma-crossing
  #     class makes each comma position rescan the rest of the line: GNU grep in
  #     a UTF-8 locale (what CI and the Docker image run) measured 6336ms on a
  #     72KB line against 3ms for the bounded form.
  # ACCEPTED GAP: a tail containing a non-terminal full stop (`, ensuring parity
  # with Node.js consumers.`, a version number, a dotted filename) is not
  # detected. #390 proposed recovering it and was measured and DECLINED: on the
  # no-match path production actually takes, the candidate ran 41ms to 6881ms as
  # the line grew 5KB to 83KB (quadratic), dropping the {0,200} bound would have
  # silently auto-stripped filler tails over 200 chars, and the recovered shapes
  # can never be auto-fixed anyway because the perl strip's own [^,.!?]* cannot
  # cross a dot either. Roughly 1 body in 300 carries the shape. Do not retry
  # without reading #390 first.
  # The This-X arm stays enumerated to bound false positives
  # but is extended with the gap verbs the same analysis surfaced (prevents,
  # avoids, serves). Warn-only framing keeps any false positive cheap.
  padding_re=',[[:space:]]+[a-z]{3,}ing([[:space:]][^.!?]{0,200})?[.!?]?[[:space:]]*$|(^|[.!?][[:space:]]+)(this[[:space:]]+(means|approach|ensures|enables|guarantees|delivers|provides|prevents|avoids|serves)|in summary|overall|consequently|ultimately|in effect|as a result)\b|(going|moving)[[:space:]]+forward|clos(es|ing)[[:space:]]+the[[:space:]]+(gap|loop)'
  # ADR 0017's adoption rule, held byte-identical to the pre-anchor expression on
  # purpose. The strip is gated twice by a padding match: once to fire, and again
  # here to decide whether the stripped text is clean enough to adopt. Anchoring
  # THAT second gate would widen the strip, because a result still carrying a
  # mid-line participial would newly read as clean and be adopted, silently
  # mutating output ADR 0017 deliberately left alone with a warning. Detection
  # narrows; adoption does not.
  padding_re_adopt=',[[:space:]]+[a-z]{3,}ing([[:space:]]|[.!?,]|$)|(^|[.!?][[:space:]]+)(this[[:space:]]+(means|approach|ensures|enables|guarantees|delivers|provides|prevents|avoids|serves)|in summary|overall|consequently|ultimately|in effect|as a result)\b|(going|moving)[[:space:]]+forward|clos(es|ing)[[:space:]]+the[[:space:]]+(gap|loop)'
  check_first_line=$(printf '%s' "$output" | awk 'NF { print; exit }')
  check_last_line=$(printf '%s' "$output" | awk 'NF { l=$0 } END { print l }')
  while IFS= read -r cline; do
    # Parse `  key: value` in-process (no sed subshells in this per-line loop);
    # non-matching/blank lines are skipped. The nested-expansion trim drops any
    # trailing whitespace on the value (bash 3.2 safe).
    if [[ "$cline" =~ ^[[:space:]]*([a-zA-Z_]+):[[:space:]]*(.*)$ ]]; then
      ckey="${BASH_REMATCH[1]}"
      cval="${BASH_REMATCH[2]}"
      cval="${cval%"${cval##*[![:space:]]}"}"
    else
      continue
    fi
    case "$ckey" in
      subject_max)
        if [[ "$cval" =~ ^[0-9]+$ ]]; then
          checks_run=$((checks_run + 1))
          if (( ${#check_first_line} > cval )); then
            echo "delegate: check 'subject_max' FAILED — first line is ${#check_first_line} chars (> $cval)" >&2
            checks_failed=$((checks_failed + 1))
            checks_failed_names="${checks_failed_names:+$checks_failed_names,}subject_max"
            capability_failed=$((capability_failed + 1))
          fi
        fi
        ;;
      no_padding_tail)
        if [[ "$cval" == "true" ]]; then
          checks_run=$((checks_run + 1))
          if printf '%s' "$check_last_line" | grep -Eiq "$padding_re"; then
            # Padding detected. Detection (above) is intentionally broad — any
            # `, <gerund>` tail — for full recall. The auto-strip is deliberately
            # NARROWER for precision: it fires only on a trailing
            # ", <filler-gerund> ...<end>" clause where the gerund is one of a
            # focused FILLER-verb allowlist and there is no comma inside the
            # clause. The allowlist (not the broad structural matcher) is what
            # keeps the mutation from deleting a meaningful participial like
            # "..., preserving insertion order" — those stay a FAILED warning for
            # the reviewer rather than being silently removed. The strip is then
            # adopted only if it is non-empty (a perl failure returns nothing) AND
            # actually clears the padding; otherwise the original output is kept
            # untouched, so a FAILED verdict always matches the emitted text. The
            # "This-X"/"in summary" shapes are never auto-stripped. Opt out with
            # DELEGATE_NO_AUTOFIX=1.
            stripped=0
            if [[ "${DELEGATE_NO_AUTOFIX:-}" != "1" ]]; then
              new_output=$(printf '%s' "$output" | perl -0777 -pe '
                my @l = split /\n/, $_, -1;
                for (my $i = $#l; $i >= 0; $i--) {
                  next if $l[$i] =~ /^\s*$/;            # skip trailing blank lines
                  $l[$i] =~ s/(\S.*\S)\s*,\s+(?:ensuring|confirming|allowing|enabling|providing|leading|reflecting|making|supporting|helping|keeping|maintaining|delivering|guaranteeing|underscoring|highlighting|streamlining|facilitating|promoting|fostering|paving|cementing|reinforcing)\b[^,.!?]*([.!?])?\s*$/$1 . (defined $2 ? $2 : ".")/ie;
                  last;                                  # only the last non-empty line
                }
                $_ = join("\n", @l);
              ')
              if [[ -n "$new_output" && "$new_output" != "$output" ]]; then
                new_last=$(printf '%s' "$new_output" | awk 'NF { l=$0 } END { print l }')
                if ! printf '%s' "$new_last" | grep -Eiq "$padding_re_adopt"; then
                  output="$new_output"
                  check_first_line=$(printf '%s' "$output" | awk 'NF { print; exit }')
                  check_last_line="$new_last"
                  stripped=1
                fi
              fi
            fi
            if (( stripped )); then
              echo "delegate: check 'no_padding_tail' AUTO-FIXED — stripped a trailing participial padding clause" >&2
              checks_autofixed=$((checks_autofixed + 1))
            else
              echo "delegate: check 'no_padding_tail' FAILED — output ends on a padding/restating clause" >&2
              checks_failed=$((checks_failed + 1))
              checks_failed_names="${checks_failed_names:+$checks_failed_names,}no_padding_tail"
            fi
          fi
        fi
        ;;
      subject_type)
        # Caller-supplied conventional-commit type the subject MUST carry. The
        # value rides {{key}} substitution, so `subject_type: {{type}}` is the
        # caller's --var type=X echoed here; an omitted (optional) type collapses
        # to empty and the check is skipped — it only fires when the caller
        # asserted a type and the model ignored it (a recurring MISS the recipe
        # was built to catch). Compared with pure
        # string ops, not a regex built from cval, so a regex metacharacter in
        # the caller's --var type can't break the match. Strips the optional
        # `!` and `(scope)` from the subject's pre-colon segment so the full
        # conventional shape (type, type(scope), type!, type(scope)!) is honoured.
        if [[ -n "$cval" ]]; then
          checks_run=$((checks_run + 1))
          subj_type="${check_first_line%%:*}"   # segment before the first colon
          subj_type="${subj_type%!}"            # drop a trailing ! (type!: form)
          subj_type="${subj_type%%(*}"          # drop a (scope) suffix
          if [[ "$check_first_line" != *:* || "$subj_type" != "$cval" ]]; then
            echo "delegate: check 'subject_type' FAILED — subject does not start with '$cval:' (got '${check_first_line%%:*}:')" >&2
            checks_failed=$((checks_failed + 1))
            checks_failed_names="${checks_failed_names:+$checks_failed_names,}subject_type"
            capability_failed=$((capability_failed + 1))
          fi
        fi
        ;;
      body_required)
        # A commit body is required: fail when the model returns a subject-only
        # message (fewer than 2 non-empty lines). Mirrors the no_padding_tail
        # boolean gate. `printf '%s\n'` guarantees a trailing newline so awks that
        # drop a final unterminated line still count it; `tr -d '\r'` strips CRs
        # portably so a CRLF blank separator (a lone \r is non-whitespace to awk)
        # is not miscounted; the NF idiom then counts non-empty lines so an LF
        # blank separator between subject and body is not counted. The `+ 0` keeps
        # the count numeric (0) on empty output so the compare can't choke.
        if [[ "$cval" == "true" ]]; then
          checks_run=$((checks_run + 1))
          body_lines=$(printf '%s\n' "$output" | tr -d '\r' | awk 'NF { n++ } END { print n + 0 }')
          if (( body_lines < 2 )); then
            echo "delegate: check 'body_required' FAILED — output is subject-only ($body_lines non-empty line(s), need >= 2)" >&2
            checks_failed=$((checks_failed + 1))
            checks_failed_names="${checks_failed_names:+$checks_failed_names,}body_required"
            capability_failed=$((capability_failed + 1))
          fi
        fi
        ;;
      body_max_words)
        # ADR 0014 length check for the BODY (everything after the first blank
        # line), counted in words. Added 2026-08-26 after eight rejections in a
        # week named an over-long body and three captured draft/final pairs
        # separated cleanly: every shipped body came in at 31-45 words, every
        # draft that had to be cut at 56-104, with nothing in between. The
        # prompt has asked for "1-2 short flowing-prose paragraphs" under a
        # "mandatory, non-negotiable" heading the whole time, which is why this
        # is a check rather than a third rewording of the instruction.
        #
        # The limit is a flavor placeholder, not a constant: how long a commit
        # body should be is house style, and the shipped default only enforces
        # the prompt's own stated contract. Tighten it in profile.sh.
        if [[ "$cval" =~ ^[0-9]+$ ]]; then
          checks_run=$((checks_run + 1))
          # tr -d '\r' first, for the same reason body_required does it: a CRLF
          # blank separator is a lone \r, which some awks do not count as
          # [[:space:]], and the separator would then never be found so the
          # body would measure 0 words and always pass. BWK awk (macOS) does
          # match it and the bug is invisible there; CI runs mawk.
          body_words=$(printf '%s\n' "$output" | tr -d '\r' | awk '
            BEGIN { s = 0 }
            s { n += NF; next }
            /^[[:space:]]*$/ { s = 1 }
            END { print n + 0 }')
          if [[ "$body_words" =~ ^[0-9]+$ ]] && (( body_words > cval )); then
            echo "delegate: check 'body_max_words' FAILED — body is $body_words words (> $cval)" >&2
            checks_failed=$((checks_failed + 1))
            checks_failed_names="${checks_failed_names:+$checks_failed_names,}body_max_words"
            capability_failed=$((capability_failed + 1))
          fi
        fi
        ;;
      no_single_item_list)
        # A numbered list holding exactly ONE item is never a correct reply.
        # Both reply recipes say so from opposite directions: MULTI-ASK-SPLIT
        # rule 2 gives each of two-or-more asks its own item, and rule 4 says a
        # single ask is one sentence however many clauses it carries. So a
        # one-item list breaks the recipe on whichever branch the caller is on,
        # and the check needs no knowledge of how many asks were passed in.
        #
        # This is the third attempt at the same defect and the first that is
        # not prompt text. MULTI-ASK-SPLIT (2026-08-03) introduced the numbered
        # shape, rules 4 and 5 (2026-08-26) tried to bound it to genuine
        # multi-ask input, and hours after those landed a single ask came back
        # as `1. Would you like to apply the two inline suggestions ...` on
        # pr-agent. Per docs/self-improvement-loop.md, a defect that survives
        # two rewordings gets a check instead of a third one.
        #
        # Warn-only, like every declared check except no_padding_tail. The
        # counting matches body_required's idiom: `printf '%s\n'` guarantees a
        # final newline, `tr -d '\r'` keeps a CRLF line from hiding the marker
        # from awks that do not treat a lone \r as whitespace.
        if [[ "$cval" == "true" ]]; then
          checks_run=$((checks_run + 1))
          list_items=$(printf '%s\n' "$output" | tr -d '\r' \
            | awk '/^[[:space:]]*[0-9]+[.)][[:space:]]/ { n++ } END { print n + 0 }')
          if [[ "$list_items" =~ ^[0-9]+$ ]] && (( list_items == 1 )); then
            echo "delegate: check 'no_single_item_list' FAILED — output is a numbered list of one item; a single ask is one sentence" >&2
            checks_failed=$((checks_failed + 1))
            checks_failed_names="${checks_failed_names:+$checks_failed_names,}no_single_item_list"
            capability_failed=$((capability_failed + 1))
          fi
        fi
        ;;
      no_example_echo)
        # Handled before this loop (it is on by default for every recipe, not
        # declared per-recipe); the frontmatter key exists only as an opt-out
        # switch, so it is accepted here and does nothing.
        ;;
      *)
        echo "delegate: unknown check '$ckey' in recipe '$recipe' — ignored" >&2
        ;;
    esac
  done <<< "$recipe_checks"
fi
}

# Run the checks on the primary (tier-resolved) output.
run_output_checks

end_epoch_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
duration_ms=$((end_epoch_ms - start_epoch_ms))

# Derive queue_wait_ms and generation_ms from curl's time_starttransfer
# (seconds-float). awk handles the float→int conversion without depending
# on bc (not always installed on stripped CI images). If curl failed or
# emitted an empty TTFB (some failure modes leave ttfb_s blank), fall back
# to attributing the whole duration to generation_ms so the two fields
# still sum to duration_ms and consumers can detect "no queue split
# available" by queue_wait_ms == 0 on a failed call. Clamp queue_wait_ms
# at duration_ms in case clock skew or sub-millisecond rounding pushes
# it above; the generation_ms = duration_ms - queue_wait_ms invariant
# stays intact.
queue_wait_ms=0
if [[ -n "${ttfb_s:-}" ]] && [[ "$status" -eq 0 ]]; then
  queue_wait_ms=$(awk -v s="$ttfb_s" 'BEGIN { printf "%.0f", s * 1000 }')
  if (( queue_wait_ms > duration_ms )); then
    queue_wait_ms=$duration_ms
  fi
fi
generation_ms=$((duration_ms - queue_wait_ms))

# Char counts that feed both the metrics row and the stderr meta line. Both
# surfaces route through compute_tokens_local so the two cannot drift on
# the formula — the assistant surfaces `tokens_local` from the stderr line
# while metrics-summary.sh rolls up `estimated_tokens_avoided` from the
# JSONL; if they ever disagreed, "how much have I saved" would mean two
# different things depending on which surface you ask.
prompt_chars=$(( ${#recipe_template} + ${#prompt} ))
context_chars=${#context}
output_chars=${#output}
tokens_local=$(compute_tokens_local "$prompt_chars" "$context_chars" "$output_chars")

draft_file=""
if (( status == 0 )); then
  draft_file=$(capture_draft "$output" "$ts_start")
fi
log_metric "$ts_start" "$tier" "$model" "$prompt_chars" "$context_chars" "$output_chars" "$duration_ms" "$status" "$recipe" "$queue_wait_ms" "$generation_ms" "$otel_trace_id" "$otel_span_id" "$metric_sampling_temperature" "$metric_sampling_top_p" "$metric_sampling_top_k" "$metric_sampling_presence_penalty" "$delegate_project" "$checks_run" "$checks_failed" "$checks_autofixed" "$checks_failed_names" "$draft_file"
emit_otel_span "$start_epoch_ms" "$duration_ms" "$status" "$otel_trace_id" "$otel_span_id" "$model" "$backend" "$tier" "$recipe" "$prompt_chars" "$context_chars" "$output_chars" "$queue_wait_ms" "$generation_ms" "$tokens_local" "${recipe_template}${prompt}" "$context" "$output" "$delegate_project"

# Structured stderr contract — the line SKILL.md teaches the assistant to
# read after every delegation, so it can tell the user which model handled
# the work and how many tokens stayed on-device. Format is parser-friendly
# `key=value` pairs separated by spaces (matches the verdict-nudge plain-text
# convention rather than the JSONL machine surface — humans skim this line
# too). Conditions: successful call only (status==0; meaningless on a failed
# call where there's no output to count), silenceable via NO_META for batch
# runs that want clean stderr. The `tokens_local` value is the local-model
# tokenizer's view (chars/4 estimate, same number as the JSONL row's
# `estimated_tokens_avoided`) — not Anthropic's tokenizer, hence "kept local"
# framing in SKILL.md rather than "saved from Claude".
if [[ "${DELEGATE_LOCAL_NO_META:-}" != "1" ]] \
   && (( status == 0 )); then
  # String-typed fields are quoted so a model or recipe name containing a
  # space stays a single token rather than ambiguating the format ("recipe=my
  # name" otherwise reads as `recipe=my` + bare `name`). Today's Ollama tags
  # and MLX HF identifiers don't have spaces, but model ids come from whatever
  # a provider reports and the JSONL surface already escapes them via jq;
  # the stderr surface owes the same defensive shape — flagged on PR #133.
  # Integer fields (tokens_local, duration_ms) stay bare to avoid visual
  # noise on the line.
  meta="model=\"$model\" tier=\"$tier\" backend=\"$backend\" tokens_local=$tokens_local duration_ms=$duration_ms"
  if [[ -n "$recipe" ]]; then
    meta="$meta recipe=\"$recipe\""
  fi
  if (( checks_failed > 0 )); then
    meta="$meta checks_failed=$checks_failed"
  fi
  if (( checks_autofixed > 0 )); then
    meta="$meta checks_autofixed=$checks_autofixed"
  fi
  echo "delegate-meta: $meta" >&2
fi

# Verdict nudge — without it the metrics file accumulates "untracked" rows
# (delegate row with no matching feedback row) and the recipe library can't
# self-correct from production data. Fires unconditionally on success when
# metrics are on, regardless of stdin/stdout shape. A TTY-only gate was
# considered (issue #139 / PR #140) to avoid noisy CI stderr, but the cost
# of the silent-skip on Agent SDK callers — the highest-volume users of
# delegate.sh and the only ones whose verdicts feed future recipe iterations
# — proved higher than the cost of an extra stderr line in CI logs. Lifetime
# coverage was 47.8% under the TTY-gate approach; removing the gate is the
# fix for issue #149. The three escape hatches stay: NO_VERDICT_NUDGE (opt
# out per call), NO_METRICS (no metrics row → nothing to verdict against),
# and non-zero exit (failed calls have no model output to judge). Issue #139
# (parallel-capture callers contaminating stdout via 2>&1) is addressed
# without re-introducing the coverage-losing gate by routing the nudge to a
# caller-chosen file descriptor via DELEGATE_LOCAL_VERDICT_NUDGE_FD=N
# (default 2 = back-compat); the caller-side recipe is to redirect fd N
# alongside the 2>&1 capture so coverage tracking stays intact while stdout
# stays clean.
if [[ "${DELEGATE_LOCAL_NO_METRICS:-}" != "1" ]] \
   && [[ "${DELEGATE_LOCAL_NO_VERDICT_NUDGE:-}" != "1" ]] \
   && (( status == 0 )); then
  # nudge_fd was validated up-front (see "Validate the verdict-nudge FD"
  # block at the top); the value here is guaranteed to be a positive integer.
  # The fd=2 path is the default, back-compat shape — write directly so the
  # nudge can't be lost. The fd!=2 path wraps the echo + redirect in a
  # compound `{ ...; } 2>/dev/null` so bash's "Bad file descriptor" error
  # (emitted by the shell when the >&N redirect can't be set up against a
  # closed fd, not by the echo command) is absorbed. A bare `echo ... >&"$N"
  # 2>/dev/null` only catches what echo writes; the redirect-failure noise
  # would still leak back to the very fd 2 the caller was trying to keep
  # clean. The two branches keep fd=2 callers simple and only pay the
  # absorption cost on the gotcha-prone redirect path. Pin verified on
  # macOS bash 3.2.57.
  # The nudge names the WHOLE contract, because it is the only place most
  # callers ever read it. It listed two verdicts and no --final until
  # 2026-08-26, and the corpus showed the cost: of 47 rejections only 2 carried
  # the text that actually shipped, and 12 carried no reason at all, so the
  # calibration loop had almost nothing to diff. `scaffold` is here for the
  # same reason — a draft you edited and shipped is not a miss, and recording
  # it as one both understates quality and fires the recurrence nudge on a
  # non-defect.
  nudge_msg='delegate: record verdict → bash scripts/delegate-feedback.sh --source agent hit | scaffold "<reason>" | miss "<reason>"
delegate:   on scaffold/miss also pass --final <path|-> naming what you shipped instead. The draft is already saved; the pair is what calibrates the recipe.
delegate:   scaffold = you edited it and shipped it, miss = you threw it away; drop --source if you are a human recording a taste judgment'
  if (( nudge_fd == 2 )); then
    echo "$nudge_msg" >&2
  else
    { echo "$nudge_msg" >&"$nudge_fd"; } 2>/dev/null
  fi
fi

printf '%s\n' "$output"
exit $status
