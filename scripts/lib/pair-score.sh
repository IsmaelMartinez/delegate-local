#!/usr/bin/env bash
# Pair-scoring helpers shared by self-improve.sh (the evidence bundle) and
# replay-recipe.sh (the offline gate), so a rejection's DROPPED list and a
# replay's dropped count are the same measurement. Sourcing has no side
# effects. bash 3.2 portable: awk, grep -E, sed -E only. The
# feedback-to-delegation join is not here but in lib/pair.jq (#564).

# salient <file> — one salient token per line, deduped, lowercased: a
# backticked span, an issue ref, a dotted identifier or path, or a number of
# two or more digits. Extraction is literal or a flat alternation, so it is
# linear. DROPPED / INVENTED are set differences over these.
salient() {
  [[ -f "$1" ]] || return 0
  {
    grep -oE '`[^`]+`' "$1" 2>/dev/null | tr -d '`'
    grep -oE '#[0-9]+' "$1" 2>/dev/null
    grep -oE '[A-Za-z0-9_][A-Za-z0-9_-]*\.[A-Za-z0-9_]+[A-Za-z0-9_.:/-]*' "$1" 2>/dev/null
    grep -oE '[0-9]+' "$1" 2>/dev/null | awk 'length($0) >= 2'
  } | tr '[:upper:]' '[:lower:]' | sed 's/[.,;:)]*$//' | awk 'NF' | sort -u
}

# absent_from <file> — filter: reads salient tokens on stdin and prints the
# ones that do not occur in <file>, case-insensitively, as a whole token:
# not preceded or followed by a word character, so `#12` is not found in
# `#123` and `412` is found in `main.js:412`. The extraction above is
# asymmetric between a backticked span and the same name written bare
# (`inLocale()` yields a token, inLocale() yields none), so a set difference
# alone reported four inventions on a 2026-09-19 draft whose every name was
# in the context. A token that is in the text, however it was written, was
# neither dropped nor invented. One perl per call, the token quoted literal
# and the boundaries fixed-width, so the match is linear.
absent_from() {
  perl -e '
    my $file = shift;
    my $text = "";
    if (open(my $fh, "<", $file)) { local $/; $text = <$fh>; close $fh; }
    while (my $tok = <STDIN>) {
      chomp $tok;
      next if $tok eq "";
      my $q = quotemeta($tok);
      print "$tok\n" unless $text =~ /(?<![A-Za-z0-9_])$q(?![A-Za-z0-9_])/i;
    }
  ' "$1"
}

