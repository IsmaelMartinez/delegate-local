#!/usr/bin/env bash
# quality-report.sh — re-review the recorded hit/miss verdicts and produce a
# more honest quality number than the raw hit-rate.
#
# Why this exists: a "hit" in the metrics means the agent USED the delegated
# output, not that the output was clean — the verdict is binary and counts
# "used after I fixed it" the same as "used verbatim". The raw hit-rate
# therefore overstates quality. This script re-derives quality from the
# free-text `reason` the verdict carries, splitting hits into "clean" (used
# as-is) and "fixed" (used after an edit), and buckets the problem cases by
# failure mode. It re-reviews PAST decisions from data already on disk — it
# does not need the original model output (which is never stored). See
# docs/adr/0016-historical-quality-rereview.md.
#
# Two modes:
#   default     — keyword heuristic. Zero dependencies, instant, repeatable,
#                 but a large share of hits land "ambiguous": a floor, not a
#                 trusted number.
#   --classify  — delegates each reason to a local model for closed-form
#                 classification (CLEAN / FAITHFULNESS / PADDING / STRUCTURAL /
#                 STYLE / OPERATIONAL / OTHER). Accurate, still on-device and
#                 repeatable; slower (one local call per ~25 reasons).
#
# Honesty boundaries, stated in the output too:
#   - The `reason` is self-reported by the same agent that judged, so problem
#     counts are a LOWER bound and the clean-as-is rate an UPPER bound: a flaw
#     the agent never noticed never became a reason.
#   - Verdicts with no reason cannot be re-reviewed; reported as indeterminate.
#
# Usage:
#   quality-report.sh [--file PATH] [--since YYYY-MM-DD|ISO] [--days N]
#                     [--classify] [--by-recipe] [--tier human|agent|all]
# Env:
#   DELEGATE_METRICS_FILE   metrics JSONL (default
#                           ~/.local/share/delegate-local/metrics.jsonl).
#   DELEGATE_LOCAL_DATA_DIR where per-user data lives
#                           (default ~/.local/share/delegate-local).
#   DELEGATE_QUALITY_BATCH  reasons per --classify model call (default 25).
# Exit: 0 on a successful report; 2 on a usage / dependency error.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The delegate.sh used by --classify; overridable so the test suite can inject a
# stub model without a live backend.
delegate_sh="${DELEGATE_QUALITY_DELEGATE_SH:-$script_dir/delegate.sh}"
metrics_file="${DELEGATE_METRICS_FILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/metrics.jsonl}"
since=""; days=""; classify=0; by_recipe=0; tier="agent"

while (($# > 0)); do
  case "$1" in
    --file)  [[ $# -ge 2 ]] || { echo "--file requires a path" >&2; exit 2; }; metrics_file="$2"; shift 2 ;;
    --file=*) metrics_file="${1#--file=}"; shift ;;
    --since) [[ $# -ge 2 ]] || { echo "--since requires a value (YYYY-MM-DD or ISO-8601)" >&2; exit 2; }; since="$2"; shift 2 ;;
    --since=*) since="${1#--since=}"; shift ;;
    --days)  [[ $# -ge 2 ]] || { echo "--days requires an integer" >&2; exit 2; }; days="$2"; shift 2 ;;
    --days=*) days="${1#--days=}"; shift ;;
    --classify) classify=1; shift ;;
    --by-recipe) by_recipe=1; shift ;;
    # ADR 0015 splits feedback into human verdicts (quality) and
    # verdict_source:"agent" (usage). Pooling them is the conflation #408
    # removed from the dashboards; this tool must not reintroduce it, so it
    # reports one tier at a time and always says which.
    --tier)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == -* ]]; then
        echo 'quality-report: --tier requires human|agent|all' >&2; exit 2
      fi
      tier="$2"; shift 2 ;;
    --tier=*) tier="${1#--tier=}"; shift ;;
    -h|--help) awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    *) echo "quality-report: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[[ -n "$since" && -n "$days" ]] && { echo "quality-report: --since and --days are mutually exclusive" >&2; exit 2; }
[[ -f "$metrics_file" ]] || { echo "quality-report: metrics file not found: $metrics_file" >&2; exit 2; }
command -v jq >/dev/null || { echo "quality-report: jq not on PATH" >&2; exit 2; }

# Optional window cutoff, resolved in jq via now/fromdateiso8601 (no date(1) math).
cutoff_epoch=""; cutoff_iso=""
if [[ -n "$days" ]]; then
  [[ "$days" =~ ^[0-9]+$ ]] && (( days > 0 )) || { echo "quality-report: --days must be a positive integer" >&2; exit 2; }
  IFS=$'\t' read -r cutoff_epoch cutoff_iso < <(jq -rn --argjson d "$days" '((now|floor) - ($d * 86400)) | [., todateiso8601] | @tsv')
