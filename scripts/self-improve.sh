#!/usr/bin/env bash
# self-improve.sh — the gate and the evidence bundle for the recurring
# calibration session (docs/self-improvement-loop.md). It GATES (nothing new
# since the watermark: exit 10 and say nothing) and it BUNDLES the new
# verdicts, reasons, per-recipe keep rates, deterministic check failures and,
# where both were captured, a diff between the draft and the shipped text.
# The diff is the one objective part of a MISS: DROPPED names the tokens the
# human had to put back, which is what a calibrated recipe edit aims at. Where
# the rendered input was stored too (#516), the pair is scored against what
# the caller supplied: DROPPED narrows to supplied anchors and ADDED takes
# the ones nobody supplied, UNUSED names the supplied anchors the shipped
# text left out, ECHOED the supplied sentences the draft handed back.
#
# Usage:
#   self-improve.sh [--file PATH] [--peek] [--min-delegations N] [--days N]
#
#   --peek             report without advancing the watermark
#   --min-delegations  new delegations needed before there is anything to
#                      report (default 1)
#   --days N           rolling window for the per-recipe section (default 7);
#                      the since-watermark sections are unaffected
# Env:
#   DELEGATE_METRICS_FILE        metrics JSONL (default <data dir>/metrics.jsonl)
#   DELEGATE_LOCAL_DATA_DIR      per-user data (default ~/.local/share/delegate-local)
#   DELEGATE_SELF_IMPROVE_STATE  watermark file (default <data dir>/self-improve.state)
#   DELEGATE_PROMPTS_DIR         recipe directory whose templates are subtracted
#                                from a stored input (default <script dir>/../prompts)
# Exit: 0 evidence emitted, 10 nothing new (quiet, the normal cron outcome),
#       2 usage or dependency error.
set -uo pipefail

metrics_file="${DELEGATE_METRICS_FILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/metrics.jsonl}"
state_file="${DELEGATE_SELF_IMPROVE_STATE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/self-improve.state}"
peek=0
min_delegations=1
window_days=7

while (($# > 0)); do
  case "$1" in
    --file) metrics_file="${2:?--file requires a path}"; shift 2;;
    --file=*) metrics_file="${1#--file=}"; shift;;
    --peek) peek=1; shift;;
    --min-delegations) min_delegations="${2:?--min-delegations requires a number}"; shift 2;;
    --min-delegations=*) min_delegations="${1#--min-delegations=}"; shift;;
    --days) window_days="${2:?--days requires a number}"; shift 2;;
    --days=*) window_days="${1#--days=}"; shift;;
    -h|--help)
      sed -n '/^# Usage:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2;;
    *) echo "self-improve: unknown argument '$1'" >&2; exit 2;;
  esac
done

command -v jq >/dev/null || { echo "self-improve: jq not on PATH" >&2; exit 2; }
if [[ ! -f "$metrics_file" ]]; then
  echo "self-improve: metrics file not found: $metrics_file" >&2; exit 2
fi
case "$min_delegations" in ''|*[!0-9]*) echo "self-improve: --min-delegations must be a number" >&2; exit 2;; esac
case "$window_days" in ''|*[!0-9]*) echo "self-improve: --days must be a number" >&2; exit 2;; esac

drafts_dir="$(dirname "$metrics_file")/drafts"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prompts_dir="${DELEGATE_PROMPTS_DIR:-$script_dir/../prompts}"

# An absent watermark (first run, or a reset corpus) means everything is new.
prev_ts=""
[[ -f "$state_file" ]] && prev_ts=$(head -n 1 "$state_file" 2>/dev/null | tr -d '[:space:]')

newest_ts=$(jq -r 'select((.source // "delegate") == "delegate") | .ts' "$metrics_file" 2>/dev/null | tail -n 1)
if [[ -z "$newest_ts" || "$newest_ts" == "null" ]]; then
  echo "self-improve: no delegate rows in $metrics_file" >&2
  exit 10
fi

new_count=$(jq -r --arg prev "$prev_ts" \
  'select((.source // "delegate") == "delegate") | select($prev == "" or .ts > $prev) | .ts' \
  "$metrics_file" 2>/dev/null | grep -c '' || true)
new_count=${new_count:-0}

