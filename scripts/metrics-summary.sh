#!/usr/bin/env bash
# Read the delegate metrics JSONL and print a summary: headline, per-source,
# per-backend, feedback, per-project, per-recipe, trigger-rate, per-tier and
# top-model sections. Rows missing `source` are treated as `delegate`. A
# recipe more than one model served in the window gets a sub-line per model
# (#655), since ADR 0009 binds calibration to the model.
#
# Usage:  metrics-summary.sh [--file path] [--since YYYY-MM-DD|ISO-8601] [--days N]
#                            [--model SUBSTRING]
#         --since / --days restrict every section to rows at or after the cutoff.
#         --model restricts every section to delegations whose model contains
#         SUBSTRING (case-insensitive, as pick-model.sh matches) and the
#         verdicts that join to them; opportunity rows carry no model and
#         are left out.
# Env:    DELEGATE_METRICS_FILE   override the metrics path
#         DELEGATE_LOCAL_DATA_DIR per-user data (default ~/.local/share/delegate-local)
# Exit:   0 OK, 1 file missing, 2 usage error.

set -uo pipefail

metrics_file="${DELEGATE_METRICS_FILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/metrics.jsonl}"
since=""
days=""
model_filter=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) [[ $# -ge 2 ]] || { echo "--file requires a path" >&2; exit 2; }; metrics_file="$2"; shift 2 ;;
    --since) [[ $# -ge 2 ]] || { echo "--since requires a value (YYYY-MM-DD or ISO-8601)" >&2; exit 2; }; since="$2"; shift 2 ;;
    --days) [[ $# -ge 2 ]] || { echo "--days requires a positive integer" >&2; exit 2; }; days="$2"; shift 2 ;;
    --model) [[ $# -ge 2 && -n "$2" ]] || { echo "--model requires a substring of the model name" >&2; exit 2; }; model_filter="$2"; shift 2 ;;
    -h|--help) echo "usage: metrics-summary.sh [--file path] [--since YYYY-MM-DD|ISO] [--days N] [--model SUBSTRING]"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$metrics_file" ]]; then
  echo "no metrics file at $metrics_file" >&2
  echo "(run delegate.sh at least once, or set DELEGATE_METRICS_FILE)" >&2
  # #360: a message, not a resolution fallback, because a fallback never
  # disarms and would silently revert to the migration-day snapshot.
  _legacy="$HOME/.claude/skills/delegate-local/metrics.jsonl"
  if [[ -f "$_legacy" ]]; then
    echo "  $_legacy exists with $(grep -c '' "$_legacy" 2>/dev/null || echo 0) rows" >&2
    echo "  migrate it: bash scripts/onboard.sh --migrate-data" >&2
  fi
  exit 1
fi

command -v jq >/dev/null || { echo "jq not on PATH" >&2; exit 2; }

# The verdict model (join, outcome, window, percentages) is scripts/lib/pair.jq,
# shared with self-improve.sh and replay-recipe.sh (#564). -L takes an
# absolute path.
lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"

# The cutoff is resolved in jq (now / fromdateiso8601), not `date` arithmetic,
# so there is no BSD-vs-GNU epoch split. Matching rows are filtered once into
# a temp file that every downstream pass reads.
display_file="$metrics_file"
window_active=0
cutoff_iso=""
orig_total=0
filtered=""
mfiltered=""
trap 'rm -f "$filtered" "$mfiltered"' EXIT
if [[ -n "$since" || -n "$days" ]]; then
  if [[ -n "$since" && -n "$days" ]]; then
    echo "use either --since or --days, not both" >&2; exit 2
  fi
  if [[ -n "$days" ]]; then
    [[ "$days" =~ ^[0-9]+$ && "$days" -gt 0 ]] \
      || { echo "--days takes a positive integer, got '$days'" >&2; exit 2; }
    # Epoch and ISO form from one jq pass; a generated cutoff cannot be
    # invalid, so the error path below is --since-only.
    IFS=$'\t' read -r cutoff_epoch cutoff_iso \
      < <(jq -L "$lib_dir" -rn --argjson d "$days" 'include "pair"; cutoff($d) | [., todateiso8601] | @tsv')
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
  jq -L "$lib_dir" -c --argjson cutoff "$cutoff_epoch" \
    'include "pair"; select(in_window($cutoff))' "$metrics_file" > "$filtered"
  metrics_file="$filtered"
  window_active=1
fi

# --model (#655), applied after the window: the delegations whose model
# contains the substring, case-insensitive as pick-model.sh matches, and the
# verdicts whose delegate row (pair.jq's parent_join) is one of them, so a
# verdict lands on the model of the delegation it scored. Other call sources
# match on their own model; opportunity rows and unjoined verdicts have none.
model_active=0
pre_model=0
if [[ -n "$model_filter" ]]; then
  pre_model=$(jq -s 'length' "$metrics_file")
  mfiltered=$(mktemp "${TMPDIR:-/tmp}/delegate-metrics.XXXXXX") \
    || { echo "cannot create temp file for the model filter" >&2; exit 2; }
  jq -L "$lib_dir" -sc --arg m "$model_filter" '
    include "pair";
    ($m | ascii_downcase) as $lm
    | def matches: (.model // "") | ascii_downcase | contains($lm);
    [to_entries[] | .value + {_fi: .key}] as $all
    | ($all | parent_join | map(select(._p != null and (._p | matches)) | {key: (._fi | tostring), value: true}) | from_entries) as $fb
    | $all[]
    | select(if src == "feedback" then $fb[._fi | tostring] == true
             elif src == "opportunity" then false
             else matches end)
    | del(._fi)
  ' "$metrics_file" > "$mfiltered"
  metrics_file="$mfiltered"
  model_active=1
fi

total=$(jq -s 'length' "$metrics_file")
if (( total == 0 )); then
  if (( model_active )); then
    scope="$pre_model rows"
    (( window_active )) && scope="$pre_model rows since $cutoff_iso"
    echo "no rows match --model '$model_filter' — $scope in $display_file"
  elif (( window_active )); then
    echo "no rows in window (since $cutoff_iso) — $orig_total total rows in $display_file"
  else
    echo "metrics file is empty: $metrics_file"
  fi
  exit 0
fi

# One jq pass for the headline and the existence checks. Feedback events are
# excluded from token / latency / model rollups.
IFS=$'\t' read -r ts_first ts_last total_avoided errors n_call n_tier n_feedback n_opp < <(jq -rs '
  def src: .source // "delegate";
  def call: select(src != "feedback" and src != "opportunity");
  [
    # `// "-"` for the same reason as below: a file of feedback or
    # opportunity rows only has no call row to take a ts from.
    ((map(call) | min_by(.ts) | .ts) // "-"),
    ((map(call) | max_by(.ts) | .ts) // "-"),
    # `// 0` matters: add over an all-null list is null, @tsv renders it as an
    # EMPTY field, and tab is IFS whitespace, so bash read would shift every
    # later column left.
    ((map(call | .estimated_tokens_avoided) | add) // 0),
    (map(call | select(.exit_status != 0)) | length),
    (map(call) | length),
    (map(call | select(.tier != null)) | length),
    (map(select(src == "feedback")) | length),
    (map(select(src == "opportunity")) | length)
  ] | @tsv' "$metrics_file")

echo "=== delegate-local metrics ==="
echo "File:                $display_file"
(( window_active )) && echo "Window:              since $cutoff_iso  ($(( model_active ? pre_model : total )) of $orig_total rows)"
(( model_active )) && echo "Model filter:        '$model_filter'  ($total of $pre_model rows)"
echo "Time range:          $ts_first  →  $ts_last"
echo "Total invocations:   $n_call  (not counted: feedback=$n_feedback, opportunity=$n_opp)"
echo "Errors (non-zero):   $errors"
echo "Tokens avoided (≈):  $total_avoided"

# What the total actually avoided (#412): estimated_tokens_avoided is written
# on EVERY row, failed calls and rewritten drafts included, so the headline
# stays the gross figure (the Per-source block sums to it, and the test pins
# that) and the qualification goes underneath. Its own pass: the feedback
# rollup sits inside an `n_feedback > 0` guard. Every sum takes `// 0` and
# every percentage guards a non-zero denominator, since jq aborts on
# divide-by-zero and under `set -uo pipefail` the section would vanish.
#
# Every section that needs a delegate row's current verdict reads it from
# `verdict_index` in scripts/lib/pair.jq, the one join self-improve.sh and
# replay-recipe.sh read too (#564): one verdict per delegation, the latest,
# whether it was pinned by otel_span_id or by ts, and a ts-only verdict on a
# shared second lands on one delegation, not on every row in that second.
#
# A verdict whose final was already in the piped stdin (#588) is its own
# class, "ritual": the caller posted text it had before the delegation, so the
# draft never had a chance. It is the stored final_preexisting tag, or for a
# verdict recorded before the field, the measurement `self-improve.sh
# --ritual` wrote to ritual-verdicts.tsv beside the metrics file; reading the
# sidecar keeps this script cheap and read-only. A final
# `self-improve.sh --quarantine` listed in suspect-finals.tsv is not what
# shipped (#587), so it is never ritual. Every verdict rate leaves ritual out
# of n and prints it as ritual=, and every rate prints sessions=, the
# distinct sessions its rows come from, since two sessions made most of one
# template's rejections. Both sidecars go to every program as --rawfile.
suspect_file="$(dirname "$display_file")/suspect-finals.tsv"
[[ -f "$suspect_file" ]] || suspect_file=/dev/null
ritual_file="$(dirname "$display_file")/ritual-verdicts.tsv"
[[ -f "$ritual_file" ]] || ritual_file=/dev/null
# The ritual= column, when there is anything to put in it.
ritual_col='def ritual_col: if .ritual > 0 then "  ritual=\(.ritual)" else "" end;'
jq -L "$lib_dir" -rs --rawfile sl "$suspect_file" --rawfile rl "$ritual_file" '
  include "pair";
  verdict_index($sl; $rl) as $vi
  | delegates as $dl
  | ($dl | map(select(ok | not))) as $bad
  | ($dl | map(select(ok))
        | map({t: (.estimated_tokens_avoided // 0), v: ($vi[dkey] // "none")})) as $ok
  | ($ok | map(.t) | add // 0) as $ok_tok
  | (def bucket($k): ($ok | map(select(.v == $k)));
     [ ["shipped as-is",   "kept"],
       ["rewritten",       "rewrote"],
       ["used as scaffold","scaffold"],
       ["no verdict",      "none"] ]
     + (if any($ok[]; .v == "ritual") then [["ritual (own text)", "ritual"]] else [] end)
     | map(. as [$label, $key]
           | (bucket($key)) as $b
           | "    \($label + (" " * (18 - ($label | length))))tokens≈\($b | map(.t) | add // 0)  \(pct(($b | map(.t) | add // 0); $ok_tok))%  n=\($b | length)")) as $lines
  | ([ (if ($bad | length) > 0 then "  excluded: failed delegations    tokens≈\($bad | map(.estimated_tokens_avoided // 0) | add // 0)  n=\($bad | length)" else empty end),
       "  successful delegations          tokens≈\($ok_tok)  n=\($ok | length)"
     ] + (if ($ok | length) > 0 then $lines else [] end))
  | .[]
' "$metrics_file"
echo

# Feedback and opportunity events have no duration / token cost and are
# reported in their own sections.
#
# One percentile for every latency column (#552): over a sorted array, index
# floor(n*p/100) clamped to n-1, n bound before indexing. The inline form it
# replaces clamped against `length` of the index, a number, whose length is
# its absolute value, so the clamp always fired and p95 came back one low.
pct_def='def pct($p): sort | length as $n | if $n == 0 then null else .[[($n * $p / 100 | floor), $n - 1] | min] end;'
echo "Per-source:"
jq -rs '
  def src: .source // "delegate";
  '"$pct_def"'
  map(select(src != "feedback" and src != "opportunity"))
  | group_by(src)
  | map({
      source: (.[0] | src),
      n: length,
      tokens: (map(.estimated_tokens_avoided) | add),
      p50: (map(.duration_ms) | pct(50)),
      p95: (map(.duration_ms) | pct(95))
    })
  | sort_by(-.n)
  | .[]
  | "  \(.source | . + (" " * (12 - length)))  n=\(.n)  tokens≈\(.tokens)  p50=\(.p50)ms  p95=\(.p95)ms"
' "$metrics_file"
echo

# Only printed with 2+ distinct backends. Rows missing the field pre-date it
# and are bucketed as `ollama`, the only path then.
n_backends=$(jq -rs '
  map(select((.source // "delegate") == "delegate"))
  | map(.backend // "ollama")
  | unique
  | length
' "$metrics_file")
if (( n_backends > 1 )); then
  echo "Per-backend (delegate):"
  jq -rs '
    '"$pct_def"'
    map(select((.source // "delegate") == "delegate"))
    | group_by(.backend // "ollama")
    | map({
        backend: (.[0].backend // "ollama"),
        n: length,
        tokens: (map(.estimated_tokens_avoided // 0) | add),
        p50: (map(.duration_ms) | pct(50) // 0),
        p95: (map(.duration_ms) | pct(95) // 0)
      })
    | sort_by(-.n)
    | .[]
    | "  \(.backend | . + (" " * (10 - length)))  n=\(.n)  tokens≈\(.tokens)  p50=\(.p50)ms  p95=\(.p95)ms"
  ' "$metrics_file"
  echo
fi

# Feedback rollup, scoped to RECIPE delegations (the unit the library
# self-corrects on); raw delegations get their own line so optional verdicts
# do not inflate "untracked". Scoped to exit_status==0: a failed delegation
# produced nothing to judge. One verdict tier (ADR 0030): every feedback row
# counts, tagged or not. The scaffold column is shown only when a scaffold
# verdict exists, so legacy files print as before; the counter and gate are
# initialised unconditionally because later blocks read them (set -u).
n_scaffold=0
show_scaffold=false
if (( n_feedback > 0 )); then
  n_scaffold=$(jq -rs '
    map(select((.source // "") == "feedback" and (.scaffold // false) == true))
    | length' "$metrics_file")
  (( n_scaffold > 0 )) && show_scaffold=true
  # The header self-describes the scaffold column when one is present.
  if [[ "$show_scaffold" == true ]]; then
    echo "Delegation feedback (hit/miss/scaffold):"
  else
    echo "Delegation feedback (hit/miss):"
  fi
  # Hook capture measured on disk (#552): a rejection counts when its draft's
  # <stem>.final.txt sits in the drafts dir beside the metrics file (where
  # delegate.sh, the boundary hook and delegate-feedback.sh all put it) and
  # the hook wrote it. The stem is read off the verdict's own final_file,
  # else its ref_id, else its ref_ts only when one delegate row holds that
  # second (a shared second is skipped, not guessed). The hook never
  # overwrites, so a base <stem>.final.txt that any verdict names without
  # final_source:"posted" was written by an explicit --final, and that stem
  # never counts, whatever later verdicts stored as <stem>.final.2.txt.
  drafts_dir="$(dirname "$display_file")/drafts"
  hook_captured=0
  while read -r stem; do
    [[ -f "$drafts_dir/$stem.final.txt" ]] && hook_captured=$((hook_captured + 1))
  done < <(jq -rs '
    def src: .source // "delegate";
    def stem_of_final: (.final_file // "") | sub("\\.final(\\.[0-9]+)?\\.txt$"; "");
    [.[] | select(src == "delegate" and (.draft_file // "") != "")
         | {id: (.otel_span_id // ""), ts: (.ts // ""), stem: (.draft_file | sub("\\.draft\\.txt$"; ""))}] as $rows
    | (reduce ($rows[] | select(.id != "")) as $r ({}; .[$r.id] = $r.stem)) as $by_id
    | (reduce $rows[] as $r ({}; .[$r.ts] += [$r.stem])) as $by_ts
    | (reduce ($all[] | select(src == "feedback" and .final_source != "posted"
                            and ((.final_file // "") | test("\\.final\\.txt$"))
                            and ((.final_file // "") | test("\\.final\\.[0-9]+\\.txt$") | not)))
         as $f ({}; .[$f | stem_of_final] = true)) as $by_hand
    | .[]
    | select(src == "feedback" and (.kept // false) == false)
    | (if (.final_file // "") != "" then stem_of_final
       elif $by_id[.ref_id // ""] != null then $by_id[.ref_id]
       elif ($by_ts[.ref_ts // ""] // [] | length) == 1 then $by_ts[.ref_ts][0]
       else empty end) as $stem
    | select($by_hand[$stem] != true)
    | $stem
  ' --slurpfile all "$display_file" "$metrics_file")
  jq -L "$lib_dir" -rs --rawfile sl "$suspect_file" --rawfile rl "$ritual_file" --argjson show_scaffold "$show_scaffold" --argjson hook_captured "$hook_captured" '
    include "pair";
    '"$ritual_col"'
    verdict_index($sl; $rl) as $vi
    | (delegates | map(select(ok) | {recipe, tier, session, u: $vi[dkey]})) as $d
    | ($d | map(select(.recipe != null))) as $rx_all
    | ($rx_all | map(select(.u != "ritual"))) as $rx
    | ($d | map(select(.recipe == null))) as $raw
    | ($rx_all | tally) as $t
    | ($raw | length) as $wn
    | "  Recipe delegations (calibration signal): n=\($t.n)  hits=\($t.kept)  misses=\($t.rewrote)" + (if $show_scaffold then "  scaffold=\($t.scaffold)" else "" end) + "  untracked=\($t.untracked)" + ($t | ritual_col) + (if $t.n > 0 then "  coverage=\(rate($t.n - $t.untracked; $t.n))%  sessions=\($t.sessions)" else "" end),
      ($rx | group_by(.tier) | map({tier: .[0].tier} + tally) | sort_by(-.n) | .[] | "    \(.tier | . + (" " * (14 - length)))  n=\(.n)  hits=\(.kept)  misses=\(.rewrote)" + (if $show_scaffold then "  scaffold=\(.scaffold)" else "" end) + "  untracked=\(.untracked)"),
      # Captured-pair coverage, counted over feedback ROWS (a delegation can
      # carry more than one verdict). inferred= is adoption: the verdict took
      # the final the hook wrote, as no --final was passed (final_source:"posted").
      # by-hand= is an explicit --final. Callers now pass --final, so inferred
      # stays near 0 while the hook keeps capturing; hook-captured= is that
      # capture, read from the drafts dir above, and 0 there is the failure.
      (([.[] | select(src == "feedback" and (.kept // false) == false)]) as $rej
       | ($rej | map(select((.final_file // "") != ""))) as $cap
       | if ($rej | length) > 0 then
           "  Captured pairs (rejections with the shipped text stored): n=\($cap|length)/\($rej|length)  inferred=\($cap|map(select(.final_source == "posted"))|length)  by-hand=\($cap|map(select(.final_source != "posted"))|length)  hook-captured=\($hook_captured)"
         else empty end),
      (if $wn > 0 then "  Raw / no-recipe (verdicts optional — experiments, audits, ad-hoc): n=\($wn)  tracked=\($raw|map(select(.u!=null))|length)  untracked=\($raw|map(select(.u==null))|length)" else empty end)
  ' "$metrics_file"
  echo
fi

# Per-project rollup. Rows with no project are current and deliberate:
# delegate_project_name emits nothing outside a git repository (#476), so they
# get one `(no project)` line after the named projects, outside the count
# ranking. Only printed with 2+ distinct project values.
n_projects=$(jq -rs '
  map(select((.source // "delegate") == "delegate" and (.exit_status // 0) == 0))
  | map(.project // "")
  | unique
  | length
' "$metrics_file")
if (( n_projects > 1 )); then
  echo "Per-project (delegate):"
  jq -L "$lib_dir" -rs --rawfile sl "$suspect_file" --rawfile rl "$ritual_file" --argjson show_scaffold "$show_scaffold" '
    include "pair";
    '"$pct_def"'
    '"$ritual_col"'
    verdict_index($sl; $rl) as $vi
    | delegates | map(select(ok) | {project: (.project // ""), session, duration_ms, u: $vi[dkey]})
    | group_by(.project)
    # Latency is every delegation the project ran, ritual ones included:
    # only the verdict counts leave them out.
    | map({project: .[0].project, p50: (map(.duration_ms) | pct(50) // 0)} + tally)
    | sort_by((.project == ""), -.n)
    | .[]
    | "  \((if .project == "" then "(no project)" else .project end) | . + (" " * (20 - length)))  n=\(.n)  hits=\(.kept)  misses=\(.rewrote)" + (if $show_scaffold then "  scaffold=\(.scaffold)" else "" end) + "  untracked=\(.untracked)\(ritual_col)  p50=\(.p50)ms  sessions=\(.sessions)"
  ' "$metrics_file"
  echo
fi

# Per-recipe rollup: which recipes underperform. Printed when at least one
# recipe row exists.
n_recipe=$(jq -rs '
  map(select((.source // "delegate") == "delegate" and .recipe != null and (.exit_status // 0) == 0))
  | length
' "$metrics_file")
if (( n_recipe > 0 )); then
  echo "Per-recipe (delegate):"
  jq -L "$lib_dir" -rs --rawfile sl "$suspect_file" --rawfile rl "$ritual_file" --argjson show_scaffold "$show_scaffold" '
    include "pair";
    '"$ritual_col"'
    def counts: tally | "n=\(.n)  hits=\(.kept)  misses=\(.rewrote)" + (if $show_scaffold then "  scaffold=\(.scaffold)" else "" end) + "  untracked=\(.untracked)" + ritual_col + "  sessions=\(.sessions)";
    verdict_index($sl; $rl) as $vi
    | delegates | map(select(.recipe != null and ok) | {recipe, session, iq: (.input_quality // []), u: $vi[dkey],
                                                       model: (.model // "(unknown)"), ts: (.ts // "")})
    | group_by(.recipe)
    | sort_by(-length)
    | .[]
    # A recipe with any row delegate.sh flagged as a weak input (#590) gets a
    # sub-line per label, a row with two labels counting under both, and one
    # for its unflagged rows, so the confound reads beside the hit rate.
    | . as $rows
    | "  \($rows[0].recipe | . + (" " * (20 - length)))  \($rows | counts)",
      (if any($rows[]; (.iq | length) > 0) then
         ([$rows[] | select((.iq | length) == 0)] | select(length > 0) | "    input_quality=(none)             \(counts)"),
         ([$rows[].iq[]] | unique | .[] as $l
          | [$rows[] | select(any(.iq[]; . == $l))] | "    input_quality=\($l + (" " * (17 - ($l | length))))  \(counts)")
       else empty end),
      # A recipe more than one model served (#655) gets a sub-line per model,
      # most rows first, then the model that served it first: ADR 0009 binds
      # calibration to the model, so a switch must not blend two corpora.
      # The model is read off the delegate row, so each verdict lands on it.
      (if ([$rows[].model] | unique | length) > 1 then
         $rows | group_by(.model) | sort_by(-length, (map(.ts) | min)) | .[]
         | "    model=\(.[0].model + (" " * (25 - (.[0].model | length))))  \(counts)"
       else empty end)
  ' "$metrics_file"
  echo
fi

# Trigger rate (#277): one source:"opportunity" row per boundary the hook saw,
# .delegated marking whether a local delegation preceded it; rate = delegated
# / opportunities per project, every row counting (#465). Projectless rows get
# one `(no project)` line after the named ones, outside the ranking. Two kinds
# of row leave the ratio (#483): `below_floor:true`, a body no recipe should
# draft, and `denied:true` when the same session retried within the window,
# since the retry is the row that counts; a denial never retried stays a miss.
# Since #607 `approved:true` leaves it too: a post of text the human was
# shown and answered before it went out, which the hook does not deny. An
# approved post after a denial is that denial's retry.
# The footer names the floor and window in force for this shell, read with the
# hook's own guards, because the rows carry the verdict, not the threshold.
if (( n_opp > 0 )); then
  echo "Trigger rate (commit/PR/release/comment boundaries):"
  floor_override=""
  [[ "${DELEGATE_BOUNDARY_MIN_CHARS:-}" =~ ^[0-9]+$ ]] && floor_override="$DELEGATE_BOUNDARY_MIN_CHARS"
  retry_win="${DELEGATE_BOUNDARY_WINDOW_MIN:-480}"
  [[ "$retry_win" =~ ^[0-9]+$ ]] || retry_win=480
  # No ritual= here (#588): ritual is a verdict tag, and a verdict is not
  # joined to the opportunity row this line counts, so the per-project and
  # per-recipe rollups above carry it and this line carries sessions= only.
  jq -rs --arg floor "$floor_override" --argjson win_min "$retry_win" '
    def epoch: ((.ts | fromdateiso8601?) // 0);
    def sessions: map(.session // "" | select(. != "")) | unique | length;
    # A denial is retried when a LATER row (append order, not ts: a redraft in
    # the same second must not count as both a miss and a hit) for the same
    # session, project and boundary lands within the window AND is itself a
    # counted post: not denied, not below_floor, not the retry-cap fall-open.
    # The window is measured on ts, bounded below at zero so a clock-skewed
    # row cannot pass an upper-bound-only check. Rows with no session match on
    # project alone. O(denied x rows), and the denied set is small.
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
    | (map(select(.approved == true)) | length) as $approved
    | (map(select(.denied == true and .retried == true)) | length) as $denied
    | map(select(.below_floor != true and .approved != true and (.denied != true or .retried != true)))
    | (group_by(.project // "")
      | map({
          project: (.[0].project // ""),
          n: length,
          delegated: (map(select(.delegated == true)) | length),
          missed: (map(select(.delegated == false)) | length),
          sessions: sessions
        })
      | sort_by((.project == ""), -.n)
      | .[]
      | "  \((if .project == "" then "(no project)" else .project end) | . + (if length < 20 then " " * (20 - length) else "" end))  opportunities=\(.n)  delegated=\(.delegated)  missed=\(.missed)"
        + "  rate=\(.delegated * 100 / .n | floor)%"
        + "  sessions=\(.sessions)"),
      "  excluded \($floored) boundaries under " + (if $floor != "" then "\($floor) chars" else "the floor (20 chars for git-commit, 120 for the rest)" end)
        + (if $approved > 0 then " and \($approved) approved posts (text shown to the human and answered before it was posted)" else "" end),
      (if $denied > 0 then "  excluded \($denied) denied attempts retried within \($win_min)m (the post did not happen; the retry is what counts)" else empty end)
  ' "$metrics_file"
  echo
fi

if (( n_tier > 0 )); then
  echo "Per-tier (delegate):"
  jq -rs '
    '"$pct_def"'
    map(select((.source // "delegate") != "feedback" and .tier != null))
    | group_by(.tier)
    | map({
        tier: .[0].tier,
        n: length,
        p50: (map(.duration_ms) | pct(50)),
        p95: (map(.duration_ms) | pct(95))
      })
    | sort_by(-.n)
    | .[]
    | "  \(.tier | . + (" " * (14 - length)))  n=\(.n)  p50=\(.p50)ms  p95=\(.p95)ms"
  ' "$metrics_file"
  echo
fi

echo "Top models:"
jq -rs '
  map(select((.source // "delegate") | . != "feedback" and . != "opportunity"))
  | group_by(.model)
  | map({model: .[0].model, n: length})
  | sort_by(-.n)
  | .[0:5]
  | .[]
  | "  \(.n)  \(.model)"
' "$metrics_file"
