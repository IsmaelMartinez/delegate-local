#!/usr/bin/env bash
# verify-draft.sh — grounding check of a draft against its inputs (#659, epic
# #663): asks decide.sh, on the verify tier's logprobs, whether every claim in
# the draft is stated in or directly implied by the facts, and passes or flags
# p(supported) at a threshold calibrated per model. delegate.sh runs it on a
# recipe call's draft when the recipe sets `verify: true` or DELEGATE_VERIFY=1
# (#661). docs/verify.md has the measurements behind the question and the
# default tier.
#
# Usage:  verify-draft.sh --id <delegation id>
#         verify-draft.sh < {"facts": "...", "draft": "..."}
#         verify-draft.sh --calibrate FILE.jsonl [--dry-run]
#
# --id takes the otel_span_id delegate-meta prints as id="..." and reads that
# row's stored draft and structured inputs; the facts are the piped stdin then
# every --var value in key order, newline-joined (not the rendered prompt, so
# the template's own instructions are not mistaken for facts). Facts are cut
# at 16000 characters, as measured.
#
# Prints one JSON line: {"model","p_supported","threshold","verdict","latency_ms"},
# verdict "pass" when p_supported >= threshold, else "flag".
#
# --calibrate scores every row of FILE.jsonl ({facts, draft, label}, label one
# of supported, contradicted or unsupported; the last two count as not
# supported), prints n, AUROC, the chosen
# threshold, accuracy there and at 0.5, recall per label and p50 latency, and
# records the threshold for the resolved model in <data dir>/verify-thresholds.tsv
# (model<TAB>threshold; --dry-run records nothing). The threshold is the
# observed p that maximises balanced accuracy; on a tie the higher one wins,
# since a missed contradiction ships while a false flag costs one look.
#
# Exit codes:  0 pass (or calibration done), 1 flag, 2 usage or input error,
#              3 verifier unavailable (no model resolves for the verify tier,
#              the decision request failed, or the answer held neither option
#              letter); --calibrate also exits 3, recording nothing, when any
#              row could not be scored or the resolved model changed mid-run.
#
# Env:  DELEGATE_VERIFY_THRESHOLD overrides the recorded threshold (0-1); with
#       neither, 0.5 and a one-line stderr note. DELEGATE_LOCAL_DATA_DIR and
#       DELEGATE_METRICS_FILE locate the thresholds, metrics and drafts.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# recipe_verify_input: the --id facts rule, shared with delegate.sh (#661).
# shellcheck source=lib/recipe.sh
. "$script_dir/lib/recipe.sh"
data_dir="${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}"
metrics_file="${DELEGATE_METRICS_FILE:-$data_dir/metrics.jsonl}"
thresholds_file="$data_dir/verify-thresholds.tsv"

id=""
calibrate=""
dry_run=0
need_value() { [[ -n "${2:-}" ]] || { echo "verify-draft: $1 requires a value" >&2; exit 2; }; }
while (( $# > 0 )); do
  case "$1" in
    --id) need_value "$@"; id="$2"; shift 2 ;;
    --calibrate) need_value "$@"; calibrate="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "verify-draft: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
if [[ -n "$id" && -n "$calibrate" ]]; then
  echo "verify-draft: pass --id or --calibrate, not both" >&2; exit 2
fi

