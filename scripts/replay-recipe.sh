#!/usr/bin/env bash
# replay-recipe.sh — the offline half of the replay gate (ADR 0031 as amended
# 2026-09-19; the procedure is docs/self-improvement-loop.md). Re-renders a
# recipe's stored cases under the champion template (the one that is live)
# and a candidate (the edit), sends both through delegate.sh itself so the
# checks, the retry and the envelope are production's, scores each output
# against what the caller supplied and what actually shipped, and reports
# per-case wins, losses and ties with a one-sided sign test. Greedy decoding
# is deterministic on this backend (ADR 0018, ADR 0031), so one pass per arm
# is the measurement, and a case whose two outputs differ is a decision
# rather than a sample: the online read needs ~134 verdicts per arm to see a
# fifteen-point lift, the paired read reaches p < 0.05 at six wins to none.
#
# A case is a recipe delegation with its structured inputs stored
# (`inputs_file`), a verdict, and a reference for the shipped text: the
# `final_file` a rejection stored, or the draft itself when the verdict was
# kept. Kept cases are the regression guard — a candidate that changes an
# output the agent shipped unedited has to answer for it.
#
# Usage:
#   replay-recipe.sh --recipe NAME [--candidate DIR] [--champion DIR]
#                    [--limit N] [--seed FILE] [--out DIR]
#
#   --recipe NAME     recipe to replay (required)
#   --candidate DIR   prompts directory holding the edited NAME.md; without
#                     one the champion alone is scored (a baseline read)
#   --champion DIR    the live prompts directory (default DELEGATE_PROMPTS_DIR,
#                     else this checkout's prompts/)
#   --limit N         newest N cases (default 40)
#   --seed FILE       JSON array of extra cases {id, ts, recipe, stdin, vars,
#                     draft, final, verdict}; one without a final is skipped,
#                     one whose id the corpus already has is skipped
#   --out DIR         per-arm output cache (default <data dir>/replay); an
#                     output is keyed by case and template hash, so a second
#                     run against the same candidate sends nothing
# Env:
#   DELEGATE_METRICS_FILE, DELEGATE_LOCAL_DATA_DIR   as every other script
#   DELEGATE_REPLAY_DELEGATE_SH   the wrapper to run (tests inject a stub)
# Exit: 0 report printed (the last line is the verdict); 3 no replayable case
#       for the recipe; 2 usage or dependency error; 4 every case errored.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
data_dir="${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}"
metrics_file="${DELEGATE_METRICS_FILE:-$data_dir/metrics.jsonl}"
delegate_sh="${DELEGATE_REPLAY_DELEGATE_SH:-$script_dir/delegate.sh}"
champion="${DELEGATE_PROMPTS_DIR:-$script_dir/../prompts}"
candidate=""
recipe=""
limit=40
seed=""
out_dir="$data_dir/replay"

while (($# > 0)); do
  case "$1" in
    --recipe) recipe="${2:?--recipe requires a name}"; shift 2;;
    --recipe=*) recipe="${1#--recipe=}"; shift;;
    --candidate) candidate="${2:?--candidate requires a directory}"; shift 2;;
    --candidate=*) candidate="${1#--candidate=}"; shift;;
    --champion) champion="${2:?--champion requires a directory}"; shift 2;;
    --champion=*) champion="${1#--champion=}"; shift;;
    --limit) limit="${2:?--limit requires a number}"; shift 2;;
    --limit=*) limit="${1#--limit=}"; shift;;
    --seed) seed="${2:?--seed requires a path}"; shift 2;;
    --seed=*) seed="${1#--seed=}"; shift;;
    --out) out_dir="${2:?--out requires a directory}"; shift 2;;
    --out=*) out_dir="${1#--out=}"; shift;;
    -h|--help)
      sed -n '/^# Usage:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2;;
    *) echo "replay-recipe: unknown argument '$1'" >&2; exit 2;;
  esac
