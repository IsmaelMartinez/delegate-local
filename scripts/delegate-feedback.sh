#!/usr/bin/env bash
# Append a hit/miss feedback event to the delegate metrics JSONL, referencing
# the `source:"delegate"` row pinned by `--id <otel_span_id>` (or `--ts`), or
# the one row inside the freshness window when no pin is given. Lets the
# agent that requested the delegation record whether it used the output as-is
# (hit), edited it and shipped it (scaffold), or rewrote/discarded it (miss),
# with a one-line reason that is mandatory on scaffold and miss.
#
# The file remains append-only — feedback events join the JSONL as their own
# rows, keyed by `ref_ts` (and `ref_id`, the row's otel_span_id) to the
# delegate event they evaluate. `metrics-summary.sh` joins them at read time
# to compute hit-rate per tier / model. Every row carries
# verdict_source:"agent": there is one verdict tier (ADR 0030), the agent's.
#
# Usage:  delegate-feedback.sh [--id <otel_span_id>|--ts <iso8601>]
#                              [--source agent] [--final <path>|-]
#                              hit|miss|scaffold [reason words...]
# Env:
#   DELEGATE_LOCAL_DATA_DIR     where per-user data lives
#                               (default ~/.local/share/delegate-local)
#   DELEGATE_METRICS_FILE                 override default metrics path
#   DELEGATE_FEEDBACK_STALE_SECONDS       the window an unpinned verdict looks
#                                         in: exactly one delegate row inside
#                                         it is the row, more than one refuses
#                                         as ambiguous, none refuses as stale
#                                         (#474) (default 300; set 0 to attach
#                                         to the most recent row unbounded).
#   DELEGATE_FEEDBACK_NO_NUDGE            set to 1 to silence the trigger-on-
#                                         MISS recurrence nudge.
#   DELEGATE_FEEDBACK_NUDGE_AT            minimum total similar MISSes (this
#                                         one included) to trigger the nudge
#                                         (default 3).
#   DELEGATE_FEEDBACK_NUDGE_WINDOW_DAYS   lookback for similar MISS counting
#                                         (default 30).
#   DELEGATE_FEEDBACK_SIMILAR_THRESHOLD   Jaccard similarity (over content
#                                         tokens, stopwords removed) at which
#                                         two MISS reasons are considered
#                                         similar (default 0.4).
#   DELEGATE_GITHUB_REPO                  owner/repo the draft `gh issue
#                                         create` nudge command targets
#                                         (default IsmaelMartinez/delegate-local;
#                                         forks set their own).
#   DELEGATE_OTEL_ENDPOINT                Phase 11 Track A (#134). When set,
#                                         POST a feedback-as-linked-span to
#                                         this OTLP/HTTP traces URL after the
#                                         feedback JSONL row is written. The
#                                         feedback span is a NEW trace whose
#                                         `links` array points back to the
#                                         parent delegation's trace/span IDs
#                                         (per ADR 0007). Off by default.
#                                         The POST is SYNCHRONOUS — a hung
#                                         collector adds up to
#                                         DELEGATE_OTEL_TIMEOUT seconds of
#                                         user-visible latency per feedback
#                                         call. Set DELEGATE_OTEL_VERBOSE=1
#                                         to diagnose, or unset the endpoint
#                                         to disable.
#   DELEGATE_OTEL_TIMEOUT                 default 5. curl --max-time on the
#                                         OTLP POST so a hung collector
#                                         cannot block the script.
#   DELEGATE_OTEL_VERBOSE                 when =1, log exporter failures to
#                                         stderr. Default silent. Use this
#                                         to diagnose suspected exporter
#                                         failures (timeouts, auth, DNS).
#   DELEGATE_OTEL_HEADERS                 optional. Comma-separated
#                                         Header: value pairs for collector
#                                         auth (Grafana Cloud, Langfuse).
#                                         Per OTel SDK convention, values
#                                         containing commas (or any
#                                         reserved char) MUST be url-
#                                         encoded — the script url-decodes
#                                         each value before emitting -H
#                                         flags so the on-wire header is
#                                         the literal original.
#   DELEGATE_OTEL_INCLUDE_CONTENT         Phase 11 Track F (#158). When =1,
#                                         include the free-text
#                                         `delegate.feedback.reason`
#                                         attribute on the feedback span.
#                                         Default unset = redact: only
#                                         metadata (verdict, parent IDs)
#                                         leaves the host. WARNING: the
#                                         reason field is user-authored
#                                         free text and may carry PII,
#                                         API keys, internal URLs, or
#                                         model output excerpts; only
#                                         enable this against trusted
#                                         collectors. See ADR 0007 +
#                                         docs/otel-schema.md.
# Exit:   0 OK, 1 file/event missing or stale, 2 usage error. OTLP-export
#         failures NEVER change the exit status — telemetry is non-fatal.

