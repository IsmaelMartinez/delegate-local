#!/usr/bin/env bash
# Latency harness for the two Bash hooks (#563): delegate-boundary-hook.sh
# (PreToolUse) and delegate-boundary-confirm-hook.sh (PostToolUse). Not a
# test-*.sh file, so CI does not run it; it measures, it asserts nothing.
#
# Three scenarios per hook: a non-boundary call (`ls -la`, the path every Bash
# call pays), a credited post (`gh pr comment` with a delegation in the window,
# so no provider probe runs), and the same post with a 100 KB inline body.
# The boundary hook also times an uncredited enforced post (`gh issue create`,
# no github-issue-body delegation), the deny path that reads the session
# transcript for approved text (#607) before its probe of a closed port. The
# PostToolUse payload of the non-boundary call carries 2 KB of stdout, as a
# real one does. The confirm hook's credited scenarios time the confirmation
# of the marker the boundary hook left in the untimed setup.
#
# The machine running this is often loaded by other jobs, so the baseline and
# the candidate are run interleaved on the same run (A B, then B A, ...) and
# both distributions are reported, never one against a remembered number.
# Every run starts from a fresh scratch data dir; nothing outside a temp dir
# is written, and no provider is contacted (DELEGATE_BASE_URL is a closed
# port, and the credited scenarios never reach the probe).
#
# Usage: bash tests/bench-hooks.sh [-n RUNS] [--base REF|DIR] [--candidate DIR]
#   --base       a git ref of this repo (default origin/main), materialised
#                with `git archive`, or a directory holding scripts/ and prompts/
#   --candidate  a directory holding scripts/ and prompts/ (default this checkout)
#   -n           samples per scenario per variant (default 40)

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runs=40 base="origin/main" cand="$REPO"
while (( $# )); do
  case "$1" in
    -n) runs="$2"; shift 2 ;;
    --base) base="$2"; shift 2 ;;
    --candidate) cand="$2"; shift 2 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "bench-hooks: unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ "$runs" =~ ^[1-9][0-9]*$ ]] || { echo "bench-hooks: -n needs a positive integer" >&2; exit 2; }
command -v jq >/dev/null && command -v perl >/dev/null || { echo "bench-hooks: needs jq and perl" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if [[ -d "$base" ]]; then
  base_dir="$base"
else
  mkdir -p "$work/base"
  git -C "$REPO" archive "$base" scripts prompts | tar -x -C "$work/base" || { echo "bench-hooks: cannot archive $base" >&2; exit 2; }
  base_dir="$work/base"
fi
for d in "$base_dir" "$cand"; do
  [[ -f "$d/scripts/delegate-boundary-hook.sh" && -f "$d/scripts/delegate-boundary-confirm-hook.sh" ]] \
    || { echo "bench-hooks: $d has no hooks under scripts/" >&2; exit 2; }
done

# A git repository as the payload cwd, so the project is derived as in use.
repo="$work/github/bench-repo"
mkdir -p "$repo"
( cd "$repo" && git init -q . && git config user.email b@b.b && git config user.name b \
  && : > f && git add f && git commit -qm init ) >/dev/null 2>&1
proj=bench-repo
sid="0b5e7c1a-3f2d-4e8b-9a61-c0ffee563000"
# A synthetic 12 MB session transcript (#607): the denied scenario reads it
# for text the human already approved, so its cost is the scanner's over the
# default 8 MB tail. Mostly tool calls and results, with assistant text and a
# human turn every block, the mix a long agent session has.
transcript="$work/transcript.jsonl"
perl -e '
  my $pad = "x" x 3000;
  my $usage = q{"usage":{"input_tokens":2,"cache_read_input_tokens":65842,"output_tokens":318}};
  my $i = 0;
  while ((-s STDOUT // 0) < 12 * 1024 * 1024) {
    $i++;
    print qq({"type":"user","isSidechain":false,"message":{"role":"user","content":"carry on with step $i"}}\n);
    print qq({"type":"assistant","isSidechain":false,"message":{"id":"msg_t$i","role":"assistant","content":[{"type":"text","text":"Step $i: the parser reads the attached form and the regression test covers both shapes."}],$usage}}\n);
    print qq({"type":"assistant","isSidechain":false,"message":{"id":"msg_u$i","role":"assistant","content":[{"type":"tool_use","id":"toolu_$i","name":"Bash","input":{"command":"ls"}}],$usage}}\n);
    print qq({"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_$i","content":"$pad"}]}}\n);
  }' > "$transcript"
data="$work/data"

