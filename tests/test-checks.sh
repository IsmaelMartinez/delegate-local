#!/usr/bin/env bash
# Unit tests for scripts/lib/checks.sh and scripts/lib/text.sh: every output
# check called directly, without a wrapper process or a mock provider (#560).
# tests/test-delegate.sh keeps covering the wiring (the retry, the metrics
# row, the meta line); this file covers what each check decides.

set -u

# shellcheck source=lib/assert.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"
# shellcheck source=../scripts/lib/checks.sh
. "$REPO/scripts/lib/checks.sh"

tmp=$(mktemp -d)
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

# The cases below ran through the wrapper in tests/test-delegate.sh until
# #561 and decide only what a check reports, so they run here directly under
# their old names; the wrapper file keeps one case per check for the wiring.
# Each output is what delegate.sh hands the checks: the mock's content with
# its JSON escapes decoded and trailing newlines gone, as $(...) leaves it.

echo "=== no_padding_tail through the wrapper's cases ==="
pad=$'  no_padding_tail: true'
check "$pad" $'short subject\n\nthe body drops the per-call cost, confirming the need for a matcher' ""
assert_contains "check 'no_padding_tail' AUTO-FIXED" "$err" "checks: structural matcher catches+auto-fixes unenumerated gerund tail"
check "$pad" $'short subject\n\nthe body drops the per-call cost and stops here' ""
assert_not_contains "no_padding_tail' FAILED" "$err" "checks: clean finite-verb tail not flagged"
check "$pad" $'short subject\n\nthe list is built, ensuring order, then returned to the caller' ""
assert_contains "check 'no_padding_tail' FAILED" "$err" "checks: ambiguous multi-comma tail not auto-stripped (stays a warning)"
assert_contains "then returned to the caller" "$output" "checks: ambiguous tail content preserved (not stripped)"
check "$pad" $'short subject\n\nthe cache is rebuilt, surfacing the new latency numbers' ""
assert_contains "check 'no_padding_tail' FAILED" "$err" "checks: non-allowlisted gerund detected but not auto-stripped"
assert_contains "surfacing the new latency numbers" "$output" "checks: non-allowlisted participial preserved"
check "$pad" $'short subject\n\nthe block is deleted, leaving the actions block unchanged. the fix is verified by the next run' ""
assert_not_contains "no_padding_tail" "$err" "checks: mid-line participial followed by a sentence not flagged"
check "$pad" $'short subject\n\nauto-strip the padding clause on a filler-verb allowlist, adopting the strip only when it clears the padding; persist the counters to metrics so quality is observable. default-on with an opt-out' ""
assert_not_contains "no_padding_tail" "$err" "checks: hand-written mid-line participial not flagged"
check "$pad" $'short subject\n\nthe change lands, ensuring the cache, the limiter and the queue stay in sync' ""
assert_contains "check 'no_padding_tail' FAILED" "$err" "checks: padding tail with an internal comma still detected"
check "$pad" $'short subject\n\nreads the flag from the repo config, settings are merged per section' ""
assert_not_contains "no_padding_tail" "$err" "checks: -ings plural not treated as a gerund tail"
check "$pad" $'short subject\n\nadds a cache, improving latency. also fixes the lock, ensuring parity' ""
assert_contains "check 'no_padding_tail' FAILED" "$err" "checks: adoption gate still rejects a not-clean strip"
assert_contains "ensuring parity" "$output" "checks: adoption unchanged, output not silently mutated"

echo "=== no_example_echo through the wrapper's cases ==="
anchor_tpl=$'Answer using only the facts below.\n\nWrong: The regression is in the date parser, and ask the reporter to confirm it.\nCorrect: The regression is in the date parser. Could you confirm whether it also happens on older inputs?\n\n=== Facts ===\n{{stdin}}'
correct='The regression is in the date parser. Could you confirm whether it also happens on older inputs?'
template="$anchor_tpl" check "" "The regression is in the date parser, and ask the reporter to confirm it." "facts"
assert_contains "check 'no_example_echo' FAILED" "$err" "echo-check: echoed Wrong: arm caught after label strip"
template="$anchor_tpl" check "" "Correct: $correct" "facts"
assert_contains "check 'no_example_echo' FAILED" "$err" "echo-check: echo that keeps the Correct: label is caught"
template=$'Write a commit message.\n\nCorrect: fix: bump the model-resolution cache TTL to 60 seconds flat\n\n=== Facts ===\n{{stdin}}' \
  check "" "fix: bump the model-resolution cache TTL to 60 seconds flat" "facts"
