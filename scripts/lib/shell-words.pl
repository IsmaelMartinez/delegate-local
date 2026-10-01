#!/usr/bin/env perl
# Shell-word tokenizer for delegate-boundary-hook.sh (#562). Reads one Bash
# command on stdin and splits it into segments, one per separator character
# (; & | ( ) newline and a bare { or }), so `&&` is two separators with an
# empty segment between. Nothing is expanded or run.
#
# With no argument it prints the classification surface: each segment's words
# with every quoted span reduced to a space, one segment per line, then 0x1e,
# the separator characters in order, then 0x1e. With a segment index N
# (0-based) it prints a `TARGET\t<key>` line (what the segment posts to),
# then the text that segment posts: `FILE\t<path>`, `NONE`, `HELP` (the
# segment asks for its command's help and posts nothing), or
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
  return (0) unless $s =~ /\G\$\([ \t]*cat[ \t]+<<(-?)[ \t]*(?:'([^']*)'|"([^"]*)"|(\\?)(\w+))[ \t]*\n/gc;
  my ($dash, $quoted) = ($1, !defined $5 || $4 ne '');
  my $delim = defined $2 ? $2 : defined $3 ? $3 : $5;
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
    if ($s =~ /\G<<(-?)[ \t]*(?:'([^']*)'|"([^"]*)"|(\\?)(\w+))/gc) {
      push @pend, [scalar(@segs), $1, defined $2 ? $2 : defined $3 ? $3 : $5, !defined $5 || $4 ne ''];
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

