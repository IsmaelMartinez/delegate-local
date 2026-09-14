#!/usr/bin/env bash
# Read the delegate metrics JSONL and print a summary: per-source breakdown
# (delegate = interactive calls via scripts/delegate.sh, experiment = runner
# traffic via experiments/lib/run_api_cell.sh), per-tier or per-session
# rollup, and top models. Entries missing a `source` field are treated as
# `delegate` for backward compatibility with lines written before the
# source field landed.
#
# Usage:  metrics-summary.sh [--file path] [--since YYYY-MM-DD|ISO-8601] [--days N]
#         --since / --days restrict every section to rows at or after the cutoff
#         (a windowed view of recent activity; --days N == "the last N days").
# Env:    DELEGATE_METRICS_FILE   override default metrics path
#         DELEGATE_LOCAL_DATA_DIR where per-user data lives
#                                 (default ~/.local/share/delegate-local);
#                                 DELEGATE_METRICS_FILE takes precedence
# Exit:   0 OK, 1 file missing, 2 usage error.

set -uo pipefail

metrics_file="${DELEGATE_METRICS_FILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/metrics.jsonl}"
since=""
days=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) [[ $# -ge 2 ]] || { echo "--file requires a path" >&2; exit 2; }; metrics_file="$2"; shift 2 ;;
    --since) [[ $# -ge 2 ]] || { echo "--since requires a value (YYYY-MM-DD or ISO-8601)" >&2; exit 2; }; since="$2"; shift 2 ;;
    --days) [[ $# -ge 2 ]] || { echo "--days requires a positive integer" >&2; exit 2; }; days="$2"; shift 2 ;;
    -h|--help) echo "usage: metrics-summary.sh [--file path] [--since YYYY-MM-DD|ISO] [--days N]"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$metrics_file" ]]; then
  echo "no metrics file at $metrics_file" >&2
  echo "(run delegate.sh at least once, or set DELEGATE_METRICS_FILE)" >&2
  # #360: user data moved out of the installer-owned skill directory. Point an
  # existing install at the migration rather than silently starting from zero.
  # Deliberately NOT a resolution fallback: a fallback never disarms, so losing
  # the new file at any later date would silently revert every consumer to the
  # migration-day snapshot. A message the user acts on cannot do that.
  _legacy="$HOME/.claude/skills/delegate-local/metrics.jsonl"
  if [[ -f "$_legacy" ]]; then
    echo "  $_legacy exists with $(grep -c '' "$_legacy" 2>/dev/null || echo 0) rows" >&2
    echo "  migrate it: bash scripts/onboard.sh --migrate-data" >&2
  fi
  exit 1
fi

command -v jq >/dev/null || { echo "jq not on PATH" >&2; exit 2; }

# Optional time window. --since DATE|ISO or --days N restricts every section
# below to rows at or after the cutoff. The cutoff is resolved with jq (now /
# fromdateiso8601) rather than `date` arithmetic so there is no BSD-vs-GNU epoch
# portability split. Matching rows are filtered once into a temp file; every
# downstream jq pass then reads that file unchanged.
display_file="$metrics_file"
window_active=0
cutoff_iso=""
orig_total=0
if [[ -n "$since" || -n "$days" ]]; then
  if [[ -n "$since" && -n "$days" ]]; then
    echo "use either --since or --days, not both" >&2; exit 2
  fi
  if [[ -n "$days" ]]; then
    [[ "$days" =~ ^[0-9]+$ && "$days" -gt 0 ]] \
      || { echo "--days takes a positive integer, got '$days'" >&2; exit 2; }
    # We generate the cutoff, so its epoch and ISO form come from one jq pass —
    # no second jq to re-parse a self-generated timestamp. The error path below
    # is --since-only because a generated cutoff cannot be invalid.
    IFS=$'\t' read -r cutoff_epoch cutoff_iso \
      < <(jq -rn --argjson d "$days" '((now | floor) - ($d * 86400)) | [., todateiso8601] | @tsv')
  else
    case "$since" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) cutoff_iso="${since}T00:00:00Z" ;;
      *) cutoff_iso="$since" ;;
    esac
    cutoff_epoch=$(jq -rn --arg c "$cutoff_iso" '$c | fromdateiso8601' 2>/dev/null) \
      || { echo "invalid --since value '$since' (use YYYY-MM-DD or an ISO-8601 timestamp)" >&2; exit 2; }
  fi
  orig_total=$(jq -s 'length' "$metrics_file")
  filtered=$(mktemp "${TMPDIR:-/tmp}/delegate-metrics.XXXXXX") \
    || { echo "cannot create temp file for the metrics window" >&2; exit 2; }
  trap 'rm -f "$filtered"' EXIT
  jq -c --argjson cutoff "$cutoff_epoch" \
    'select(((.ts // "") | fromdateiso8601?) >= $cutoff)' "$metrics_file" > "$filtered"
  metrics_file="$filtered"
  window_active=1
fi

total=$(jq -s 'length' "$metrics_file")
if (( total == 0 )); then
  if (( window_active )); then
    echo "no rows in window (since $cutoff_iso) — $orig_total total rows in $display_file"
  else
    echo "metrics file is empty: $metrics_file"
  fi
  exit 0
fi

# Headline + existence checks in a single jq pass so big metrics files are
# read once, not three times. Feedback events (`source:"feedback"`) are
# excluded from token / latency / model rollups — they're zero-cost
# annotations on prior delegate events, surfaced separately below.
IFS=$'\t' read -r ts_first ts_last total_avoided errors n_delegate n_experiment n_tier n_session n_feedback < <(jq -rs '
  def src: .source // "delegate";
  def call: select(src != "feedback" and src != "opportunity");
  [
    (map(call) | min_by(.ts) | .ts),
    (map(call) | max_by(.ts) | .ts),
    # `// 0` matters: `add` over an all-null list returns null, which @tsv
    # renders as an EMPTY field. Tab is IFS whitespace, so bash read collapses
    # the resulting double-tab into one delimiter and shifts every later column
    # left. A file whose delegate rows carry no estimated_tokens_avoided then
    # misreports errors, delegate and experiment counts at once, silently.
    ((map(call | .estimated_tokens_avoided) | add) // 0),
    (map(call | select(.exit_status != 0)) | length),
    (map(call | select(src == "delegate")) | length),
    (map(call | select(src == "experiment")) | length),
    (map(call | select(.tier != null)) | length),
    (map(call | select(.session != null)) | length),
    (map(select(src == "feedback")) | length)
  ] | @tsv' "$metrics_file")

echo "=== delegate-local metrics ==="
echo "File:                $display_file"
(( window_active )) && echo "Window:              since $cutoff_iso  ($total of $orig_total rows)"
echo "Time range:          $ts_first  →  $ts_last"
echo "Total invocations:   $total  (delegate=$n_delegate, experiment=$n_experiment)"
echo "Errors (non-zero):   $errors"
echo "Tokens avoided (≈):  $total_avoided"

# What that total actually avoided (#412). estimated_tokens_avoided is written
# on EVERY row — including calls that failed and drafts the agent then rewrote —
# so the bare total reads as a saving when roughly half of it is not. The
# headline itself is deliberately unchanged: it is the gross local-processing
# figure across all sources, the Per-source block below sums to it, and
# tests/test-metrics-summary.sh pins that cross-source contract. The
# qualification goes underneath instead of redefining the number.
#
# The split is the agent's own record of what it did with the draft, which is
# the one verdict tier there is (ADR 0030): "were tokens avoided" is answered
# by whether the text shipped, and the agent that shipped or rewrote it is the
# party that knows. The producing agent grading itself skews toward "I used
# it, so it was good" — hence "shipped as-is" rather than any word implying an
# audit. Untagged rows (written before the tier tag existed) count the same
# as tagged ones; the latest verdict on a delegation wins.
#
# Its own pass, deliberately: the feedback rollup further down sits inside an
# `if (( n_feedback > 0 ))` guard, and a file with no verdicts still needs to
# see where its tokens went. Every sum takes `// 0` (jq's `[] | add` is null)
# and every percentage is guarded on a non-zero denominator (jq aborts the whole
# program on divide-by-zero, which under `set -uo pipefail` would silently drop
# the section and still exit 0).
#
# The feedback join is defined once here and interpolated into every jq
# program that needs a delegate row's current verdict (this pass, the
# feedback rollup, per-project, per-recipe), so the four sections cannot
# disagree on what "the verdict" is. `verdict` is evaluated with a delegate
# row as `.` and returns hit / miss / scaffold, or null when none references
# it.
#
# The key is the row's otel_span_id first and its ts second (#481). ts is
# second-precision and parallel delegations share it, so a map keyed on ts
# alone handed one verdict to both same-second siblings. A feedback row
# written since #479 carries ref_id, the delegate row's otel_span_id, and is
# keyed on that; one written before carries ref_ts only and is keyed on the
# ts, which still reaches every delegate row of that second — the best a
# legacy row can do. A feedback row with neither key cannot be joined and is
# skipped: without the guard, indexing an object by null aborts the jq, and
# under `set -uo pipefail` the whole section vanished while the script exited
# 0. The latest verdict per key wins (verdict revision); sort_by(.ts) is a
# guard, not a correction — the 994 feedback rows this was first written
# against were perfectly chronological, but delegate-feedback.sh appends
# without checking, so a concurrent or backfilled write breaks "latest wins"
# unless it means latest in time.
verdict_join='
  def fbv: if (.scaffold // false) then "scaffold" elif .kept then "hit" else "miss" end;
  def fbkey: if (.ref_id // "") != "" then "id:" + .ref_id else "ts:" + .ref_ts end;
  (reduce ([.[] | select((.source // "delegate") == "feedback" and (.ref_id != null or .ref_ts != null))] | sort_by(.ts) | .[]) as $i
     ({}; .[$i | fbkey] = ($i | fbv))) as $vmap
  | def verdict: $vmap["id:" + (.otel_span_id // "")] // $vmap["ts:" + .ts];
'
jq -rs '
  def src: .source // "delegate";
  # One decimal always, so the column does not go ragged on a whole number.
  def pct($n; $d):
    if $d > 0 then ((($n * 1000 / $d) | round) as $t | "\($t / 10 | floor).\($t % 10)")
    else "0.0" end;
  '"$verdict_join"'
  (map(select(src == "experiment")) | map(.estimated_tokens_avoided // 0) | add // 0) as $exp_tok
  | (map(select(src == "experiment")) | length) as $exp_n
  | (map(select(src == "delegate"))) as $dl
  | ($dl | map(select((.exit_status // 0) != 0))) as $bad
  | ($dl | map(select((.exit_status // 0) == 0))
        | map({t: (.estimated_tokens_avoided // 0), v: (verdict // "none")})) as $ok
  | ($ok | map(.t) | add // 0) as $ok_tok
  | (def bucket($k): ($ok | map(select(.v == $k)));
     [ ["shipped as-is",   "hit"],
       ["rewritten",       "miss"],
       ["used as scaffold","scaffold"],
       ["no verdict",      "none"] ]
     | map(. as [$label, $key]
           | (bucket($key)) as $b
           | "    \($label + (" " * (18 - ($label | length))))tokens≈\($b | map(.t) | add // 0)  \(pct(($b | map(.t) | add // 0); $ok_tok))%  n=\($b | length)")) as $lines
  | ([ (if $exp_n > 0 then "  excluded: experiment rows       tokens≈\($exp_tok)  n=\($exp_n)" else empty end),
       (if ($bad | length) > 0 then "  excluded: failed delegations    tokens≈\($bad | map(.estimated_tokens_avoided // 0) | add // 0)  n=\($bad | length)" else empty end),
       "  successful delegations          tokens≈\($ok_tok)  n=\($ok | length)"
     ] + (if ($ok | length) > 0 then $lines else [] end))
  | .[]
' "$metrics_file"
echo

# Per-source breakdown: count, tokens avoided, p50/p95 latency. Feedback and
# opportunity events are excluded — they have no duration / token cost and are
# reported in their own sections below.
echo "Per-source:"
jq -rs '
  def src: .source // "delegate";
  map(select(src != "feedback" and src != "opportunity"))
  | group_by(src)
  | map({
      source: (.[0] | src),
      n: length,
      tokens: (map(.estimated_tokens_avoided) | add),
      p50: ((sort_by(.duration_ms) | .[(length / 2 | floor)] | .duration_ms)),
      p95: ((sort_by(.duration_ms) | .[((length * 95 / 100) | floor) | if . >= length then length - 1 else . end] | .duration_ms))
    })
  | sort_by(-.n)
  | .[]
  | "  \(.source | . + (" " * (12 - length)))  n=\(.n)  tokens≈\(.tokens)  p50=\(.p50)ms  p95=\(.p95)ms"
' "$metrics_file"
echo

# Per-backend rollup (delegate entries only). Only printed when 2+ distinct
# backends appear in the file so single-backend users (the common case
# today) don't see a redundant section. Rows missing the backend field —
# pre-2026-05 delegate rows written before DELEGATE_BACKEND landed — are
# bucketed as `ollama` because that was the only path then.
n_backends=$(jq -rs '
  map(select((.source // "delegate") == "delegate"))
  | map(.backend // "ollama")
  | unique
  | length
' "$metrics_file")
if (( n_backends > 1 )); then
  echo "Per-backend (delegate):"
  jq -rs '
    map(select((.source // "delegate") == "delegate"))
    | group_by(.backend // "ollama")
    | map({
        backend: (.[0].backend // "ollama"),
        n: length,
        tokens: (map(.estimated_tokens_avoided // 0) | add),
        p50: ((sort_by(.duration_ms) | .[(length / 2 | floor)] | .duration_ms // 0)),
        p95: ((sort_by(.duration_ms) | .[((length * 95 / 100) | floor) | if . >= length then length - 1 else . end] | .duration_ms // 0))
      })
    | sort_by(-.n)
    | .[]
    | "  \(.backend | . + (" " * (10 - length)))  n=\(.n)  tokens≈\(.tokens)  p50=\(.p50)ms  p95=\(.p95)ms"
  ' "$metrics_file"
  echo
fi

# Feedback rollup. Verdict coverage is the recipe-calibration signal, so it is
# scoped to RECIPE delegations (--recipe NAME calls — the unit the recipe library
# self-corrects on). Raw / no-recipe delegations (ad-hoc prose calls plus
# experiment / audit / benchmark sessions run from scratch dirs like `audit`) are
# reported on their own line: their hit/miss verdict is optional and would
# otherwise inflate "untracked" even though they belong to no recipe's calibration
# history. (Benchmark/audit sessions should set DELEGATE_LOCAL_NO_METRICS=1 to stay
# out of the metrics stream entirely; this split is the backstop for ones that
# didn't.) The ref_ts -> kept map is built in one reduce pass; direct $fb_map[.ts]
# access (NOT // false) so a recorded miss (false) isn't coerced back to null and
# dropped, and latest feedback for a delegate wins (verdict revision).
#
# Failed delegations (exit_status != 0 — canary timeout exit 3, flaky-gate exit 4,
# pick-model/dispatch failure exit 1/2) produced no output, so there is nothing to
# judge hit/miss against. Counting them would inflate "untracked" and depress
# coverage with operational failures that belong to the exit_status error metric,
# not the calibration signal. The rollup therefore scopes to exit_status==0 (or
# absent, for pre-exit_status rows) delegations only.
# One verdict tier (ADR 0030). Every feedback row is the agent's own record of
# whether it used its delegated output, and every row is the signal: hits,
# misses and scaffold count each row whether or not it carries the
# verdict_source tag (rows written before the tag existed do not). ADR 0015
# kept a separate maintainer tier as the headline and reported these rows as
# usage; that tier filled at a few rows a week and the live corpus holds none.
# n_scaffold: a feedback row carries scaffold:true when the verdict is the
# third "discarded but useful" outcome (G1). The scaffold column is shown only
# when at least one scaffold verdict exists, so files without any (every legacy
# file) print exactly as before. The counter AND the show_scaffold gate are
# initialised unconditionally because the per-project / per-recipe blocks below
# read them outside the n_feedback>0 guard (set -u safety).
n_scaffold=0
show_scaffold=false
if (( n_feedback > 0 )); then
  n_scaffold=$(jq -rs '
    map(select((.source // "") == "feedback" and (.scaffold // false) == true))
    | length' "$metrics_file")
  (( n_scaffold > 0 )) && show_scaffold=true
  # The header self-describes the scaffold column when one is present; with no
  # scaffold rows it stays the legacy "hit/miss" form so existing output is
  # byte-identical.
  if [[ "$show_scaffold" == true ]]; then
    echo "Delegation feedback (hit/miss/scaffold):"
  else
    echo "Delegation feedback (hit/miss):"
  fi
  jq -rs --argjson show_scaffold "$show_scaffold" '
    def src: .source // "delegate";
    # verdict_join: fbv maps a feedback row to hit / miss / scaffold (scaffold
    # is checked first because it also carries kept:false; a legacy row with no
    # scaffold field falls through to the hit/miss read of kept), and verdict
    # looks a delegate row up by otel_span_id, then ts.
    '"$verdict_join"'
    (map(select(src == "delegate" and (.exit_status // 0) == 0) | {recipe, tier, v: verdict})) as $d
    | ($d | map(select(.recipe != null))) as $rx
    | ($d | map(select(.recipe == null))) as $raw
    | ($rx | length) as $rn
    | ($raw | length) as $wn
    | "  Recipe delegations (calibration signal): n=\($rn)  hits=\($rx|map(select(.v=="hit"))|length)  misses=\($rx|map(select(.v=="miss"))|length)" + (if $show_scaffold then "  scaffold=\($rx|map(select(.v=="scaffold"))|length)" else "" end) + "  untracked=\($rx|map(select(.v==null))|length)" + (if $rn > 0 then "  coverage=\((($rx|map(select(.v!=null))|length) * 100 / $rn) | floor)%" else "" end),
      ($rx | group_by(.tier) | map({tier:.[0].tier, n:length, hits:(map(select(.v=="hit"))|length), misses:(map(select(.v=="miss"))|length), scaffold:(map(select(.v=="scaffold"))|length), untracked:(map(select(.v==null))|length)}) | sort_by(-.n) | .[] | "    \(.tier | . + (" " * (14 - length)))  n=\(.n)  hits=\(.hits)  misses=\(.misses)" + (if $show_scaffold then "  scaffold=\(.scaffold)" else "" end) + "  untracked=\(.untracked)"),
      # Captured-pair coverage (#461 follow-up). A rejection is only diffable
      # when the shipped text was stored beside the draft, and the two ways
      # that happens are NOT interchangeable: `--final` needs the caller to
      # remember, while the boundary hook infers it from a credited post and
      # marks the row final_source:"posted". Splitting them is the point. The
      # hook capture shipped in #457 and did not fire once for eleven days,
      # because the scanner could not read a body out of `gh api -f body=`;
      # `inferred=0` says that out loud, where the field merely being absent
      # from every row looked exactly like "nobody has delegated a reply yet".
      # Counted over feedback ROWS rather than delegations: a delegation can
      # carry more than one verdict, and each one either stored a final or
      # did not.
      (([.[] | select(src == "feedback" and (.kept // false) == false)]) as $rej
       | ($rej | map(select((.final_file // "") != ""))) as $cap
       | if ($rej | length) > 0 then
           "  Captured pairs (rejections with the shipped text stored): n=\($cap|length)/\($rej|length)  inferred=\($cap|map(select(.final_source == "posted"))|length)  by-hand=\($cap|map(select(.final_source != "posted"))|length)"
         else empty end),
      (if $wn > 0 then "  Raw / no-recipe (verdicts optional — experiments, audits, ad-hoc): n=\($wn)  tracked=\($raw|map(select(.v!=null))|length)  untracked=\($raw|map(select(.v==null))|length)" else empty end)
  ' "$metrics_file"
  echo
fi

# Per-project rollup (delegate entries only): volume, hit/miss/untracked, and
# p50 latency grouped by .project. Rows missing the project field are current
# and deliberate, not a legacy artefact: delegate_project_name emits nothing
# outside a git repository rather than the cwd's basename (#476), so every
# delegation issued from a scratch or parent directory lands here. They get
# the same `(no project)` line the trigger-rate section prints, after the
# named projects and outside the count ranking. Only printed when 2+ distinct
# project values appear so single-project users (the common case) don't see a
# noise section. The hit/miss derivation mirrors the feedback block: a ref_ts
# -> kept map built in one reduce pass, then direct $fb_map[.ts] access (NOT
# // false) so a recorded miss (false) isn't coerced back to null and dropped.
n_projects=$(jq -rs '
  map(select((.source // "delegate") == "delegate" and (.exit_status // 0) == 0))
  | map(.project // "")
  | unique
  | length
' "$metrics_file")
if (( n_projects > 1 )); then
  echo "Per-project (delegate):"
  jq -rs --argjson show_scaffold "$show_scaffold" '
    def src: .source // "delegate";
    '"$verdict_join"'
    map(select(src == "delegate" and (.exit_status // 0) == 0) | {ts, project: (.project // ""), duration_ms, v: verdict})
    | group_by(.project)
    | map({
        project: .[0].project,
        n: length,
        hits: (map(select(.v == "hit")) | length),
        misses: (map(select(.v == "miss")) | length),
        scaffold: (map(select(.v == "scaffold")) | length),
        untracked: (map(select(.v == null)) | length),
        p50: ((sort_by(.duration_ms) | .[(length / 2 | floor)] | .duration_ms // 0))
      })
    | sort_by((.project == ""), -.n)
    | .[]
    | "  \((if .project == "" then "(no project)" else .project end) | . + (" " * (20 - length)))  n=\(.n)  hits=\(.hits)  misses=\(.misses)" + (if $show_scaffold then "  scaffold=\(.scaffold)" else "" end) + "  untracked=\(.untracked)  p50=\(.p50)ms"
  ' "$metrics_file"
  echo
fi

# Per-recipe rollup: hit-rate grouped by .recipe across the delegate rows that
# carry a recipe field (i.e. --recipe NAME calls). Only printed when at least
# one recipe row exists. Same feedback-join shape as the per-project block so a
# recorded miss is counted, not dropped. This answers "which recipes underperform."
n_recipe=$(jq -rs '
  map(select((.source // "delegate") == "delegate" and .recipe != null and (.exit_status // 0) == 0))
  | length
' "$metrics_file")
if (( n_recipe > 0 )); then
  echo "Per-recipe (delegate):"
  jq -rs --argjson show_scaffold "$show_scaffold" '
    def src: .source // "delegate";
    '"$verdict_join"'
    map(select(src == "delegate" and .recipe != null and (.exit_status // 0) == 0) | {ts, recipe, v: verdict})
    | group_by(.recipe)
    | map({
        recipe: .[0].recipe,
        n: length,
        hits: (map(select(.v == "hit")) | length),
        misses: (map(select(.v == "miss")) | length),
        scaffold: (map(select(.v == "scaffold")) | length),
        untracked: (map(select(.v == null)) | length)
      })
    | sort_by(-.n)
    | .[]
    | "  \(.recipe | . + (" " * (20 - length)))  n=\(.n)  hits=\(.hits)  misses=\(.misses)" + (if $show_scaffold then "  scaffold=\(.scaffold)" else "" end) + "  untracked=\(.untracked)"
  ' "$metrics_file"
  echo
fi

# Trigger rate (#277): boundary events (commit / PR / release / comment reply)
# recorded by the delegate-boundary hook. Each source:"opportunity" row is one delegatable
# opportunity; .delegated marks whether a local delegation preceded it inside the
# look-back window. Rate = delegated / opportunities, per project — the
# under-triggering number this signal exists to make visible. Only printed when
# opportunity rows exist (i.e. the boundary hook is installed).
#
# Every opportunity row counts. state:"pre-drafted" rows (#349) used to sit
# outside both halves of the ratio; #465 removed that exclusion, because the
# hook could not tell an approved body file from one the agent wrote a call
# earlier, and because the same act WAS counted whenever the write and the post
# shared a Bash call. Historical rates therefore move: the 31 legacy
# pre-drafted rows in the corpus at the time became counted misses.
#
# Rows with no project are real: the hook records none when the session cwd is
# outside a git repository (#476), the same as delegate.sh — before that it
# invented one from the cwd, which is how `gitlab` (a parent folder of
# checkouts) came to hold 14 rows at rate=0%. They are neither dropped nor
# filed under a name: one `(no project)` line after the per-project rows, kept
# out of the count ranking so a scratch cwd cannot rank above a real project.
#
# Two kinds of row leave the ratio since #483, and one line under the table
# says how many. `below_floor:true` is a body the hook measured under its
# floor (an applied-in hash, a dependabot command, one word); no recipe
# should draft it, so it is neither a hit nor a miss — inline review comments
# read 3% while those were counted. `denied:true` is an attempt the hook
# blocked: the post did not happen, and when the same session retried that
# boundary within the hook's window the retry is the row that counts, so
# counting the attempt too would record every enforced boundary as a miss
# and then a hit. A denial that was never retried — or was retried through a
# bypass the hook could not see — is the miss it is, and stays (PR #484
# review, item K); dropping every denied row let those vanish from the rate.
# An `enforce_skipped` row (the deny fell open and the post went through
# undrafted) is a real miss and counts as it always did.
#
# The floor named on the footer is the one in force for this shell, read
# with the same guard the hook applies — a numeric DELEGATE_BOUNDARY_MIN_CHARS
# overrides, anything else means the per-boundary defaults (20 for
# git-commit, 120 for the rest) — because the rows carry the verdict, not the
# threshold it was made against. The retry window is the hook's
# DELEGATE_BOUNDARY_WINDOW_MIN (480) for the same reason.
n_opp=$(jq -rs 'map(select((.source // "") == "opportunity")) | length' "$metrics_file")
if (( n_opp > 0 )); then
  echo "Trigger rate (commit/PR/release/comment boundaries):"
  floor_override=""
  [[ "${DELEGATE_BOUNDARY_MIN_CHARS:-}" =~ ^[0-9]+$ ]] && floor_override="$DELEGATE_BOUNDARY_MIN_CHARS"
  retry_win="${DELEGATE_BOUNDARY_WINDOW_MIN:-480}"
  [[ "$retry_win" =~ ^[0-9]+$ ]] || retry_win=480
  jq -rs --arg floor "$floor_override" --argjson win_min "$retry_win" '
    def epoch: ((.ts | fromdateiso8601?) // 0);
    # A denial is "retried" when a LATER row for the same session, project
    # and boundary lands within the window AND is itself a counted post: not
    # denied, not below_floor (a one-line post the floor waved through is not
    # the redraft), and not the retry-cap fall-open (an undrafted post the cap
    # let through). Accepting any non-denied row erased a denied miss behind
    # an unrelated short post (third review round on #484); matching on the
    # session alone let a later commit in ANOTHER repo erase this one, and
    # "later" as a strictly greater second-precision timestamp counted a
    # denial and its redraft in the same second as both a miss and a hit
    # (fourth round). Later is therefore append order — the row index in the
    # file — and the window is still measured on ts, bounded below at zero so
    # an out-of-order or clock-skewed row cannot pass an upper-bound-only
    # check (fifth round). Rows with no session match on project alone, so a
    # pre-#479 corpus still resolves. O(denied x rows), and the denied set is
    # small.
    [ map(select((.source // "") == "opportunity"))
      | range(0; length) as $i | .[$i] + {_i: $i} ] as $all
    | $all
    | map(if .denied == true then . as $d
            | .retried = any($all[]; ._i > $d._i
                and .denied != true and .below_floor != true
                and (.enforce_skipped // "") != "retry-cap"
                and (.boundary // "") == ($d.boundary // "")
                and (.session // "") == ($d.session // "")
                and (.project // "") == ($d.project // "")
                and (epoch - ($d | epoch)) >= 0
                and (epoch - ($d | epoch)) <= ($win_min * 60))
          else . end)
    | (map(select(.below_floor == true)) | length) as $floored
    | (map(select(.denied == true and .retried == true)) | length) as $denied
    | map(select(.below_floor != true and (.denied != true or .retried != true)))
    | (group_by(.project // "")
      | map({
          project: (.[0].project // ""),
          n: length,
          delegated: (map(select(.delegated == true)) | length),
          missed: (map(select(.delegated == false)) | length)
        })
      | sort_by((.project == ""), -.n)
      | .[]
      | "  \((if .project == "" then "(no project)" else .project end) | . + (if length < 20 then " " * (20 - length) else "" end))  opportunities=\(.n)  delegated=\(.delegated)  missed=\(.missed)"
        + "  rate=\(.delegated * 100 / .n | floor)%"),
      "  excluded \($floored) boundaries under " + (if $floor != "" then "\($floor) chars" else "the floor (20 chars for git-commit, 120 for the rest)" end),
      (if $denied > 0 then "  excluded \($denied) denied attempts retried within \($win_min)m (the post did not happen; the retry is what counts)" else empty end)
  ' "$metrics_file"
  echo
fi

# Per-tier (delegate entries only have tier; experiment entries have session).
if (( n_tier > 0 )); then
  echo "Per-tier (delegate):"
  jq -rs '
    map(select((.source // "delegate") != "feedback" and .tier != null))
    | group_by(.tier)
    | map({
        tier: .[0].tier,
        n: length,
        p50: ((sort_by(.duration_ms) | .[(length / 2 | floor)] | .duration_ms)),
        p95: ((sort_by(.duration_ms) | .[((length * 95 / 100) | floor) | if . >= length then length - 1 else . end] | .duration_ms))
      })
    | sort_by(-.n)
    | .[]
    | "  \(.tier | . + (" " * (14 - length)))  n=\(.n)  p50=\(.p50)ms  p95=\(.p95)ms"
  ' "$metrics_file"
  echo
fi

if (( n_session > 0 )); then
  echo "Per-session (experiment):"
  jq -rs '
    map(select(.session != null))
    | group_by(.session)
    | map({session: .[0].session, n: length, ms: (map(.duration_ms) | add)})
    | sort_by(-.n)
    | .[]
    | "  n=\(.n)  total=\(.ms)ms  \(.session)"
  ' "$metrics_file"
  echo
fi

echo "Top models:"
jq -rs '
  map(select((.source // "delegate") != "feedback"))
  | group_by(.model)
  | map({model: .[0].model, n: length})
  | sort_by(-.n)
  | .[0:5]
  | .[]
  | "  \(.n)  \(.model)"
' "$metrics_file"