assert_contains "check 'no_example_echo' FAILED" "$err" \
  "echo-check: echoed template example beginning with a type prefix is caught"
template="$anchor_tpl" check "" "The override in src/config/loader.js:88 silently wins. Could you make it defer?" "facts"
assert_not_contains "no_example_echo" "$err" "echo-check: genuine answer does not trip the check"
template="$anchor_tpl" check "" "$correct" "facts"
assert_contains "strip it from" "$err" "echo-check: the failure says to strip boilerplate from the exemplar"
assert_contains "pass two" "$err" "echo-check: the failure says why one exemplar cannot be classified"
template="$anchor_tpl" check "" "=== Facts ===" "facts"
assert_not_contains "no_example_echo" "$err" "echo-check: short shared line stays below the length floor"
template="$anchor_tpl" DELEGATE_NO_ECHO_CHECK=1 check "" "$correct" "facts"
assert_not_contains "no_example_echo" "$err" "echo-check: DELEGATE_NO_ECHO_CHECK=1 silences it"
template=$'Answer using only the facts below.\n\nCorrect: '"$correct"$'\n\n=== Facts ===\n{{stdin}}' \
  check $'  no_example_echo: false' "$correct" "facts"
assert_lacks "no_example_echo|unknown check" "$err" "echo-check: frontmatter opt-out is silent and recognised"

