#!/usr/bin/env bash
# Differential test for the #562 tokenizer: runs every hook call in
# test-delegate-boundary-hook.sh through a shim that also runs the call under
# the other scanner (the awk scanners vs scripts/lib/shell-words.pl) against a
# copy of the metrics directory, and compares what each leaves behind: the
# hook's stdout and exit status, the metrics rows and the pending markers
# (timestamps masked). The suite's own assertions still run on the first run.
# Every disagreement must match an entry in the allowlist below, each one a
# command the awk scanners mis-read, and every entry must be used.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
ko() { echo "  FAIL  $1"; fail=$((fail+1)); }

# Fixed substrings of the commands whose outcome may differ, with the reason.
# Each is `substring<TAB>reason`.
allow=(
  $'--body-file - <<\ta stdin heredoc is the posted body, now measured (the awk scanner read "-" as a path)'
  $'git commit -F - <<\tgit commit -F - reads its message from the heredoc, now measured'
  $'--body \'it\'\\\'\'s\tconcatenated quoting is one word (awk measured 2 chars)'
  $'--body="hello\tan attached --body= value is read (awk saw no body)'
  $'--message="fix\tan attached --message= value is read (awk saw no body)'
  $'-m"fix\tan attached -m"x" value is read (awk saw no body)'
  $'--body $\'line\ta $\'...\' body is resolved and measured (awk called it unmeasurable)'
  $'cat <<-EOF\ta <<- terminator is tab-indented; awk never found it and hid the post after it'
)

cat > "$work/shim.sh" <<EOF
#!/usr/bin/env bash
real="$REPO/scripts/delegate-boundary-hook.sh"
log="$work/diff.jsonl"
count="$work/count"
EOF
cat >> "$work/shim.sh" <<'EOF'
input=$(cat)
if [[ "${DELEGATE_BOUNDARY_TOKENIZER:-}" == "1" ]]; then other=0; else other=1; fi
cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)
m="${DELEGATE_METRICS_FILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/metrics.jsonl}"
[[ "$m" != /* && -n "$cwd" ]] && m="$cwd/$m"
d=$(dirname "$m")
snap=""
case "$d" in
  "$HOME/.local/share"*) ;;   # never the live data dir
  *) if [[ ! -e "$d" ]]; then snap=$(mktemp -d); mkdir "$snap/d"
     elif [[ -d "$d" && -r "$d" && -w "$d" ]]; then snap=$(mktemp -d); cp -Rp "$d" "$snap/d" 2>/dev/null || { rm -rf "$snap"; snap=""; }
     fi ;;
esac
dump() { # dir
  [[ -d "$1" ]] || return 0
  ( cd "$1" && find . -type f ! -path './.boundary-hook.lock/*' | LC_ALL=C sort | while IFS= read -r f; do
      printf '== %s\n' "$f"; cat "$f"; printf '\n'
    done ) | sed -E 's/"ts":"[^"]*"/"ts":T/g; s/"epoch":[0-9]+/"epoch":E/g'
}
out_a=$(printf '%s' "$input" | bash "$real"); rc_a=$?
[[ -n "$snap" ]] || { printf '%s' "$out_a"; exit "$rc_a"; }
state_a=$(dump "$d")
out_b=$(printf '%s' "$input" | DELEGATE_BOUNDARY_TOKENIZER=$other DELEGATE_METRICS_FILE="$snap/d/$(basename "$m")" bash "$real"); rc_b=$?
state_b=$(dump "$snap/d")
rm -rf "$snap"
echo x >> "$count"
if [[ "$out_a" != "$out_b" || "$rc_a" != "$rc_b" || "$state_a" != "$state_b" ]]; then
  jq -nc --arg cmd "$(jq -r '.tool_input.command // ""' <<<"$input")" --arg a "$out_a" --arg b "$out_b" \
     --arg sa "$state_a" --arg sb "$state_b" --arg other "$other" \
     '{cmd:$cmd, other:$other, out_a:$a, out_b:$b, state_a:$sa, state_b:$sb}' >> "$log"
fi
printf '%s' "$out_a"
exit "$rc_a"
EOF

: > "$work/diff.jsonl"; : > "$work/count"
BOUNDARY_HOOK_UNDER_TEST="$work/shim.sh" bash "$REPO/tests/test-delegate-boundary-hook.sh" > "$work/suite.log" 2>&1
suite_rc=$?
if (( suite_rc == 0 )); then ok "the hook suite passes with every call run twice"
else ko "the hook suite passes with every call run twice ($(tail -1 "$work/suite.log"))"; grep FAIL "$work/suite.log"; fi

compared=$(wc -l < "$work/count" | tr -d ' ')
(( compared > 250 )) && ok "compared $compared hook calls" || ko "compared only $compared hook calls"

used=()
unexplained=0
while IFS= read -r row; do
  c=$(jq -r .cmd <<<"$row")
  hit=""
  for i in "${!allow[@]}"; do
    [[ "$c" == *"${allow[i]%%	*}"* ]] && { hit=$i; break; }
  done
  if [[ -n "$hit" ]]; then used[hit]=1
  else
    unexplained=$((unexplained + 1))
    printf '  -- unexplained difference for: %s\n' "$c"
    jq -r '"     ours:  \(.out_a)\n     other: \(.out_b)"' <<<"$row"
    diff <(jq -r .state_a <<<"$row") <(jq -r .state_b <<<"$row") | sed 's/^/     /'
  fi
done < "$work/diff.jsonl"
differ=$(grep -c . "$work/diff.jsonl")
(( unexplained == 0 )) && ok "all $differ differing calls are allowlisted improvements" \
  || ko "$unexplained of $differ differing calls are not in the allowlist"
for i in "${!allow[@]}"; do
  [[ -n "${used[i]-}" ]] && ok "allowlist entry used: ${allow[i]##*	}" \
    || ko "allowlist entry never differed: ${allow[i]%%	*}"
done

echo
echo "boundary-tokenizer-diff: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