# Printed first: `TARGET\t<key>`, what the segment posts to (#563), so a
# pending marker is reused only by a retry of the same post. Read from the
# words, never a regex over the line: a git commit names no target (its
# project is the key); a gh/glab post names its positional arguments after
# the subcommand (a PR or issue number, URL or branch, a release tag, the
# `gh api` endpoint), its --repo, and the `gh api` fields that pick a
# thread. Values of the options that take one (bodies, files, titles,
# headers) and redirections are skipped, as are words before the command
# (env assignments, sudo, timeout). Which options take a value is per
# command, as `gh <cmd> --help` and `glab <cmd> --help` list them: a short
# flag is overloaded (`-r` is --reviewer on `gh pr create` but the boolean
# --request-changes on `gh pr review`, `-p` --project there but the boolean
# --prerelease on `gh release create`), so one global table swallowed the
# word after a boolean as its value. An unlisted command knows only --repo.
my %value_flags = (
  'gh pr create'      => '-a --assignee --attach -B --base -b --body -F --body-file -H --head -l --label -m --milestone -p --project --recover -r --reviewer -T --template -t --title -R --repo',
  'gh pr comment'     => '--attach -b --body -F --body-file -R --repo',
  'gh pr review'      => '-b --body -F --body-file -R --repo',
  'gh issue create'   => '-a --assignee --attach --blocked-by --blocking -b --body -F --body-file -l --label -m --milestone --parent -p --project --recover -T --template -t --title --type -R --repo',
  'gh issue comment'  => '--attach -b --body -F --body-file -R --repo',
  'gh release create' => '--discussion-category -n --notes -F --notes-file --notes-start-tag --target -t --title -R --repo',
  'gh api'            => '--cache -F --field -H --header --hostname --input -q --jq -X --method -p --preview -f --raw-field -t --template',
  'glab mr create'    => '-a --assignee --attach -d --description --description-file -H --head -l --label -m --milestone --recover -i --related-issue -R --repo --reviewer -s --source-branch -b --target-branch --template -t --title',
  'glab mr note'      => '--attach --file --line -m --message --old-line --reply -R --repo',
  'glab issue note'   => '--attach -m --message -R --repo',
);
#
# A segment asking for its command's help posts nothing, so `HELP` follows
# the TARGET line in place of a body. `--help` or `-h` counts only as an
# option word of its own: `-h` is help on every classified gh, glab and git
# commit command, while the value of a flag that takes one (`--body --help`,
# `-m -h`, or a cluster ending in one such as `-dt --help`) is posted text,
# and anything after `--` is an argument. A cluster holding h (`-dh`) is
# left a boundary: failing closed costs a nudge, failing open a bypass.
my @tgt;
my $help = 0;
my $c = 0;
$c++ while $c < @W && $W[$c][0] !~ m{(?:\A|/)(?:git|gh|glab)\z};
if ($c < @W && $W[$c][0] =~ m{(?:\A|/)git\z}) {
  # git's global options, then commit's own; a short cluster takes the next
  # word when its first value letter ends it (`-am msg`).
  my %gv = map { $_ => 1 } qw(-C -c --git-dir --work-tree --namespace);
  my %cv = map { $_ => 1 } qw(-m --message -F --file -c --reedit-message -C --reuse-message
    --author --date --fixup --squash -t --template --cleanup --trailer --pathspec-from-file);
  my $sub = 0;
  for (my $k = $c + 1; $k < @W; $k++) {
    my $t = $W[$k][0];
    last if $t eq '--';
    if ($t eq '--help' || $t eq '-h') { $help = 1; last }
    if (substr($t, 0, 1) ne '-') { next if $sub; last if $t ne 'commit'; $sub = 1; next }
    $k++ if $sub ? ($cv{$t} || $t =~ /\A-[^-mFcCt]*[mFcCt]\z/) : $gv{$t};
  }
} elsif ($c < @W && $W[$c][0] =~ m{(?:\A|/)(?:gh|glab)\z}) {
  my $tool = $W[$c][0] =~ m{glab\z} ? 'glab' : 'gh';
  my $api = $c + 1 < @W && $W[$c + 1][0] eq 'api';
  my $k = $c + ($api ? 2 : 3);
  my $cmd = $api ? 'gh api' : join(' ', $tool, map { $k - 2 + $_ < @W ? $W[$k - 2 + $_][0] : '' } 0, 1);
  # `glab mr discussion note` is the note command under another name.
  if ($cmd =~ /\Aglab (mr|issue) discussion\z/ && $k < @W && $W[$k][0] eq 'note') { $cmd = "glab $1 note"; $k++ }
  $k++ if $cmd eq 'glab mr note' && $k < @W && $W[$k][0] eq 'create';
  # A command with no table still never keys on a body-ish value.
  my %takes_value = map { $_ => 1 } split ' ',
    ($value_flags{$cmd} // '-R --repo --body --message --notes --title --field --raw-field');
  my $ended = 0;
  for (; $k < @W; $k++) {
    my $t = $W[$k][0];
    $help = 1 if !$ended && ($t eq '--help' || $t eq '-h');
    $ended = 1 if $t eq '--';
    if ($t =~ /\A--repo=/) { push @tgt, 'repo=' . substr($t, 7); next }
    if ($t =~ /\A[0-9]*(?:<<?|>>?)&?\z/) { $k++; next }   # a bare redirection and its target
    next if $t =~ /\A[0-9]*[<>]/;                        # an attached one
    if (substr($t, 0, 1) eq '-') {
      # A shorthand cluster parses as pflag does: booleans, then at most one
      # flag that takes a value, which takes the rest of the cluster or, when
      # it ends the cluster, the next word (`-dt --help` is a title).
      if ($t =~ /\A-([A-Za-z]{2,})\z/) {
        my $s = $1;
        my $at = -1;
        for my $i (0 .. length($s) - 1) {
          if ($takes_value{'-' . substr($s, $i, 1)}) { $at = $i; last }
        }
        next unless $at == length($s) - 1;
        $t = '-' . substr($s, $at, 1);
      }
      next if index($t, '=') >= 0 || !$takes_value{$t} || $k + 1 >= @W;
      my $v = $W[++$k][0];
      if ($t eq '-R' || $t eq '--repo') { push @tgt, "repo=$v" }
      elsif ($t =~ /\A(?:-f|-F|--field|--raw-field)\z/
             && $v =~ /\A(?:in_reply_to|number|pull_number|issue_number|comment_id)=/) { push @tgt, $v }
      next;
    }
    push @tgt, $t;
  }
}
my $key = join(' ', sort @tgt); $key =~ tr/\t\n/  /;
print "TARGET\t$key\n";
if ($help) { print "HELP\n"; exit 0 }
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