done

command -v jq >/dev/null || { echo "replay-recipe: jq not on PATH" >&2; exit 2; }
command -v shasum >/dev/null || { echo "replay-recipe: shasum not on PATH" >&2; exit 2; }
[[ -n "$recipe" ]] || { echo "replay-recipe: --recipe is required" >&2; exit 2; }
case "$limit" in ''|*[!0-9]*|0) echo "replay-recipe: --limit must be a positive number" >&2; exit 2;; esac
[[ -f "$champion/$recipe.md" ]] || { echo "replay-recipe: no $recipe.md in champion dir $champion" >&2; exit 2; }
if [[ -n "$candidate" && ! -f "$candidate/$recipe.md" ]]; then
  echo "replay-recipe: no $recipe.md in candidate dir $candidate" >&2; exit 2
fi
[[ -n "$seed" && ! -f "$seed" ]] && { echo "replay-recipe: seed file not found: $seed" >&2; exit 2; }
[[ -f "$metrics_file" ]] || [[ -n "$seed" ]] || { echo "replay-recipe: metrics file not found: $metrics_file" >&2; exit 2; }

# shellcheck source=lib/pair-score.sh
. "$script_dir/lib/pair-score.sh"

drafts_dir="$(dirname "$metrics_file")/drafts"
mkdir -p "$out_dir" || { echo "replay-recipe: cannot create $out_dir" >&2; exit 2; }
chmod 700 "$out_dir" 2>/dev/null || true

template_hash() { shasum -a 256 "$1" | cut -c1-12; }
champion_sha=$(template_hash "$champion/$recipe.md")
candidate_sha=""
[[ -n "$candidate" ]] && candidate_sha=$(template_hash "$candidate/$recipe.md")

# ---------------------------------------------------------------------------
# Cases. One record per line, `|`-separated (no field can carry one):
#   id|ts|verdict|draft path|final path|inputs path|template sha|checks_failed
# Corpus first, newest first; then seed cases whose id is not already there.
# ---------------------------------------------------------------------------
cases_tmp=$(mktemp)
trap 'rm -f "$cases_tmp"' EXIT

