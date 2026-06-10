#!/usr/bin/env bash
# Scan the delegate metrics JSONL for recurring MISS patterns and print one
# draft `gh issue create` command per bucket of similar reasons. The
# on-demand counterpart to the per-MISS nudge in `delegate-feedback.sh`
# (issue #88 option B) — useful for periodic review and for scanning
# cross-machine JSONLs the runtime nudge would never see.
#
# Read-only: never modifies the JSONL, never opens issues. Just prints.
#
# Usage:  audit-metrics.sh
# Env (shared names with the runtime nudge so a single tuning applies to both):
#   DELEGATE_METRICS_FILE                 metrics JSONL path
#                                         (default ~/.claude/skills/delegate-local/metrics.jsonl)
#   DELEGATE_FEEDBACK_NUDGE_WINDOW_DAYS   lookback in days (default 30; 0 disables)
#   DELEGATE_FEEDBACK_NUDGE_AT            minimum bucket size to emit a draft
#                                         (default 3)
#   DELEGATE_FEEDBACK_SIMILAR_THRESHOLD   Jaccard cutoff (default 0.4)
#   DELEGATE_GITHUB_REPO                  owner/repo the draft `gh issue create`
#                                         commands target
#                                         (default IsmaelMartinez/delegate-local;
#                                         forks set their own)
# Exit:   0 OK (with or without buckets), 1 file/dep missing, 2 usage error.

set -uo pipefail

usage() {
  cat >&2 <<'EOF'
usage: audit-metrics.sh
  Scans $DELEGATE_METRICS_FILE for source:"feedback" rows with kept:false
  in the lookback window, buckets them by Jaccard similarity over content
  tokens, and prints a draft `gh issue create` command for each bucket
  with at least DELEGATE_FEEDBACK_NUDGE_AT entries. Read-only.
EOF
  exit 2
}

# No positional arguments accepted.
if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help) usage ;;
    *) echo "audit-metrics: unexpected argument '$1'" >&2; usage ;;
  esac
fi

metrics_file="${DELEGATE_METRICS_FILE:-$HOME/.claude/skills/delegate-local/metrics.jsonl}"
nudge_at="${DELEGATE_FEEDBACK_NUDGE_AT:-3}"
window_days="${DELEGATE_FEEDBACK_NUDGE_WINDOW_DAYS:-30}"
similar_threshold="${DELEGATE_FEEDBACK_SIMILAR_THRESHOLD:-0.4}"
github_repo="${DELEGATE_GITHUB_REPO:-IsmaelMartinez/delegate-local}"
window_secs=$((window_days * 86400))

[[ -f "$metrics_file" ]] || { echo "metrics file not found: $metrics_file" >&2; exit 1; }
command -v perl >/dev/null || { echo "perl not on PATH" >&2; exit 1; }

