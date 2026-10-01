#!/usr/bin/env perl
# Shell-word tokenizer for delegate-boundary-hook.sh (#562). Reads one Bash
# command on stdin and splits it into segments, one per separator character
# (; & | ( ) newline and a bare { or }), so `&&` is two separators with an
# empty segment between. Nothing is expanded or run.
#
# With no argument it prints the classification surface: each segment's words
# with every quoted span reduced to a space, one segment per line, then 0x1e,
# the separator characters in order, then 0x1e. With a segment index N
# (0-based) it prints the text that segment posts: `FILE\t<path>`, `NONE`, or
# `INLINE\t<1 if literal, else 0>\n<text>`. A body is unmeasurable (literal 0)
# when it carries `$` or a backtick the shell would expand; the one resolved
# shape is `"$(cat <<EOF ... EOF\n)"`, whose heredoc is the text. Heredoc
# bodies are read by a line scan and belong to the segment that opened them,
# so `--body-file - <<EOF` posts its heredoc. Every regex here is anchored
# with \G or matches a single token, with no nested quantifier.
use strict;
use warnings;

binmode STDIN; binmode STDOUT;
my $want = @ARGV ? $ARGV[0] : undef;
my $s = do { local $/; <STDIN> };
$s = '' unless defined $s;
# No real command line is decided by anything past 32 KB.
$s = substr($s, 0, 32768) if length($s) > 32768;
my $n = length $s;

my (@segs, @seps, @cur, @pend);
my ($w, $wb, $lit, $in) = ('', '', 1, 0);   # word text, blanked form, literal, started
sub endword { $w =~ tr/\0//d; push @cur, [$w, $wb, $lit] if $in; ($w, $wb, $lit, $in) = ('', '', 1, 0) }
sub endseg { endword(); push @segs, { w => [@cur], hd => [] }; @cur = () }

# Lines from $p up to the one equal to $delim (leading tabs stripped from
# every line under <<-). Returns the body, the position after the terminator
# line, and whether the terminator was found; unterminated, the rest is body.
sub heredoc {
  my ($p, $delim, $dash) = @_;
  my $body = '';
  while ($p < $n) {
    my $e = index($s, "\n", $p);
    my $line = $e < 0 ? substr($s, $p) : substr($s, $p, $e - $p);
    $p = $e < 0 ? $n : $e + 1;
    $line =~ s/^\t+// if $dash;
    return ($body, $p, 1) if $line eq $delim;
    $body .= "$line\n";
  }
  return ($body, $p, 0);
}

# `$(cat <<EOF ... EOF )` inside double quotes, at $i: (1, body, quoted, end)
# or (0). The body loses its trailing newlines, as command substitution does.
sub cat_heredoc {
  my ($i) = @_;
  pos($s) = $i;
  return (0) unless $s =~ /\G\$\([ \t]*cat[ \t]+<<(-?)[ \t]*(?:'([^']*)'|"([^"]*)"|\\?(\w+))[ \t]*\n/gc;
  my ($dash, $quoted) = ($1, !defined $4);
  my $delim = defined $2 ? $2 : defined $3 ? $3 : $4;
  my ($body, $p, $found) = heredoc(pos($s), $delim, $dash);
  return (0) unless $found;
  pos($s) = $p;
  return (0) unless $s =~ /\G[ \t\n]*\)/gc;
  my $l = length $body;
  $l-- while $l > 0 && substr($body, $l - 1, 1) eq "\n";
  return (1, substr($body, 0, $l), $quoted, pos($s));
}

my %esc = (n => "\n", t => "\t", r => "\r", a => "\a", b => "\b", e => "\e",
           E => "\e", f => "\f", v => "\013", "\\" => "\\", "'" => "'", '"' => '"');