# word_overlap <text> <candidate>... — how much of its vocabulary each
# candidate file shares with <text>: the Jaccard index of the two word sets
# as a whole percent, one line per candidate in argument order, `-` for a
# candidate that cannot be read or when either set is empty. A word is the
# unit content_words uses in delegate.sh, lowercased letters and hyphens of
# four or more starting with a letter, minus the same function words, so
# "could" and "that" do not pair two unrelated texts. It pairs a shipped text with
# the draft it came from (#587): the boundary hooks file a post under the
# unspent draft it overlaps most, delegate-feedback.sh refuses to adopt a
# posted final that shares next to nothing with its own draft, and the
# suspect-finals scan flags a final closer to a neighbour's draft than its
# own. One perl for all candidates; the pattern is a single class, linear.
word_overlap() {
  perl -e '
    my %stop = map { $_ => 1 } qw(could would should shall will have does been
      were being that this these those what which when where whether your yours
      them they their there here each both same other another such some many
      much most more very else itself yourself with from into onto upon about
      over once only also then than while until before after because since
      though although make made know want need like able sure must might please
      just still);
    sub words {
      my $f = shift; my %w;
      open(my $fh, "<", $f) or return undef;
      local $/; my $t = lc(<$fh> // ""); close $fh;
      while ($t =~ /(?<![a-z-])([a-z][a-z-]{3,})(?![a-z-])/g) { $w{$1} = 1 unless $stop{$1} }
      return \%w;
    }
    my $base = words(shift) || {};
    my $nb = scalar keys %$base;
    for my $c (@ARGV) {
      my $w = words($c);
      if (!$w || !$nb || !%$w) { print "-\n"; next }
      my $i = grep { $base->{$_} } keys %$w;
      my $u = $nb + scalar(keys %$w) - $i;
      printf "%d\n", $i * 100 / $u;
    }
  ' "$@"
}

# best_draft <text> <drafts dir> <draft name>... — the draft <text> was the
# shipped form of: the one it overlaps most, the first (oldest) on a tie or
# when no draft can be read. Prints nothing when given no draft.
best_draft() {
  local text="$1" dir="$2" best="" best_s=-1 s i=0
  shift 2
  (( $# > 0 )) || return 0
  local -a paths=()
  for s in "$@"; do paths+=("$dir/$s"); done
  while IFS= read -r s; do
    i=$((i + 1))
    [[ "$s" =~ ^[0-9]+$ ]] || s=-1
    if (( s > best_s )) || [[ -z "$best" ]]; then best="${!i}"; best_s=$s; fi
  done < <(word_overlap "$text" "${paths[@]}")
  printf '%s' "${best:-$1}"
}

# suspect_reason <sidecar> <final name> — why the final is quarantined, from
# the suspect-finals sidecar `self-improve.sh --quarantine` writes beside
# the metrics file (#587); nothing when it is not listed or there is no
# sidecar. A listed final is not the shipped text of its draft, so neither
# the bundle nor the replay scores it; the file itself is kept.
suspect_reason() {
  [[ -f "$1" ]] || return 0
  awk -F '\t' -v n="$2" '$1 == n { print ($2 == "" ? "suspect" : $2); exit }' "$1" 2>/dev/null
}

# list_markers <file> — how many lines open with a list marker. grep -c
# prints 0 and exits 1 on no match, so a `|| echo 0` fallback would append a
# second zero.
list_markers() {
  local n
  [[ -f "$1" ]] || { echo 0; return 0; }
  n=$(grep -cE '^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]' "$1" 2>/dev/null)
  echo "${n:-0}"
}

# body_only <file> — the file without its trailer lines: a Closes/Fixes/
# Resolves line naming a ref, a Refs line, Co-Authored-By, Signed-off-by,
# Claude-Session, the Claude Code footer, a bare session URL, a Stacked-on
# line. The caller fixes those lines whatever the draft said, so they are
# neither the draft's shape nor its facts (#589): 60 of 64 pr-description
# finals read as three or more paragraphs with them and 23 without. A body
# line that merely starts with a trailer word ("Refs are resolved") is kept.
# One anchored alternation with flat quantifiers, so the match is linear.
body_only() {
  [[ -f "$1" ]] || return 0
  grep -viE '^[[:space:]]*((close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]:]+([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+|refs?(:|[[:space:]]+#)|co-authored-by:|signed-off-by:|claude-session:|stacked on[[:space:]]|[^[:alnum:]]*generated with \[?claude code|https?://claude\.ai/code/)' "$1" 2>/dev/null
  return 0
}

# paragraphs <file> — how many blank-line-separated blocks of body, trailer
# lines left out (body_only), so a paragraph of trailers is not one. With
# list_markers it is the shape signal: a draft of one paragraph where three
# or more shipped is the collapse pr-description showed on 10 of 10 pairs on
# 2026-09-19 (drafts of 1 paragraph against shipped bodies of 3 to 7).
paragraphs() {
  [[ -f "$1" ]] || { echo 0; return 0; }
  body_only "$1" | awk 'BEGIN { RS=""; n=0 } { n++ } END { print n }' 2>/dev/null
}

# shape_mismatch <a> <b> — 1 when the two texts differ in shape: one is a
# list and the other prose, or one is a single paragraph and the other three
# or more. Symmetric, so a kept case scores a candidate that adds structure
# the same as one that removes it.
shape_mismatch() {
  local am bm ap bp
  am=$(list_markers "$1"); bm=$(list_markers "$2")
  ap=$(paragraphs "$1"); bp=$(paragraphs "$2")
  if { (( am > 0 )) && (( bm == 0 )); } || { (( bm > 0 )) && (( am == 0 )); }; then echo 1; return 0; fi
  if { (( ap == 1 )) && (( bp >= 3 )); } || { (( bp == 1 )) && (( ap >= 3 )); }; then echo 1; return 0; fi
  echo 0
}

# sentences — stdin to one sentence per line, terminator dropped, normalised,
# under the 40-char floor discarded: the unit, normalisation and floor
# no_context_echo applies in delegate.sh (split_sentences, echo_normalise,
# echo_matches), so the sentence the bundle names is the one the wrapper
# would have flagged. The sed is echo_normalise's, rule for rule and in its
# order: trim, the Wrong:/Correct: label, the commit type prefix, a trailing
# (#NNN). Not shared with delegate.sh because its helpers sit inside the
# checks region.
sentences() {
  awk '{ gsub(/[.?!]+[[:space:]]+/, "\n"); sub(/[.?!]+[[:space:]]*$/, "") } 1' \
    | sed -E -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
             -e 's/^[Ww]rong:[[:space:]]*//' -e 's/^[Cc]orrect:[[:space:]]*//' \
             -e 's/^[a-z]+(\([^)]*\))?!?:[[:space:]]*//' \
             -e 's/[[:space:]]*\(#[0-9]+\)$//' \
    | awk 'length($0) >= 40'
}

# The share of its word bigrams a shipped final must find in the stdin the
# caller piped for the delegation to be ritual (#588): the caller already
# had the text, ran the recipe for the boundary hook's credit and posted its
# own words, so no template could have produced a keepable draft.
ritual_min_pct=90

# bigram_containment — reads `<text path>TAB<source path>` pairs on stdin and
# prints, one line per pair, the whole percent of the text's distinct word
# bigrams that also occur in the source, or `-` when either file cannot be
# read or the text has fewer than two words. A source named *.inputs.json is
# read as its `stdin` value, the piped context delegate.sh stored (#588). A
# word is a run of ASCII letters and digits, lowercased, and every word
# counts: word_overlap's four-letter content words would drop the "is in"
# and "to the" that make a bigram a sequence rather than a vocabulary. One
# perl for every pair; the pattern is a single class, linear.
bigram_containment() {
  perl -MJSON::PP -e '
    sub slurp {
      my $f = shift;
      open(my $fh, "<", $f) or return undef;
      local $/; my $t = <$fh> // ""; close $fh;
      if ($f =~ /\.inputs\.json$/) {
        my $j = eval { JSON::PP->new->utf8->decode($t) };
        return undef unless ref $j eq "HASH";
        $t = $j->{stdin} // "";
        utf8::encode($t) if utf8::is_utf8($t);
      }
      return $t;
    }
    sub bigrams {
      my @w = (lc(shift) =~ /[a-z0-9]+/g);
      my %b; $b{"$w[$_ - 1] $w[$_]"} = 1 for 1 .. $#w;
      return \%b;
    }
    while (my $line = <STDIN>) {
      chomp $line;
      my ($text, $src) = split /\t/, $line, 2;
      my $t = defined $text ? slurp($text) : undef;
      my $s = defined $src ? slurp($src) : undef;
      if (!defined $t || !defined $s) { print "-\n"; next }
      my $tb = bigrams($t);
      my $n = scalar keys %$tb;
      if (!$n) { print "-\n"; next }
      my $sb = bigrams($s);
      my $in = grep { $sb->{$_} } keys %$tb;
      printf "%d\n", $in * 100 / $n;
    }
  '
}