# Many-vs-many bucketing in Perl: the matcher mirrors the tokeniser used by
# delegate-feedback.sh (lowercase, stopwords stripped, length ≥ 3, dedupe
# per reason) so the on-demand audit and the per-MISS nudge agree on what
# counts as "similar". Greedy clustering: walk MISS rows in time order
# (oldest first), assigning each to the first existing bucket whose seed
# reason scores Jaccard ≥ threshold, or seeding a new bucket otherwise.
# Bucket output is plain text with field delimiters that the bash layer
# below parses — keeping the Perl portable (no JSON encode dep on stdout).
out=$(perl -MJSON::PP -MTime::Local=timegm -e '
  use strict; use warnings; binmode(STDOUT, ":utf8");
  my ($threshold, $window_secs, $nudge_at) = @ARGV;
  my $now = time;
  my %STOP = map { $_ => 1 } qw(
    the a an and or but is was were be been being am are
    for to from with on in of at by into onto out up down
    this that these those it its also too just only very
    has have had do does did can could should would shall
    will may might must about against some any all most
    more less few many much over under above below than then
    not no nor so yet still already even either neither
    such same other another own here there where when how why
  );
  sub toks {
    my $s = lc(shift // "");
    my %seen;
    grep { length >= 3 && !$STOP{$_} && !$seen{$_}++ }
      grep { length } split /\W+/, $s;
  }

  my @rows;  # each: { ts => ..., reason => ..., toks => [...], set => {...} }
  while (my $line = <STDIN>) {
    my $j = eval { decode_json($line) };
    next unless ref $j eq "HASH";
    next unless ($j->{source} // "") eq "feedback";
    next if $j->{kept};
    next unless $j->{ts};
    if ($window_secs > 0 && $j->{ts} =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/) {
      my $epoch = timegm($6, $5, $4, $3, $2-1, $1);
      next if ($now - $epoch) > $window_secs;
    }
    my $reason = $j->{reason} // "";
    my @t = toks($reason);
    next unless @t;
    push @rows, { ts => $j->{ts}, reason => $reason, toks => \@t,
                  set => { map { $_ => 1 } @t } };
  }

  # Sort by ts ascending so the oldest similar MISS becomes the bucket seed
  # — gives stable ordering across runs regardless of JSONL append order.
  @rows = sort { $a->{ts} cmp $b->{ts} } @rows;

  my @buckets;  # each: { seed => $row, members => [$row, ...] }
  for my $row (@rows) {
    my $assigned = 0;
    for my $b (@buckets) {
      my $seed = $b->{seed};
      my $inter = 0;
      for my $t (@{$row->{toks}}) { $inter++ if $seed->{set}{$t} }
      my $union = scalar(@{$row->{toks}}) + scalar(@{$seed->{toks}}) - $inter;
      next if $union == 0;
      my $jac = $inter / $union;
      if ($jac >= $threshold) {
        push @{$b->{members}}, $row;
        $assigned = 1;
        last;
      }
    }
    push @buckets, { seed => $row, members => [$row] } unless $assigned;
  }

  # Filter to recurring buckets, rank by size (largest first) so the most
  # acute pattern surfaces at the top of the audit output.
  my @recurring = grep { scalar(@{$_->{members}}) >= $nudge_at } @buckets;
  @recurring = sort { scalar(@{$b->{members}}) <=> scalar(@{$a->{members}}) } @recurring;

  print "TOTAL_MISSES=" . scalar(@rows) . "\n";
  print "BUCKETS=" . scalar(@recurring) . "\n";

  my $bid = 0;
  for my $b (@recurring) {
    $bid++;
    my $count = scalar(@{$b->{members}});
    my $seed_reason = $b->{seed}{reason};
    $seed_reason =~ s/\s+/ /g;
    my $rep = substr($seed_reason, 0, 100) . (length($seed_reason) > 100 ? "…" : "");
    print "BUCKET_START\tid=$bid\tcount=$count\trep=$rep\n";
    for my $m (@{$b->{members}}) {
      my $r = $m->{reason};
      $r =~ s/\s+/ /g;
      $r = substr($r, 0, 100) . (length($r) > 100 ? "…" : "");
      print "MEMBER\t$m->{ts}\t$r\n";
    }
    print "BUCKET_END\n";
  }
' "$similar_threshold" "$window_secs" "$nudge_at" < "$metrics_file")
perl_status=$?
if (( perl_status != 0 )); then
  echo "audit-metrics: perl processing failed (exit $perl_status)" >&2
  exit 1
fi

total_misses=$(printf '%s\n' "$out" | awk -F= '/^TOTAL_MISSES=/ {print $2}')
bucket_count=$(printf '%s\n' "$out" | awk -F= '/^BUCKETS=/ {print $2}')

if [[ "${total_misses:-0}" -eq 0 ]]; then
  echo "No MISS feedback rows found in the last ${window_days}d window."
  exit 0
fi

if [[ "${bucket_count:-0}" -eq 0 ]]; then
  echo "Scanned ${total_misses} MISS row(s) in the last ${window_days}d window — no bucket reached the threshold of ${nudge_at}."
  exit 0
fi

echo "Scanned ${total_misses} MISS row(s) in the last ${window_days}d window — found ${bucket_count} recurring bucket(s) at threshold ${similar_threshold}."
echo

# Stream the buckets back out as human-readable summaries plus a draft
# `gh issue create` command per bucket. The body is built with printf so
# embedded newlines survive into the gh --body argument unmolested.
printf '%s\n' "$out" | awk -F'\t' -v repo="$github_repo" '
  /^BUCKET_START/ {
    # Strip the leading "id=" / "count=" / "rep=" prefixes.
    id=$2; sub(/^id=/, "", id)
    count=$3; sub(/^count=/, "", count)
    rep=$4; sub(/^rep=/, "", rep)
    printf "── Bucket %s — %s similar MISSes ──\n", id, count
    printf "Representative: %s\n", rep
    printf "Matched reasons:\n"
    cur_id=id; cur_count=count; cur_rep=rep
    members=""
    next
  }
  /^MEMBER/ {
    printf "  - %s: %s\n", $2, $3
    if (members == "") members=$2 ": " $3
    else members=members "\n" $2 ": " $3
    next
  }
  /^BUCKET_END/ {
    # Build a draft gh issue create command. Title is bucket-numbered so the
    # author can tighten it manually before firing; body lists every matched
    # reason so the issue captures the full N data points (the multi-row
    # summary advantage option B has over option A).
    title="prompt-pattern: " cur_rep
    # Truncate title to ~80 chars so gh does not balk and the author can
    # see at a glance whether the bucket label is meaningful.
    if (length(title) > 80) title=substr(title, 1, 79) "…"
    # gsub backslashes and double-quotes in title for safe single-quoting.
    gsub(/\x27/, "\x27\\\x27\x27", title)
    body="Found " cur_count " similar MISS rows in the metrics JSONL.\n\n"
    body=body "Matched reasons:\n" members "\n\n"
    body=body "See .github/ISSUE_TEMPLATE/prompt-pattern.md for the full template — paste the prompt, the model output, and a suggested fix if known."
    gsub(/\x27/, "\x27\\\x27\x27", body)
    printf "\nDraft issue command:\n"
    printf "  gh issue create --repo %s \\\n", repo
    printf "    --label prompt-pattern \\\n"
    printf "    --title \x27%s\x27 \\\n", title
    printf "    --body \x27%s\x27\n\n", body
    next
  }
'