set -uo pipefail

metrics_file="${DELEGATE_METRICS_FILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/metrics.jsonl}"
stale_seconds="${DELEGATE_FEEDBACK_STALE_SECONDS:-300}"
github_repo="${DELEGATE_GITHUB_REPO:-IsmaelMartinez/delegate-local}"

usage() {
  cat >&2 <<'EOF'
usage: delegate-feedback.sh [--id <otel_span_id>|--ts <iso8601>] [--source agent]
                           [--final <path>|-] hit|miss|scaffold [reason words...]
  hit = output kept as-is; miss = rewritten/discarded as useless; scaffold =
  discarded but genuinely useful (a divergent or executable draft that improved
  the final result). scaffold is recorded distinct from both and never fires the
  MISS-recurrence nudge. A miss or scaffold REQUIRES a reason: the agent
  recording its own just-finished delegation always knows why it rewrote the
  draft, and a rejection with no reason counts in every denominator while
  telling the loop nothing.
  --id pins the verdict to one delegate row by its otel_span_id — the value
  delegate.sh prints on its delegate-meta line as id="..." and in the
  verdict nudge. It is the only pin that cannot name two rows: ts has
  second precision and parallel delegations share it, so --ts (kept for
  older callers) refuses when more than one row carries that second.
  Without a pin, the verdict attaches to the one delegate row inside the
  freshness window (default 300 s); with parallel sessions "most recent" is
  routinely someone else's, so two fresh rows refuse and list the
  candidates with their ids, and none refuses as stale. The verdict's
  project is copied from the row it references.
  --source agent is the default and the only value: the agent that used or
  rewrote the draft records the verdict (ADR 0030). The flag is accepted so
  existing callers keep working; --source human is refused, because that
  tier was retired.
  --final stores the text that ACTUALLY shipped (a file path, or - for
  stdin) beside the captured draft, so a MISS carries the concrete
  (generated, shipped) pair instead of only a prose description of the
  difference. This is the signal recipe edits are calibrated from.
  All three flags may appear anywhere on the line, including after the
  reason words. Put `--` before the verdict when the reason itself needs
  to name a flag, e.g. `-- miss "the nudge should say --final"`.
EOF
  exit 2
}