my $i = 0;
while ($i < $n) {
  pos($s) = $i;
  # A run of ordinary characters in one step.
  if ($s =~ /\G([^ \t\n;&|()<{}'"\\\$`#]+)/gc) { $w .= $1; $wb .= $1; $in = 1; $i = pos($s); next }
  my $c = substr($s, $i, 1);
  my $c2 = substr($s, $i, 2);
  if ($c eq ' ' || $c eq "\t") { endword(); $i++; next }
  if ($c eq '#' && !$in) { my $p = index($s, "\n", $i); $i = $p < 0 ? $n : $p; next }
  if ($c eq '\\') {
    my $e = substr($s, $i + 1, 1); $i += 2;
    next if $e eq "\n" || $e eq '';
    $w .= $e; $in = 1; next;
  }
  if ($c eq "'") {
    my $p = index($s, "'", $i + 1); $p = $n if $p < 0;
    $w .= substr($s, $i + 1, $p - $i - 1); $wb .= ' '; $in = 1; $i = $p + 1; next;
  }
  if ($c2 eq "\$'") {
    $i += 2; $in = 1; $wb .= ' ';
    while ($i < $n) {
      pos($s) = $i;
      if ($s =~ /\G([^'\\]+)/gc) { $w .= $1; $i = pos($s); next }
      last if substr($s, $i, 1) eq "'";
      my $e = substr($s, $i + 1, 1); $i += 2;
      pos($s) = $i - 1;
      if (exists $esc{$e}) { $w .= $esc{$e} }
      elsif ($e eq 'x' && $s =~ /\Gx([0-9A-Fa-f]{1,2})/gc) { $w .= chr(hex $1); $i = pos($s) }
      elsif ($s =~ /\G([0-7]{1,3})/gc) { $w .= chr(oct($1) & 255); $i = pos($s) }
      else { $w .= "\\$e" }
    }
    $i++; next;
  }
  if ($c eq '"') {
    $i++; $in = 1; $wb .= ' ';
    while ($i < $n) {
      pos($s) = $i;
      if ($s =~ /\G([^"\\\$`]+)/gc) { $w .= $1; $i = pos($s); next }
      my $d = substr($s, $i, 1);
      last if $d eq '"';
      if ($d eq '\\') {
        my $e = substr($s, $i + 1, 1); $i += 2;
        next if $e eq "\n";
        $w .= ($e =~ /[\$`"\\]/ ? '' : '\\') . $e; next;
      }
      if (substr($s, $i, 2) eq '$(') {
        my ($ok, $body, $quoted, $end) = cat_heredoc($i);
        if ($ok) { $w .= $body; $lit = 0 if !$quoted && $body =~ /[\$`]/; $i = $end; next }
        # Any other substitution is opaque: consumed to its closing paren to
        # keep quote parity, and the word is no longer literal.
        $lit = 0; $w .= '$('; $i += 2;
        my $dep = 1;
        while ($i < $n && $dep) {
          my $ch = substr($s, $i++, 1);
          $dep++ if $ch eq '('; $dep-- if $ch eq ')';
          $w .= $ch;
        }
        next;
      }
      if ($d eq '`') {
        my $p = index($s, '`', $i + 1); $p = $n - 1 if $p < 0;
        $w .= substr($s, $i, $p - $i + 1); $lit = 0; $i = $p + 1; next;
      }
      $lit = 0 if $d eq '$';
      $w .= $d; $i++;
    }
    $i++; next;
  }
  if ($c eq '`') {
    my $p = index($s, '`', $i + 1); $p = $n - 1 if $p < 0;
    $w .= substr($s, $i, $p - $i + 1); $wb .= ' '; $lit = 0; $in = 1; $i = $p + 1; next;
  }
  if ($c eq '$') { $w .= $c; $wb .= $c; $lit = 0; $in = 1; $i++; next }
  if (substr($s, $i, 3) eq '<<<') { endword(); $i += 3; next }
  if ($c2 eq '<<') {
    endword(); pos($s) = $i;
    if ($s =~ /\G<<(-?)[ \t]*(?:'([^']*)'|"([^"]*)"|\\?(\w+))/gc) {
      push @pend, [scalar(@segs), $1, defined $2 ? $2 : defined $3 ? $3 : $4, !defined $4];
      $i = pos($s); next;
    }
    $i += 2; next;
  }
  # `2>&1` and `&>file` are redirections, not separators.
  if ($c eq '&' && (($in && $w =~ /[<>]\z/) || substr($s, $i + 1, 1) eq '>')) {
    $w .= $c; $wb .= $c; $in = 1; $i++; next;
  }
  if ($c =~ /[;&|()\n]/ || ($c =~ /[{}]/ && !$in && substr($s, $i + 1, 1) =~ /\A[ \t\n;]?\z/)) {
    endseg(); push @seps, $c; $i++;
    if ($c eq "\n") {
      for my $h (@pend) {
        my ($seg, $dash, $delim, $quoted) = @$h;
        my ($body, $p) = heredoc($i, $delim, $dash);
        $i = $p;
        push @{ $segs[$seg]{hd} }, [$body, $quoted] if $seg < @segs;
      }
      @pend = ();
    }
    next;
  }
  $w .= $c; $wb .= $c; $in = 1; $i++;
}
endseg();

unless (defined $want) {
  my @lines = map { my $l = join(' ', map { $_->[1] } @{ $_->{w} }); $l =~ tr/\x1e\n/  /; $l } @segs;
  print join("\n", @lines), "\x1e", join('', @seps), "\x1e";
  exit 0;
}
exit 0 unless $want =~ /\A[0-9]+\z/ && $want < @segs;

# The posted body of segment $want. A body file wins over an inline body;
# repeated inline bodies are joined with a blank line as git does with -m.
# -f/-F and their long forms are gh api FIELD flags whose argument is
# key=value, and only the body key is a body (#461): `body=@path` names a
# file. -F without an = keeps its file meaning, being also the short
# --body-file. -m and -am are git commit and glab note.
my $sg = $segs[$want];
my @W = @{ $sg->{w} };
my ($file, @body) = ('');
my $blit = 1;
for (my $k = 0; $k < @W; $k++) {
  my ($t, $b) = @{ $W[$k] };
  my ($name, $val, $vlit, $att);
  if ($b =~ /\A--(body-file|raw-field|field|body|message)(=|\z)/) {
    $name = $1; $att = $2 eq '=';
    $val = substr($t, length($name) + 3) if $att;
  } elsif ($b =~ /\A-(?:a|s|as|sa)?([mbfF])/) {
    $name = $1;
    my $rest = substr($t, $+[0]);
    ($att, $val) = (1, $rest) if $rest ne '';
  } else { next }
  $vlit = $W[$k][2];
  unless ($att) { next if $k + 1 >= @W; $k++; ($val, $vlit) = @{ $W[$k] }[0, 2] }
  my $isfield = $name =~ /\A(?:raw-field|field|f|F)\z/;
  my $isfile = $name =~ /\A(?:body-file|F)\z/;
  if ($isfield && $val =~ /\A([A-Za-z0-9_-]+)=/) {
    next unless $1 eq 'body';
    my $v = substr($val, 5);
    if (substr($v, 0, 1) eq '@') { $file = substr($v, 1) if $file eq '' }
    else { push @body, $v; $blit &&= $vlit }
    next;
  }
  if ($isfile) { $file = $val if $file eq ''; next }
  next if $isfield;
  push @body, $val; $blit &&= $vlit;
}
if ($file eq '-' && @{ $sg->{hd} }) {
  my ($hb, $quoted) = @{ $sg->{hd}[0] };
  print "INLINE\t", (($quoted || $hb !~ /[\$`]/) ? 1 : 0), "\n", $hb;
} elsif ($file ne '') { print "FILE\t$file\n" }
elsif (@body) { print "INLINE\t", ($blit ? 1 : 0), "\n", join("\n\n", @body) }
else { print "NONE\n" }
