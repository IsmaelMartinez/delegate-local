# pair.jq — the one verdict model (#564), shared by metrics-summary.sh,
# self-improve.sh and replay-recipe.sh so their verdict counts cannot
# disagree. Load it with `jq -L "<absolute lib dir>" 'include "pair"; ...'`
# over the slurped metrics file (-s).

def src: .source // "delegate";
def ok: (.exit_status // 0) == 0;

# A feedback row with neither ref_id nor ref_ts names no delegation and is
# skipped everywhere: keyed on the empty reference, every such row would
# share one key.
def referenced: .source == "feedback" and (.ref_id != null or .ref_ts != null);

# The delegate rows, each with its position in the input as `_i`.
def delegates: [to_entries[] | select(.value | src == "delegate") | .value + {_i: .key}];

# A delegate row's key: otel_span_id when it has one (#481), else its
# position, so two legacy rows without an id in one second stay two
# delegations. Only rows from `delegates` carry the position.
def dkey: if .otel_span_id != null then "id:" + .otel_span_id else "row:\(._i)" end;

# Every referenced feedback row with its delegate row attached as `parent`:
# looked up by ref_id first, then ref_ts. A ts-only verdict on a second
# several delegations share lands on the last of them in the file, one
# delegation and not all of them.
def parent_join:
  (delegates | map(select(.ts != null))) as $dl
  | (($dl | INDEX("ts:" + .ts)) + ($dl | map(select(.otel_span_id != null)) | INDEX("id:" + .otel_span_id))) as $d
  | [.[] | select(referenced) | . + {_p: ($d["id:" + (.ref_id // "")] // $d["ts:" + (.ref_ts // "")])}];
def parent: ._p;

# The delegation a verdict belongs to, whichever way it was pinned, so an
# id-pinned verdict and a later ts-only one on the same row collapse to one.
def pkey:
  if ._p == null then (if (.ref_id // "") != "" then "id:" + .ref_id else "ts:" + .ref_ts end)
  else (._p | dkey) end;

# One verdict per delegation, the latest by ts; sort_by is stable, so file
# order breaks a tie.
def latest_verdicts: parent_join | sort_by(.ts) | INDEX(pkey) | [.[]];

# A verdict's own key, which the ritual sidecar is keyed on.
def fkey: (.ts // "") + "|" + (.ref_id // .ref_ts // "");

# The two sidecars beside the metrics file, read with --rawfile:
# suspect-finals.tsv (`self-improve.sh --quarantine`, #587) as a set of final
# names, and ritual-verdicts.tsv (`self-improve.sh --ritual`, #588) as fkey ->
# the final it measured.
def suspect_set: [split("\n")[] | select(. != "") | split("\t")[0] | {(.): true}] | add // {};
def measured_map: [split("\n")[] | select(. != "") | split("\t") | {(.[0]): (.[1] // "")}] | add // {};

# Ritual (#588): the shipped final was already in the piped stdin. The tag
# stored on the verdict wins; a verdict recorded before the field is ritual
# when --ritual measured it so. A quarantined final is never ritual.
def ritual($suspect; $measured):
  if has("final_preexisting") then
    .final_preexisting == true and (($suspect[.final_file // ""] // false) | not)
  else
    ($measured[fkey] // null) as $f | $f != null and (($suspect[$f] // false) | not)
  end;

# kept | scaffold | rewrote | ritual. A scaffold row also carries kept:false.
def outcome($suspect; $measured):
  if ritual($suspect; $measured) then "ritual"
  elif (.scaffold // false) then "scaffold"
  elif .kept then "kept"
  else "rewrote" end;

# latest_verdicts, each with its outcome as `u`, given the two raw sidecars.
def latest_outcomes($sl; $rl):
  ($sl | suspect_set) as $s | ($rl | measured_map) as $m
  | latest_verdicts | map(. + {u: outcome($s; $m)});

# dkey -> the outcome of that delegation's latest verdict.
def verdict_index($sl; $rl): latest_outcomes($sl; $rl) | map({key: pkey, value: .u}) | from_entries;

# Counts over rows of {u: outcome or null (no verdict), session}. Ritual rows
# are left out of n and every count but their own; sessions are the distinct
# sessions of the rows that count.
def tally:
  (map(select(.u == "ritual")) | length) as $r
  | map(select(.u != "ritual"))
  | {n: length,
     kept: (map(select(.u == "kept")) | length),
     scaffold: (map(select(.u == "scaffold")) | length),
     rewrote: (map(select(.u == "rewrote")) | length),
     untracked: (map(select(.u == null)) | length),
     ritual: $r,
     sessions: (map(.session // "" | select(. != "")) | unique | length)};

# The rolling window: rows at or after $cut, an epoch from cutoff($days).
def cutoff($days): (now | floor) - ($days * 86400);
def in_window($cut): ((.ts // "") | fromdateiso8601? // 0) >= $cut;

# A whole percent, floored; one decimal always for pct, so a column does not
# go ragged on a whole number. Both are 0 on an empty denominator.
def rate($n; $d): if $d > 0 then ($n * 100 / $d | floor) else 0 end;
def pct($n; $d):
  if $d > 0 then ((($n * 1000 / $d) | round) as $t | "\($t / 10 | floor).\($t % 10)")
  else "0.0" end;