# Argument parsing. Flags are honoured wherever they appear — before the
# verdict, after it, or after the reason words — and the positional arguments
# are collected in order and re-established as "$@" once scanning is done.
#
# Parsing used to stop at the first non-flag argument, which is always the
# verdict, so anything after it was reason words. Measured 2026-08-27: three
# rejections in the live corpus recorded a reason ending
# `--final /Users/.../tmp/msg.txt` and stored no shipped text at all. Against
# 17 successfully stored finals that is 3 of 20 capture attempts lost, and each
# loss is a rejection that reaches the loop as prose about a draft nobody can
# look at again — the ceiling ADR 0029 exists to break. Trailing is also the
# natural way to type it, because the flag is an afterthought about a verdict
# the caller has already decided.
#
# The cost is that a reason can no longer contain a bare `--final`, `--ts` or
# `--source` as prose. `--` ends flag parsing for exactly that case.
override_ts=""
override_id=""
verdict_source="agent"
final_src=""
positional=()
while (($# > 0)); do
  case "$1" in
    --id)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo 'delegate-feedback: --id requires a value (the row otel_span_id from delegate-meta id="...")' >&2; exit 2
      fi
      override_id="$2"; shift 2;;
    --id=*)
      override_id="${1#--id=}"
      if [[ -z "$override_id" ]]; then
        echo 'delegate-feedback: --id requires a value (the row otel_span_id from delegate-meta id="...")' >&2; exit 2
      fi
      shift;;
    --final)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo 'delegate-feedback: --final requires a path or -' >&2; exit 2
      fi
      final_src="$2"; shift 2;;
    --final=*)
      final_src="${1#--final=}"
      if [[ -z "$final_src" ]]; then
        echo 'delegate-feedback: --final requires a path or -' >&2; exit 2
      fi
      shift;;
    --ts)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo 'delegate-feedback: --ts requires a value' >&2; exit 2
      fi
      override_ts="$2"; shift 2;;
    --ts=*)
      override_ts="${1#--ts=}"
      if [[ -z "$override_ts" ]]; then
        echo 'delegate-feedback: --ts requires a value' >&2; exit 2
      fi
      shift;;
    --source)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo 'delegate-feedback: --source requires a value (agent)' >&2; exit 2
      fi
      verdict_source="$2"; shift 2;;
    --source=*)
      verdict_source="${1#--source=}"
      if [[ -z "$verdict_source" ]]; then
        echo 'delegate-feedback: --source requires a value (agent)' >&2; exit 2
      fi
      shift;;
    -h|--help) usage;;
    --) shift; while (($# > 0)); do positional+=("$1"); shift; done;;
    *) positional+=("$1"); shift;;
  esac
done
# bash 3.2 (the macOS baseline) expands an empty array under `set -u` as an
# unbound variable, so the `+` form is load-bearing rather than decorative:
# `delegate-feedback.sh` with no arguments at all must reach the usage check
# below, not die with "positional: unbound variable".
set -- ${positional[@]+"${positional[@]}"}

# One verdict tier (ADR 0030). "agent" is the agent's record of whether it used
# its own delegated output, and it is the calibration signal; every caller
# passes it and it is the default, so the flag is accepted rather than
# removed. "human" was the ADR 0015 taste-judgment tier: it filled at a few
# rows a week, the live corpus holds none, and a row written under it now
# would be the one kind the reporting cannot place — refuse it, and name the
# ADR so the caller knows it is retired rather than misspelt. Any other value
# fails loudly for the same reason.
case "$verdict_source" in
  agent) ;;
  human) echo "delegate-feedback: --source human is no longer a tier — the agent that used the draft records the verdict (ADR 0030); drop the flag" >&2; exit 2 ;;
  *) echo "delegate-feedback: --source must be 'agent' (got '$verdict_source')" >&2; exit 2 ;;
esac

if [[ -n "$final_src" && "$final_src" != "-" && ! -f "$final_src" ]]; then
  echo "delegate-feedback: --final file not found: $final_src" >&2; exit 2
fi
# Two pins name one row twice; if they disagree there is no right answer, and
# if they agree one of them is noise. Refuse rather than pick.
if [[ -n "$override_id" && -n "$override_ts" ]]; then
  echo 'delegate-feedback: pass --id or --ts, not both' >&2; exit 2
fi

[[ $# -ge 1 ]] || usage

# A third outcome alongside hit/miss: `scaffold` records a draft that was
# discarded but genuinely useful (divergence or executable feedback improved
# the final result). It writes kept:false (so any kept-only reader treats it as
# "not used verbatim", never inflating hit-rate) plus a scaffold:true
# discriminator the reporting partition reads. It is NOT a miss, so it does not
# fire the MISS-recurrence nudge below.
case "$1" in
  hit)      kept=true;  verdict=hit;      is_scaffold=false ;;
  miss)     kept=false; verdict=miss;     is_scaffold=false ;;
  scaffold) kept=false; verdict=scaffold; is_scaffold=true ;;
  *) echo "first arg must be 'hit', 'miss', or 'scaffold' (got '$1')" >&2; usage ;;
esac
shift
reason="$*"

# A rejection with no reason is a row that counts in every denominator and
# tells the loop nothing. Measured 2026-08-26: 12 of the 63 rejections in the
# live corpus carry no reason at all — all written in a single bulk sweep on
# 2026-08-25, all on the recipe that then sat at the bottom of the per-recipe
# ranking with no usable evidence behind its position. The loop doc is explicit
# that a rejection with only a prose reason is already thin; one with none
# cannot be acted on at all.
#
# This used to be scoped to `--source agent`, with the human sweep exempt
# because "I no longer remember why" was honest for someone working through
# old rows. With one tier (ADR 0030) every verdict is the agent's own
# just-finished delegation, and it always knows.
if [[ "$kept" == "false" && -z "${reason// }" ]]; then
  echo "delegate-feedback: a '$verdict' needs a reason." >&2
  echo "  It is the only thing that makes the row actionable — the rate it moves" >&2
  echo "  is computed either way. Name what was wrong with the draft:" >&2
  echo "    delegate-feedback.sh $verdict \"dropped every file:line anchor\"" >&2
  echo "  and on a miss or scaffold add --final <path|-> naming what you shipped." >&2
  exit 2
