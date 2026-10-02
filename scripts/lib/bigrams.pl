# Word-bigram containment, the one definition shared by bigram_containment in
# lib/pair-score.sh (a verdict's `final_preexisting`, #588) and
# lib/transcript-approved.pl (the boundary hook's approved-text exemption,
# #607), so "90% of the bigrams" means the same in both. Loaded with
# `require`; defines subs only. A word is a run of ASCII letters and digits,
# lowercased, and every word counts: content words alone would drop the
# "is in" and "to the" that make a bigram a sequence rather than a
# vocabulary. The pattern is a single class, linear.
use strict;
use warnings;

# bigrams TEXT -> hashref of its distinct word bigrams.
sub bigrams {
  my @w = (lc(shift) =~ /[a-z0-9]+/g);
  my %b; $b{"$w[$_ - 1] $w[$_]"} = 1 for 1 .. $#w;
  return \%b;
}

# containment_pct TEXT_BIGRAMS SOURCE_TEXT -> the whole percent of the text's
# bigrams that occur in the source, or undef when the text has none.
sub containment_pct {
  my ($tb, $src) = @_;
  my $n = scalar keys %$tb;
  return undef unless $n;
  my $sb = bigrams($src);
  my $in = grep { $sb->{$_} } keys %$tb;
  return int($in * 100 / $n);
}

1;
