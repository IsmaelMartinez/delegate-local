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
# output the agent shipped unedited has to answer for it, so every token the
# output carries that the reference and the inputs do not counts against it.
#
# Usage:
#   replay-recipe.sh --recipe NAME [--candidate DIR] [--champion DIR]
#                    [--limit N] [--seed FILE] [--out DIR]
#
#   --recipe NAME     recipe to replay (required)
#   --candidate DIR   prompts directory holding the edited NAME.md; without
#                     one the champion alone is scored (a baseline read)
#   --champion DIR    the live prompts directory. Default: the recipe as
#                     committed on `main` (DELEGATE_REPLAY_BASE overrides the
#                     ref), materialised in a temp dir, so an edit made on a
#                     branch in this same checkout is compared against what is
#                     live rather than against itself; when git cannot show it,
#                     DELEGATE_PROMPTS_DIR, else this checkout's prompts/
#   --limit N         newest N cases (default 40)
#   --seed FILE       JSON array of extra cases {id, ts, recipe, tier, stdin,
#                     vars, draft, final, verdict, model}; one without a final
#                     is skipped, one whose id the corpus already has is
#                     skipped, ids are [A-Za-z0-9_-]+
#   --out DIR         per-arm output cache (default <data dir>/replay); an
#                     output is keyed by case, template hash and model, so a
#                     second run against the same candidate sends nothing.
#                     Written under umask 077 and pruned on the same
#                     DELEGATE_DRAFT_RETENTION_DAYS as the drafts.
# Env:
#   DELEGATE_METRICS_FILE, DELEGATE_LOCAL_DATA_DIR   as every other script
#   DELEGATE_REPLAY_DELEGATE_SH   the wrapper to run (tests inject a stub)
#   DELEGATE_REPLAY_MODEL         the model the arms run on, when known; else
#                                 pick-model.sh resolves the recipe's tier once
# Exit: 0 report printed (the last line is the verdict); 3 no replayable case
#       for the recipe; 2 usage or dependency error; 4 every case errored.
set -uo pipefail
umask 077

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$script_dir/.."
data_dir="${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}"
metrics_file="${DELEGATE_METRICS_FILE:-$data_dir/metrics.jsonl}"
delegate_sh="${DELEGATE_REPLAY_DELEGATE_SH:-$script_dir/delegate.sh}"
champion=""
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
case "$recipe" in *[!A-Za-z0-9_-]*) echo "replay-recipe: recipe names are [A-Za-z0-9_-]+" >&2; exit 2;; esac

work_tmp=$(mktemp -d)
trap 'rm -rf "$work_tmp"' EXIT

# shellcheck source=lib/pair-score.sh
. "$script_dir/lib/pair-score.sh"
# shellcheck source=lib/recipe.sh
. "$script_dir/lib/recipe.sh"

# The champion is what is live, which on this machine is the committed
# recipe on main, not the working file: the procedure edits the recipe on a
# branch in this checkout, and a champion read from the same checkout would
# be the candidate.
champion_label=""
if [[ -z "$champion" ]]; then
  base="${DELEGATE_REPLAY_BASE:-main}"
  if git -C "$repo_root" show "$base:prompts/$recipe.md" > "$work_tmp/champion.md" 2>/dev/null \
     && [[ -s "$work_tmp/champion.md" ]]; then
    mkdir -p "$work_tmp/champion"
    mv "$work_tmp/champion.md" "$work_tmp/champion/$recipe.md"
    champion="$work_tmp/champion"
    champion_label="$base:prompts/$recipe.md"
  else
    champion="${DELEGATE_PROMPTS_DIR:-$repo_root/prompts}"
  fi
fi
[[ -n "$champion_label" ]] || champion_label="$champion"
[[ -f "$champion/$recipe.md" ]] || { echo "replay-recipe: no $recipe.md in champion dir $champion" >&2; exit 2; }
if [[ -n "$candidate" && ! -f "$candidate/$recipe.md" ]]; then
  echo "replay-recipe: no $recipe.md in candidate dir $candidate" >&2; exit 2