fi

# The migration hint (#360) is repeated here rather than shared, because the
# only two scripts that need it are this one (the agent's entry point) and
# metrics-summary.sh (the human's). A shared lib was reviewed and rejected; see
# the design doc.
if [[ ! -f "$metrics_file" ]]; then
  echo "metrics file not found: $metrics_file" >&2
  _legacy="$HOME/.claude/skills/delegate-local/metrics.jsonl"
  if [[ -f "$_legacy" ]]; then
    echo "  $_legacy exists with $(grep -c '' "$_legacy" 2>/dev/null || echo 0) rows" >&2
    echo "  migrate it: bash scripts/onboard.sh --migrate-data" >&2
  fi
  exit 1
fi
command -v jq >/dev/null || { echo "jq not on PATH" >&2; exit 2; }

# OTel ID generation and the OTLP/HTTP feedback-span emission live in
# scripts/lib/otel.sh — shared with delegate.sh and backfill-otel.sh (Track E,
# #157). The lib defines otel_gen_id, emit_otel_feedback_span,
# emit_otel_feedback_span_with_ids, and the deterministic-ID helper.
# emit_otel_feedback_span carries the Track F redaction behaviour
# (DELEGATE_OTEL_INCLUDE_CONTENT=1 to include the free-text reason; default
# omits it). Sourcing has no side effects.
_fb_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/otel.sh
. "$_fb_script_dir/lib/otel.sh"

# Select the delegate row this verdict is about — ONE row, in ONE pass, and
# every field the rest of the script needs comes off that same row: ts, the
# otel_span_id it is pinned by, the trace id the OTel feedback span links to,
# model, recipe (delegate.recipe, #187), project (copied onto the feedback
# row and span, #474 — it used to be re-derived from the cwd at verdict
# time, which is how 59 of 254 verdicts came to name a project other than
# the row they judge) and draft_file (the stem the final is stored under).
# Reading them in two scans with the same select, or validating with
# `head -n 1` and reading with `tail -n 1`, is how a --ts pin on a shared
# second gave caller A sibling B's project, draft pairing and OTel parent
# and stored A's commit message as B's final (PR #479 review).
#
# Four ways to choose:
#   --id      exact match on otel_span_id — the pin delegate-meta prints as
#             id="..." and the nudge hands out. Every row since the corpus
#             reset carries one (log_metric generates it whether or not the
#             exporter is on) and none repeat.
#   --ts      back-compat. Rows sharing that second are an ambiguity, not a
#             choice: refuse and list them with their ids.
#   window    no pin, DELEGATE_FEEDBACK_STALE_SECONDS > 0 (default 300):
#             every delegate row whose ts is inside the window. Exactly one
#             is the row; more than one is the same ambiguity ("most recent"
#             cannot tell sibling delegations from parallel sessions apart —
#             one ref_ts carried four verdicts from four drafts within 12 s
#             while its five siblings stayed untracked); none is the stale
#             refusal. The single candidate is taken from this pass, not
#             from the last line of the file: rows are appended at
#             completion but ts is the start time, so a long delegation
#             lands after a shorter one it preceded. The cutoff is resolved
#             in jq (fromdateiso8601) as metrics-summary.sh does, so there is
#             no BSD-vs-GNU `date` split and no second staleness pass.
#   all       DELEGATE_FEEDBACK_STALE_SECONDS=0: the unbounded most-recent
#             row, for back-compat scripts.
#
# Empty fields are tolerated: the IDs are absent on rows that pre-date the
# exporter, recipe on bare-tier calls, project outside a repo, draft_file
# with capture opted out. The separator is US (\037), not a tab: tab is IFS
# whitespace to bash, so `read` collapses a run of them and an empty recipe
# would shift project into parent_recipe.
if [[ -n "$override_id" ]]; then
  pin_mode="id"; pin_desc="--id $override_id"
elif [[ -n "$override_ts" ]]; then
  pin_mode="ts"; pin_desc="--ts $override_ts"
elif [[ "$stale_seconds" -gt 0 ]]; then
  pin_mode="window"; pin_desc="the last ${stale_seconds}s"
else
  pin_mode="all"; pin_desc="the metrics file"