if [[ -f "$metrics_file" ]]; then
  # `$d` is parent_join's delegate index; the drafts dir gets its own name.
  jq -rs --arg recipe "$recipe" --arg ddir "$drafts_dir" '
    '"$parent_join"'
    latest_verdicts
    | map(select(parent != null
                 and (parent.recipe // "") == $recipe
                 and (parent.inputs_file // "") != ""
                 and (parent.exit_status // 0) == 0))
    | map(parent as $p
          | {id: ($p.otel_span_id // $p.ts), ts: $p.ts,
             verdict: (if .kept then "kept" elif .scaffold then "scaffold" else "rewrote" end),
             draft: ($p.draft_file // ""),
             final: (if .kept then ($p.draft_file // "") else (.final_file // "") end),
             inputs: $p.inputs_file, sha: ($p.template_sha // ""),
             checks: ($p.checks_failed // 0)})
    | map(select(.final != "" and .draft != ""))
    | sort_by(.ts) | reverse
    | .[]
    | [.id, .ts, .verdict, ($ddir + "/" + .draft), ($ddir + "/" + .final), ($ddir + "/" + .inputs), .sha, (.checks | tostring)]
    | join("|")
  ' "$metrics_file" 2>/dev/null > "$cases_tmp"
fi

if [[ -n "$seed" ]]; then
  seed_dir="$out_dir/seed"
  mkdir -p "$seed_dir"
  jq -r --arg recipe "$recipe" '
    .[] | select(.recipe == $recipe and (.final // "") != "" and (.draft // "") != "")
    | [.id, (.ts // "1970-01-01T00:00:00Z"), (.verdict // "rewrote")] | join("|")
  ' "$seed" 2>/dev/null | while IFS='|' read -r sid sts sverdict; do
    [[ -n "$sid" ]] || continue
    grep -q "^$sid|" "$cases_tmp" && continue
    jq -c --arg id "$sid" '.[] | select(.id == $id) | {recipe, stdin, vars: (.vars // {})}' "$seed" > "$seed_dir/$sid.inputs.json"
    jq -j --arg id "$sid" '.[] | select(.id == $id) | .draft' "$seed" > "$seed_dir/$sid.draft.txt"
    jq -j --arg id "$sid" '.[] | select(.id == $id) | .final' "$seed" > "$seed_dir/$sid.final.txt"
    case "$sverdict" in kept|scaffold|rewrote) ;; hit) sverdict=kept;; miss) sverdict=rewrote;; *) sverdict=rewrote;; esac
    printf '%s|%s|%s|%s|%s|%s||0\n' "$sid" "$sts" "$sverdict" \
      "$seed_dir/$sid.draft.txt" "$seed_dir/$sid.final.txt" "$seed_dir/$sid.inputs.json" >> "$cases_tmp"
  done
  # Newest first across both sources; the limit takes the newest.
  sort -t'|' -k2,2r "$cases_tmp" -o "$cases_tmp"
fi

# A case whose files were pruned (retention) cannot be replayed.
usable_tmp=$(mktemp)
while IFS='|' read -r id ts verdict draft final inputs sha checks; do
  [[ -f "$draft" && -f "$final" && -f "$inputs" ]] || continue
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$id" "$ts" "$verdict" "$draft" "$final" "$inputs" "$sha" "$checks"
done < "$cases_tmp" | head -n "$limit" > "$usable_tmp"
mv "$usable_tmp" "$cases_tmp"

n_cases=$(grep -c '' "$cases_tmp")
if (( n_cases == 0 )); then
  echo "replay-recipe: no replayable case for '$recipe' (a case needs inputs_file, a verdict and a stored final, or a --seed)" >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# One output per case and arm, cached by template hash.
# ---------------------------------------------------------------------------

# run_wrapper <prompts dir> <inputs.json> <out file> <err file>: the same
# call the original delegation made, under another template. Metrics, the
# canary and the nudge are off: a replay is a measurement, not a delegation.
run_wrapper() {
  local dir="$1" inputs="$2" out="$3" err="$4" k v prompt
  local args=()
  while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    v=$(jq -r --arg k "$k" '.vars[$k]' "$inputs")
    args+=(--var "$k=$v")
  done < <(jq -r '.vars // {} | keys[]' "$inputs")
  prompt=$(jq -r '.prompt // ""' "$inputs")
  jq -j '.stdin' "$inputs" \
    | env DELEGATE_PROMPTS_DIR="$dir" DELEGATE_LOCAL_NO_METRICS=1 DELEGATE_NO_PREFLIGHT=1 \
          DELEGATE_LOCAL_NO_VERDICT_NUDGE=1 \
          bash "$delegate_sh" --recipe "$recipe" ${args[@]+"${args[@]}"} ${prompt:+"$prompt"} \
      > "$out" 2> "$err"
}

# arm_output <dir> <sha> <case fields...>: prints "<out file>|<checks_failed>"
# or "ERR". The champion's output for a case produced under the same
# template is the stored draft itself, checks from the row: no call.
arm_output() {
  local dir="$1" sha="$2" id="$3" draft="$4" inputs="$5" row_sha="$6" row_checks="$7"
  local out="$out_dir/$id.$sha.out.txt" checks_f="$out_dir/$id.$sha.checks" err
  if [[ ! -f "$out" ]]; then
    if [[ -n "$row_sha" && "$row_sha" == "$sha" ]]; then
      cp "$draft" "$out" && printf '%s' "$row_checks" > "$checks_f"
    else
      err="$out_dir/$id.$sha.err.txt"
      echo "replay-recipe: $id under $sha ..." >&2
      if run_wrapper "$dir" "$inputs" "$out" "$err"; then
        grep -o 'checks_failed=[0-9]*' "$err" | head -1 | cut -d= -f2 > "$checks_f"
        rm -f "$err"
      else
        rm -f "$out"
        echo "ERR"
        return 0
      fi
    fi
  fi
  local c
  c=$(cat "$checks_f" 2>/dev/null)
  printf '%s|%s' "$out" "${c:-0}"
}

# score <inputs.json> <final> <output> <checks>: prints "c/d/e/s=total" where
# c is failed checks, d the supplied anchors the shipped text carried and
# this output dropped, e the piped sentences this output handed back, s a
# list-vs-prose mismatch against the shipped text. The same salient tokens
# and sentence unit as the bundle's DROPPED and ECHOED.
score() {
  local inputs="$1" final="$2" out="$3" checks="$4"
  local supplied stdin dropped echoed shape om fm
  supplied=$(mktemp); stdin=$(mktemp)
  jq -j '.stdin' "$inputs" > "$stdin"
  { cat "$stdin"; echo; jq -r '(.vars // {} | .[]), (.prompt // "")' "$inputs"; } > "$supplied"
  dropped=$(comm -12 <(salient "$supplied") <(salient "$final") | comm -23 - <(salient "$out") | grep -c '')
  echoed=$(sentences < "$stdin" | grep -Fxf - <(sentences < "$out") | sort -u | grep -c '')
  om=$(list_markers "$out"); fm=$(list_markers "$final")
  shape=0
  if { (( om > 0 )) && (( fm == 0 )); } || { (( fm > 0 )) && (( om == 0 )); }; then shape=1; fi
  rm -f "$supplied" "$stdin"
  printf '%s/%s/%s/%s=%s' "$checks" "$dropped" "$echoed" "$shape" "$(( checks + dropped + echoed + shape ))"
}

# sign_p <wins> <losses>: one-sided exact sign test, P(X >= wins | n, 1/2).
sign_p() {
  perl -e 'my ($w,$l)=@ARGV; my $n=$w+$l; my $p=0;
           for my $k ($w..$n) { my $c=1; for my $i (1..$k) { $c *= ($n-$i+1)/$i } $p += $c }
           printf "%.3f", $p / (2**$n)' "$1" "$2"
}

echo "=== replay: $recipe ==="
echo "Champion:  $champion (template=$champion_sha)"
if [[ -n "$candidate" ]]; then
  echo "Candidate: $candidate (template=$candidate_sha)"
  if [[ "$candidate_sha" == "$champion_sha" ]]; then
    echo "Verdict: INCONCLUSIVE — the candidate template is byte-identical to the champion."
    exit 0
  fi
fi
kept_n=$(grep -c '|kept|' "$cases_tmp"); scaffold_n=$(grep -c '|scaffold|' "$cases_tmp"); rewrote_n=$(grep -c '|rewrote|' "$cases_tmp")
echo "Cases:     $n_cases (kept=$kept_n scaffold=$scaffold_n rewrote=$rewrote_n; newest $limit)"
echo

wins=0; losses=0; ties=0; errors=0
champ_checks=0; cand_checks=0
newest_n=$(( (n_cases + 2) / 3 ))
newest_wins=0; newest_losses=0
i=0
if [[ -n "$candidate" ]]; then
  printf '  %-10s %-20s %-8s %-14s %-14s %s\n' case ts verdict champion candidate result
else
  printf '  %-10s %-20s %-8s %-14s\n' case ts verdict champion
fi
while IFS='|' read -r id ts verdict draft final inputs sha checks; do
  i=$((i + 1))
  a=$(arm_output "$champion" "$champion_sha" "$id" "$draft" "$inputs" "$sha" "$checks")
  if [[ "$a" == "ERR" ]]; then
    errors=$((errors + 1)); printf '  %-10s %-20s %-8s %s\n' "${id:0:10}" "$ts" "$verdict" "ERR (champion)"; continue
  fi
  a_out="${a%|*}"; a_checks="${a##*|}"
  a_score=$(score "$inputs" "$final" "$a_out" "$a_checks")
  champ_checks=$((champ_checks + a_checks))
  if [[ -z "$candidate" ]]; then
    printf '  %-10s %-20s %-8s %-14s\n' "${id:0:10}" "$ts" "$verdict" "$a_score"
    continue
  fi
  b=$(arm_output "$candidate" "$candidate_sha" "$id" "$draft" "$inputs" "$sha" "$checks")
  if [[ "$b" == "ERR" ]]; then
    errors=$((errors + 1)); printf '  %-10s %-20s %-8s %-14s %s\n' "${id:0:10}" "$ts" "$verdict" "$a_score" "ERR (candidate)"; continue
  fi
  b_out="${b%|*}"; b_checks="${b##*|}"
  b_score=$(score "$inputs" "$final" "$b_out" "$b_checks")
  cand_checks=$((cand_checks + b_checks))
  a_total="${a_score##*=}"; b_total="${b_score##*=}"
  if (( b_total < a_total )); then
    result=WIN; wins=$((wins + 1)); (( i <= newest_n )) && newest_wins=$((newest_wins + 1))
  elif (( b_total > a_total )); then
    result=LOSS; losses=$((losses + 1)); (( i <= newest_n )) && newest_losses=$((newest_losses + 1))
  else
    result=tie; ties=$((ties + 1))
  fi
  printf '  %-10s %-20s %-8s %-14s %-14s %s\n' "${id:0:10}" "$ts" "$verdict" "$a_score" "$b_score" "$result"
done < "$cases_tmp"
echo
echo "Scores are checks/dropped/echoed/shape=total; lower is better."

if (( errors == n_cases )); then
  echo "Verdict: ERROR — every case failed to run; see $out_dir/*.err.txt"
  exit 4
fi
if [[ -z "$candidate" ]]; then
  echo "Summary: n=$n_cases  checks failed under the champion=$champ_checks  errors=$errors"
  echo "Verdict: BASELINE — pass --candidate DIR to compare an edit."
  exit 0
fi

echo "Summary: n=$n_cases  wins=$wins  losses=$losses  ties=$ties  errors=$errors"
echo "Checks failed: champion=$champ_checks  candidate=$cand_checks"
echo "Newest third ($newest_n cases): wins=$newest_wins  losses=$newest_losses"
if (( wins > losses )); then
  p=$(sign_p "$wins" "$losses")
  echo "Sign test: p=$p (one-sided, $wins wins to $losses)"
  if awk -v p="$p" 'BEGIN { exit !(p < 0.05) }' && (( cand_checks <= champ_checks )); then
    echo "Verdict: ACCEPT — the candidate wins $wins cases and loses $losses (p=$p) with no rise in failed checks."
  elif (( cand_checks > champ_checks )); then
    echo "Verdict: INCONCLUSIVE — more wins than losses, but failed checks rose from $champ_checks to $cand_checks."
  else
    echo "Verdict: INCONCLUSIVE — $wins wins to $losses is not yet significant (p=$p); wait for more cases or a wider edit."
  fi
elif (( losses > wins )); then
  p=$(sign_p "$losses" "$wins")
  echo "Sign test: p=$p (one-sided, $losses losses to $wins)"
  if awk -v p="$p" 'BEGIN { exit !(p < 0.05) }'; then
    echo "Verdict: REJECT — the candidate loses $losses cases and wins $wins (p=$p)."
  else
    echo "Verdict: INCONCLUSIVE — $losses losses to $wins wins is not yet significant (p=$p)."
  fi
else
  echo "Verdict: INCONCLUSIVE — $wins wins to $losses losses; the edit did not separate the arms."
fi
exit 0