elif [[ -n "$since" ]]; then
  case "$since" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) cutoff_iso="${since}T00:00:00Z" ;;
    *) cutoff_iso="$since" ;;
  esac
  cutoff_epoch=$(jq -rn --arg c "$cutoff_iso" '$c | fromdateiso8601' 2>/dev/null) \
    || { echo "quality-report: --since '$since' is not a valid YYYY-MM-DD or ISO-8601 timestamp" >&2; exit 2; }
fi

feedback=$(mktemp "${TMPDIR:-/tmp}/quality-report.XXXXXX")
reasoned_tsv=$(mktemp "${TMPDIR:-/tmp}/quality-reasoned.XXXXXX")
cats_file=$(mktemp "${TMPDIR:-/tmp}/quality-cats.XXXXXX")
trap 'rm -f "$feedback" "$reasoned_tsv" "$cats_file"' EXIT

case "$tier" in
  human|agent|all) ;;
  *) echo "quality-report: --tier must be human|agent|all (got '$tier')" >&2; exit 2 ;;
esac
# A human verdict omits verdict_source entirely (delegate-feedback.sh writes the
# field only for the agent tier), so "human" is the complement of "agent" rather
# than a positive match on a literal.
jq -c --argjson cutoff "${cutoff_epoch:-0}" --arg tier "$tier" '
  select((.source//"")=="feedback")
  | select($cutoff == 0 or (((.ts // "") | fromdateiso8601?) >= $cutoff))
  | select($tier == "all"
           or ($tier == "agent" and (.verdict_source // "") == "agent")
           or ($tier == "human" and (.verdict_source // "") != "agent"))
' "$metrics_file" > "$feedback"

# The count in the tier NOT being reported, so a reader always knows the other
# population exists rather than mistaking this one for the whole picture.
other_tier_n=$(jq -r --argjson cutoff "${cutoff_epoch:-0}" --arg tier "$tier" '
  select((.source//"")=="feedback")
  | select($cutoff == 0 or (((.ts // "") | fromdateiso8601?) >= $cutoff))
  | select(($tier == "agent" and (.verdict_source // "") != "agent")
           or ($tier == "human" and (.verdict_source // "") == "agent"))
  | 1' "$metrics_file" | wc -l | tr -d ' ')

total=$(wc -l < "$feedback" | tr -d ' ')
if (( total == 0 )); then
  echo "quality-report: no feedback rows${cutoff_iso:+ in window (since $cutoff_iso)} in $metrics_file" >&2
  exit 0
fi

pct() { (( $2 == 0 )) && { echo "n/a"; return; }; awk -v n="$1" -v d="$2" 'BEGIN { printf "%d%%", (n*100/d)+0.5 }'; }

# Hits/misses are known from the kept flag regardless of mode.
scaffold=$(jq -r 'select((.scaffold // false)) | 1' "$feedback" | wc -l | tr -d ' ')
miss=$(jq -r 'select((.kept|not) and ((.scaffold // false) | not)) | 1' "$feedback" | wc -l | tr -d ' ')
hits=$(( total - miss - scaffold ))
# reasoned rows -> "kept<TAB>reason" (newlines/tabs flattened). Line N == reason N.
jq -rc 'select((.reason//"")!="") | [(.kept|tostring), (.reason|gsub("[\r\n\t]";" "))] | @tsv' "$feedback" > "$reasoned_tsv"
reasoned=$(wc -l < "$reasoned_tsv" | tr -d ' ')
unreasoned=$(( total - reasoned ))

# ---------------------------------------------------------------------------
# Build cats_file: one "globalReasonIndex<TAB>CATEGORY" line per reasoned row.
# default mode = keyword rules; --classify = local-model classification.
# ---------------------------------------------------------------------------
if (( classify )); then
  CLASSIFY_PROMPT='You are labelling short notes a reviewer wrote about a delegated text output. For each numbered note output exactly one line "N: LABEL" with ONE label, first matching rule wins:
CLEAN = used verbatim / as-is / no edits / clean.
FAITHFULNESS = a hallucination, invented content, a factual error, or a claim contradicting the source.
PADDING = a trailing participial or restating padding/filler clause.
STRUCTURAL = subject too long, a stray (#NN), wrong commit-type prefix, bullets-instead-of-prose, or other length/format issue.
STYLE = wrong voice/tone, spelling variant, jargon, or style-anchor leakage, no factual error.
OPERATIONAL = a stall, timeout, or failed/aborted call.
OTHER = none of the above.
Examples: "used verbatim, 6/6 checks" -> CLEAN; "stripped a hallucinated PR number" -> FAITHFULNESS; "trailing ensuring-X padding removed" -> PADDING; "subject was 80 chars" -> STRUCTURAL. Output only the N: LABEL lines, one per note.'
  batch="${DELEGATE_QUALITY_BATCH:-25}"
  base=0
  while (( base < reasoned )); do
    batch_txt=$(awk -v s=$((base+1)) -v e=$((base+batch)) -F'\t' 'NR>=s && NR<=e { printf "%d. %s\n", NR-s+1, $2 }' "$reasoned_tsv")
    [[ -z "$batch_txt" ]] && break
    out=$(printf '%s\n' "$batch_txt" | DELEGATE_LOCAL_NO_METRICS=1 DELEGATE_LOCAL_NO_VERDICT_NUDGE=1 DELEGATE_LOCAL_NO_META=1 \
          bash "$delegate_sh" code "$CLASSIFY_PROMPT" 2>/dev/null)
    printf '%s\n' "$out" \
      | sed -nE 's/^[[:space:]]*([0-9]+):[[:space:]]*([A-Za-z]+).*/\1 \2/p' \
      | awk -v base="$base" '{ print (base+$1) "\t" toupper($2) }' >> "$cats_file"
    base=$((base+batch))
    echo "  classified $(( base < reasoned ? base : reasoned ))/$reasoned ..." >&2
  done
else
  # Keyword rules in a single awk pass (no per-row shell forks). Conservative on
  # purpose; "fix" is excluded (collides with the conventional-commit type
  # "fix:" quoted in commit-message reasons).
  awk -F'\t' '
    { d = tolower($2)
      if (d ~ /edited|stripped|strip |removed|trimmed|hallucinat|rewrot|rewritten|corrected|dropped|de-?indent|tweaked|adjusted|reworded|by hand|hand-|had to|minor edit|light edit|one edit|mechanical edit|miss-with-edit/) c = "FIXEDKW"
      else if (d ~ /verbatim|as-is|as is|used as is|no edit|no changes|unchanged|used clean/) c = "CLEAN"
      else c = "AMBIG"
      print NR "\t" c
    }
  ' "$reasoned_tsv" > "$cats_file"
fi

# ---------------------------------------------------------------------------
# Aggregate from cats_file (reasonIndex -> CATEGORY) joined with reasoned_tsv
# (line N -> kept). A hit is clean iff CATEGORY==CLEAN; any other category on a
# hit means it was used-but-fixed. Misses keep their failure-mode category.
# ---------------------------------------------------------------------------
read -r clean_hit fixed_hit miss_classified faith padding structural style operational other_mode ambiguous classified < <(
  awk -F'\t' '
    NR==FNR { kept[FNR]=$1; n=FNR; next }           # reasoned_tsv: line -> kept; n = row count (length(array) is gawk-only)
    { cat[$1]=$2 }                                  # cats_file: index -> CATEGORY
    END {
      for (i=1; i<=n; i++) {
        if (!(i in cat)) continue                   # parse gap -> indeterminate, never a problem case
        c = cat[i]; classified++
        khit = (kept[i]=="true")
        if (khit && c=="CLEAN") clean_hit++
        else if (khit && c=="AMBIG") ambiguous++
        else if (khit) fixed_hit++
        else miss_classified++
        # failure-mode tally over problem cases (misses + fixed hits), by category
        if (!(khit && (c=="CLEAN"||c=="AMBIG"))) {
          if (c=="FAITHFULNESS") faith++
          else if (c=="PADDING") padding++
          else if (c=="STRUCTURAL") structural++
          else if (c=="STYLE") style++
          else if (c=="OPERATIONAL") operational++
          else if (c=="FIXEDKW") fixedkw++       # keyword mode: fix known, mode unknown
          else other++
        }
      }
      printf "%d %d %d %d %d %d %d %d %d %d %d\n",
        clean_hit+0, fixed_hit+0, miss_classified+0, faith+0, padding+0,
        structural+0, style+0, operational+0, (other+fixedkw)+0, ambiguous+0, classified+0
    }
  ' "$reasoned_tsv" "$cats_file"
)
problems=$(( fixed_hit + miss ))

# --- output -----------------------------------------------------------------
mode_label=$([[ $classify -eq 1 ]] && echo "local-model classification" || echo "keyword heuristic")
printf '\nQuality re-review of %s%s\n' "$metrics_file" "${cutoff_iso:+  (since $cutoff_iso)}"
printf 'mode: %s\n' "$mode_label"
printf '%s\n' "------------------------------------------------------------------"
case "$tier" in
  agent) printf 'Tier:                     agent-observed (usage — did the agent ship it, ADR 0015)\n' ;;
  human) printf 'Tier:                     human verdicts (quality — was it good, ADR 0015)\n' ;;
  all)   printf 'Tier:                     ALL — pooled usage and quality, NOT a quality figure\n' ;;
esac
(( other_tier_n > 0 )) && printf '                          (%d verdict(s) in the other tier, not counted here)\n' "$other_tier_n"
printf 'Verdicts:                 %d  (%d hits, %d misses, %d scaffold)\n' "$total" "$hits" "$miss" "$scaffold"
printf 'Reason coverage:          %d / %d  (%s) — the rest cannot be re-reviewed\n' "$reasoned" "$total" "$(pct "$reasoned" "$total")"
printf '\n'
printf 'Raw hit-rate (used):      %s   (%d/%d)   <- counts "used after fixing" as success\n' "$(pct "$hits" "$total")" "$hits" "$total"
printf 'Clean-as-is rate:         %s   (%d/%d classified)   <- used verbatim, no edit\n' "$(pct "$clean_hit" "$classified")" "$clean_hit" "$classified"
printf '\n'
printf 'Re-reviewed verdicts (%d classified of %d reasoned):\n' "$classified" "$reasoned"
printf '  clean hit (used as-is):       %4d  (%s)\n' "$clean_hit" "$(pct "$clean_hit" "$classified")"
printf '  fixed hit (used, then edited):%4d  (%s)\n' "$fixed_hit" "$(pct "$fixed_hit" "$classified")"
(( classify == 0 )) && printf '  ambiguous hit (keyword unsure):%4d (%s)\n' "$ambiguous" "$(pct "$ambiguous" "$classified")"
printf '  miss (rewritten / discarded): %4d  (%s)\n' "$miss_classified" "$(pct "$miss_classified" "$classified")"
printf 'Indeterminate (no reason):      %4d\n' "$unreasoned"
printf '\n'
if (( classify )); then
  printf 'Failure modes in the %d problem cases (fixed-hits + misses):\n' "$problems"
  printf '  faithfulness  %4d  (%s)   <- hallucination / factual error; structural checks cannot catch this\n' "$faith" "$(pct "$faith" "$problems")"
  printf '  padding       %4d  (%s)\n' "$padding" "$(pct "$padding" "$problems")"
  printf '  structural    %4d  (%s)\n' "$structural" "$(pct "$structural" "$problems")"
  printf '  style         %4d  (%s)\n' "$style" "$(pct "$style" "$problems")"
  printf '  operational   %4d  (%s)\n' "$operational" "$(pct "$operational" "$problems")"
  printf '  other         %4d  (%s)\n' "$other_mode" "$(pct "$other_mode" "$problems")"
  (( classified < reasoned )) && printf 'NOTE: %d reasoned rows were not classified (model parse gaps) — counted as indeterminate.\n' "$(( reasoned - classified ))"
fi
printf '\n'
printf 'Caveats: reasons are self-reported, so problem counts are a LOWER bound — a\n'
printf 'flaw never noticed never became a reason. %d verdicts carry no reason and are\n' "$unreasoned"
printf 'indeterminate; clean-as-is is denominated on CLASSIFIED rows, so it does not\n'
printf 'silently fall as reason coverage falls (coverage differs sharply between the\n'
printf 'tiers, so a cross-tier read of a total-denominated rate would mislead).\n'
if [[ "$tier" == "agent" ]]; then
printf 'This tier is the producing agent grading its own output, which skews toward\n'
printf '"I used it, so it was good" (ADR 0015, 2026-06-18 update).\n'
fi
printf 'Default mode is a keyword heuristic; run --classify for the accurate\n'
printf 'on-device breakdown (see ADR 0016).\n'

# --- optional per-recipe breakdown -----------------------------------------
if (( by_recipe )); then
  printf '\nVerdict mix by recipe (reasoned verdicts only):\n'
  recipe_index=$(jq -s 'map(select((.source//"delegate")=="delegate" and .recipe!=null) | {(.ts): .recipe}) | add // {}' "$metrics_file")
  jq -rs --argjson rec "$recipe_index" '
    map(select((.reason//"")!="") | . + {recipe: ($rec[.ref_ts] // "(none)")})
    | map(select(.recipe != "(none)"))
    | group_by(.recipe)[]
    | {recipe: .[0].recipe, n: length,
       hit:  (map(select(.kept)) | length),
       miss: (map(select(.kept|not)) | length)}
    | "  \(.recipe): n=\(.n) hit=\(.hit) miss=\(.miss)"
  ' "$feedback" | sort
fi

exit 0