fi
candidates=$(jq -r --arg mode "$pin_mode" --arg id "$override_id" --arg ts "$override_ts" \
  --argjson cutoff "$(( $(jq -n 'now | floor') - stale_seconds ))" \
  'select((.source // "delegate") == "delegate")
   | select(if $mode == "id" then .otel_span_id == $id
            elif $mode == "ts" then .ts == $ts
            elif $mode == "window" then ((.ts // "") | fromdateiso8601?) >= $cutoff
            else true end)
   | [.ts, (.otel_span_id // ""), (.otel_trace_id // ""), (.model // ""), (.recipe // ""), (.project // ""), (.draft_file // "")]
   | join("\u001f")' \
  "$metrics_file")
[[ "$pin_mode" == "all" ]] && candidates=$(printf '%s\n' "$candidates" | tail -n 1)
n_candidates=$(printf '%s' "$candidates" | grep -c '')

if (( n_candidates == 0 )); then
  case "$pin_mode" in
    id|ts)
      echo "delegate-feedback: $pin_desc does not match any delegate row in $metrics_file" >&2
      exit 1 ;;
    window)
      # Nothing inside the window. Either there is no delegate row at all, or
      # the newest one is stale — refuse to silently attach to a row that
      # almost certainly isn't the delegation the caller meant. The 5-minute
      # default bounds "I just delegated" without forcing tight clock
      # discipline.
      newest=$(jq -r 'select((.source // "delegate") == "delegate") | .ts' "$metrics_file" | tail -n 1)
      if [[ -z "$newest" || "$newest" == "null" ]]; then
        echo "no recent delegate event found in $metrics_file" >&2
        exit 1
      fi
      age=$(jq -rn --arg t "$newest" '($t | fromdateiso8601?) as $e | if $e == null then "?" else ((now | floor) - $e | tostring) end')
      cat >&2 <<MSG
delegate-feedback: most recent delegate row is ${age}s old (> ${stale_seconds}s).
  ts=$newest is likely not the delegation you mean. Pass --id <otel_span_id>
  (delegate-meta prints it as id="...") to pin the verdict explicitly, or set
  DELEGATE_FEEDBACK_STALE_SECONDS=0 to disable this check.
MSG
      exit 1 ;;
    *)
      echo "no recent delegate event found in $metrics_file" >&2
      exit 1 ;;
  esac
fi
if (( n_candidates > 1 )); then
  cat >&2 <<MSG
delegate-feedback: $n_candidates delegate rows match $pin_desc, so the row this
  verdict is about is ambiguous. Pass --id <otel_span_id> naming it
  (delegate-meta prints it as id="..."):
MSG
  printf '%s\n' "$candidates" | awk -F "$(printf '\037')" '{ printf "    %s  %s  %s  %s\n", ($2 == "" ? "-" : $2), $1, ($5 == "" ? "(bare)" : $5), ($6 == "" ? "-" : $6) }' >&2
  exit 1
fi
IFS=$'\037' read -r ref_ts ref_id parent_trace_id parent_model parent_recipe feedback_project parent_draft <<< "$candidates"
parent_span_id="$ref_id"

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --final: persist the text that actually shipped next to the captured draft
# (delegate.sh writes <stem>.draft.txt; this writes <stem>.final.txt for the
# same delegation). The pair is what makes a recipe edit evidence-driven: the
# free-text `reason` says "dropped every load-bearing fact", the pair says
# WHICH facts and what the model wrote instead. Same locality and sensitivity
# rules as the draft — local file beside metrics.jsonl, never transmitted.
# Failure to write is non-fatal: the verdict row still lands, without the field.
final_file=""
final_source=""
drafts_dir="$(dirname "$metrics_file")/drafts"
# Name the final after the DRAFT the selected row points at, not after ref_ts.
# ref_ts has second precision and parallel delegations share it (the archived
# corpus has one second carrying eight of them), so a ts-derived name would
# overwrite another delegation's shipped text and silently corrupt the pair.
# draft_file came off the same row as every other field above, so the two
# halves are guaranteed to be the same delegation's. The ts fallback is for
# rows written before draft capture existed, or with capture opted out; those
# cannot collide with a real draft because the draft-side name always carries
# a uniquifying suffix.
#
# Untrusted: it comes out of a JSONL file and becomes part of a path this
# script reads and writes. A bare filename ending in .draft.txt, nothing else
# — a row carrying `../../x.draft.txt` would otherwise place the stored final
# outside the drafts directory. A rejected value falls through to the
# ts-derived stem below, which is the same path a row with no draft takes.
case "$parent_draft" in
  *.draft.txt) [[ "$parent_draft" == */* || "$parent_draft" == .* ]] && parent_draft="" ;;
  *) parent_draft="" ;;
esac

if [[ -n "$final_src" ]]; then
  if [[ -n "$parent_draft" ]]; then
    final_stem="${parent_draft%.draft.txt}"
  else
    final_stem="$(printf '%s' "$ref_ts" | tr -d ':-')-nodraft"
  fi
  # Never overwrite a final that is already there (#474). A second final on
  # the same stem is either the boundary hook's capture (which an explicit
  # --final outranks but must not destroy) or a second verdict on the row —
  # and on 2026-09-11 that second verdict was another session's, so a
  # commit-message draft was left paired with a D-Bus badge reply as its
  # "shipped" half and the real commit message was gone. Each further final
  # takes the next free number and the row names the file it actually wrote,
  # so a pair is always one delegation's; self-improve.sh maps
  # `<stem>.final.N.txt` back to `<stem>.draft.txt` the same way as the bare
  # name.
  #
  # The name is claimed by the open, not by a stat. `set -C` (noclobber) makes
  # `>` fail on an existing file at the redirect, before `cat` runs — so stdin
  # is untouched on a failed claim and the next number can be tried. A
  # check-then-truncate allocation let 12 parallel writers on one stem leave
  # 2 files and 11 rows all naming S.final.txt (PR #479 review). The claim and
  # the copy are two steps, because they fail for different reasons: a claim
  # that fails on an existing name means try the next number; a claim that
  # fails otherwise (unwritable directory) ends the loop; and a copy that
  # fails after a successful claim (the source passed -f and then became
  # unreadable) releases the claim and ends the loop — folding the two into
  # one subshell had the empty claimed file read as a collision, and the loop
  # created an empty numbered file at every step without end (PR #479 review).
  # Either way the verdict lands without the field. Same sensitivity
  # as the draft it sits beside, and more of it: this is verbatim what went
  # out, anchors included. 700 on the directory, 600 on the file, written
  # under `umask 077` so there is no permissive window.
  if mkdir -p "$drafts_dir" 2>/dev/null; then
    chmod 700 "$drafts_dir" 2>/dev/null || true
    final_n=1
    while :; do
      if (( final_n == 1 )); then final_name="$final_stem.final.txt"; else final_name="$final_stem.final.$final_n.txt"; fi
      if ( umask 077; set -C; : > "$drafts_dir/$final_name" ) 2>/dev/null; then
        if [[ "$final_src" == "-" ]]; then
          cat > "$drafts_dir/$final_name" 2>/dev/null && final_file="$final_name"
        else
          cat "$final_src" > "$drafts_dir/$final_name" 2>/dev/null && final_file="$final_name"
        fi
        [[ -n "$final_file" ]] || rm -f "$drafts_dir/$final_name"
        break
      fi
      [[ -e "$drafts_dir/$final_name" ]] || break
      final_n=$((final_n + 1))
    done
    [[ -n "$final_file" ]] && chmod 600 "$drafts_dir/$final_file" 2>/dev/null
  fi
  if [[ -z "$final_file" ]]; then
    echo "delegate-feedback: could not store --final text (verdict still recorded)" >&2
  elif (( final_n > 1 )); then
    # Worth a line, because an existing final usually means this is not the
    # delegation the caller thinks it is.
    echo "delegate-feedback: $final_stem.final.txt already exists (a final was already stored against ts=$ref_ts); this one is stored as $final_file" >&2
  fi
elif [[ -n "$parent_draft" && "$kept" == "false" ]]; then
  # No --final was passed, but the boundary hook may already have stored what
  # was posted: when a `gh`/`glab` post is credited to a delegation, that post
  # IS the delegation's shipped form, and the hook writes it under the draft's
  # own stem. This is the only capture path for the reply recipes, whose output
  # is posted inline and never reaches a file the caller could name — before it
  # existed, `maintainer-reply` had 32 rejections and not one captured pair.
  #
  # An explicit --final is handled above and always wins (it is stored beside
  # this file, never over it). `final_source` marks which of the two produced
  # the file, so a pair inferred from a post is never mistaken for one the
  # caller vouched for — which cuts both ways: a bare `<stem>.final.txt` that
  # an earlier verdict on this row supplied with --final is hand-supplied, and
  # a later verdict carrying its name must not relabel it as inferred. A
  # feedback row on this ref already naming the file without the `posted`
  # marker is what tells the two apart (one carrying the marker adopted it
  # from the hook itself, and vouches for nothing).
  adopt_name="${parent_draft%.draft.txt}.final.txt"
  if [[ -f "$drafts_dir/$adopt_name" ]]; then
    final_file="$adopt_name"
    vouched=$(jq -r --arg ts "$ref_ts" --arg f "$adopt_name" \
      'select(.source == "feedback" and .ref_ts == $ts and .final_file == $f and (.final_source // "") != "posted") | .ts' \
      "$metrics_file" | head -n 1)
    [[ -z "$vouched" ]] && final_source="posted"
  fi
fi

# Build the feedback row in one jq call. Each optional field is appended only
# when present, so an empty `reason` is omitted (no empty-string entries to
# pollute future filters) and `scaffold` rides only on the scaffold verdict.
# `verdict_source:"agent"` is written on every row: it is the only tier (ADR
# 0030), every row in the live corpus already carries it, and the Grafana
# calibration dashboard and the other consumers filter on it. `project` is the
# referenced row's (selected above), never the cwd's: DELEGATE_PROJECT is not
# consulted here, because the verdict has to land where the delegation did
# whatever shell it is recorded from. `ref_id` is the referenced row's
# otel_span_id, written beside `ref_ts` (omitted on the rare row that has
# none): every reader still joins on ref_ts today, and ref_id is what lets
# them join on a key that two delegations cannot share.
jq -nc --arg ts "$ts" --arg ref "$ref_ts" --arg refid "$ref_id" --argjson kept "$kept" --argjson scaffold "$is_scaffold" --arg reason "${reason:-}" --arg project "$feedback_project" --arg vsource "$verdict_source" --arg final "$final_file" --arg finalsrc "$final_source" \
  '{ts:$ts, source:"feedback", ref_ts:$ref} + (if $refid != "" then {ref_id:$refid} else {} end) + {kept:$kept} + (if $scaffold then {scaffold:true} else {} end) + (if $reason != "" then {reason:$reason} else {} end) + (if $project != "" then {project:$project} else {} end) + {verdict_source:$vsource} + (if $final != "" then {final_file:$final} else {} end) + (if $finalsrc != "" then {final_source:$finalsrc} else {} end)' \
  >> "$metrics_file"

case "$verdict" in
  hit)      verdict_word="HIT" ;;
  miss)     verdict_word="MISS" ;;
  scaffold) verdict_word="SCAFFOLD" ;;
esac

# Emit OTel feedback-as-linked-span (Phase 11 Track A #134). The parent
# fields came off the one selected row above. Empty fields are tolerated — emit_otel_feedback_span omits the `links`
# array when the parent IDs are unknown (row pre-dates the exporter) and
# omits delegate.recipe (#187) when the parent was a bare-tier call.
# delegate.project is the referenced row's project, the same value the JSONL
# row above carries, so per-project calibration dashboards can scope feedback
# spans the same way they scope delegation spans.
# $verdict is already the lowercase wire form (hit, miss or scaffold); the OTel
# span carries it verbatim as the delegate.feedback.verdict attribute.
emit_otel_feedback_span "$ts" "$verdict" "$reason" "$parent_trace_id" "$parent_span_id" "$parent_model" "$parent_recipe" "$feedback_project" "$verdict_source"

echo "$verdict_word recorded against delegate ts=$ref_ts${reason:+ ($reason)}"

# Trigger-on-MISS nudge — when a MISS is recorded and the reason has token
# overlap with N-1 or more recent MISSes already in the JSONL, surface a
# draft `prompt-pattern` issue command so the calibration discipline the
# README documents has a runtime nudge to back it. Issue #88. The matcher
# scores Jaccard similarity over content tokens (lowercased, stopwords
# stripped, length ≥ 3) and only runs on MISS so HIT recording stays quiet.
# The just-appended row is excluded from the count by ts so the matcher
# does not see itself.
if [[ "$verdict" == "miss" && "${DELEGATE_FEEDBACK_NO_NUDGE:-0}" != "1" && -n "$reason" ]]; then
  nudge_at="${DELEGATE_FEEDBACK_NUDGE_AT:-3}"
  window_days="${DELEGATE_FEEDBACK_NUDGE_WINDOW_DAYS:-30}"
  similar_threshold="${DELEGATE_FEEDBACK_SIMILAR_THRESHOLD:-0.4}"
  window_secs=$((window_days * 86400))

  # Perl rather than awk because the matcher needs JSON parsing, set
  # arithmetic, and floating-point Jaccard — all messy in awk and clean
  # in Perl, which is already a project runtime dep (scripts/delegate.sh,
  # the score-t3.sh stdev calc). Inputs on
  # the command line; the JSONL streams in on stdin. Output is one
  # `SIMILAR_COUNT=<n>` line plus one `<ts>\t<reason>` line per match.
  matcher_out=$(perl -MJSON::PP -MTime::Local=timegm -e '
    use strict; use warnings;
    my ($new_reason, $threshold, $window_secs, $self_ts) = @ARGV;
    my $now = time;
    my %STOP = map { $_ => 1 } qw(
      the a an and or but is was were be been being am are
      for to from with on in of at by into onto out up down
      this that these those it its also too just only very
      has have had do does did can could should would shall
      will may might must about against some any all most
      more less few many much over under above below than then
      not no nor so yet still already even either neither
      such same other another own here there where when how why
    );
    sub toks {
      my $s = lc(shift // "");
      my %seen;
      grep { length >= 3 && !$STOP{$_} && !$seen{$_}++ }
        grep { length } split /\W+/, $s;
    }
    my @new_t = toks($new_reason);
    my %new_set = map { $_ => 1 } @new_t;
    if (!@new_t) { print "SIMILAR_COUNT=0\n"; exit 0; }

    my $similar = 0;
    my @rows;
    while (my $line = <STDIN>) {
      my $j = eval { decode_json($line) };
      next unless ref $j eq "HASH";
      next unless ($j->{source} // "") eq "feedback";
      next if  $j->{kept};                      # only MISS rows
      next if  $j->{scaffold};                  # scaffold is useful, not a miss
      next unless $j->{ts};
      next if $j->{ts} eq $self_ts;             # skip the just-appended row
      if ($window_secs > 0 && $j->{ts} =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/) {
        my $epoch = timegm($6, $5, $4, $3, $2-1, $1);
        next if ($now - $epoch) > $window_secs;
      }
      my @h_t = toks($j->{reason} // "");
      next unless @h_t;
      # Inclusion-exclusion: |A ∪ B| = |A| + |B| - |A ∩ B|. Avoids the
      # per-row anonymous-hash merge the earlier draft used; both @new_t
      # and @h_t are already deduped by toks().
      my $inter = 0; for my $t (@h_t) { $inter++ if $new_set{$t} }
      my $union = scalar(@new_t) + scalar(@h_t) - $inter;
      next if $union == 0;
      my $jac = $inter / $union;
      if ($jac >= $threshold) {
        $similar++;
        my $r = $j->{reason} // "";
        $r =~ s/\s+/ /g;
        $r = substr($r, 0, 100) . (length($r) > 100 ? "…" : "");
        push @rows, sprintf("%s\t%s", $j->{ts}, $r);
      }
    }
    print "SIMILAR_COUNT=$similar\n";
    for (@rows) { print "$_\n" }
  ' "$reason" "$similar_threshold" "$window_secs" "$ts" < "$metrics_file" 2>/dev/null) || matcher_out=""

  if [[ -n "$matcher_out" ]]; then
    similar_count=$(echo "$matcher_out" | awk -F= '/^SIMILAR_COUNT=/ {print $2}')
    # The nudge triggers when this MISS plus prior similars hits nudge_at:
    #   similar_count is "prior similar MISSes" (excludes self)
    #   total including this one = similar_count + 1
    if [[ -n "$similar_count" ]] && (( similar_count + 1 >= nudge_at )); then
      total=$((similar_count + 1))
      cat >&2 <<NUDGE_HEADER
NOTE: this MISS plus ${similar_count} prior similar one(s) in the last ${window_days}d = ${total} total.
Recent matches (most recent first):
NUDGE_HEADER
      echo "$matcher_out" | awk -F'\t' 'NF==2 {printf "  - %s: %s\n", $1, $2}' >&2
      cat >&2 <<NUDGE_FOOTER
Consider filing a prompt-pattern issue so the recipe library tracks the gap:
  gh issue create --repo ${github_repo} \\
    --label prompt-pattern \\
    --title "<recipe-name>: <one-line pattern summary>" \\
    --body "See .github/ISSUE_TEMPLATE/prompt-pattern.md — paste the matched MISS reasons above, the prompt, the model output, and a suggested fix if known."
Silence this nudge for one call with DELEGATE_FEEDBACK_NO_NUDGE=1.
NUDGE_FOOTER
    fi
  fi
fi