env_threshold="${DELEGATE_VERIFY_THRESHOLD:-}"
if [[ -n "$env_threshold" ]] && ! [[ "$env_threshold" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; then
  echo "verify-draft: DELEGATE_VERIFY_THRESHOLD='$env_threshold' is not a number from 0 to 1" >&2
  exit 2
fi

# The request measured on 2026-10-07; changing a word invalidates every
# recorded threshold.
request_jq='{state: {facts: (.facts[:16000]), draft},
  questions: {grounded: {type: "noul",
    instructions: "Is every claim in `draft` stated in or directly implied by `facts`?",
    criteria: {"true": "Each statement in `draft` matches `facts`; nothing is reversed, swapped or added.",
               "false": "`draft` contradicts `facts` somewhere, or states something `facts` does not say."}}}}'

# score <{facts, draft} JSON> — prints "<model>\t<p>\t<latency_ms>"; exit 3
# when the verifier cannot answer.
score() {
  local answer
  if ! answer=$(jq -c "$request_jq" <<<"$1" | bash "$script_dir/decide.sh" --backend logprob --tier verify); then
    echo "verify-draft: the verifier is unavailable (decide.sh --tier verify failed)" >&2
    return 3
  fi
  # No option letter among the top logprobs: decide.sh reports coverage 0
  # and a uniform 0.5 made up from nothing, which must not pass for a score.
  if jq -e '.answers.grounded.coverage == 0' <<<"$answer" >/dev/null; then
    echo "verify-draft: the verifier answered with neither option letter (coverage 0); no score" >&2
    return 3
  fi
  jq -r '[.model, .answers.grounded.probabilities.true, .latency_ms] | @tsv' <<<"$answer"
}

if [[ -n "$calibrate" ]]; then
  if [[ ! -f "$calibrate" ]]; then
    echo "verify-draft: calibration set '$calibrate' not found" >&2; exit 2
  fi
  if ! jq -se 'length > 0 and all(.[]; (.facts | type) == "string" and (.draft | type) == "string" and (.label | type) == "string")
               and any(.[]; .label == "supported") and any(.[]; .label != "supported")' "$calibrate" >/dev/null 2>&1; then
    echo "verify-draft: $calibrate needs rows with string facts, draft and label, both supported and not-supported" >&2
    exit 2
  fi
  # Labels feed label<TAB>p lines to the scorer, so only the three known
  # values are accepted, checked before any row is scored.
  bad_row=$(jq -rs 'to_entries[] | select(.value.label | IN("supported", "contradicted", "unsupported") | not) | .key + 1' "$calibrate" | head -n 1)
  if [[ -n "$bad_row" ]]; then
    echo "verify-draft: $calibrate row $bad_row has a label other than supported, contradicted or unsupported" >&2
    exit 2
  fi
  scored=""
  model=""
  errors=0
  # || [[ -n $row ]]: a file without a trailing newline keeps its last row.
  while IFS= read -r row || [[ -n "$row" ]]; do
    [[ -n "$row" ]] || continue
    if line=$(score "$row"); then
      # One threshold per model: a verifier that changes mid-run (a server
      # restart, a config.sh edit) would record a mixture under one name.
      if [[ -n "$model" && "${line%%$'\t'*}" != "$model" ]]; then
        echo "verify-draft: the verify model changed from $model to ${line%%$'\t'*} mid-calibration; nothing recorded" >&2
        exit 3
      fi
      model="${line%%$'\t'*}"
      scored="$scored$(jq -r '.label' <<<"$row")"$'\t'"${line#*$'\t'}"$'\n'
    else
      errors=$((errors + 1))
    fi
  done < "$calibrate"
  if [[ -z "$scored" ]]; then
    echo "verify-draft: no row could be scored" >&2; exit 3
  fi
  # label<TAB>p<TAB>latency per line in; the threshold, then the summary, out.
  result=$(printf '%s' "$scored" | perl -e '
    my @r = map { chomp; [split /\t/] } <STDIN>;
    my @pos = grep { $_->[0] eq "supported" } @r; my @neg = grep { $_->[0] ne "supported" } @r;
    die "verify-draft: the scored rows lack a supported or a not-supported label\n" unless @pos && @neg;
    my $s = 0; for my $n (@neg) { for my $p (@pos) { $s += $p->[1] > $n->[1] ? 1 : $p->[1] == $n->[1] ? .5 : 0 } }
    my $auroc = $s / (@pos * @neg);
    my $bal = sub { my $t = shift; ((grep { $_->[1] >= $t } @pos) / @pos + (grep { $_->[1] < $t } @neg) / @neg) / 2 };
    my ($best, $best_bal) = (undef, -1);
    for my $t (sort { $b <=> $a } keys %{{ map { $_->[1] => 1 } @r }}) {
      my $ba = $bal->($t); ($best, $best_bal) = ($t, $ba) if $ba > $best_bal + 1e-9 }
    my $acc = sub { my $t = shift; scalar grep { ($_->[1] >= $t) == ($_->[0] eq "supported") } @r };
    my %lab; push @{ $lab{ $_->[0] } }, $_ for @r;
    my $rec = join " ", map { my $l = $_; sprintf "%s=%d/%d", $l, scalar(grep { ($_->[1] >= $best) == ($l eq "supported") } @{ $lab{$l} }), scalar @{ $lab{$l} } } sort { ($b eq "supported") <=> ($a eq "supported") or $a cmp $b } keys %lab;
    my @lat = sort { $a <=> $b } map { $_->[2] } @r;
    print "$best\n";
    printf "n=%d auroc=%.3f threshold=%s balanced_accuracy=%.3f accuracy=%d/%d acc\@0.5=%d/%d recall %s p50_ms=%d\n",
      scalar @r, $auroc, $best, $best_bal, $acc->($best), scalar @r, $acc->(0.5), scalar @r, $rec, $lat[@lat / 2];
  ') || { (( errors > 0 )) && exit 3; exit 2; }
  threshold="${result%%$'\n'*}"
  echo "verify-calibrate: model=$model errors=$errors ${result#*$'\n'}"
  # A threshold chosen over a subset is not the set it claims to be.
  if (( errors > 0 )); then
    echo "verify-calibrate: $errors row(s) could not be scored; threshold not recorded" >&2
    exit 3
  fi
  if (( dry_run )); then
    echo "verify-calibrate: --dry-run, threshold not recorded" >&2
  else
    mkdir -p "$data_dir"
    tmp=$(mktemp "$data_dir/verify-thresholds.XXXXXX")
    if [[ -f "$thresholds_file" ]]; then
      awk -F'\t' -v m="$model" '$1 != m' "$thresholds_file" > "$tmp"
    fi
    printf '%s\t%s\n' "$model" "$threshold" >> "$tmp"
    mv "$tmp" "$thresholds_file"
    echo "verify-calibrate: recorded threshold $threshold for $model in $thresholds_file" >&2
  fi
  exit 0
fi

if [[ -n "$id" ]]; then
  if [[ ! -f "$metrics_file" ]]; then
    echo "verify-draft: metrics file not found: $metrics_file" >&2; exit 2
  fi
  files=$(jq -r --arg id "$id" 'select((.source // "delegate") == "delegate" and .otel_span_id == $id)
    | [(.draft_file // ""), (.inputs_file // "")] | @tsv' "$metrics_file" | tail -n 1)
  if [[ -z "$files" ]]; then
    echo "verify-draft: --id $id does not match any delegate row in $metrics_file" >&2; exit 2
  fi
  draft_file="${files%%$'\t'*}"
  inputs_file="${files#*$'\t'}"
  drafts_dir="$(dirname "$metrics_file")/drafts"
  # The names come out of a JSONL file and become paths: bare filenames only.
  for f in "$draft_file" "$inputs_file"; do
    if [[ -z "$f" || "$f" == */* || "$f" == .* || ! -f "$drafts_dir/$f" ]]; then
      echo "verify-draft: row $id has no stored inputs and draft (not a recipe call, capture off, or pruned)" >&2
      exit 2
    fi
  done
  input=$({ cat "$drafts_dir/$inputs_file"; jq -Rs . < "$drafts_dir/$draft_file"; } | recipe_verify_input)
else
  input=$(cat)
  if ! jq -e '(.facts | type) == "string" and (.draft | type) == "string" and (.draft | length) > 0' <<<"$input" >/dev/null 2>&1; then
    echo "verify-draft: stdin must be JSON with string facts and a non-empty draft" >&2; exit 2
  fi
fi

line=$(score "$input") || exit 3
IFS=$'\t' read -r model p latency <<<"$line"
threshold="$env_threshold"
if [[ -z "$threshold" && -f "$thresholds_file" ]]; then
  threshold=$(awk -F'\t' -v m="$model" '$1 == m { t = $2 } END { print t }' "$thresholds_file")
fi
if [[ -z "$threshold" ]]; then
  threshold=0.5
  echo "verify-draft: no calibrated threshold for $model; using 0.5 (run --calibrate)" >&2
fi
jq -nc --arg m "$model" --argjson p "$p" --argjson t "$threshold" --argjson ms "$latency" \
  '{model: $m, p_supported: $p, threshold: $t, verdict: (if $p >= $t then "pass" else "flag" end), latency_ms: $ms}'
jq -ne --argjson p "$p" --argjson t "$threshold" '$p >= $t' >/dev/null || exit 1
