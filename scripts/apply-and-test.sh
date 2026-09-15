#!/usr/bin/env bash
# Apply SEARCH/REPLACE blocks from a model patch file to a source directory,
# run pytest against the patched copy, and emit a machine-readable verdict.
# Handles empty SEARCH, SEARCH not in source, ambiguous SEARCH, no blocks at
# all, a REFUSE line, pytest timeout and interpreter override.
#
# Usage:
#   apply-and-test.sh [--test-script NAME] [--timeout SECS] [--out DIR] <source-dir> <patch-file>
#
# Args:
#   <source-dir>   directory containing source.py and test_source.py (override
#                  test filename via --test-script). Original files are not
#                  modified; the patched copy lives in --out (or a temp dir).
#   <patch-file>   file containing SEARCH/REPLACE blocks. Use - for stdin.
#
# Flags:
#   --test-script NAME  test file to execute (default: test_source.py)
#   --timeout SECS      pytest timeout in seconds (default: 30)
#   --out DIR           where to write the patched copy (default: mktemp -d)
#   --source-name NAME  filename inside source-dir to patch (default: source.py)
#
# Env:
#   APPLY_AND_TEST_PYTHON  python interpreter for pytest (default: $(command -v python3))
#
# Exit codes / verdict mapping:
#   0  PASS     all tests pass after patching
#   1  FAIL     pytest returned non-zero
#   2  PARSE    no SEARCH/REPLACE blocks found and no REFUSE line
#   3  APPLY    a block could not be applied (empty / unmatched / ambiguous)
#   4  TIMEOUT  pytest exceeded the timeout
#   5  REFUSE   model emitted a REFUSE: line and no blocks
#   6  USAGE    bad invocation
#
# Output:
#   `VERDICT: <PASS|FAIL|PARSE|APPLY|TIMEOUT|REFUSE>` on stdout for every exit
#   except USAGE (6), which had no run to report on; non-PASS adds
#   `DETAIL: <one-line context>` (pytest's last line on FAIL/TIMEOUT).
#
# Security note: this executes model-generated Python via pytest on the host
# with no sandboxing. For untrusted model output or third-party fixtures, run
# inside a container or with seccomp/resource caps.

set -uo pipefail

test_script="test_source.py"
source_name="source.py"
timeout_secs=30
out_dir=""
source_dir=""
patch_file=""

usage() {
  cat >&2 <<'EOF'
usage: apply-and-test.sh [--test-script NAME] [--timeout SECS] [--out DIR] [--source-name NAME] <source-dir> <patch-file>
  patch-file may be '-' to read from stdin
EOF
  exit 6
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --test-script) test_script="$2"; shift 2 ;;
    --timeout)     timeout_secs="$2"; shift 2 ;;
    --out)         out_dir="$2"; shift 2 ;;
    --source-name) source_name="$2"; shift 2 ;;
    -h|--help)     usage ;;
    --*)           echo "unknown flag: $1" >&2; usage ;;
    *)
      if [[ -z "$source_dir" ]]; then source_dir="$1"
      elif [[ -z "$patch_file" ]]; then patch_file="$1"
      else echo "too many positional args" >&2; usage; fi
      shift
      ;;
  esac
done

[[ -n "$source_dir" && -n "$patch_file" ]] || usage
[[ -d "$source_dir" ]] || { echo "source-dir not a directory: $source_dir" >&2; exit 6; }
[[ -f "$source_dir/$source_name" ]] || { echo "missing $source_name in $source_dir" >&2; exit 6; }
[[ -f "$source_dir/$test_script" ]] || { echo "missing $test_script in $source_dir" >&2; exit 6; }
command -v perl >/dev/null || { echo "perl not on PATH" >&2; exit 6; }

py="${APPLY_AND_TEST_PYTHON:-$(command -v python3 2>/dev/null)}"
[[ -n "$py" && -x "$py" ]] || { echo "python3 not on PATH (set APPLY_AND_TEST_PYTHON to override)" >&2; exit 6; }

# Read the patch (file or stdin).
if [[ "$patch_file" == "-" ]]; then
  patch_text=$(cat)
else
  [[ -f "$patch_file" ]] || { echo "patch-file not found: $patch_file" >&2; exit 6; }
  patch_text=$(cat "$patch_file")
fi

emit() {
  local verdict="$1" detail="${2:-}"
  printf 'VERDICT: %s\n' "$verdict"
  [[ -n "$detail" ]] && printf 'DETAIL: %s\n' "$detail"
}

