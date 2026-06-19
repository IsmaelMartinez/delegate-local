#!/usr/bin/env bash
# Faithfulness grounding check (prototype). Given an INPUT (a unified diff or
# other source context) and a model OUTPUT, decide whether the output is
# "grounded": does it mention at least one distinctive identifier — a changed
# file name or a code symbol — that actually appears in the input? An output
# that mentions NONE of the input's identifiers is likely invented or
# regurgitated from elsewhere (the failure shape measured 2026-06-18, where a
# 0.6B wrote about "stale lock file / daemon crash" for a diff about account
# lockout). This catches GROSS faithfulness failures (whole-topic drift), not
# subtle ones (right topic, wrong detail), so it is a recall FLOOR, not a
# ceiling. Matching is lenient (substring, case-insensitive) on purpose: we
# only ever flag UNGROUNDED when the output cites zero identifiers, so leaning
# toward "grounded" keeps false positives (flagging a faithful output) low at
# the cost of missing some drift — the right bias for an advisory check.
#
# Usage:
#   grounding-check.sh --input <diff-file> [--min-idents N] < output.txt
#   echo "$output" | grounding-check.sh --input <diff-file>
#
# Prints one machine-parseable line and sets the exit code:
#   GROUNDING: GROUNDED   matched=<k> input_idents=<m> sample=<...>   (exit 0)
#   GROUNDING: UNGROUNDED matched=0 input_idents=<m> sample=<...>     (exit 1)
#   GROUNDING: SKIP       input_idents=<m> (<min N — too few to judge) (exit 0)
#
# --min-idents (default 3): the input must carry at least this many distinctive
# identifiers before a verdict is rendered; trivial diffs (a one-token change,
# a whitespace-only hunk) cannot ground anything and would only generate noise.

set -uo pipefail

input=""
min_idents=3
while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)      [[ $# -ge 2 ]] || { echo "--input requires a value" >&2; exit 2; }; input="$2"; shift 2 ;;
    --min-idents) [[ $# -ge 2 ]] || { echo "--min-idents requires a value" >&2; exit 2; }; min_idents="$2"; shift 2 ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
if [[ -z "$input" || ! -f "$input" ]]; then
  echo "usage: grounding-check.sh --input <diff-file> [--min-idents N] < output" >&2
  exit 2
fi
if ! [[ "$min_idents" =~ ^[0-9]+$ ]]; then
  echo "grounding-check: --min-idents must be a non-negative integer" >&2; exit 2
fi

GC_INPUT="$input" GC_MIN="$min_idents" perl -e '
  my $input_file = $ENV{GC_INPUT};
  my $min        = $ENV{GC_MIN} + 0;
  # Read the model output from STDIN (not an env var) so a large output cannot
  # exceed the OS environment-size limit.
  my $output     = do { local $/; <STDIN> };
  $output        = defined($output) ? lc $output : "";

  # Stoplist: programming keywords + structural English function words that
  # carry no grounding signal. Lowercased. Kept deliberately small — the
  # >=4-char floor below already removes most noise; this catches the frequent
  # 4+ char keywords that would otherwise match almost any prose output.
  my %stop = map { $_ => 1 } qw(
    return import from class self this that with then else elif while
    true false none null void func function const static public private
    print echo def end args kwargs param result data item items
    list dict array string number boolean object type test tests case cases
    when where which what have been will would should could into over under
    your their there here some more most than them they also each both
    only just like such does done make made used uses using need
    line lines file files code text name names call calls main init exit
    error errors check checks valid value values
  );

  # %idents maps a lowercased identifier -> distinctive flag (1/0). A DISTINCTIVE
  # identifier looks like a code symbol the model could not have produced by
  # chance from generic prose: it contains an underscore, contains an uppercase
  # letter (camelCase / PascalCase / CONSTANT), or is long (>=7 chars); a
  # filename-derived token counts as distinctive at >=4 chars. Generic short
  # lowercase words (lock, file, user) are kept but only weakly ground — a lone
  # one of them is a coincidence, not evidence (measured: a 0.6B regurgitation
  # about "lock file" matched the word "lock" from an unrelated diff comment).
  my %idents;
  my $mark = sub {
    my ($tok, $is_file) = @_;
    my $lc = lc $tok;
    return if $stop{$lc};
    my $distinctive = ($tok =~ /_/) || ($tok =~ /[A-Z]/) || (length($tok) >= 7)
                      || ($is_file && length($tok) >= 4) ? 1 : 0;
    $idents{$lc} = $distinctive if !exists $idents{$lc} || $distinctive > $idents{$lc};
  };

  open(my $fh, "<", $input_file)
    or do { print STDERR "grounding-check: cannot open input file: $!\n"; exit 2; };
  while (my $line = <$fh>) {
    chomp $line;
    if ($line =~ m{^diff --git a/(\S+) b/(\S+)} or
        $line =~ m{^\+\+\+ b/(\S+)} or
        $line =~ m{^--- a/(\S+)}) {
      my $path = $2 // $1;
      next if $path eq "/dev/null";
      my $base = $path; $base =~ s{.*/}{};       # basename
      $mark->($_, 1) for grep { length($_) >= 3 } split(/[._\-\/]/, $base);
      next;
    }
    next unless $line =~ /^[+-]/ && $line !~ /^[+-]{3}/;
    my $body = substr($line, 1);
    while ($body =~ /([A-Za-z_][A-Za-z0-9_]{3,})/g) { $mark->($1, 0); }
  }
  close($fh);

  my @ids = sort keys %idents;
  my $m = scalar @ids;
  my $dn = grep { $idents{$_} } @ids;   # how many of them are DISTINCTIVE

  # Lenient substring match (case-insensitive): an identifier "counts" if it
  # appears anywhere in the output. Track distinctive vs total matches.
  my (@dist_matched, @any_matched);
  for my $id (@ids) {
    next unless index($output, $id) >= 0;
    push @any_matched, $id;
    push @dist_matched, $id if $idents{$id};
  }
  my $k = scalar @any_matched;
  my $d = scalar @dist_matched;

  # Grounded if at least one DISTINCTIVE identifier matched, or at least two
  # identifiers of any kind (two independent coincidences are unlikely).
  my $grounded = ($d >= 1 || $k >= 2) ? 1 : 0;

  my @show = $d ? @dist_matched : (@any_matched ? @any_matched : @ids);
  my $sample = join(",", @show[0 .. ($#show > 3 ? 3 : $#show)]);
  $sample = "(none)" if $sample eq "";

  if ($dn < $min) {
    printf "GROUNDING: SKIP       distinctive_idents=%d (<%d — too few to judge)\n", $dn, $min;
    exit 0;
  } elsif (!$grounded) {
    printf "GROUNDING: UNGROUNDED matched=%d distinctive=%d input_idents=%d sample=%s\n", $k, $d, $m, $sample;
    exit 1;
  } else {
    printf "GROUNDING: GROUNDED   matched=%d distinctive=%d input_idents=%d sample=%s\n", $k, $d, $m, $sample;
    exit 0;
  }
'