fi
[[ -n "$seed" && ! -f "$seed" ]] && { echo "replay-recipe: seed file not found: $seed" >&2; exit 2; }
[[ -f "$metrics_file" ]] || [[ -n "$seed" ]] || { echo "replay-recipe: metrics file not found: $metrics_file" >&2; exit 2; }

drafts_dir="$(dirname "$metrics_file")/drafts"
mkdir -p "$out_dir" || { echo "replay-recipe: cannot create $out_dir" >&2; exit 2; }
chmod 700 "$out_dir" 2>/dev/null || true
# The cache holds model output derived from the piped context and, with
# --seed, verbatim copies of it: the drafts' retention applies.
keep="${DELEGATE_DRAFT_RETENTION_DAYS:-14}"
if [[ "$keep" =~ ^[0-9]+$ ]] && (( 10#$keep > 0 )); then
  find "$out_dir" -type f -mtime "+$keep" -exec rm -f {} + 2>/dev/null || true
fi

champion_sha=$(recipe_template_sha "$champion/$recipe.md")
candidate_sha=""
[[ -n "$candidate" ]] && candidate_sha=$(recipe_template_sha "$candidate/$recipe.md")

# The model both arms run on. A stored draft stands in for the champion's
# output only when the same model produced it, and the cache is keyed on it,
# so a routing change between the delegation and the replay is not read as
# a template effect. Resolved once from the recipe's tier; unknown when no
# provider answers, in which case the shortcut and the cache are model-blind
# and the report says so.
model="${DELEGATE_REPLAY_MODEL:-}"
if [[ -z "$model" && -x "$script_dir/pick-model.sh" ]]; then
  tier=$(recipe_tier "$champion/$recipe.md")
  [[ -n "$tier" ]] && model=$(bash "$script_dir/pick-model.sh" "$tier" 2>/dev/null | head -n 1)
fi
if [[ -n "$model" ]]; then
  model_slug=$(printf '%s' "$model" | tr -c 'A-Za-z0-9.-' '_')
else
  model_slug="unknown-model"
fi

# ---------------------------------------------------------------------------
# Cases. One record per line, `|`-separated (no field can carry one):
#   id|ts|verdict|draft path|final path|inputs path|template sha|checks_failed|model
# Corpus first, newest first; then seed cases whose id is not already there.
# ---------------------------------------------------------------------------
cases_tmp="$work_tmp/cases"
: > "$cases_tmp"

if [[ -f "$metrics_file" ]]; then
  # `$d` is parent_join's delegate index; the drafts dir gets its own name.
  # Only verdicts pinned by ref_id: a ts-only verdict on a second two
  # delegations share would pair the other one's inputs and final with this
  # case, and a replay decides on cases, so it takes none it cannot be sure
  # of.
  jq -rs --arg recipe "$recipe" --arg ddir "$drafts_dir" '
    '"$parent_join"'
    latest_verdicts
    | map(select((.ref_id // "") != ""
                 and parent != null
                 and (parent.recipe // "") == $recipe
                 and (parent.inputs_file // "") != ""
                 and (parent.exit_status // 0) == 0))
    | map(parent as $p
          | {id: ($p.otel_span_id // $p.ts), ts: $p.ts,
             verdict: (if .kept then "kept" elif .scaffold then "scaffold" else "rewrote" end),
             draft: ($p.draft_file // ""),
             final: (if .kept then ($p.draft_file // "") else (.final_file // "") end),
             inputs: $p.inputs_file, sha: ($p.template_sha // ""),
             checks: ($p.checks_failed // 0), model: ($p.model // "")})
    | map(select(.final != "" and .draft != ""))
    | sort_by(.ts) | reverse
    | .[]
    | [.id, .ts, .verdict, ($ddir + "/" + .draft), ($ddir + "/" + .final), ($ddir + "/" + .inputs), .sha, (.checks | tostring), .model]
    | join("|")
  ' "$metrics_file" 2>/dev/null > "$cases_tmp"
fi

if [[ -n "$seed" ]]; then
  seed_dir="$out_dir/seed"
  mkdir -p "$seed_dir"
  jq -r --arg recipe "$recipe" '
    .[] | select(.recipe == $recipe and (.final // "") != "" and (.draft // "") != "")
    | [.id, (.ts // "1970-01-01T00:00:00Z"), (.verdict // "rewrote"), (.model // "")] | join("|")
  ' "$seed" 2>/dev/null | while IFS='|' read -r sid sts sverdict smodel; do
    [[ -n "$sid" ]] || continue
    # The id names files and is matched literally: no metacharacters, no
    # path separators.
    case "$sid" in *[!A-Za-z0-9_-]*)
      echo "replay-recipe: seed id '$sid' skipped (ids are [A-Za-z0-9_-]+)" >&2; continue;; esac
    cut -d'|' -f1 "$cases_tmp" | grep -Fxq -- "$sid" && continue
    jq -c --arg id "$sid" '.[] | select(.id == $id) | {recipe, stdin: (.stdin // ""), vars: (.vars // {})} + (if (.tier // "") != "" then {tier} else {} end)' "$seed" > "$seed_dir/$sid.inputs.json"
    jq -j --arg id "$sid" '.[] | select(.id == $id) | .draft' "$seed" > "$seed_dir/$sid.draft.txt"
    jq -j --arg id "$sid" '.[] | select(.id == $id) | .final' "$seed" > "$seed_dir/$sid.final.txt"
    case "$sverdict" in kept|scaffold|rewrote) ;; hit) sverdict=kept;; miss) sverdict=rewrote;; *) sverdict=rewrote;; esac
    printf '%s|%s|%s|%s|%s|%s||0|%s\n' "$sid" "$sts" "$sverdict" \
      "$seed_dir/$sid.draft.txt" "$seed_dir/$sid.final.txt" "$seed_dir/$sid.inputs.json" "$smodel" >> "$cases_tmp"
  done
  # Newest first across both sources; the limit takes the newest.
  sort -t'|' -k2,2r "$cases_tmp" -o "$cases_tmp"
fi

# A case whose files were pruned (retention) cannot be replayed, nor one
# whose inputs are not valid JSON (an over-cap capture is not written, but a
# hand-made seed can be anything).
usable_tmp="$work_tmp/usable"
while IFS='|' read -r id ts verdict draft final inputs sha checks rmodel; do
  [[ -f "$draft" && -f "$final" && -f "$inputs" ]] || continue
  jq -e . "$inputs" >/dev/null 2>&1 || { echo "replay-recipe: $id skipped: $inputs is not valid JSON" >&2; continue; }
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$id" "$ts" "$verdict" "$draft" "$final" "$inputs" "$sha" "$checks" "$rmodel"
done < "$cases_tmp" | head -n "$limit" > "$usable_tmp"
mv "$usable_tmp" "$cases_tmp"

n_cases=$(grep -c '' "$cases_tmp")
if (( n_cases == 0 )); then
  echo "replay-recipe: no replayable case for '$recipe' (a case needs inputs_file, a verdict and a stored final, or a --seed)" >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# One output per case and arm, cached by template hash and model.
# ---------------------------------------------------------------------------

# read_exact <file> — the file's bytes into stdout-free variable form: $(cat)
# would strip a trailing newline, which a heredoc-built --var carries.
read_exact() { local v; v=$(cat "$1"; printf x); printf '%s' "${v%x}"; }

# run_wrapper <prompts dir> <inputs.json> <out file> <err file>: the same
# call the original delegation made, under another template, on the tier it
# was made on. Metrics, the canary and the nudge are off: a replay is a
# measurement, not a delegation.
run_wrapper() {
  local dir="$1" inputs="$2" out="$3" err="$4" k tier prompt
  local args=()
  while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    jq -j --arg k "$k" '.vars[$k] | if type == "string" then . else tojson end' "$inputs" > "$work_tmp/var"
    args+=(--var "$k=$(read_exact "$work_tmp/var")")
  done < <(jq -r '.vars // {} | keys[]' "$inputs")
  tier=$(jq -r '.tier // ""' "$inputs")
  [[ -n "$tier" ]] && args+=(--tier "$tier")
  jq -j '.prompt // ""' "$inputs" > "$work_tmp/prompt"
  prompt=$(read_exact "$work_tmp/prompt")
  jq -j '.stdin // ""' "$inputs" \
    | env DELEGATE_PROMPTS_DIR="$dir" DELEGATE_LOCAL_NO_METRICS=1 DELEGATE_NO_PREFLIGHT=1 \
          DELEGATE_LOCAL_NO_VERDICT_NUDGE=1 \
          bash "$delegate_sh" --recipe "$recipe" ${args[@]+"${args[@]}"} ${prompt:+"$prompt"} \
      > "$out" 2> "$err"
}

# arm_output <dir> <sha> <id> <draft> <inputs> <row sha> <row checks> <row model>:
# prints "<out file>|<checks_failed>" or "ERR". The champion's output for a
# case produced under the same template by the same model is the stored
# draft itself, checks from the row: no call — unless the draft was cut at
# the byte cap, which a fresh output never is. The output is written to a
# temp name and moved into place after its checks sidecar, so an interrupted
# run leaves nothing a later run mistakes for a result.
arm_output() {
  local dir="$1" sha="$2" id="$3" draft="$4" inputs="$5" row_sha="$6" row_checks="$7" row_model="$8"
  local stem="$out_dir/$id.$sha.$model_slug" out checks_f err
  out="$stem.out.txt"; checks_f="$stem.checks"
  [[ -f "$out" && ! -f "$checks_f" ]] && rm -f "$out"
  if [[ ! -f "$out" ]]; then
    if [[ -n "$row_sha" && "$row_sha" == "$sha" ]] \
       && { [[ -z "$model" ]] || [[ "$row_model" == "$model" ]]; } \
       && ! grep -qF '[truncated at ' "$draft"; then
      if ! { cp "$draft" "$out.tmp" && printf '%s' "$row_checks" > "$checks_f" && mv "$out.tmp" "$out"; }; then
        rm -f "$out.tmp" "$checks_f"
        echo "ERR"
        return 0
      fi
    else
      err="$stem.err.txt"
      echo "replay-recipe: $id under $sha ..." >&2
      if run_wrapper "$dir" "$inputs" "$out.tmp" "$err"; then
        grep -o 'checks_failed=[0-9]*' "$err" | head -1 | cut -d= -f2 > "$checks_f"
        mv "$out.tmp" "$out"
        rm -f "$err"
      else
        rm -f "$out.tmp" "$checks_f"
        echo "ERR"
        return 0
      fi
    fi
  fi
  local c
  c=$(cat "$checks_f" 2>/dev/null)
  printf '%s|%s' "$out" "${c:-0}"
}

# The reference sets of one case, computed once for both arms:
#   sup_sal    salient tokens the caller supplied (stdin, vars, prompt)
#   fin_sal    salient tokens the shipped text carries
#   stdin_sent piped sentences (the unit no_context_echo measures)
#   fin_echo   the piped sentences the shipped text itself reproduces
#   fin_markers whether the shipped text is a list
case_refs() { # <inputs.json> <final>
  jq -j '.stdin // ""' "$1" > "$work_tmp/stdin"
  { cat "$work_tmp/stdin"; echo; jq -r '(.vars // {} | .[] | if type == "string" then . else tojson end), (.prompt // "")' "$1"; } > "$work_tmp/supplied"
  salient "$work_tmp/supplied" > "$work_tmp/sup_sal"
  salient "$2" > "$work_tmp/fin_sal"
  sentences < "$work_tmp/stdin" | sort -u > "$work_tmp/stdin_sent"
  sentences < "$2" | sort -u | comm -12 "$work_tmp/stdin_sent" - > "$work_tmp/fin_echo"
  fin_markers=$(list_markers "$2")
}

# score <output> <checks>: prints "c/d/i/e/s=total" where c is failed
# checks, d the supplied anchors the shipped text carried and this output
# dropped, i the anchors this output carries that neither the inputs nor the
# shipped text do (the bundle's INVENTED), e the piped sentences this output
# hands back beyond the ones the shipped text itself carries, s a
# list-vs-prose mismatch against the shipped text. Symmetric on a kept case:
# any anchor the output has over or under its reference counts.
score() {
  local out="$1" checks="$2" dropped invented echoed shape om
  salient "$out" > "$work_tmp/out_sal"
  dropped=$(comm -12 "$work_tmp/sup_sal" "$work_tmp/fin_sal" | comm -23 - "$work_tmp/out_sal" | grep -c '')
  invented=$(comm -23 "$work_tmp/out_sal" "$work_tmp/sup_sal" | comm -23 - "$work_tmp/fin_sal" | grep -c '')
  echoed=$(sentences < "$out" | sort -u | comm -12 "$work_tmp/stdin_sent" - | comm -23 - "$work_tmp/fin_echo" | grep -c '')
  om=$(list_markers "$out")
  shape=0
  if { (( om > 0 )) && (( fin_markers == 0 )); } || { (( fin_markers > 0 )) && (( om == 0 )); }; then shape=1; fi
  printf '%s/%s/%s/%s/%s=%s' "$checks" "$dropped" "$invented" "$echoed" "$shape" "$(( checks + dropped + invented + echoed + shape ))"
}

# sign_p <wins> <losses>: one-sided exact sign test, P(X >= wins | n, 1/2).
sign_p() {
  perl -e 'my ($w,$l)=@ARGV; my $n=$w+$l; my $p=0;
           for my $k ($w..$n) { my $c=1; for my $i (1..$k) { $c *= ($n-$i+1)/$i } $p += $c }
           printf "%.3f", $p / (2**$n)' "$1" "$2"
}

echo "=== replay: $recipe ==="
echo "Champion:  $champion_label (template=$champion_sha)"
if [[ -n "$candidate" ]]; then
  echo "Candidate: $candidate (template=$candidate_sha)"
  if [[ "$candidate_sha" == "$champion_sha" ]]; then
    echo "Verdict: INCONCLUSIVE — the candidate's frontmatter and prompt block are identical to the champion's."
    exit 0
  fi
fi
if [[ -n "$model" ]]; then
  echo "Model:     $model"
else
  echo "Model:     (unresolved — stored drafts stand in for the champion whatever model produced them)"
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
while IFS='|' read -r id ts verdict draft final inputs sha checks rmodel; do
  i=$((i + 1))
  case_refs "$inputs" "$final"
  a=$(arm_output "$champion" "$champion_sha" "$id" "$draft" "$inputs" "$sha" "$checks" "$rmodel")
  if [[ "$a" == "ERR" ]]; then
    errors=$((errors + 1)); printf '  %-10s %-20s %-8s %s\n' "${id:0:10}" "$ts" "$verdict" "ERR (champion)"; continue
  fi
  a_out="${a%|*}"; a_checks="${a##*|}"
  a_score=$(score "$a_out" "$a_checks")
  champ_checks=$((champ_checks + a_checks))
  if [[ -z "$candidate" ]]; then
    printf '  %-10s %-20s %-8s %-14s\n' "${id:0:10}" "$ts" "$verdict" "$a_score"
    continue
  fi
  b=$(arm_output "$candidate" "$candidate_sha" "$id" "$draft" "$inputs" "$sha" "$checks" "$rmodel")
  if [[ "$b" == "ERR" ]]; then
    errors=$((errors + 1)); printf '  %-10s %-20s %-8s %-14s %s\n' "${id:0:10}" "$ts" "$verdict" "$a_score" "ERR (candidate)"; continue
  fi
  b_out="${b%|*}"; b_checks="${b##*|}"
  b_score=$(score "$b_out" "$b_checks")
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
echo "Scores are checks/dropped/invented/echoed/shape=total; lower is better."

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
# A case that did not run is neither a win nor a loss, and a gate that
# accepts on the cases that happened to run would pass a candidate that
# fails on the ones that did not.
if (( errors > 0 )); then
  echo "Verdict: INCONCLUSIVE — $errors case(s) failed to run; fix the errors (see $out_dir/*.err.txt) and run again."
  exit 0
fi
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
