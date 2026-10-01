#!/usr/bin/env bash
# Unit tests for scripts/lib/checks.sh and scripts/lib/text.sh: every output
# check called directly, without a wrapper process or a mock provider (#560).
# tests/test-delegate.sh keeps covering the wiring (the retry, the metrics
# row, the meta line); this file covers what each check decides.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/checks.sh
. "$REPO/scripts/lib/checks.sh"

pass=0
fail=0
assert_eq() {
  if [[ "$1" == "$2" ]]; then echo "  PASS  $3"; pass=$((pass+1))
  else echo "  FAIL  $3 (expected '$1', got '$2')"; fail=$((fail+1)); fi
}
assert_contains() {
  if [[ "$2" == *"$1"* ]]; then echo "  PASS  $3"; pass=$((pass+1))
  else echo "  FAIL  $3 (missing '$1' in '$2')"; fail=$((fail+1)); fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
unset DELEGATE_LOCAL_NO_META DELEGATE_NO_ECHO_CHECK DELEGATE_NO_AUTOFIX

# check <checks block> <output> [context] [--var k=v ...] — run the checks in
# this shell, as delegate.sh does, so output and the counters are visible.
# Stderr lands in $err. No template unless $template is set, so no_example_echo
# runs only in the tests that give it one.
check() {
  recipe_checks="$1" output="$2" context="${3:-}"
  shift 3 2>/dev/null || shift $#
  recipe_vars=("$@")
  status=0 recipe=fixture
  recipe_template_raw="${template:-}"
  recipe_echo_guard_vars="${guard_vars:-}"
  run_output_checks 2>"$tmp/err"
  err=$(cat "$tmp/err")
}
result() { echo "run=$checks_run failed=$checks_failed fixed=$checks_autofixed names=$checks_failed_names"; }

echo "=== text.sh helpers ==="
assert_eq "a fact" "$(printf '  Correct: fix(x): a fact (#12)  \n' | echo_normalise)" \
  "echo_normalise: trims, drops the label, the type prefix and a trailing (#N)"
assert_eq "One"$'\n'"Two"$'\n'"Three" "$(printf 'One. Two? Three!\n' | split_sentences)" \
  "split_sentences: one unit per sentence, terminators dropped"
assert_eq "Is it?"$'\n'"Or not?" "$(printf 'A fact. Is it? Or not?\n' | question_units)" \
  "question_units: questions only, the ? kept"
assert_eq "#42"$'\n'"main.js:12"$'\n'"snake_case" \
  "$(printf 'see #42 at main.js:12, snake_case\n' | fact_anchors)" \
  "fact_anchors: refs, file:line, numbers and identifiers, sorted unique"
assert_eq "change"$'\n'"merge" "$(printf 'Could you merge that change?\n' | content_words)" \
  "content_words: four-plus letters minus the function words"
long='The release workflow now pins the toolchain to one version.'
assert_eq "$long" "$(printf 'Wrong: %s\n' "$long" | echo_matches "$long")" \
  "echo_matches: a pattern unit at or over the floor matches its normalised answer unit"
assert_eq "" "$(printf 'Short line.\n' | echo_matches 'Short line.')" \
  "echo_matches: a pattern unit under the 40-char floor never matches"
assert_eq "bob" "$(mentions_in $'Thanks @Bob, see `@property` and\n```\n@decorator\n```\nmail a@b.c @scope/pkg')" \
  "mentions_in: code spans, fenced blocks, emails and scoped packages are not mentions"
assert_eq "dangling" "$(mentions_in $'```\n@dangling')" \
  "mentions_in: a fence that never closes is scanned"

echo "=== fail_check and var_value ==="
checks_failed=0 checks_failed_names=""
fail_check one "first" "  second line" 2>"$tmp/err"
fail_check two "again" 2>>"$tmp/err"
assert_eq "delegate: check 'one' FAILED — first"$'\n'"  second line"$'\n'"delegate: check 'two' FAILED — again" \
  "$(cat "$tmp/err")" "fail_check: the FAILED line, then each further argument as a line"
assert_eq "2 one,two" "$checks_failed $checks_failed_names" "fail_check: counts and names the check"
recipe_vars=("ask=first" "other=o" "ask=second")
assert_eq "first" "$(var_value ask)" "var_value: a key passed twice gives its first value"
assert_eq "second" "$(var_value ask last)" "var_value last: the last value"
var_value missing >/dev/null; assert_eq 1 "$?" "var_value: returns 1 when the key was not passed"
recipe_vars=("empty=")
var_value empty >/dev/null; assert_eq 0 "$?" "var_value: an empty value passed is still found"

echo "=== gating ==="
check $'  subject_max: 5' "a long first line" ""
assert_eq "run=1 failed=1 fixed=0 names=subject_max" "$(result)" "checks run on a successful recipe call"
DELEGATE_LOCAL_NO_META=1 check $'  subject_max: 5' "a long first line" ""
assert_eq "run=0 failed=0 fixed=0 names=" "$(result)" "DELEGATE_LOCAL_NO_META=1: no check runs"
recipe_checks=$'  subject_max: 5' output="a long first line" status=1 recipe_template_raw="x"
run_output_checks 2>/dev/null
assert_eq "run=0 failed=0 fixed=0 names=" "$(result)" "a failed call (status != 0): no check runs"
check $'  bogus_check: true' "text" ""
assert_eq "delegate: unknown check 'bogus_check' in recipe 'fixture' — ignored" "$err" "an unknown check is named and ignored"
check $'  min_context_chars: 10' "text" ""
assert_eq "run=0 failed=0 fixed=0 names=" "$(result)" "min_context_chars is a setting, not a check"

echo "=== subject_max, subject_type, body_required, body_max_words ==="
check $'  subject_max: 08' "123456789" ""
assert_eq "subject_max" "$checks_failed_names" "subject_max: a leading zero reads as decimal 8, not octal"
assert_eq "delegate: check 'subject_max' FAILED — first line is 9 chars (> 08)" "$err" "subject_max: the message names both lengths"
check $'  subject_max: 9' "123456789" ""
assert_eq "" "$checks_failed_names" "subject_max: at the limit passes"
check $'  subject_type: fix' "fix(core)!: thing" ""
assert_eq "" "$checks_failed_names" "subject_type: a scope and ! are honoured"
check $'  subject_type: fix' "feat: thing" ""
assert_eq "delegate: check 'subject_type' FAILED — subject does not start with 'fix:' (got 'feat:')" "$err" "subject_type: another type fails"
check $'  subject_type: ' "feat: thing" ""
assert_eq "run=0 failed=0 fixed=0 names=" "$(result)" "subject_type: an empty value (an omitted optional type) is skipped"
check $'  body_required: true' "subject only" ""
assert_eq "body_required" "$checks_failed_names" "body_required: a subject alone fails"
check $'  body_required: true' $'subject\r\n\r\nbody' ""
assert_eq "" "$checks_failed_names" "body_required: a CRLF body counts"
check $'  body_max_words: 3' $'subject\n\none two three four' ""
assert_eq "delegate: check 'body_max_words' FAILED — body is 4 words (> 3)" "$err" "body_max_words: counts the words after the blank line"
check $'  body_max_words: 3' $'subject with many words in it\n\none two' ""
assert_eq "" "$checks_failed_names" "body_max_words: the subject is not body"

echo "=== no_padding_tail ==="
check $'  no_padding_tail: true' "Pinned the toolchain, ensuring builds are stable." ""
assert_eq "run=1 failed=0 fixed=1 names=" "$(result)" "no_padding_tail: an allowlisted gerund tail is auto-stripped"
assert_eq "Pinned the toolchain." "$output" "no_padding_tail: the strip keeps the sentence and its full stop"
DELEGATE_NO_AUTOFIX=1 check $'  no_padding_tail: true' "Pinned the toolchain, ensuring builds are stable." ""
assert_eq "run=1 failed=1 fixed=0 names=no_padding_tail" "$(result)" "no_padding_tail: DELEGATE_NO_AUTOFIX=1 reports instead"
check $'  no_padding_tail: true' "Pinned the toolchain. This ensures stable builds." ""
assert_eq "no_padding_tail" "$checks_failed_names" "no_padding_tail: a This-X tail is reported, never stripped"
check $'  no_padding_tail: true' "Pinned the toolchain to one version." ""
assert_eq "" "$checks_failed_names" "no_padding_tail: a plain ending passes"

echo "=== no_single_item_list, no_invented_task_list, no_invented_headings ==="
check $'  no_single_item_list: true' $'Asks:\n1. one thing' ""
assert_eq "no_single_item_list" "$checks_failed_names" "no_single_item_list: one numbered item fails"
check $'  no_single_item_list: true' $'1. one\n2. two' ""
assert_eq "" "$checks_failed_names" "no_single_item_list: two items pass"
check $'  no_invented_task_list: recent_prs' $'Body\n- [ ] tested' "" "recent_prs=plain prose"
assert_contains "carries 1 markdown task-list item(s) but the 'recent_prs' examples carry none" "$err" \
  "no_invented_task_list: a task list the examples lack fails"
check $'  no_invented_task_list: recent_prs' $'Body\n- [ ] tested' "" "recent_prs=- [x] done"
assert_eq "" "$checks_failed_names" "no_invented_task_list: examples carrying one are the authority"
check $'  no_invented_task_list: recent_prs' $'Body\n- [ ] tested' "" "recent_prs=- [x] done" "recent_prs=none"
assert_eq "no_invented_task_list" "$checks_failed_names" "no_invented_task_list: a key passed twice reads its last value"
check $'  no_invented_headings: recent_prs' $'## Summary\nBody' "" "recent_prs=plain"
assert_eq "no_invented_headings" "$checks_failed_names" "no_invented_headings: a heading the examples lack fails"
check $'  no_invented_headings: recent_prs' $'```\n# a shell comment\n```\nBody' "" "recent_prs=plain"
assert_eq "" "$checks_failed_names" "no_invented_headings: a # line inside a fence is not a heading"

echo "=== no_invented_refs ==="
check $'  no_invented_refs: true' $'Body\n\nRefs: #4271' "context names #427" "why=see #427"
assert_eq "delegate: check 'no_invented_refs' FAILED — trailer names #4271, which appears in none of the inputs you supplied" "$err" \
  "no_invented_refs: matched token for token, so #4271 is not #427"
check $'  no_invented_refs: true' $'Body\n\nRefs: #427, AI-123' "#427" "ticket=AI-123"
assert_eq "" "$checks_failed_names" "no_invented_refs: refs in the context or a --var pass"
check $'  no_invented_refs: true' $'Body mentions #999 in prose' "" ""
assert_eq "" "$checks_failed_names" "no_invented_refs: only trailer lines are scanned"

echo "=== no_example_echo and no_subject_echo ==="
ex='<subject naming the change in under seventy characters total>'
template="Correct: $ex" check "" "$ex" ""
assert_eq "run=1 failed=1 fixed=0 names=no_example_echo" "$(result)" "no_example_echo: on with no checks block, a template line copied fails"
assert_contains "content: \"$ex\"" "$err" "no_example_echo: the copied line is quoted"
template="Correct: $ex" check "  no_example_echo: false" "$ex" ""
assert_eq "run=0" "${checks_run:+run=$checks_run}" "no_example_echo: false opts out"
template="Correct: $ex" DELEGATE_NO_ECHO_CHECK=1 check "" "$ex" ""
assert_eq "run=0" "${checks_run:+run=$checks_run}" "no_example_echo: DELEGATE_NO_ECHO_CHECK=1 opts out"
one='feat: add the release workflow that pins the toolchain version'
two='fix: stop the canary probe from timing out on a cold model load'
template="Write it." guard_vars=recent_commits check "" "$one" "" "recent_commits=$one"$'\n'"$two"
assert_eq "no_example_echo" "$checks_failed_names" "no_example_echo: a line unique to one exemplar is that exemplar's content"
trailer='Co-Authored-By: Some Body Who Writes Long Names <a@b.c>'
template="Write it." guard_vars=recent_commits check "" "$trailer" "" \
  "recent_commits=$one"$'\n'"$trailer"$'\n\n'"$two"$'\n'"$trailer"
assert_eq "" "$checks_failed_names" "no_example_echo: a line two exemplars share is convention, not content"
template="Write it." guard_vars=recent_commits check "" "$trailer" "" \
  "recent_commits=$one"$'\n'"$trailer" "recent_commits=$two"$'\n'"$trailer"
assert_eq "no_example_echo" "$checks_failed_names" "no_example_echo: only the first --var of a key is an exemplar, so its trailer is content"
guard_vars=recent_commits check $'  no_subject_echo: true' $'fix: short subject\n\nBody.' "" "recent_commits=abc1234 feat: other; fix: short subject (#9)"
assert_eq "no_subject_echo" "$checks_failed_names" "no_subject_echo: a ;-joined exemplar subject is found with no floor"
guard_vars=recent_commits check $'  no_subject_echo: true' $'fix: a new subject\n\nBody.' "" "recent_commits=fix: short subject"
assert_eq "" "$checks_failed_names" "no_subject_echo: a subject of its own passes"
assert_eq "short subject" "$(recipe_vars=("recent_commits=deadbeef fix(x): short subject"); subject_echo_match "fix: Short Subject")" \
  "subject_echo_match: hash and type prefix stripped, case-insensitive"

echo "=== no_context_echo and max_context_ratio ==="
facts=$'The canary probe now times out after ninety seconds on MLX.\nThe pr-description recipe no longer opens with a title line.\nA third fact that is long enough to clear the forty-char floor.'
check $'  no_context_echo: true' "The canary probe now times out after ninety seconds on MLX. The pr-description recipe no longer opens with a title line." "$facts"
assert_contains "2 distinct sentence(s) of the answer reproduce sentences of the piped context verbatim" "$err" \
  "no_context_echo: two context sentences joined into one line fail"
check $'  no_context_echo: true' "The canary probe now times out after ninety seconds on MLX. Thanks!" "$facts"
assert_eq "" "$checks_failed_names" "no_context_echo: one quoted sentence is allowed"
DELEGATE_NO_ECHO_CHECK=1 check $'  no_context_echo: true' "The canary probe now times out after ninety seconds on MLX. The pr-description recipe no longer opens with a title line." "$facts"
assert_eq "run=0 failed=0 fixed=0 names=" "$(result)" "no_context_echo: DELEGATE_NO_ECHO_CHECK=1 skips it"
ctx=$(printf 'x%.0s' $(seq 1 500))
check $'  max_context_ratio: 0.8' "$(printf 'y%.0s' $(seq 1 400))" "$ctx"
assert_eq "delegate: check 'max_context_ratio' FAILED — the answer is 400 chars against 500 chars of context (ratio 0.80 >= 0.8)"$'\n'"  The draft runs about as long as its facts; curate them, well under the facts' length, in sentences of your own." \
  "$err" "max_context_ratio: at the ratio fails, with the second line"
check $'  max_context_ratio: 0.8\n  min_context_chars: 600' "$(printf 'y%.0s' $(seq 1 400))" "$ctx"
assert_eq "" "$checks_failed_names" "max_context_ratio: a context under min_context_chars is exempt"
check $'  max_context_ratio: 0.8' "$(printf 'y%.0s' $(seq 1 399))" "$ctx"
assert_eq "" "$checks_failed_names" "max_context_ratio: under the ratio passes"

echo "=== no_fact_as_question ==="
qfacts=$'All 531 tests pass on #3359.\nThe fix touches main.js:412.'
check $'  no_fact_as_question: ask' "Could you confirm that all 531 tests pass?" "$qfacts" "ask=please rebase"
assert_contains "a supplied fact comes back as a question to the reader: \"Could you confirm that all 531 tests pass?\"" "$err" \
  "no_fact_as_question: a question whose anchors are all facts fails"
check $'  no_fact_as_question: ask' "Could you confirm that all 531 tests pass?" "$qfacts" "ask=confirm the 531 tests"
assert_eq "" "$checks_failed_names" "no_fact_as_question: an anchor in the ask var is the caller's ask"
check $'  no_fact_as_question: ask' "Could you check #9999 too?" "$qfacts" "ask=x"
assert_eq "" "$checks_failed_names" "no_fact_as_question: an anchor outside the facts is the model's own question"
check $'  no_fact_as_question: ask' "Hi, are the tests green now?" "$qfacts" "ask=x" "opener=are the tests green now?"
assert_eq "" "$checks_failed_names" "no_fact_as_question: a question the caller wrote in any --var is skipped"
check $'  no_fact_as_question: ask' "Does the fix touch the tests and the docs?" $'The fix touches the tests and the docs.' "ask=x"
assert_eq "no_fact_as_question" "$checks_failed_names" "no_fact_as_question: with no anchor, two content words from the facts fail"

echo "=== no_unbidden_mention ==="
check $'  no_unbidden_mention: recipient' "Thanks @alice and @bob." "" "recipient=@Alice"
assert_eq "delegate: check 'no_unbidden_mention' FAILED — the answer mentions @bob; the only handle you supplied is @alice, and a mention notifies whoever it names" \
  "$err" "no_unbidden_mention: a handle other than the recipient fails, compared case-insensitively"
check $'  no_unbidden_mention: recipient' "Thanks @bob." "" ""
assert_contains "you supplied no 'recipient', so the reply addresses the reader as \"you\"" "$err" \
  "no_unbidden_mention: with no recipient every mention fails"
check $'  no_unbidden_mention: recipient' "Thanks @alice, cc @carol." "" "recipient=alice" "signoff=cc @carol."
assert_eq "" "$checks_failed_names" "no_unbidden_mention: a mention the caller wrote in another --var is skipped"
check $'  no_unbidden_mention: recipient' "Thanks @bob." "" "recipient=@alice" "recipient=@bob"
assert_eq "no_unbidden_mention" "$checks_failed_names" "no_unbidden_mention: the recipient passed twice permits its first value only"

echo "=== no_title_line ==="
check $'  no_title_line: true' $'feat(x): add a thing\n\nThe body paragraph.' ""
assert_eq "run=1 failed=0 fixed=1 names=" "$(result)" "no_title_line: a title above a blank line is stripped"
assert_eq "The body paragraph." "$output" "no_title_line: the body is what remains"
check $'  no_title_line: true' $'#12 fix: thing\nglued body' ""
assert_eq "no_title_line" "$checks_failed_names" "no_title_line: a title glued to the body is reported, not guessed at"
check $'  no_title_line: true\n  subject_max: 20' $'feat: a title line that is long\n\nShort body.' ""
assert_eq "run=2 failed=0 fixed=1 names=" "$(result)" "no_title_line: later checks read the stripped output"

echo "=== retry_constraint_for ==="
recipe_checks=$'  subject_max: 72\n  body_max_words: 80'
assert_eq "subject_max: the first line must be at most 72 characters." "$(retry_constraint_for subject_max)" \
  "retry_constraint_for: the limit is read back from the checks block"
assert_eq "body_max_words: everything after the first blank line must be at most 80 words." "$(retry_constraint_for body_max_words)" \
  "retry_constraint_for: body_max_words names its limit"
assert_eq "made_up: the constraint of that name, stated above, was not met." "$(retry_constraint_for made_up)" \
  "retry_constraint_for: an unknown name gets the generic sentence"

echo "=== pair-score.sh shares the helpers ==="
# shellcheck source=../scripts/lib/pair-score.sh
. "$REPO/scripts/lib/pair-score.sh"
s=$'Wrong: The canary probe now times out after ninety seconds on MLX. Short one.\nfix(x): The pr-description recipe no longer opens with a title (#12)'
assert_eq "$(printf '%s\n' "$s" | split_sentences | echo_normalise | awk 'length($0) >= 40')" "$(printf '%s\n' "$s" | sentences)" \
  "sentences: split_sentences | echo_normalise | the 40-char floor"
assert_eq "The canary probe now times out after ninety seconds on MLX"$'\n'"The pr-description recipe no longer opens with a title" \
  "$(printf '%s\n' "$s" | sentences)" "sentences: label, type prefix and (#N) gone, the short one dropped"

echo
echo "$pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then exit 1; fi
