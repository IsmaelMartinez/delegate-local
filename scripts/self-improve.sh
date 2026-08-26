#!/usr/bin/env bash
# self-improve.sh — the gate and the evidence bundle for the recurring
# calibration session.
#
# Why this exists: the corpus already records WHY a delegation was rejected
# (the free-text `reason` on every feedback row), but nothing read it on a
# schedule, so the loop closed only when a human happened to ask "how are we
# doing". On 2026-08-26 that gap cost a full day: twenty delegations, zero
# kept, and the dominant defect (a recipe reproducing its own example) had
# been visible in the reasons since the first one.
#
# This script does the two mechanical halves of that loop so the session can
# spend its judgement on the third. It GATES (has anything happened since the
# last run? if not, exit 10 and say nothing) and it BUNDLES (here are the new
# verdicts, the reasons, the per-recipe keep rates, the deterministic check
# failures, and — where both were captured — an objective diff between the
# draft the model produced and the text that actually shipped).
#
# The draft/final diff is the part that is new information rather than a
# re-reading of old rows. `reason` is the agent's prose account of the gap;
# the diff is the gap itself, and in particular the DROPPED list names the
# specific salient tokens (file paths, identifiers, numbers, issue refs) the
# human had to put back. A recipe edit aimed at those is calibrated; one aimed
# at "dropped every load-bearing fact" is a guess.
#
# Usage:
#   self-improve.sh [--file PATH] [--peek] [--min-delegations N] [--days N]
#
#   --peek             report without advancing the watermark, so a dry run
#                      does not consume the window the next real run needs.
#   --min-delegations  how many NEW delegations must exist before there is
#                      anything worth a session (default 1).
#   --days N           rolling window for the per-recipe context section
#                      (default 7). The new-since-watermark sections are not
#                      affected — those are always "everything since last run".
# Env:
#   DELEGATE_METRICS_FILE     metrics JSONL (default
#                             ~/.local/share/delegate-local/metrics.jsonl).
#   DELEGATE_LOCAL_DATA_DIR   where per-user data lives
#                             (default ~/.local/share/delegate-local).
#   DELEGATE_SELF_IMPROVE_STATE  watermark file (default <data dir>/
#                             self-improve.state). Holds the ts of the newest
#                             delegate row the last run saw.
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

# The watermark is the ts of the newest delegate row the previous run saw.
# Absent (first run, or a reset corpus) means "treat everything as new" — the
# first session then gets the whole backlog once, which is the right shape for
# a loop that has just been switched on.
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
  # The quiet path, and the one that runs most of the time. Nothing on stdout
  # so a cron session can stop without producing noise.
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

# INDEX(.ts) keeps one row per key, and delegate timestamps are second-
# precision, so parallel callers can share one. Where that happens a feedback
# row's ref_ts cannot say which delegation it scored, and the recipe/project
# shown below is whichever row INDEX kept. Say so rather than reporting an
# attribution that might be wrong; the draft/final pair itself stays exact,
# because it is named after the draft rather than after the timestamp.
dupe_ts=$(jq -r 'select((.source // "delegate") == "delegate") | .ts' "$metrics_file" 2>/dev/null | sort | uniq -d)
if [[ -n "$dupe_ts" ]]; then
  echo "AMBIGUOUS: $(printf '%s\n' "$dupe_ts" | grep -c '') timestamp(s) are shared by more than one delegation;"
  echo "  recipe and project attribution for verdicts on those is a guess. Captured pairs are unaffected."
fi
echo