# The model may opt out of patching by emitting `REFUSE: <reason>`.
has_refuse=$(printf '%s' "$patch_text" | awk '
  toupper($0) ~ /^[[:space:]]*REFUSE[: ]/ { print "1"; exit }
')

# Each block is emitted as two NUL-terminated records (search, replace): NUL
# cannot collide with newlines or equals signs inside block content. `-CSD`
# so non-ASCII identifiers in model patches round-trip verbatim.
blocks_file=$(mktemp)
patched_file=$(mktemp)
# One EXIT trap for every tempfile, including the not-yet-created ones; a
# later phase re-setting the trap leaked $patched_file. Unset vars are skipped.
log_file=""
next_file=""
cleanup() {
  rm -f "$blocks_file" "$patched_file"
  [[ -n "$log_file" ]] && rm -f "$log_file"
  [[ -n "$next_file" ]] && rm -f "$next_file"
  return 0
}
trap cleanup EXIT
printf '%s' "$patch_text" | perl -CSD -0777 -ne '
  while (/<{5,}\s*SEARCH\s*\n(.*?)\n={5,}\s*\n(.*?)\n>{5,}\s*REPLACE/sg) {
    print $1, "\0", $2, "\0";
  }
' > "$blocks_file"

block_bytes=$(wc -c < "$blocks_file" | tr -d ' ')

if [[ "$block_bytes" == "0" ]]; then
  if [[ -n "$has_refuse" ]]; then
    emit REFUSE "model emitted REFUSE line and no SEARCH/REPLACE blocks"
    exit 5
  fi
  emit PARSE "no SEARCH/REPLACE blocks in patch"
  exit 2
fi

# An ambiguous SEARCH (>1 match) returns APPLY rather than patching the first
# occurrence: the format requires unique context, so it is a prompt-compliance
# failure. Source content lives in $patched_file, not a string variable:
# command substitution and here-strings both mangle trailing newlines.
cp "$source_dir/$source_name" "$patched_file"

# `read -d ''` reads up to NUL.
exec 3< "$blocks_file"
block_idx=0
while IFS= read -r -d '' search <&3 && IFS= read -r -d '' replace <&3; do
  block_idx=$((block_idx + 1))
  if [[ -z "$search" ]]; then
    emit APPLY "block $block_idx: empty SEARCH"
    exit 3
  fi
  # Literal index() match in perl: BSD awk rejects literal newlines in -v
  # values. Reads the file directly to preserve trailing newlines.
  count=$(SEARCH="$search" perl -CSD -0777 -e '
    my $text = do { local $/; <STDIN> };
    my $s = $ENV{SEARCH};
    my $c = 0;
    my $pos = 0;
    while ((my $i = index($text, $s, $pos)) >= 0) {
      $c++;
      $pos = $i + length($s);
      last if length($s) == 0;
    }
    print $c;
  ' < "$patched_file")
  if [[ "$count" == "0" ]]; then
    snippet=$(printf '%s' "$search" | head -1 | cut -c1-60)
    emit APPLY "block $block_idx: SEARCH not found ($snippet)"
    exit 3
  fi
  if [[ "$count" -gt 1 ]]; then
    snippet=$(printf '%s' "$search" | head -1 | cut -c1-60)
    emit APPLY "block $block_idx: SEARCH ambiguous ($count matches) ($snippet)"
    exit 3
  fi
  # A literal-quoted perl substitution so regex metacharacters in SEARCH are
  # not interpreted, written to a sibling file and rotated for byte-exactness.
  # No `set -e` here, so the rotation is guarded: a failed perl leaves a
  # truncated $next_file that mv would silently promote.
  next_file=$(mktemp)
  if ! SEARCH="$search" REPLACE="$replace" perl -CSD -0777 -e '
    my $text = do { local $/; <STDIN> };
    my $s = $ENV{SEARCH};
    my $r = $ENV{REPLACE};
    my $idx = index($text, $s);
    if ($idx >= 0) {
      $text = substr($text, 0, $idx) . $r . substr($text, $idx + length($s));
    }
    print $text;
  ' < "$patched_file" > "$next_file"; then
    emit APPLY "block $block_idx: substitution failed writing patched copy"
    exit 3
  fi
  mv "$next_file" "$patched_file" || { emit APPLY "block $block_idx: failed to update patched file"; exit 3; }
  next_file=""
done
exec 3<&-

# The whole source-dir is copied so sibling files (conftest.py, fixtures,
# helper modules) keep their dependencies; then <source_name> is overwritten.
if [[ -z "$out_dir" ]]; then
  out_dir=$(mktemp -d)
  echo "patched-out: $out_dir" >&2
fi
mkdir -p "$out_dir"
cp -R "$source_dir/." "$out_dir/"
cp "$patched_file" "$out_dir/$source_name"

# `timeout` is coreutils, not part of the BSD baseline. pytest is invoked as
# a python module so only the chosen interpreter matters.
log_file=$(mktemp)

run_pytest() {
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=5 "$timeout_secs" "$py" -m pytest -q --no-header "$test_script" >"$log_file" 2>&1
  else
    # No timeout on the BSD baseline: an infinite loop hangs the caller.
    "$py" -m pytest -q --no-header "$test_script" >"$log_file" 2>&1
  fi
}

(cd "$out_dir" && run_pytest)
pytest_rc=$?

# coreutils timeout returns 124 on timeout, 137 on SIGKILL after kill-after.
if [[ "$pytest_rc" == "124" || "$pytest_rc" == "137" ]]; then
  emit TIMEOUT "pytest exceeded ${timeout_secs}s"
  exit 4
fi

last_line=$(tail -1 "$log_file" 2>/dev/null | tr -d '\r')
if [[ "$pytest_rc" == "0" ]]; then
  emit PASS "$last_line"
  exit 0
fi
emit FAIL "$last_line"
exit 1