# The scenarios' commands and payloads, written once.
short_body=$(printf 'Fixed in the latest push: the parser now reads the attached form, and the regression test covers both shapes. %.0s' 1 2 3)
big_body=$(perl -e 'my $s = ""; my $i = 0; while (length $s < 102400) { $s .= "word$i lorem ipsum dolor sit amet "; $i++ } print substr($s, 0, 102400)')
pre_payload() { # cmd tool_use_id
  jq -nc --arg cmd "$1" --arg cwd "$repo" --arg sid "$sid" --arg tp "$transcript" --arg id "$2" \
    '{session_id:$sid, transcript_path:$tp, cwd:$cwd, permission_mode:"default", hook_event_name:"PreToolUse",
      tool_name:"Bash", tool_input:{command:$cmd, description:"Run the step"}, tool_use_id:$id}'
}
post_payload() { # cmd tool_use_id stdout
  jq -nc --arg cmd "$1" --arg cwd "$repo" --arg sid "$sid" --arg tp "$transcript" --arg id "$2" --arg out "$3" \
    '{session_id:$sid, transcript_path:$tp, cwd:$cwd, permission_mode:"default", hook_event_name:"PostToolUse",
      tool_name:"Bash", tool_input:{command:$cmd, description:"Run the step"}, tool_use_id:$id,
      tool_response:{stdout:$out, stderr:"", interrupted:false, isImage:false}}'
}
listing=$(perl -e 'for (1..30) { printf "-rw-r--r--  1 user  staff  %5d Sep 30 10:%02d file-%02d.txt\n", $_ * 37, $_, $_ }')
pre_payload 'ls -la' toolu_bench_ls > "$work/pre-ls.json"
post_payload 'ls -la' toolu_bench_ls "$listing" > "$work/post-ls.json"
pre_payload "gh pr comment 12 --body \"$short_body\"" toolu_bench_post > "$work/pre-post.json"
post_payload "gh pr comment 12 --body \"$short_body\"" toolu_bench_post "https://github.com/o/r/pull/12#issuecomment-1" > "$work/post-post.json"
pre_payload "gh pr comment 12 --body \"$big_body\"" toolu_bench_big > "$work/pre-big.json"
pre_payload "gh issue create --title t --body \"$short_body\"" toolu_bench_deny > "$work/pre-deny.json"
post_payload "gh pr comment 12 --body \"$big_body\"" toolu_bench_big "https://github.com/o/r/pull/12#issuecomment-2" > "$work/post-big.json"

# The state each sample starts from: an empty data dir holding one unspent
# maintainer-reply delegation for this project and session, and the confirm
# hook's seen file, so the credited path is the one taken.
cat > "$work/reset.sh" <<EOF
rm -rf "$data"; mkdir -p "$data/.boundary-pending" "$data/drafts"
printf '%s\n' "\$(jq -nc --arg ts "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{ts:\$ts, source:"delegate", project:"$proj", session:"$sid", tier:"prose", recipe:"maintainer-reply", exit_status:0, draft_file:"20260930T100000Z-bench.draft.txt"}')" > "$data/metrics.jsonl"
printf 'draft text\n' > "$data/drafts/20260930T100000Z-bench.draft.txt"
: > "$data/.boundary-pending/$sid.seen"
EOF

export DELEGATE_METRICS_FILE="$data/metrics.jsonl"
export DELEGATE_BASE_URL="http://127.0.0.1:9/v1"
unset DELEGATE_PROJECT DELEGATE_BOUNDARY_MODE DELEGATE_BOUNDARY_ENFORCE DELEGATE_LOCAL_NO_METRICS DELEGATE_LOCAL_DATA_DIR

echo "bench-hooks: $runs samples per scenario per variant, interleaved"
echo "  A (baseline):  $base"
echo "  B (candidate): $cand"
# The timing loop is perl: fork + exec of `bash <hook>` with the payload on
# stdin, timed with Time::HiRes, the setup (reset.sh, and for the confirm
# scenarios the boundary hook that leaves the marker) run untimed before each.
perl -MTime::HiRes=time -e '
  my ($runs, $work, $A, $B) = @ARGV;
  my @sc = (
    ["pre",  "non-boundary", "pre-ls.json",   undef],
    ["pre",  "credited",     "pre-post.json", undef],
    ["pre",  "100KB body",   "pre-big.json",  undef],
    ["pre",  "uncredited",   "pre-deny.json", undef],
    ["post", "non-boundary", "post-ls.json",  undef],
    ["post", "credited",     "post-post.json", "pre-post.json"],
    ["post", "100KB body",   "post-big.json",  "pre-big.json"],
  );
  my %hook = (pre => "delegate-boundary-hook.sh", post => "delegate-boundary-confirm-hook.sh");
  sub run_hook { my ($path, $in) = @_;
    my $pid = fork(); die "fork" unless defined $pid;
    if (!$pid) { open STDIN, "<", $in or die; open STDOUT, ">", "/dev/null"; open STDERR, ">", "/dev/null";
                 exec "bash", $path or exit 127 }
    waitpid($pid, 0) }
  my %t;
  for my $s (@sc) {
    my ($h, $name, $in, $pre) = @$s;
    for my $i (1 .. $runs) {
      for my $v ($i % 2 ? ("A", "B") : ("B", "A")) {
        my $dir = $v eq "A" ? $A : $B;
        system("bash", "$work/reset.sh");
        run_hook("$dir/scripts/$hook{pre}", "$work/$pre") if defined $pre;
        my $t0 = time; run_hook("$dir/scripts/$hook{$h}", "$work/$in"); my $dt = (time - $t0) * 1000;
        push @{ $t{"$h|$name|$v"} }, $dt;
      }
    }
  }
  sub pct { my ($p, @x) = @_; @x = sort { $a <=> $b } @x; my $k = int($p / 100 * $#x + 0.5); $x[$k] }
  printf "\n%-6s %-14s %16s %16s %8s\n", "hook", "scenario", "A p50/p95 ms", "B p50/p95 ms", "B/A p50";
  for my $s (@sc) {
    my ($h, $name) = @$s;
    my @a = @{ $t{"$h|$name|A"} }; my @b = @{ $t{"$h|$name|B"} };
    my ($a5, $a9, $b5, $b9) = (pct(50, @a), pct(95, @a), pct(50, @b), pct(95, @b));
    printf "%-6s %-14s %7.1f / %6.1f %7.1f / %6.1f %8.2f\n", $h, $name, $a5, $a9, $b5, $b9, $b5 / $a5;
  }
' "$runs" "$work" "$base_dir" "$cand"