jq -rs --arg prev "$prev_ts" '
  (map(select((.source // "delegate") == "delegate")) | INDEX(.ts)) as $d
  | map(select(.source == "feedback" and ($prev == "" or ($d[.ref_ts].ts // "") > $prev)))
  | (map(select(.kept)) | length) as $kept
  | (map(select(.scaffold)) | length) as $scaf
  | (length - $kept - $scaf) as $rewrote
  | "Verdicts on those delegations: \(length) total — kept=\($kept) scaffold=\($scaf) rewrote=\($rewrote)"
' "$metrics_file"
echo

# ---------------------------------------------------------------------------
# Section 2 — per-recipe keep rate over the rolling window. Context for
# "is this a new defect or a standing one", and the ranking that says which
# recipe is worth the session's time. Worst first, ties broken by volume.
# ---------------------------------------------------------------------------
echo "--- per-recipe outcomes, last ${window_days}d (worst keep-rate first) ---"
jq -rs --argjson days "$window_days" '
  (now - ($days * 86400)) as $cut
  | (map(select((.source // "delegate") == "delegate")) | INDEX(.ts)) as $d
  | map(select(.source == "feedback"))
  | map(select((($d[.ref_ts].ts // "") | if . == "" then 0 else (fromdateiso8601? // 0) end) > $cut))
  | map({r: ($d[.ref_ts].recipe // "(bare)"),
         u: (if .kept then "kept" elif .scaffold then "scaffold" else "rewrote" end)})
  | group_by(.r)
  | map({recipe: .[0].r,
         n: length,
         kept: (map(select(.u == "kept")) | length),
         scaffold: (map(select(.u == "scaffold")) | length),
         rewrote: (map(select(.u == "rewrote")) | length)})
  | map(. + {rate: (if .n > 0 then (.kept * 100 / .n | floor) else 0 end)})
  | sort_by(.rate, -.n)
  | .[]
  | "  \(.recipe)  n=\(.n)  kept=\(.kept)  scaffold=\(.scaffold)  rewrote=\(.rewrote)  keep=\(.rate)%"
' "$metrics_file"
echo

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
#
# The DROPPED / INVENTED lists are computed here rather than described,
# because they are the one part of a MISS that is objective. A salient token
# is a backticked span, a dotted identifier or path, a filename, an issue ref,
# or a number — the things a maintainer reply or a commit message is judged on
# and the things the reasons keep saying went missing. All extraction is
# literal or a flat alternation (no nested quantifiers), so it is linear in
# the size of the text.
# ---------------------------------------------------------------------------
echo "--- rejected drafts since watermark ---"

salient() {
  # Emit one salient token per line, deduped, lowercased for comparison.
  [[ -f "$1" ]] || return 0
  {
    grep -oE '`[^`]+`' "$1" 2>/dev/null | tr -d '`'
    grep -oE '#[0-9]+' "$1" 2>/dev/null
    grep -oE '[A-Za-z0-9_][A-Za-z0-9_-]*\.[A-Za-z0-9_]+[A-Za-z0-9_.:/-]*' "$1" 2>/dev/null
    grep -oE '[0-9]+' "$1" 2>/dev/null | awk 'length($0) >= 2'
  } | tr '[:upper:]' '[:lower:]' | sed 's/[.,;:)]*$//' | awk 'NF' | sort -u
}

list_markers() {
  # grep -c already prints 0 when it matches nothing; it just exits 1 doing so,
  # so a `|| echo 0` fallback appends a SECOND zero and the caller's arithmetic
  # then chokes on "0\n0".
  local n
  [[ -f "$1" ]] || { echo 0; return 0; }
  n=$(grep -cE '^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]' "$1" 2>/dev/null)
  echo "${n:-0}"
}

# Stream one record per rejected delegation: ts, project, recipe, draft file,
# final file, verdict, reason. Rejections only — a kept draft has nothing to
# teach the recipe. The separator is US (\u001f), not a tab: tab is IFS
# WHITESPACE to bash, so `read` collapses a run of them into one delimiter and
# the two frequently-empty fields (draft_file, final_file) silently shift every
# later field left.
jq -rs --arg prev "$prev_ts" '
  (map(select((.source // "delegate") == "delegate")) | INDEX(.ts)) as $d
  | map(select(.source == "feedback" and (.kept | not)))
  | map(select($prev == "" or ($d[.ref_ts].ts // "") > $prev))
  | .[]
  | (.final_file // "") as $fin
  | [ .ref_ts,
      ($d[.ref_ts].project // "-"),
      ($d[.ref_ts].recipe // "(bare)"),
      # Prefer the draft the FEEDBACK row names: final_file is derived from
      # draft_file, so the two halves are provably the same delegation even
      # when several share a second-precision ts. The $d lookup is the
      # fallback for rejections recorded without --final.
      (if $fin != "" and ($fin | endswith(".final.txt"))
       then ($fin | sub("\\.final\\.txt$"; ".draft.txt"))
       else ($d[.ref_ts].draft_file // "") end),
      $fin,
      (if .scaffold then "scaffold" else "rewrote" end),
      ((.reason // "(no reason recorded)") | gsub("[[:cntrl:]]"; " ")) ]
  | join("\u001f")
' "$metrics_file" | while IFS=$'\037' read -r rts proj rec draft final verdict reason; do
  echo
  echo "  [$verdict] $rts  project=$proj  recipe=$rec"
  echo "    reason: $reason"
  if [[ -n "$draft" && -f "$drafts_dir/$draft" ]]; then
    dpath="$drafts_dir/$draft"
    echo "    draft:  $dpath ($(wc -c < "$dpath" | tr -d ' ') bytes)"
    if [[ -n "$final" && -f "$drafts_dir/$final" ]]; then
      fpath="$drafts_dir/$final"
      echo "    final:  $fpath ($(wc -c < "$fpath" | tr -d ' ') bytes)"
      dropped=$(comm -13 <(salient "$dpath") <(salient "$fpath") | head -n 12 | tr '\n' ' ')
      invented=$(comm -23 <(salient "$dpath") <(salient "$fpath") | head -n 12 | tr '\n' ' ')
      [[ -n "${dropped// /}"  ]] && echo "    DROPPED  (in the shipped text, absent from the draft): $dropped"
      [[ -n "${invented// /}" ]] && echo "    INVENTED (in the draft, absent from the shipped text): $invented"
      dm=$(list_markers "$dpath"); fm=$(list_markers "$fpath")
      if (( dm > 0 && fm == 0 )); then
        echo "    SHAPE: draft used $dm list item(s); the shipped text used none (prose was wanted)"
      elif (( fm > 0 && dm == 0 )); then
        echo "    SHAPE: shipped text used $fm list item(s); the draft used none"
      fi
    else
      echo "    final:  (not captured — pass --final to delegate-feedback.sh to make the next one diffable)"
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
  (map(select((.source // "delegate") == "delegate")) | INDEX(.ts)) as $d
  | map(select(.source == "feedback" and (.kept | not)))
  | map(select($prev == "" or ($d[.ref_ts].ts // "") > $prev))
  | (map(select(($d[.ref_ts].draft_file // "") != "")) | length) as $wd
  | (map(select((.final_file // "") != "")) | length) as $wf
  | (map(select((.reason // "") == "")) | length) as $nr
  | "  rejections=\(length)  with draft=\($wd)  with final=\($wf)  with no reason=\($nr)"
' "$metrics_file"

if (( peek == 0 )); then
  mkdir -p "$(dirname "$state_file")" 2>/dev/null || true
  printf '%s\n' "$newest_ts" > "$state_file" 2>/dev/null \
    || echo "self-improve: could not write watermark $state_file" >&2
fi
