#!/usr/bin/env perl
# Approved-text scanner for delegate-boundary-hook.sh (#607). Usage:
#   perl transcript-approved.pl <transcript.jsonl> <min_pct> <tail_bytes> < body
# Exits 0 when the body on stdin was already shown to the human: at least
# <min_pct> of its word bigrams (lib/bigrams.pl, the measurement behind a
# verdict's `final_preexisting`) sit in the text of ONE assistant message
# that a genuine human turn followed. Exits 1 otherwise, and on any failure
# (no file, a parse error, no body), so the hook goes on to its normal deny.
#
# Only the last <tail_bytes> of the transcript are read, from the first whole
# line after the seek, which bounds the worst case on a 70 MB session. Lines
# are filtered on a substring before any JSON decode: a quoted key or value
# such as "tool_result" can only appear unescaped as JSON structure, never
# inside a string, so the test cannot drop a line it should keep. Decoding
# every line of the largest transcript took 15-18 s; the filter cut it to
# about 1 s.
#
# An assistant message is its text blocks, grouped by message.id (each block
# is its own line), in a non-sidechain entry. A genuine human turn is a
# type:"user" entry that is not a sidechain, isMeta or isCompactSummary,
# carries no tool_result, and whose text does not open with `<`,
# `[Request interrupted` or `Caveat:`; or a queued_command attachment in
# commandMode "prompt" that is not meta and does not open with `<`.
use strict;
use warnings;
use JSON::PP ();

my ($path, $min, $tail) = @ARGV;
exit 1 unless defined $path && defined $min && $min =~ /^[0-9]+$/;
$tail = 8388608 unless defined $tail && $tail =~ /^[0-9]+$/ && $tail > 0;
my $lib = __FILE__; $lib =~ s{[^/]*$}{}; $lib = "./" if $lib eq "";
$lib = "./$lib" unless $lib =~ m{^/};
eval { require "${lib}bigrams.pl"; 1 } or exit 1;

my $body = do { local $/; binmode STDIN; <STDIN> };
exit 1 unless defined $body;
my $tb = bigrams($body);
exit 1 unless %$tb;

open(my $fh, "<", $path) or exit 1;
binmode $fh;
my $size = -s $fh;
exit 1 unless defined $size;
if ($size > $tail) {
  # Land on a line start: a byte before the window that is a newline means
  # the window opens on a whole line; otherwise the first line is partial.
  seek($fh, $size - $tail - 1, 0) or exit 1;
  my $prev;
  read($fh, $prev, 1) or exit 1;
  <$fh> unless $prev eq "\n";
}

my $json = JSON::PP->new->utf8;
sub text_of {
  my $c = shift;
  return $c if !ref $c;
  return undef unless ref $c eq "ARRAY";
  my @t;
  for my $b (@$c) {
    next unless ref $b eq "HASH";
    return undef if ($b->{type} // "") eq "tool_result";
    push @t, $b->{text} if ($b->{type} // "") eq "text" && defined $b->{text} && !ref $b->{text};
  }
  return join("\n", @t);
}
sub genuine {
  my $t = shift;
  return 0 unless defined $t;
  $t =~ s/^\s+//;
  return 0 if $t eq "";
  return 0 if substr($t, 0, 1) eq "<";
  return 0 if index($t, "[Request interrupted") == 0 || index($t, "Caveat:") == 0;
  return 1;
}

# JSON::PP decodes about 1 MB a second, so an assistant line is not decoded
# unless it could match. A body bigram can only be in a message's text when
# both its words occur in the raw lines, as substrings of the lowercased
# JSON (an encoder escapes no ASCII letter or digit), so the share of body
# bigrams whose two words both occur there bounds the containment from above,
# and a message whose bound is under <min_pct> is dropped undecoded.
my $n_bi = scalar keys %$tb;
my @pairs = map { [split / /] } keys %$tb;
my %words; $words{$_->[0]} = $words{$_->[1]} = 1 for @pairs;
sub bound_ok {
  my $raw = lc shift;
  my %has = map { $_ => (index($raw, $_) >= 0) } keys %words;
  my $in = grep { $has{$_->[0]} && $has{$_->[1]} } @pairs;
  return int($in * 100 / $n_bi) >= $min;
}

my (@order, %raw);   # assistant messages (raw lines by message.id) awaiting a human turn
while (my $line = <$fh>) {
  next if index($line, '"isSidechain":true') >= 0
       || index($line, '"isMeta":true') >= 0
       || index($line, '"tool_result"') >= 0;
  if (index($line, '"type":"assistant"') >= 0) {
    next unless index($line, '"type":"text"') >= 0;
    # message.id is the first "id" inside "message", before any nested
    # object; a quote inside a string is escaped, so this is structure.
    next unless $line =~ /"message":\{[^{}]*?"id":"([^"\\]+)"/;
    push @order, $1 unless exists $raw{$1};
    push @{ $raw{$1} }, $line;
    next;
  }
  my $queued = index($line, '"queued_command"') >= 0;
  next unless $queued || index($line, '"type":"user"') >= 0;
  # Nothing is waiting, so no turn can approve anything.
  next unless @order;
  # The bulk of what survives in a long session is task notifications and
  # system text, which can never be a human turn: a queued command that is
  # not a prompt, and a user entry whose content opens with `<`. Skipped
  # before the decode, as is the base64 of a pasted image, the one large
  # payload a genuine turn can carry (a single class, linear).
  next if $queued && index($line, '"commandMode":"prompt"') < 0;
  next if index($line, '"content":"<') >= 0 || index($line, '"content":[{"type":"text","text":"<') >= 0;
  # A message that cannot reach the threshold never will, whatever turn
  # follows it.
  my @cand = grep { bound_ok(join("", @{ $raw{$_} })) } @order;
  unless (@cand) { @order = (); %raw = (); next }
  $line =~ s/"data":"[A-Za-z0-9+\/=]{256,}"/"data":""/g if length($line) > 65536;
  my $e = eval { $json->decode($line) };
  next unless ref $e eq "HASH";
  next if $e->{isSidechain} || $e->{isMeta};
  my $type = $e->{type} // "";
  my $human = 0;
  if ($type eq "user") {
    next if $e->{isCompactSummary};
    my $m = $e->{message};
    $human = ref $m eq "HASH" && genuine(text_of($m->{content}));
  } elsif ($type eq "attachment") {
    my $a = $e->{attachment};
    $human = ref $a eq "HASH" && ($a->{type} // "") eq "queued_command"
      && ($a->{commandMode} // "") eq "prompt" && !$a->{isMeta}
      && genuine(text_of($a->{prompt}));
  }
  next unless $human;
  for my $id (@cand) {
    my @t;
    for my $l (@{ $raw{$id} }) {
      my $a = eval { $json->decode($l) };
      next unless ref $a eq "HASH" && !$a->{isSidechain} && ($a->{type} // "") eq "assistant"
        && ref $a->{message} eq "HASH" && ($a->{message}{id} // "") eq $id;
      my $t = text_of($a->{message}{content});
      push @t, $t if defined $t && $t ne "";
    }
    my $pct = @t ? containment_pct($tb, join("\n", @t)) : undef;
    exit 0 if defined $pct && $pct >= $min;
  }
  @order = (); %raw = ();
}
exit 1;