if (( new_count < min_delegations )); then
  # The quiet path: nothing on stdout, so a cron session stops without noise.
  echo "self-improve: $new_count new delegation(s) since ${prev_ts:-the beginning} (< $min_delegations) — nothing to do" >&2
  exit 10
fi

# ---------------------------------------------------------------------------
# Section 1 — what happened since the last run.
# ---------------------------------------------------------------------------
echo "=== delegate-local self-improvement evidence ==="
echo "Metrics:    $metrics_file"
echo "Watermark:  ${prev_ts:-(none — first run, reporting the whole corpus)}"
echo "Newest row: $newest_ts"
echo "New delegations since watermark: $new_count"

# The feedback-to-delegation join (`parent_join`, interpolated into every jq
# program below) and the pair scorers (`salient`, `list_markers`,
# `sentences`) are shared with replay-recipe.sh, so a rejection's DROPPED
# list and a replay's dropped count are one measurement.
# shellcheck source=lib/pair-score.sh
. "$script_dir/lib/pair-score.sh"

# A ref_ts-only verdict on a second shared by several delegations cannot say
# which it scored; say so rather than report a guess. Captured pairs are
# always exact because they are named after the draft.
ambiguous=$(jq -rs '
  (map(select((.source // "delegate") == "delegate")) | group_by(.ts) | map(select(length > 1) | .[0].ts)) as $shared
  | [.[] | select(.source == "feedback" and (.ref_id // "") == "" and (.ref_ts as $t | $shared | index($t) != null))] | length
' "$metrics_file" 2>/dev/null)
if [[ -n "$ambiguous" && "$ambiguous" != "0" ]]; then
  echo "AMBIGUOUS: $ambiguous verdict(s) name a second shared by more than one delegation and carry no ref_id;"
  echo "  recipe and project attribution for those is a guess. Captured pairs are unaffected."
fi
echo

# One verdict tier (ADR 0030): the keep rate is quoted from every feedback
# row. A delegation counts once, under its latest verdict, as
# metrics-summary.sh counts it. `usable` is kept plus scaffold over n, the
# same ranking key the per-recipe section uses.
jq -rs --arg prev "$prev_ts" '
  '"$parent_join"'
  latest_verdicts
  | map(select($prev == "" or (parent.ts // "") > $prev))
  | (map(select(.kept)) | length) as $kept
  | (map(select(.scaffold)) | length) as $scaffold
  | (map(select((.kept | not) and (.scaffold | not))) | length) as $rewrote
  | "Verdicts on those delegations: n=\(length)"
    + (if length > 0
       then "  kept=\($kept)  scaffold=\($scaffold)  rewrote=\($rewrote)  usable=\((($kept + $scaffold) * 100 / length) | floor)%"
       else ""
       end)
' "$metrics_file"
echo

# ---------------------------------------------------------------------------
# Section 2 — per-recipe keep rate over the rolling window: the ranking that
# says which recipe is worth the session's time. Worst first, ties by volume.
# ---------------------------------------------------------------------------
echo "--- per-recipe outcomes, last ${window_days}d (worst usable-rate first) ---"
jq -rs --argjson days "$window_days" '
  (now - ($days * 86400)) as $cut
  | '"$parent_join"'
  latest_verdicts
  | map(select(((parent.ts // "") | if . == "" then 0 else (fromdateiso8601? // 0) end) > $cut))
  | map({r: (parent.recipe // "(bare)"),
         u: (if .kept then "kept" elif .scaffold then "scaffold" else "rewrote" end)})
  | group_by(.r)
  | map({recipe: .[0].r,
         n: length,
         kept: (map(select(.u == "kept")) | length),
         scaffold: (map(select(.u == "scaffold")) | length),
         rewrote: (map(select(.u == "rewrote")) | length)})
  # Ranked on kept+scaffold: a recipe whose drafts are all thrown away is a
  # worse problem than one whose drafts get edited, and kept alone cannot tell.
  | map(. + {rate: (if .n > 0 then ((.kept + .scaffold) * 100 / .n | floor) else 0 end)})
  | sort_by(.rate, -.n)
  | .[]
  | "  \(.recipe)  n=\(.n)  kept=\(.kept)  scaffold=\(.scaffold)  rewrote=\(.rewrote)  usable=\(.rate)%"
' "$metrics_file"
echo

# ---------------------------------------------------------------------------
# Section 2b — the same outcomes split by the template that produced them,
# for every recipe that ran under more than one template in the window: the
# online half of the replay gate (docs/self-improvement-loop.md, "Revert").
# A row from before the template hash was recorded is one bucket,
# `(unhashed)`, so the pre-edit baseline sits beside the first hashed
# template rather than vanishing. Silent when no recipe changed template.
# ---------------------------------------------------------------------------
template_lines=$(jq -rs --argjson days "$window_days" '
  (now - ($days * 86400)) as $cut
  | '"$parent_join"'
  latest_verdicts
  | map(select(((parent.ts // "") | if . == "" then 0 else (fromdateiso8601? // 0) end) > $cut))
  | map({r: (parent.recipe // "(bare)"),
         sha: (parent.template_sha // "(unhashed)"),
         ts: (parent.ts // ""),
         u: (if .kept then "kept" elif .scaffold then "scaffold" else "rewrote" end)})
  | group_by(.r)
  | map(select((map(.sha) | unique | length) > 1))
  | map(.[0].r as $r
        | group_by(.sha)
        | map({recipe: $r, sha: .[0].sha, since: (map(.ts) | min), n: length,
               kept: (map(select(.u == "kept")) | length),
               scaffold: (map(select(.u == "scaffold")) | length),
               rewrote: (map(select(.u == "rewrote")) | length)})
        | sort_by(.since) | reverse)
  | .[] | .[]
  | "  \(.recipe)  template=\(.sha)  since=\(.since)  n=\(.n)  kept=\(.kept)  scaffold=\(.scaffold)  rewrote=\(.rewrote)  usable=\(if .n > 0 then ((.kept + .scaffold) * 100 / .n | floor) else 0 end)%"
' "$metrics_file")
if [[ -n "$template_lines" ]]; then
  echo "--- per-template outcomes, last ${window_days}d (recipes that changed template, newest first) ---"
  echo "$template_lines"
  echo
fi

# ---------------------------------------------------------------------------
# Section 3 — deterministic check failures. These need no interpretation: the
# wrapper already decided the output broke a declared constraint, so any
# cluster here is the cheapest possible fix target.
# ---------------------------------------------------------------------------
echo "--- deterministic check failures, last ${window_days}d ---"
check_lines=$(jq -rs --argjson days "$window_days" '
  (now - ($days * 86400)) as $cut
  | map(select((.source // "delegate") == "delegate"))
  | map(select((.ts | fromdateiso8601? // 0) > $cut))
  | map(select(.checks_failed_names != null))
  | map({r: (.recipe // "(bare)"), names: .checks_failed_names})
  | map(.r as $r | .names | map({r: $r, name: .})) | add // []
  | group_by(.r + "/" + .name)
  | sort_by(-length)
  | .[]
  | "  \(.[0].r): \(.[0].name) × \(length)"
' "$metrics_file")
if [[ -n "$check_lines" ]]; then echo "$check_lines"; else echo "  (none)"; fi
echo

# ---------------------------------------------------------------------------
# Section 4 — the new rejections, with the draft/final pair where it exists.
# DROPPED / INVENTED are computed, not described: a salient token is a
# backticked span, a dotted identifier or path, an issue ref, or a number.
# Extraction is literal or a flat alternation, so it is linear.
# ---------------------------------------------------------------------------
echo "--- rejected drafts since watermark ---"

# supplied <input file> <recipe> — the caller's half of a stored input: every
# line of it that is not a line of the recipe's PRE-substitution template,
# whole-line and literal, the comparison no_example_echo makes. The template
# is read from prompts/ as delegate.sh reads it; without it (a renamed
# recipe) the whole input counts, and the template's own example paths and
# numbers would read as supplied anchors. A substituted line differs from its
# template line, so it survives, which is the caller's value on it.
supplied() {
  local tmpl=""
  [[ -f "$prompts_dir/$2.md" ]] && tmpl=$(awk '
    /^## Prompt template[[:space:]]*$/ { in_section=1; next }
    /^## / && in_section && !in_block { in_section=0 }
    in_section && /^```/ {
      if (in_block) { exit }
      in_block=1; next
    }
    in_section && in_block { print }
  ' "$prompts_dir/$2.md" 2>/dev/null)
  if [[ -n "$tmpl" ]]; then
    grep -Fxvf <(printf '%s\n' "$tmpl") "$1"
  else
    cat "$1"
  fi
}

# The supplied half of the input, extracted once per rejection: salient reads
# a file four times over.
supplied_tmp=$(mktemp)
trap 'rm -f "$supplied_tmp"' EXIT

# One record per rejected delegation. The separator is US (\u001f), not a tab: tab is IFS
# whitespace, so `read` would collapse the frequently-empty draft_file /
# final_file fields and shift every later field left.
jq -rs --arg prev "$prev_ts" '
  '"$parent_join"'
  map(select(referenced and (.kept | not)))
  | map(select($prev == "" or (parent.ts // "") > $prev))
  | .[]
  | (.final_file // "") as $fin
  | parent as $p
  | [ .ref_ts,
      ($p.project // "-"),
      ($p.recipe // "(bare)"),
      # The draft the FEEDBACK row names is provably the same delegation; a
      # numbered final belongs to the same draft as the bare name (#474). The
      # parent lookup is the fallback for rejections recorded without --final.
      (if $fin != "" and ($fin | test("\\.final(\\.[0-9]+)?\\.txt$"))
       then ($fin | sub("\\.final(\\.[0-9]+)?\\.txt$"; ".draft.txt"))
       else ($p.draft_file // "") end),
      $fin,
      (.final_source // ""),
      (if .scaffold then "scaffold" else "rewrote" end),
      ((.reason // "(no reason recorded)") | gsub("[[:cntrl:]]"; " ")) ]
  | join("\u001f")
' "$metrics_file" | while IFS=$'\037' read -r rts proj rec draft final fsrc verdict reason; do
  echo
  echo "  [$verdict] $rts  project=$proj  recipe=$rec"
  echo "    reason: $reason"
  if [[ -n "$draft" && -f "$drafts_dir/$draft" ]]; then
    dpath="$drafts_dir/$draft"
    dbytes=$(wc -c < "$dpath" | tr -d ' ')
    echo "    draft:  $dpath ($dbytes bytes)"
    # The input shares the draft's stem (#516), so it is provably the same
    # delegation's; rows from before it carry none and print as they did.
    ipath="$drafts_dir/${draft%.draft.txt}.input.txt"
    if [[ -f "$ipath" ]]; then
      ibytes=$(wc -c < "$ipath" | tr -d ' ')
      echo "    input:  $ipath ($ibytes bytes)"
      supplied "$ipath" "$rec" > "$supplied_tmp"
    else
      ipath=""
    fi
    if [[ -n "$final" && -f "$drafts_dir/$final" ]]; then
      fpath="$drafts_dir/$final"
      fbytes=$(wc -c < "$fpath" | tr -d ' ')
      # A final the hook inferred was captured BEFORE the post, so it is what
      # was about to go out rather than what demonstrably did.
      if [[ "$fsrc" == "posted" ]]; then
        echo "    final:  $fpath ($fbytes bytes, captured from the post)"
      else
        echo "    final:  $fpath ($fbytes bytes)"
      fi
      # The tokens the shipped text carries and the draft did not, sorted, as
      # comm emits them.
      # A token is only new (or only the draft's) when the other text does
      # not carry it in any spelling: `absent_from` in lib/pair-score.sh.
      new_tokens=$(comm -13 <(salient "$dpath") <(salient "$fpath") | absent_from "$dpath")
      draft_only=$(comm -23 <(salient "$dpath") <(salient "$fpath") | absent_from "$fpath" | head -n 12 | tr '\n' ' ')
      # With the input, DROPPED is what the caller supplied and the model
      # dropped; a token the shipped text carries that neither the input nor
      # the draft had is context the human added, not a fact the model lost,
      # and goes under ADDED. Without one, DROPPED is the whole set, as ever.
      if [[ -n "$ipath" ]]; then
        dropped=$(printf '%s\n' "$new_tokens" | comm -12 - <(salient "$supplied_tmp") | head -n 12 | tr '\n' ' ')
        added=$(printf '%s\n' "$new_tokens" | comm -23 - <(salient "$supplied_tmp") | head -n 12 | tr '\n' ' ')
        [[ -n "${dropped// /}" ]] && echo "    DROPPED  (in the input and the shipped text, absent from the draft): $dropped"
        [[ -n "${added// /}"   ]] && echo "    ADDED    (in the shipped text, absent from the input and the draft): $added"
      else
        dropped=$(printf '%s\n' "$new_tokens" | head -n 12 | tr '\n' ' ')
        [[ -n "${dropped// /}" ]] && echo "    DROPPED  (in the shipped text, absent from the draft): $dropped"
      fi
      # A draft token absent from the shipped text has two causes, and calling
      # both INVENTED reported hallucination on the commonest rejection (a body
      # the human cut for length). The discriminator is the new-token set
      # alone, DROPPED and ADDED together: invention is a claim something was
      # replaced, and the only evidence is the shipped text carrying a token
      # the draft lacked, whoever supplied it.
      if [[ -n "${draft_only// /}" ]]; then
        if [[ -z "$new_tokens" ]]; then
          echo "    CUT      (in the draft, removed; the shipped text put nothing in their place): $draft_only"
        else
          echo "    INVENTED (in the draft, replaced in the shipped text): $draft_only"
        fi
      fi
      dm=$(list_markers "$dpath"); fm=$(list_markers "$fpath")
      dp=$(paragraphs "$dpath"); fp=$(paragraphs "$fpath")
      if (( dm > 0 && fm == 0 )); then
        echo "    SHAPE: draft used $dm list item(s); the shipped text used none (prose was wanted)"
      elif (( fm > 0 && dm == 0 )); then
        echo "    SHAPE: shipped text used $fm list item(s); the draft used none"
      elif (( dp == 1 && fp >= 3 )); then
        echo "    SHAPE: draft was one paragraph; the shipped text used $fp (one per topic was wanted)"
      elif (( fp == 1 && dp >= 3 )); then
        echo "    SHAPE: draft used $dp paragraphs; the shipped text used one"
      fi
      # Scored against what was supplied rather than against the draft: the
      # anchors the caller gave that the shipped text carried nowhere.
      if [[ -n "$ipath" ]]; then
        unused=$(comm -23 <(salient "$supplied_tmp") <(salient "$fpath") | absent_from "$fpath" | head -n 12 | tr '\n' ' ')
        [[ -n "${unused// /}" ]] && echo "    UNUSED   (in the input, absent from the shipped text): $unused"
      fi
    else
      echo "    final:  (not captured — pass --final to delegate-feedback.sh to make the next one diffable)"
    fi
    # The supplied sentences the draft returned as written, the defect
    # no_context_echo measures at generation time, named from the pair so a
    # rejection reads "handed the facts back" with the facts beside it.
    if [[ -n "$ipath" ]]; then
      echoed=$(sentences < "$supplied_tmp" | grep -Fxf - <(sentences < "$dpath") | sort -u)
      if [[ -n "$echoed" ]]; then
        echoed_n=$(printf '%s\n' "$echoed" | grep -c '')
        echo "    ECHOED   ($echoed_n input sentence(s) reproduced in the draft): $(printf '%s\n' "$echoed" | head -n 3 | cut -c1-120 | sed 's/.*/"&"/' | paste -sd ' ' -)"
      fi
    fi
  else
    echo "    draft:  (not captured)"
  fi
done
echo

# ---------------------------------------------------------------------------
# Section 5 — coverage of the capture itself. A loop that cannot see its own
# blind spot goes on optimising the half it can see.
# ---------------------------------------------------------------------------
echo "--- capture coverage since watermark ---"
jq -rs --arg prev "$prev_ts" '
  '"$parent_join"'
  map(select(referenced and (.kept | not)))
  | map(select($prev == "" or (parent.ts // "") > $prev))
  | (map(select((parent.draft_file // "") != "")) | length) as $wd
  | (map(select((parent.input_file // "") != "")) | length) as $wi
  | (map(select((.final_file // "") != "")) | length) as $wf
  | (map(select((.reason // "") == "")) | length) as $nr
  | "  rejections=\(length)  with draft=\($wd)  with input=\($wi)  with final=\($wf)  with no reason=\($nr)"
' "$metrics_file"

if (( peek == 0 )); then
  mkdir -p "$(dirname "$state_file")" 2>/dev/null || true
  printf '%s\n' "$newest_ts" > "$state_file" 2>/dev/null \
    || echo "self-improve: could not write watermark $state_file" >&2
fi