echo "=== echo_guard_vars through the wrapper's cases ==="
cm_tpl=$'Write a commit message.\n\n=== Recent commits (SHAPE anchors) ===\n{{recent_commits}}\n\n=== Why ===\n{{why}}'
ANCHORS='chore(deps): bump codeql-action init and analyze together to v4.37.6 (#253)
chore(deps): bump github/codeql-action/analyze from 4.37.3 to 4.37.4 (#240)
perf(football): cut CI validate from 34 to 7 minutes (#287)'
cm() { template="$cm_tpl" guard_vars=recent_commits check "" "$1" "x" "recent_commits=$2" "why=w"; }
cm $'chore(deps): bump codeql-action init and analyze together to v4.37.6 (#253)\n\nbody here.' "$ANCHORS"
assert_contains "check 'no_example_echo' FAILED" "$err" "echo-guard: verbatim anchor including its PR suffix is caught"
cm $'chore(deps): bump codeql-action to v4.37.8 and osv-scanner-action to v2.5.1\n\nCombines four Dependabot PRs that each touch one workflow file.' "$ANCHORS"
assert_not_contains "no_example_echo" "$err" "echo-guard: the correct subject for the same change does not flag"
cm $'feat: a brand new and entirely different subject line\n\nGenerated with the standard project tooling and reviewed by a maintainer.' \
  $'chore(deps): bump one thing to v1 (#1)\n\nGenerated with the standard project tooling and reviewed by a maintainer.\n\nchore(deps): bump another thing to v2 (#2)\n\nGenerated with the standard project tooling and reviewed by a maintainer.'
assert_not_contains "no_example_echo" "$err" "echo-guard: a line repeated across anchors is convention, not flagged"
template=$'Write something.\n{{aa}}\n{{bb}}' guard_vars="aa, bb" check "" \
  "the second exemplar line which is definitely over forty characters" "" \
  "aa=the first exemplar line which is definitely over forty characters" \
  "bb=the second exemplar line which is definitely over forty characters"
assert_contains "check 'no_example_echo' FAILED" "$err" "echo-guard: a var listed after 'comma space' is still guarded"
cm $'feat: bump the shared tooling image to the newest tag\n\nbody.' \
  $'chore(deps): bump the shared tooling image to the newest tag (#1)\n\nci: bump the shared tooling image to the newest tag (#2)'
assert_not_contains "no_example_echo" "$err" "echo-guard: prefix-variant lines shared across anchors are convention"
cm $'chore: fix: update the dependency pin to the newest release (#9)\n\nbody.' \
  $'chore: fix: update the dependency pin to the newest release (#9)\n\nperf(football): cut CI validate from 34 to 7 minutes (#287)'
assert_contains "check 'no_example_echo' FAILED" "$err" \
  "echo-guard: an anchor with a doubled type prefix echoed verbatim is caught"

echo "=== body_max_words through the wrapper's cases ==="
bw=$'  body_max_words: 10'
check "$bw" $'subject here\n\none two three four five six seven eight nine ten' ""
assert_not_contains "body_max_words" "$err" "body_max_words: a body exactly at the limit passes"
check "$bw" $'a very long subject line with many many many many words indeed\n\ntwo words' ""
assert_not_contains "body_max_words" "$err" "body_max_words: the subject line is not counted"
check "$bw" "subject here" ""
assert_not_contains "body_max_words" "$err" "body_max_words: subject-only output is left to body_required"
check "$bw" $'subject\n\none two three four five six\n\nseven eight nine ten eleven twelve' ""
assert_contains "body is 12 words" "$err" "body_max_words: paragraphs after the first blank line are summed"
check "$bw" $'subject here\r\n\r\none two three four five six seven eight nine ten eleven twelve' ""
assert_contains "body is 12 words (> 10)" "$err" "body_max_words: CRLF output measures the same as LF"

echo "=== no_single_item_list through the wrapper's cases ==="
sil=$'  no_single_item_list: true'
check "$sil" $'The cause is the flag flip.\n1. Does it reproduce on 2.9?\n2. Could you paste the launch flags?' ""
assert_not_contains "no_single_item_list" "$err" "no_single_item_list: a genuine two-ask list passes"
check "$sil" "The cause is the flag flip. Could you confirm whether it survives a cold start?" ""
assert_not_contains "no_single_item_list" "$err" "no_single_item_list: prose with no list passes"
check "$sil" $'The cause is the flag flip.\n1) Could you paste the launch flags?' ""
assert_contains "check 'no_single_item_list' FAILED" "$err" "no_single_item_list: the 1) enumerator form counts"
check "$sil" $'The regression landed in\n2.9.1 and not before it.' ""
assert_not_contains "no_single_item_list" "$err" "no_single_item_list: a bare decimal is not a list item"
check "$sil" $'The cause is the flag flip.\r\n1. Could you paste the launch flags?' ""
assert_contains "check 'no_single_item_list' FAILED" "$err" "no_single_item_list: CRLF output behaves the same as LF"
check $'  no_single_item_list: false' $'The cause is the flag flip.\n1. Could you paste the launch flags?' ""
assert_lacks "no_single_item_list' FAILED|unknown check" "$err" "no_single_item_list: 'false' skips the check quietly"

echo "=== no_invented_task_list through the wrapper's cases ==="
tl=$'  no_invented_task_list: examples'
check "$tl" $'Suites: 366 passed, 94/94.\n\n## Test plan\n- [ ] Run the prompts suite (not run yet)\n- [ ] Run the unit suite (not run yet)' "" \
  $'examples=TITLE: a merged PR\nBODY:\n## Type of change\n- [x] Bug fix\n- [ ] New feature'
assert_not_contains "no_invented_task_list" "$err" "no_invented_task_list: a task list the examples also carry passes"
check "$tl" $'Two sentences of prose describing the change.\n\nRefs: AI-100' "" $'examples=TITLE: a merged PR\nBODY:\nprose'
assert_not_contains "no_invented_task_list" "$err" "no_invented_task_list: output with no task list passes"
check "$tl" $'Body.\n\n- [x] Tests pass' "" $'examples=TITLE: x\nBODY:\nprose'
assert_contains "check 'no_invented_task_list' FAILED" "$err" "no_invented_task_list: a ticked box counts too"
check "$tl" $'Body.\n\n  * [ ] one\n  + [ ] two' "" $'examples=TITLE: x\nBODY:\nprose'
assert_contains "carries 2 markdown task-list item(s)" "$err" "no_invented_task_list: * and + markers and indentation count"
check "$tl" $'Body.\n\n- [draft] not a checkbox\n- [WIP] also not' "" $'examples=TITLE: x\nBODY:\nprose'
assert_not_contains "no_invented_task_list" "$err" "no_invented_task_list: a bracketed word is not a checkbox"
check $'  no_invented_task_list: ' $'Body.\n\n- [ ] one' "" $'examples=TITLE: x\nBODY:\nprose'
assert_lacks "no_invented_task_list' FAILED|unknown check" "$err" "no_invented_task_list: an empty value is inert and quiet"

echo "=== no_invented_refs through the wrapper's cases ==="
rf=$'  no_invented_refs: true'
check "$rf" $'A short body describing the change.\n\nRefs: AI-813' "" $'examples=TITLE: one\nBODY:\nprose for AI-813\nRefs: AI-813'
assert_not_contains "no_invented_refs" "$err" "no_invented_refs: an identifier the caller supplied passes"
check "$rf" $'A short body.\n\nCloses: #4271' "" $'examples=TITLE: one\nBODY:\nprose\nCloses: #12'
assert_contains "trailer names #4271" "$err" "no_invented_refs: an ungrounded issue number fails"
check "$rf" $'A short body.\n\nCloses: #427' "" $'examples=TITLE: one\nBODY:\nfixes #4271 in the parser'
assert_contains "trailer names #427" "$err" "no_invented_refs: a prefix of a grounded identifier is not itself grounded"
check "$rf" "The parser now reads UTF-8 and rejects ISO-8859 input, per RFC-3629." "" $'examples=TITLE: one\nBODY:\nprose'
assert_not_contains "no_invented_refs" "$err" "no_invented_refs: hyphenated tokens in prose are not scanned"
check "$rf" $'A short body.\n\nSuites: 366 passed, 94/94' "" $'examples=TITLE: one\nBODY:\nprose'
assert_not_contains "no_invented_refs" "$err" "no_invented_refs: a trailer with no identifier passes"

echo "=== zero-padded limits are decimal ==="
check $'  subject_max: 08\n  body_max_words: 500' "a subject line that is definitely longer than eight characters" ""
assert_contains "check 'subject_max' FAILED" "$err" "base-10: a zero-padded subject_max still fires"
assert_not_contains "value too great for base" "$err" "base-10: subject_max leaks no arithmetic error"
check $'  subject_max: 500\n  body_max_words: 09' $'subject\n\none two three four five six seven eight nine ten eleven twelve' ""
assert_contains "check 'body_max_words' FAILED — body is 12 words (> 09)" "$err" "base-10: a zero-padded body_max_words still fires"
assert_not_contains "value too great for base" "$err" "base-10: body_max_words leaks no arithmetic error"
check $'  subject_max: 0500\n  body_max_words: 0500' $'short subject\n\ntwo words' ""
assert_lacks "FAILED|value too great for base" "$err" "base-10: a padded limit above the measured value passes"

echo "=== no_invented_headings through the wrapper's cases ==="
hd=$'  no_invented_headings: examples'
check "$hd" $'A paragraph of prose.\n\n### Implementation Details\n- Capture: pre-post.\n\n### Testing\n- 18 new assertions.' "" \
  $'examples=TITLE: a merged PR\nBODY:\n## Summary\nWhat it does.'
assert_not_contains "no_invented_headings" "$err" "no_invented_headings: a heading the examples also carry passes"
check "$hd" "Just prose, two sentences of it. Nothing else." "" $'examples=TITLE: a merged PR\nBODY:\nprose'
assert_not_contains "no_invented_headings" "$err" "no_invented_headings: output with no heading passes"
check "$hd" $'Prose about the fix.\n\n```bash\n# run the suite\nbash tests/run-tests.sh\n```\n\nMore prose.' "" $'examples=TITLE: a merged PR\nBODY:\nprose'
assert_not_contains "no_invented_headings" "$err" "no_invented_headings: a comment inside a fenced block is not a heading"
check "$hd" $'Prose.\n\n#!/usr/bin/env bash is the first line of the script.' "" $'examples=TITLE: a merged PR\nBODY:\nprose'
assert_not_contains "no_invented_headings" "$err" "no_invented_headings: a shebang is not a heading"
check "$hd" $'Prose.\n\n## Summary\nInvented.' "" $'examples=TITLE: a merged PR\nBODY:\nprose\n```bash\n# not a heading\nls\n```'
assert_contains "check 'no_invented_headings' FAILED" "$err" "no_invented_headings: a fenced comment in the examples is not a heading either"

echo "=== no_context_echo through the wrapper's cases ==="
ce=$'  no_context_echo: true'
ce_facts=$'The GPU sandbox flag flip landed in the Electron 39 upgrade at src/main.js:412.\nAll 531 tests pass on the branch with the flag forced back on, see PR #2632.\nThe regression predates the refactor by two releases.'
ce_verdict="verdict=The rework is right and the blank window is not a regression from it at all."
ce_joined='Not a regression. The GPU sandbox flag flip landed in the Electron 39 upgrade at src/main.js:412. All 531 tests pass on the branch with the flag forced back on, see PR #2632. Could you add a test?'
check "$ce" "$ce_joined" "$ce_facts" "$ce_verdict"
assert_contains "check 'no_context_echo' FAILED" "$err" "context-echo: two facts joined into one paragraph line are still caught"
check "$ce" "$ce_joined" "$(printf '%s\n' "$ce_facts" | sed 's/\.$//')" "$ce_verdict"
assert_contains "check 'no_context_echo' FAILED" "$err" "context-echo: facts piped without full stops are caught when echoed as sentences"
check "$ce" $'Not a regression.\nThe GPU sandbox flag flip landed in the Electron 39 upgrade at src/main.js:412.\nThe refactor is two releases newer, so the failure is the flag.\nCould you add a test?' "$ce_facts" "$ce_verdict"
assert_not_contains "no_context_echo" "$err" "context-echo: a single echoed line stays below the threshold"
check "$ce" $'The GPU sandbox flag flip landed in the Electron 39 upgrade at src/main.js:412.\nThe GPU sandbox flag flip landed in the Electron 39 upgrade at src/main.js:412.' "$ce_facts" "$ce_verdict"
assert_not_contains "no_context_echo" "$err" "context-echo: one line repeated is one line, not two"
check "$ce" $'Thanks again!\n=== FACTS ===\nA third short line.' $'Thanks again!\n=== FACTS ===\nA third short line.' "$ce_verdict"
assert_not_contains "no_context_echo" "$err" "context-echo: short shared lines stay below the length floor"
check "$ce" $'   The GPU sandbox flag flip landed in the Electron 39 upgrade at src/main.js:412.  \nCorrect: All 531 tests pass on the branch with the flag forced back on, see PR #2632.' "$ce_facts" "$ce_verdict"
assert_contains "check 'no_context_echo' FAILED" "$err" "context-echo: whitespace and a label prefix are normalised away before comparing"

echo "=== max_context_ratio through the wrapper's cases ==="
mcr_facts=""
for i in 1 2 3 4 5 6 7 8; do
  mcr_facts="${mcr_facts}Fact $i: the sandbox flag flip landed at src/main.js:412 and all 531 tests pass on PR #2632 now."$'\n'
done
mcr_facts="${mcr_facts%$'\n'}"
mcr_long=$(for i in 1 2 3 4 5 6; do printf '%s ' "The flip is the sandbox flag at src/main.js:412 and the 531 tests pass on PR #2632, so the branch is clear now."; done
  printf '%s' "The flip is the sandbox flag at src/main.js:412 and the 531 tests pass on PR #2632, so the branch is clear.")
check $'  max_context_ratio: 0.8' "$mcr_long" $'The sandbox flag flip is at src/main.js:412.\nAll 531 tests pass on PR #2632.'
assert_not_contains "max_context_ratio" "$err" "context-ratio: a context under the default 400-char floor is exempt"
check $'  max_context_ratio: 0.8\n  min_context_chars: 2000' "$mcr_long" "$mcr_facts"
assert_not_contains "max_context_ratio" "$err" "context-ratio: a declared min_context_chars above the context exempts it"
assert_not_contains "unknown check 'min_context_chars'" "$err" "context-ratio: min_context_chars is accepted beside the ratio"

echo "=== no_fact_as_question through the wrapper's cases ==="
fq_facts=$'The blank window is the GPU sandbox flag flip in the Electron 39 upgrade at src/main.js:412.\nAll 531 tests pass on the branch with the flag forced back on, see PR #2632.\nThe token drop is on the Teams side, in its MSAL cache, not in teams-for-linux.'
fq_ask='whether the token survives a cold start of the app'
fq() { check $'  no_fact_as_question: ask' "$1" "$fq_facts" "ask=${2:-$fq_ask}" "opener=${3:-Thanks for the report on build 4711.}" ${4:+"$4"}; }
fq 'The flip is the sandbox flag in the Electron 39 upgrade. Can you confirm the tests pass with the flag forced back on?'
assert_contains "check 'no_fact_as_question' FAILED" "$err" "fact-question: a fact without anchors asked back is caught on its content words"
assert_contains 'Can you confirm the tests pass with the flag forced back on?' "$err" "fact-question: the zero-anchor question is the one quoted"
fq $'The flip is the sandbox flag at src/main.js:412.\n1. Could you confirm that all 531 tests pass on PR #2632?\n2. Could you check whether the token survives a cold start of the app?'
assert_contains "check 'no_fact_as_question' FAILED" "$err" "fact-question: a numbered item that asks a fact back is caught"
assert_contains ': "Could you confirm that all 531 tests pass on PR #2632?"' "$err" "fact-question: the numbered item is quoted without its number"
fq 'The flip is the sandbox flag at src/main.js:412. Does PR #2632 still reproduce it on your machine?' 'whether PR #2632 still reproduces it'
assert_not_contains "no_fact_as_question" "$err" "fact-question: an anchor named in the ask var is the caller's ask"
fq 'The flip is the sandbox flag at src/main.js:412. Could you try Electron 40 and report back?'
assert_not_contains "no_fact_as_question" "$err" "fact-question: an anchor outside the facts is not a supplied fact"
fq 'The flip is the sandbox flag at src/main.js:412. Could you paste the flag you use?'
assert_not_contains "no_fact_as_question" "$err" "fact-question: one shared word stays below the two-word floor"
fq 'Thanks for the report on build 4711. The flip is the sandbox flag at src/main.js:412. Could you confirm the report was on build 4711?'
assert_not_contains "no_fact_as_question" "$err" "fact-question: a --var value asked back is not a supplied fact"
fq 'Did all 531 tests pass on PR #2632 for you too? The flip is the sandbox flag at src/main.js:412. Could you check whether the token survives a cold start of the app?' \
  "" "Did all 531 tests pass on PR #2632 for you too?"
assert_not_contains "no_fact_as_question" "$err" "fact-question: a caller-supplied opener that is a question is the caller's"
fq '@nneul, Did all 531 tests pass on PR #2632 for you too? The flip is the sandbox flag at src/main.js:412. Could you check whether the token survives a cold start of the app?' \
  "" "Did all 531 tests pass on PR #2632 for you too?" "recipient=nneul"
assert_not_contains "no_fact_as_question" "$err" "fact-question: a caller-supplied opener behind the recipient handle is the caller's"

echo "=== no_unbidden_mention through the wrapper's cases ==="
um_facts=$'The crash is in src/main.js:412 and tomgunning reported it on the referenced issue.\nAll 531 tests pass on the branch.'
um() { local out="$1"; shift; check $'  no_unbidden_mention: recipient' "$out" "$um_facts" "$@"; }
# A clean case proves the check ran and passed, not that it never ran.
assert_mention_clean() {
  assert_not_contains "no_unbidden_mention" "$err" "$1"
  assert_eq 1 "$checks_run" "$1 (the check ran)"
  assert_eq 0 "$checks_failed" "$1 (and passed)"
}
um '@nneul, thanks for the report. The crash is at src/main.js:412.' recipient=nneul
assert_mention_clean "unbidden-mention: the supplied recipient may be mentioned"
um '@nneul, thanks for the report. The crash is at src/main.js:412.' recipient=@nneul
assert_mention_clean "unbidden-mention: the recipient var may carry its own @"
um '@NNeul, thanks for the report.' recipient=nneul
assert_mention_clean "unbidden-mention: handles compare case-insensitively, as the forges resolve them"
um '@nneul, thanks. cc @tomgunning who filed the original.' recipient=nneul
assert_contains "check 'no_unbidden_mention' FAILED" "$err" "unbidden-mention: a third party beside the recipient is caught"
assert_contains 'the only handle you supplied is @nneul' "$err" "unbidden-mention: the message names the one permitted handle"
um $'The guard is a decorator:\n\n```python\n@property\ndef x(self): ...\n```\n\nReported by tomgunning.'
assert_mention_clean "unbidden-mention: a decorator inside a fenced block is not a mention"
um $'The guard is a decorator:\n\n~~~python\n@property\ndef x(self): ...\n~~~\n\nReported by tomgunning.'
assert_mention_clean "unbidden-mention: a decorator inside a tilde fence is not a mention"
um $'Quoted as sent:\n\n````markdown\n```python\n@property\n```\n@override\n````\n\nReported by tomgunning.'
assert_mention_clean "unbidden-mention: a nested fence does not close a longer one early"
um 'The `@override` annotation is the one to copy.'
assert_mention_clean "unbidden-mention: an annotation in an inline code span is not a mention"
um 'Mail the report to releases@example.com when the branch lands.'
assert_mention_clean "unbidden-mention: an email address is not a mention"
um 'Pin @scope/pkg to the patched release before merging.'
assert_mention_clean "unbidden-mention: a scoped package is not a mention"
um $'Thanks for the report.\n\n```\nsee above\n@tomgunning, see above'
assert_contains "check 'no_unbidden_mention' FAILED" "$err" "unbidden-mention: a mention after an unclosed fence is still caught"
um '@nneul, thanks for the report.' recipient=nneul recipient=other
assert_mention_clean "unbidden-mention: a repeated recipient var permits its first value"
um 'Thanks for the report. cc @IsmaelMartinez' 'signoff=cc @IsmaelMartinez'
assert_mention_clean "unbidden-mention: a mention the caller supplied in another var is permitted"
um '@tomgunning, thanks for the report. cc @IsmaelMartinez' 'signoff=cc @IsmaelMartinez'
assert_contains "check 'no_unbidden_mention' FAILED" "$err" "unbidden-mention: a caller-supplied mention does not excuse a bystander"
assert_not_contains '@ismaelmartinez' "$err" "unbidden-mention: only the bystander is named, not the caller's handle"

echo "=== no_title_line through the wrapper's cases ==="
ttl=$'  no_title_line: true'
check "$ttl" $'#587 fix: store finals after the call\n\nThe confirm hook stores every body.' ""
assert_eq "The confirm hook stores every body." "$output" "no_title_line: a #N type: title line is stripped"
check "$ttl" $'The gate replays each case.\n\nfix: nothing here is a title.' ""
assert_not_contains "no_title_line" "$err" "no_title_line: a body that opens with prose is clean"
assert_eq $'The gate replays each case.\n\nfix: nothing here is a title.' "$output" "no_title_line: a type-shaped line after the first is left alone"
check "$ttl" "feat: add the gate" ""
assert_contains "check 'no_title_line' FAILED" "$err" "no_title_line: a title with no body after it is reported, never stripped to nothing"
DELEGATE_NO_AUTOFIX=1 check "$ttl" $'feat(replay): add the gate\n\nThe gate replays each case.' ""
assert_contains "check 'no_title_line' FAILED" "$err" "no_title_line: DELEGATE_NO_AUTOFIX=1 restores warn-only"

echo "=== no_subject_echo through the wrapper's cases ==="
sub_rc='3f9e2a1 feat: add the replay gate (#534); 81a3511 fix: store finals after the call (#596)'
sub() { template=$'Wrong: fix: refresh token before handshake\nCorrect: fix(auth): refresh token before handshake\n=== Recent ===\n{{recent_commits}}' \
  guard_vars=recent_commits check $'  no_subject_echo: true' "$1" "" "recent_commits=$sub_rc" ${2:+"$2"}; }
sub $'fix(hooks): store finals after the call\n\nThe confirm hook now writes them.'
assert_contains "check 'no_subject_echo' FAILED" "$err" "no_subject_echo: a subject copied from one of the semicolon-joined recent commits fails, hash, type and (#N) aside"
sub $'fix: write finals from the confirm hook\n\nStore finals after the call.'
assert_not_contains "no_subject_echo" "$err" "no_subject_echo: a new subject is clean, whatever the body repeats"
DELEGATE_NO_ECHO_CHECK=1 sub $'fix: store finals after the call\n\nBody.'
assert_not_contains "no_subject_echo" "$err" "no_subject_echo: DELEGATE_NO_ECHO_CHECK=1 silences it with the other echo checks"
sub $'fix: tidy the release notes\n\nBody.' "recent_commits=chore: tidy the release notes"
assert_not_contains "no_subject_echo" "$err" "no_subject_echo: only the first value of a guard var passed twice is an exemplar"

echo "=== pair-score.sh shares the helpers ==="
# shellcheck source=../scripts/lib/pair-score.sh
. "$REPO/scripts/lib/pair-score.sh"
s=$'Wrong: The canary probe now times out after ninety seconds on MLX. Short one.\nfix(x): The pr-description recipe no longer opens with a title (#12)'
assert_eq "$(printf '%s\n' "$s" | split_sentences | echo_normalise | awk 'length($0) >= 40')" "$(printf '%s\n' "$s" | sentences)" \
  "sentences: split_sentences | echo_normalise | the 40-char floor"
assert_eq "The canary probe now times out after ninety seconds on MLX"$'\n'"The pr-description recipe no longer opens with a title" \
  "$(printf '%s\n' "$s" | sentences)" "sentences: label, type prefix and (#N) gone, the short one dropped"

finish
