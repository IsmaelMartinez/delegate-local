#!/usr/bin/env bash
# export-verdicts.sh — the verdict corpus as a labelled dataset for the Clef
# spike (#637; epic #642). One JSONL record per verdicted recipe delegation,
# joined by lib/pair.jq's latest_outcomes so the labels match metrics-summary:
#
#   {id, ts, recipe, template_sha, model, project, verdict, reason, ritual,
#    input, inputs, draft, final}
#
# verdict is hit | scaffold | miss | ritual (kept | scaffold | rewrote |
# ritual in pair.jq). Ritual rows are left out unless --include-ritual; a
# quarantined final (suspect-finals.tsv) is dropped to null. Rows are split by
# date into dev.jsonl and holdout.jsonl so later experiments tune on dev only.
#
# Usage:  export-verdicts.sh [--since YYYY-MM-DD] [--holdout-from YYYY-MM-DD]
#                            [--out DIR] [--include-ritual]
#
#   --since         first day exported (default 2026-09-20, the first day the
#                   corpus kept inputs.json)
#   --holdout-from  first day of the held-out set; without it the day of the
#                   row at 80% of the corpus is used and printed, so pass the
#                   printed day on later runs to keep the split frozen
#   --out           output directory (default <data dir>/spikes/clef/dataset);
#                   refused inside a git checkout, since rows hold repo and
#                   issue text
#
# Env:  DELEGATE_METRICS_FILE, DELEGATE_LOCAL_DATA_DIR (as self-improve.sh).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
data_dir="${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}"
metrics_file="${DELEGATE_METRICS_FILE:-$data_dir/metrics.jsonl}"
since="2026-09-20"
holdout_from=""
out_dir="$data_dir/spikes/clef/dataset"
include_ritual=false

need_value() { [[ -n "${2:-}" ]] || { echo "export-verdicts: $1 requires a value" >&2; exit 2; }; }
is_day() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "export-verdicts: '$1' is not YYYY-MM-DD" >&2; exit 2; }; }
while (( $# > 0 )); do
  case "$1" in
    --since) need_value "$@"; is_day "$2"; since="$2"; shift 2 ;;
    --holdout-from) need_value "$@"; is_day "$2"; holdout_from="$2"; shift 2 ;;
    --out) need_value "$@"; out_dir="$2"; shift 2 ;;
    --include-ritual) include_ritual=true; shift ;;
    -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "export-verdicts: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[[ -f "$metrics_file" ]] || { echo "export-verdicts: no metrics file at $metrics_file" >&2; exit 1; }
mkdir -p "$out_dir"
if git -C "$out_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "export-verdicts: $out_dir is inside a git checkout; the dataset holds repo and issue text, write it elsewhere" >&2
  exit 2
fi

side_dir="$(dirname "$metrics_file")"
suspect="$side_dir/suspect-finals.tsv"
ritual="$side_dir/ritual-verdicts.tsv"
[[ -f "$suspect" ]] || suspect=/dev/null
[[ -f "$ritual" ]] || ritual=/dev/null

jq -c -s -L "$script_dir/lib" --rawfile sl "$suspect" --rawfile rl "$ritual" --arg since "$since" '
  include "pair";
  ($sl | suspect_set) as $s
  | latest_outcomes($sl; $rl)
  | map(select(._p != null and (._p.recipe // "") != "" and (._p.ts // "") >= $since))
  | sort_by(._p.ts)
  | .[]
  | {id: ._p.otel_span_id, ts: ._p.ts, recipe: ._p.recipe, template_sha: ._p.template_sha,
     model: ._p.model, project: ._p.project,
     verdict: ({kept: "hit", scaffold: "scaffold", rewrote: "miss", ritual: "ritual"}[.u]),
     reason: .reason, ritual: (.u == "ritual"),
     input_file: ._p.input_file, inputs_file: ._p.inputs_file, draft_file: ._p.draft_file,
     final_file: (if ($s[.final_file // ""] // false) then null else .final_file end)}' "$metrics_file" |
DRAFTS="$side_dir/drafts" OUT="$out_dir" HOLDOUT_FROM="$holdout_from" INCLUDE_RITUAL="$include_ritual" \
perl -MJSON::PP -e '
  use strict; use warnings;
  my $json = JSON::PP->new->canonical->utf8;
  my $dir = $ENV{DRAFTS};
  # A file the row names, read whole; undef when it is missing or the name
  # could leave the drafts dir.
  sub slurp {
    my ($name) = @_;
    return undef if !defined $name || $name eq "" || $name =~ m{/} || $name =~ /^\./;
    open(my $fh, "<:raw", "$dir/$name") or return undef;
    local $/; my $text = <$fh>; close $fh;
    return $text;
  }
  my @rows; my $ritual = 0; my $no_draft = 0;
  while (my $line = <STDIN>) {
    my $r = $json->decode($line);
    if ($r->{ritual} && $ENV{INCLUDE_RITUAL} ne "true") { $ritual++; next; }
    my $draft = slurp($r->{draft_file});
    if (!defined $draft) { $no_draft++; next; }
    my $inputs = slurp($r->{inputs_file});
    my $decoded = defined $inputs ? eval { $json->decode($inputs) } : undef;
    my $input = slurp($r->{input_file});
    my $final = slurp($r->{final_file});
    utf8::decode($_) for grep { defined } ($draft, $input, $final);
    push @rows, {
      (map { $_ => $r->{$_} } qw(id ts recipe template_sha model project verdict reason ritual)),
      draft => $draft, input => $input, inputs => $decoded, final => $final,
    };
  }
  die "export-verdicts: no verdicted delegations with a stored draft\n" unless @rows;
  my $cut = $ENV{HOLDOUT_FROM};
  if ($cut eq "") { $cut = substr($rows[int(@rows * 0.8)]{ts}, 0, 10); }
  my %split = (dev => [], holdout => []);
  push @{ $split{ substr($_->{ts}, 0, 10) ge $cut ? "holdout" : "dev" } }, $_ for @rows;
  for my $name (qw(dev holdout)) {
    open(my $fh, ">:raw", "$ENV{OUT}/$name.jsonl") or die "export-verdicts: cannot write $ENV{OUT}/$name.jsonl: $!\n";
    print $fh $json->encode($_), "\n" for @{ $split{$name} };
    close $fh;
  }
  printf "holdout from %s%s\n", $cut, ($ENV{HOLDOUT_FROM} eq "" ? " (pass --holdout-from $cut to keep this split)" : "");
  printf "skipped: %d ritual, %d without a stored draft\n", $ritual, $no_draft;
  for my $name (qw(dev holdout)) {
    my %n;
    $n{ $_->{recipe} }{ $_->{verdict} }++ for @{ $split{$name} };
    printf "%s: n=%d\n", $name, scalar @{ $split{$name} };
    for my $recipe (sort keys %n) {
      my $c = $n{$recipe};
      my $total = 0; $total += $_ for values %$c;
      printf "  %-26s n=%-4d %s\n", $recipe, $total,
        join(" ", map { "$_=" . ($c->{$_} // 0) } qw(hit scaffold miss ritual));
    }
  }
  print "wrote $ENV{OUT}/dev.jsonl and $ENV{OUT}/holdout.jsonl\n";
'
