#!/usr/bin/env bash
# Deterministic output checks (ADR 0014, ADR 0017): a recipe's `checks:` block
# declares constraints run on the finalised output. All are warn-only except
# no_padding_tail and no_title_line, whose safe shapes are auto-stripped
# (checks_autofixed). Gated like the meta line, so NO_META and failed calls
# stay quiet. Sourced by delegate.sh, and by tests/test-checks.sh to call a
# check without a wrapper process (#560). The inputs are the wrapper's
# globals: output, context (the piped stdin), status, recipe, recipe_checks
# (the post-substitution `checks:` block), recipe_template_raw,
# recipe_echo_guard_vars and the recipe_vars array. run_output_checks sets
# checks_run, checks_failed, checks_failed_names and checks_autofixed, and
# rewrites output when an autofix applies. Sourcing has no side effects.
# shellcheck disable=SC2154  # those globals are assigned by the sourcer
# shellcheck source=text.sh
. "$(dirname "${BASH_SOURCE[0]}")/text.sh"

# fail_check <name> <message> [line...] — report a failed check: one
# "delegate: check '<name>' FAILED — <message>" line on stderr, each further
# argument as a line of its own, and the name counted for the metrics row.
fail_check() {
  local name="$1"
  echo "delegate: check '$name' FAILED — $2" >&2
  shift 2
  if (( $# > 0 )); then printf '%s\n' "$@" >&2; fi
  checks_failed=$((checks_failed + 1))
  checks_failed_names="${checks_failed_names:+$checks_failed_names,}$name"
}

# var_value <name> [last] — print the value of `--var <name>` and return 0,
# or print nothing and return 1 when it was not passed. A key passed twice
# gives its first value, the one the template substituted; `last` gives the
# last, which is how the shape-authority checks have always read theirs.
var_value() {
  local _kv _v="" _found=1
  for _kv in ${recipe_vars[@]+"${recipe_vars[@]}"}; do
    [[ "${_kv%%=*}" == "$1" ]] || continue
    _v="${_kv#*=}"
    _found=0
    [[ "${2:-}" == last ]] || break
  done
  printf '%s' "$_v"
  return "$_found"
}

# retry_constraint_for — one sentence per check name for the repair attempt
# (#384). The limit is read back out of $recipe_checks, the same
# post-substitution frontmatter the checks parse, so the two cannot drift.
retry_constraint_for() {
  local name="$1" val
  val=$(printf '%s\n' "${recipe_checks:-}" | awk -v k="$name" '
    { sub(/^[[:space:]]+/, "") }
    index($0, k ":") == 1 { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }')
  case "$name" in
    subject_max)
      echo "subject_max: the first line must be at most ${val:-the stated number of} characters." ;;
    body_max_words)
      echo "body_max_words: everything after the first blank line must be at most ${val:-the stated number of} words." ;;
    subject_type)
      echo "subject_type: the first line must begin with one of these types: ${val:-the stated list}." ;;
    body_required)
      echo "body_required: the answer needs a body after the first blank line, not a subject on its own." ;;
    no_padding_tail)
      echo "no_padding_tail: do not end with a clause that restates what the answer already said." ;;
    no_single_item_list)
      echo "no_single_item_list: a single item is a sentence, never a one-item numbered list." ;;
    no_invented_task_list)
      echo "no_invented_task_list: do not write a markdown task list; the examples you were given carry none." ;;
    no_invented_headings)
      echo "no_invented_headings: do not write a markdown heading; the examples you were given carry none, so write flowing prose." ;;
    no_invented_refs)
      echo "no_invented_refs: every issue or ticket identifier in a trailer must appear in the input you were given." ;;
    no_example_echo)
      echo "no_example_echo: do not reproduce any line of this prompt or of an example; write from the input." ;;
    no_title_line)
      echo "no_title_line: output only the body; do not open with a title line of the form '<type>: <summary>'." ;;
    no_subject_echo)
      echo "no_subject_echo: the subject must describe this change in words of your own; never reuse a subject from the prompt or the recent commits." ;;
    no_unbidden_mention)
      echo "no_unbidden_mention: @-mention nobody except the recipient handle you were given; with none, address the reader as \"you\" and write no \"@\" at all." ;;
    no_context_echo)
      # Measures echo, not length; max_context_ratio owns the length rule (#487).
      echo "no_context_echo: reproduce none of the supplied sentences as written; carry their paths, numbers and references inside sentences of your own." ;;
    max_context_ratio)
      # A copy ban says nothing about length, so this one says it out loud (#487).
      echo "max_context_ratio: the answer runs about as long as the supplied facts; curate it to well under the facts' length, in sentences of your own." ;;
    *)
      echo "$name: the constraint of that name, stated above, was not met." ;;
  esac
}

# echo_guard_values — the values of the --var names the recipe lists under
# `echo_guard_vars:` (#428), the first value of each, each ending in a newline:
# exemplars passed as shape anchors, whose content the answer must not copy.
echo_guard_values() {
  local _egv
  [[ -n "${recipe_echo_guard_vars:-}" ]] || return 0
  for _egv in $(printf '%s' "$recipe_echo_guard_vars" | tr ',' ' '); do
    # First value only: a var passed twice substitutes its first, and the
    # second never reached the model.
    if var_value "$_egv"; then echo; fi
  done
  return 0
}

# subject_echo_match <subject> — the exemplar subject the draft's subject
# ($1) reproduces, if any (#589). Sources are the recipe's own template and
# the echo_guard_vars values, split on ';' as well as on lines because
# callers join recent subjects into one line. Both sides lose a leading
# commit hash and then take echo_normalise (label, type prefix, trailing
# (#N)); there is NO 40-char floor, because a subject is shorter than a line
# and a lone exemplar subject normalises well under it, which is how
# no_example_echo let subject copies through. Case-insensitive, fixed-string
# whole-unit match, so linear.
subject_echo_match() {
  local subj
  subj=$(printf '%s\n' "$1" | sed -E -e 's/^[[:space:]]*//' -e 's/^[0-9a-f]{7,40}[[:space:]]+//' | echo_normalise)
  [[ -n "$subj" ]] || return 0
  { printf '%s\n' "${recipe_template_raw:-}"; echo_guard_values; } \
    | tr ';' '\n' \
    | sed -E -e 's/^[[:space:]]*//' -e 's/^[0-9a-f]{7,40}[[:space:]]+//' | echo_normalise \
    | grep -Fxi -e "$subj" | head -n 1
  return 0
}

# fact_as_question_matches — the questions of the output ($1) that hand a
# supplied fact back to the reader (#513), one per line in order. The unit is
# the anchor when the question carries one: every anchor in the piped context
# ($2) and none in the ask ($3) is a fact, not an ask (an anchor outside the
# context is the model's own, one in the ask is the caller's). With no anchor
# the unit is the content word, two or more from the context and none from
# the ask: one shared word is any question at all ("could you make that
# change?"). A question the caller wrote ($4, every --var value) is skipped
# first: an opener or sign-off is emitted as written and STATED-NOT-ASKED
# exempts it whatever it asks. The caller's questions are looked for INSIDE
# the emitted unit, not the other way round, because the recipe prefixes the
# opener with "@handle, " and the unit then carries more than the caller
# wrote. Measured on the 18 spike cases: anchors alone flag 6 of the 11
# confirm/question rejections, the fallback lifts it to 8, both at 0 of the
# 16 shipped finals. comm wants both sides sorted, which the extractors are.
fact_as_question_matches() {
  local q cq callers units ctx_anchors ask_anchors ctx_words ask_words caller_questions n_ctx n_out n_ask
  ctx_anchors=$(printf '%s\n' "$2" | fact_anchors)
  ask_anchors=$(printf '%s\n' "$3" | fact_anchors)
  ctx_words=$(printf '%s\n' "$2" | content_words)
  ask_words=$(printf '%s\n' "$3" | content_words)
  caller_questions=$(printf '%s\n' "${4:-}" | question_units)
  while IFS= read -r q; do
    callers=0
    while IFS= read -r cq; do
      [[ -n "$cq" && "$q" == *"$cq"* ]] && callers=1
    done <<<"$caller_questions"
    (( callers )) && continue
    units=$(printf '%s\n' "$q" | fact_anchors)
    if [[ -n "$units" ]]; then
      n_out=$(comm -23 <(printf '%s\n' "$units") <(printf '%s\n' "$ctx_anchors") | grep -c '')
      n_ask=$(comm -12 <(printf '%s\n' "$units") <(printf '%s\n' "$ask_anchors") | grep -c '')
      (( n_out == 0 && n_ask == 0 )) && printf '%s\n' "$q"
      continue
    fi
    units=$(printf '%s\n' "$q" | content_words)
    [[ -z "$units" ]] && continue
    n_ctx=$(comm -12 <(printf '%s\n' "$units") <(printf '%s\n' "$ctx_words") | grep -c '')
    n_ask=$(comm -12 <(printf '%s\n' "$units") <(printf '%s\n' "$ask_words") | grep -c '')
    (( n_ctx >= 2 && n_ask == 0 )) && printf '%s\n' "$q"
  done < <(printf '%s\n' "$1" | question_units)
  return 0
}

run_output_checks() {
# The result and the counters (output, checks_*) are
# deliberately NOT local: they are the function's outputs.
local subj_echo padding_re padding_re_adopt check_first_line check_last_line cline ckey cval stripped new_output new_last subj_type body_lines body_words echoed_line echo_exemplars _kv list_items task_prog out_tasks auth_tasks head_prog out_heads auth_heads authority ref_ground ref_tok invented_refs context_echoed context_echoed_n ctx_floor ctx_ratio fact_questions caller_text allowed unbidden mention_tok caller_mentions
checks_failed=0
checks_failed_names=""
checks_run=0
checks_autofixed=0

# no_example_echo — ON by default for every recipe call: a line copied out of
# the prompt is never a correct outcome, and the contrastive anchors (ADR 0011)
# hand the model a fluent sentence to fall back on when the input is long.
# Prompt text cannot close this, since the guards are themselves copyable
# lines. Compared against $recipe_template_raw so only recipe-AUTHORED text is
# a pattern. Opt out with `no_example_echo: false` or DELEGATE_NO_ECHO_CHECK=1.
if [[ "${DELEGATE_LOCAL_NO_META:-}" != "1" ]] && (( status == 0 )) \
   && [[ -n "${recipe_template_raw:-}" ]] \
   && [[ "${DELEGATE_NO_ECHO_CHECK:-}" != "1" ]] \
   && [[ "${recipe_checks:-}" != *"no_example_echo: false"* ]]; then
  checks_run=$((checks_run + 1))
  # Exemplar --var values join the pattern set when the recipe declares them
  # (#428): commit-message returned one of its shape-anchor commits as its
  # subject. A line repeated across exemplars is convention (a trailer, a
  # footer) the output is supposed to reproduce, so only a line unique to one
  # exemplar is that exemplar's own content.
  echo_exemplars=$(echo_guard_values)
  [[ -n "$echo_exemplars" ]] && echo_exemplars="${echo_exemplars}
"
  # The convention filter judges on the normalised form (so `ci: X` and
  # `chore(deps): X (#253)` count as one line repeated) but hands echo_matches
  # the RAW line: echo_normalise is not idempotent, and a twice-normalised
  # pattern never matches a once-normalised echo. paste keeps the pairs
  # aligned because echo_normalise never drops a line.
  echoed_line=$( { printf '%s\n' "$recipe_template_raw"
    if [[ -n "$echo_exemplars" ]]; then
      paste -d "$(printf '\037')" \
        <(printf '%s' "$echo_exemplars" | echo_normalise) \
        <(printf '%s' "$echo_exemplars") \
        | awk -F "$(printf '\037')" '
            { seen[$1]++; form[NR] = $1; raw[NR] = $2 }
            END { for (i = 1; i <= NR; i++) if (seen[form[i]] == 1) print raw[i] }'
    fi; } | echo_matches "$output" | head -n 1)
  if [[ -n "$echoed_line" ]]; then
    # Boilerplate every artifact carries reaches the convention filter only
    # when more than one exemplar carries it; the fix belongs in the exemplar.
    fail_check no_example_echo "REJECT this draft. The model" \
      "  reproduced a line from its own prompt (the recipe's example, or one of the" \
      "  exemplars you passed as a shape anchor) instead of writing one from your" \
      "  content: \"${echoed_line:0:120}\"" \
      "  The draft is not grounded in the input. Re-run or hand-write; do not ship it." \
      "  If that line is boilerplate every artifact in the repo carries, strip it from" \
      "  the exemplar you passed (and pass two, so shared lines can be recognised as" \
      "  convention) rather than removing it from the answer."
  fi
fi

if [[ "${DELEGATE_LOCAL_NO_META:-}" != "1" ]] && (( status == 0 )) && [[ -n "${recipe_checks:-}" ]]; then
  # The participial arm is structural (`, <word>ing`) because per-verb
  # enumeration is a treadmill, and anchored to the line end because an
  # unanchored arm flagged mid-sentence clauses. Measured, do not simplify:
  # `([[:space:]]…)?` keeps `ing` a word ending (else every -ings plural
  # matches); the class permits commas but not a sentence boundary; `{0,200}`
  # keeps the match linear (unbounded is quadratic on a long line). ACCEPTED
  # GAP: a tail with a non-terminal full stop is not detected; #390 measured
  # recovering it and declined. The This-X arm stays enumerated.
  padding_re=',[[:space:]]+[a-z]{3,}ing([[:space:]][^.!?]{0,200})?[.!?]?[[:space:]]*$|(^|[.!?][[:space:]]+)(this[[:space:]]+(means|approach|ensures|enables|guarantees|delivers|provides|prevents|avoids|serves)|in summary|overall|consequently|ultimately|in effect|as a result)\b|(going|moving)[[:space:]]+forward|clos(es|ing)[[:space:]]+the[[:space:]]+(gap|loop)'
  # ADR 0017's adoption rule, byte-identical to the pre-anchor expression on
  # purpose: anchoring this second gate would widen the strip, adopting output
  # that still carries a mid-line participial. Detection narrows; adoption does not.
  padding_re_adopt=',[[:space:]]+[a-z]{3,}ing([[:space:]]|[.!?,]|$)|(^|[.!?][[:space:]]+)(this[[:space:]]+(means|approach|ensures|enables|guarantees|delivers|provides|prevents|avoids|serves)|in summary|overall|consequently|ultimately|in effect|as a result)\b|(going|moving)[[:space:]]+forward|clos(es|ing)[[:space:]]+the[[:space:]]+(gap|loop)'
  check_first_line=$(printf '%s' "$output" | awk 'NF { print; exit }')
  check_last_line=$(printf '%s' "$output" | awk 'NF { l=$0 } END { print l }')
  while IFS= read -r cline; do
    # In-process parse, no sed subshell per line.
    if [[ "$cline" =~ ^[[:space:]]*([a-zA-Z_]+):[[:space:]]*(.*)$ ]]; then
      ckey="${BASH_REMATCH[1]}"
      cval="${BASH_REMATCH[2]}"
      cval="${cval%"${cval##*[![:space:]]}"}"
    else
      continue
    fi
    case "$ckey" in
      subject_max)
        if [[ "$cval" =~ ^[0-9]+$ ]]; then
          checks_run=$((checks_run + 1))
          if (( ${#check_first_line} > 10#$cval )); then
            fail_check subject_max "first line is ${#check_first_line} chars (> $cval)"
          fi
        fi
        ;;
      no_padding_tail)
        if [[ "$cval" == "true" ]]; then
          checks_run=$((checks_run + 1))
          if printf '%s' "$check_last_line" | grep -Eiq "$padding_re"; then
            # Detection is broad for recall; the auto-strip is NARROWER for
            # precision: only a trailing ", <filler-gerund> ...<end>" clause
            # with the gerund in an allowlist and no comma inside, so a
            # meaningful participial stays a FAILED warning. Adopted only when
            # non-empty AND it clears the padding, so a FAILED verdict always
            # matches the emitted text. DELEGATE_NO_AUTOFIX=1 opts out.
            stripped=0
            if [[ "${DELEGATE_NO_AUTOFIX:-}" != "1" ]]; then
              new_output=$(printf '%s' "$output" | perl -0777 -pe '
                my @l = split /\n/, $_, -1;
                for (my $i = $#l; $i >= 0; $i--) {
                  next if $l[$i] =~ /^\s*$/;            # skip trailing blank lines
                  $l[$i] =~ s/(\S.*\S)\s*,\s+(?:ensuring|confirming|allowing|enabling|providing|leading|reflecting|making|supporting|helping|keeping|maintaining|delivering|guaranteeing|underscoring|highlighting|streamlining|facilitating|promoting|fostering|paving|cementing|reinforcing)\b[^,.!?]*([.!?])?\s*$/$1 . (defined $2 ? $2 : ".")/ie;
                  last;                                  # only the last non-empty line
                }
                $_ = join("\n", @l);
              ')
              if [[ -n "$new_output" && "$new_output" != "$output" ]]; then
                new_last=$(printf '%s' "$new_output" | awk 'NF { l=$0 } END { print l }')
                if ! printf '%s' "$new_last" | grep -Eiq "$padding_re_adopt"; then
                  output="$new_output"
                  check_first_line=$(printf '%s' "$output" | awk 'NF { print; exit }')
                  check_last_line="$new_last"
                  stripped=1
                fi
              fi
            fi
            if (( stripped )); then
              echo "delegate: check 'no_padding_tail' AUTO-FIXED — stripped a trailing participial padding clause" >&2
              checks_autofixed=$((checks_autofixed + 1))
            else
              fail_check no_padding_tail "output ends on a padding/restating clause"
            fi
          fi
        fi
        ;;
      subject_type)
        # `subject_type: {{type}}` is the caller's --var echoed; an omitted
        # optional type collapses to empty and the check is skipped. Pure
        # string ops, not a regex built from cval, so a metacharacter in the
        # --var cannot break the match; `!` and `(scope)` are stripped so the
        # full conventional shape is honoured.
        if [[ -n "$cval" ]]; then
          checks_run=$((checks_run + 1))
          subj_type="${check_first_line%%:*}"   # segment before the first colon
          subj_type="${subj_type%!}"            # drop a trailing ! (type!: form)
          subj_type="${subj_type%%(*}"          # drop a (scope) suffix
          if [[ "$check_first_line" != *:* || "$subj_type" != "$cval" ]]; then
            fail_check subject_type "subject does not start with '$cval:' (got '${check_first_line%%:*}:')"
          fi
        fi
        ;;
      body_required)
        # `printf '%s\n'` guarantees a trailing newline so awks that drop a
        # final unterminated line still count it; `tr -d '\r'` so a CRLF blank
        # separator (a lone \r is non-whitespace to awk) is not miscounted;
        # `+ 0` keeps the count numeric on empty output.
        if [[ "$cval" == "true" ]]; then
          checks_run=$((checks_run + 1))
          body_lines=$(printf '%s\n' "$output" | tr -d '\r' | awk 'NF { n++ } END { print n + 0 }')
          if (( body_lines < 2 )); then
            fail_check body_required "output is subject-only ($body_lines non-empty line(s), need >= 2)"
          fi
        fi
        ;;
      body_max_words)
        # Body length in words (everything after the first blank line). The
        # limit is a flavor placeholder: how long a body should be is house
        # style, tuned in profile.sh.
        if [[ "$cval" =~ ^[0-9]+$ ]]; then
          checks_run=$((checks_run + 1))
          # tr -d '\r' first: a CRLF blank separator is a lone \r, which mawk
          # (CI) does not count as [[:space:]], so the body would measure 0
          # words and always pass; BWK awk (macOS) hides the bug.
          body_words=$(printf '%s\n' "$output" | tr -d '\r' | awk '
            BEGIN { s = 0 }
            s { n += NF; next }
            /^[[:space:]]*$/ { s = 1 }
            END { print n + 0 }')
          if [[ "$body_words" =~ ^[0-9]+$ ]] && (( body_words > 10#$cval )); then
            fail_check body_max_words "body is $body_words words (> $cval)"
          fi
        fi
        ;;
      no_single_item_list)
        # A one-item numbered list breaks both reply recipes whichever branch
        # applies (two-plus asks get items, one ask is a sentence), so the
        # check needs no knowledge of the ask count. A check, not a third
        # rewording: the defect survived two prompt edits. Counting matches
        # body_required's idiom (`printf '%s\n'`, `tr -d '\r'`).
        if [[ "$cval" == "true" ]]; then
          checks_run=$((checks_run + 1))
          list_items=$(printf '%s\n' "$output" | tr -d '\r' \
            | awk '/^[[:space:]]*[0-9]+[.)][[:space:]]/ { n++ } END { print n + 0 }')
          if [[ "$list_items" =~ ^[0-9]+$ ]] && (( list_items == 1 )); then
            fail_check no_single_item_list "output is a numbered list of one item; a single ask is one sentence"
          fi
        fi
        ;;
      no_invented_task_list)
        # Either box state is a claim the model cannot support. A blanket ban
        # would be wrong: a repo whose PR template carries task boxes SHOULD
        # get them back, so the value names the --var holding the shape
        # authority and the check fires only when the output has a task list
        # and the examples have none. awk, not `grep -c`, because grep exits 1
        # on no match and the `|| echo 0` workaround double-emits.
        if [[ -n "$cval" ]]; then
          checks_run=$((checks_run + 1))
          # The pattern is the awk PROGRAM, not a -v value: awk escape-processes
          # -v values, so `\[` collapses to `[` and the bracket expression breaks.
          task_prog='/^[[:space:]]*[-*+][[:space:]]+\[[ xX]\][[:space:]]/ { n++ } END { print n + 0 }'
          out_tasks=$(printf '%s\n' "$output" | tr -d '\r' | awk "$task_prog")
          if [[ "$out_tasks" =~ ^[0-9]+$ ]] && (( out_tasks > 0 )); then
            authority=$(var_value "$cval" last)
            auth_tasks=$(printf '%s\n' "$authority" | tr -d '\r' | awk "$task_prog")
            if [[ "$auth_tasks" == "0" ]]; then
              fail_check no_invented_task_list "output carries $out_tasks markdown task-list item(s) but the '$cval' examples carry none; the shape was invented, and a task-list box asserts a verification state the model cannot know"
            fi
          fi
        fi
        ;;
      no_invented_headings)
        # Same contract as no_invented_task_list: the value names the --var
        # holding the shape authority, and the check fires only when the
        # output has a heading and the examples have none. Verify an exemplar
        # is heading-free before concluding a heading was invented. Fenced
        # blocks are skipped on both sides (a pasted shell snippet carries
        # `# comment` lines), and `#+[[:space:]]` leaves a shebang alone.
        if [[ -n "$cval" ]]; then
          checks_run=$((checks_run + 1))
          # The awk PROGRAM, for the same reason as the task-list one.
          head_prog='/^[[:space:]]*```/ { fence = !fence; next } !fence && /^[[:space:]]*#+[[:space:]]/ { n++ } END { print n + 0 }'
          out_heads=$(printf '%s\n' "$output" | tr -d '\r' | awk "$head_prog")
          if [[ "$out_heads" =~ ^[0-9]+$ ]] && (( out_heads > 0 )); then
            authority=$(var_value "$cval" last)
            auth_heads=$(printf '%s\n' "$authority" | tr -d '\r' | awk "$head_prog")
            if [[ "$auth_heads" == "0" ]]; then
              fail_check no_invented_headings "output carries $out_heads markdown heading(s) but the '$cval' examples carry none; the shape was invented rather than matched"
            fi
          fi
        fi
        ;;
      no_invented_refs)
        # A trailer identifier the model made up by continuing the examples'
        # numbering. Prompt-side attempts failed, and a `Wrong:` example
        # carrying a literal identifier was copied verbatim, so the grounding
        # set is the CALLER's inputs only (every --var plus stdin), never the
        # recipe template. Only trailer-shaped lines are scanned; the ticket
        # shape needs two-plus trailing digits so `UTF-8` stays out. KNOWN
        # GAP: `SHA-256` in a trailer would flag.
        if [[ "$cval" == "true" ]]; then
          checks_run=$((checks_run + 1))
          ref_ground=""
          for _kv in ${recipe_vars[@]+"${recipe_vars[@]}"}; do
            ref_ground="${ref_ground}${_kv#*=}
"
          done
          ref_ground="${ref_ground}${context}"
          # Token-for-token, not substring: a `grep -F` for `#427` matches
          # inside `#4271`, so an invented reference one digit short would pass.
          ref_ground=$(printf '%s\n' "$ref_ground" \
            | grep -oE '#[0-9]+|[A-Z][A-Z0-9]+-[0-9]{2,}' | sort -u)
          invented_refs=""
          while IFS= read -r ref_tok; do
            [[ -z "$ref_tok" ]] && continue
            grep -qxF -- "$ref_tok" <<<"$ref_ground" && continue
            invented_refs="${invented_refs:+$invented_refs }$ref_tok"
          done < <(printf '%s\n' "$output" | tr -d '\r' \
            | awk '/^[A-Za-z][A-Za-z0-9-]*:[[:space:]]/' \
            | grep -oE '#[0-9]+|[A-Z][A-Z0-9]+-[0-9]{2,}' \
            | sort -u)
          if [[ -n "$invented_refs" ]]; then
            fail_check no_invented_refs "trailer names $invented_refs, which appears in none of the inputs you supplied"
          fi
        fi
        ;;
      no_context_echo)
        # The piped context handed straight back, the mirror of no_example_echo
        # (#475). Same machinery (echo_matches) with the unit changed to
        # SENTENCES: facts arrive one per line and come back joined into a
        # paragraph, so a whole-line compare matched nothing. The pattern set
        # is stdin ONLY, never --var values (a --var is a verdict or ask the
        # recipe tells the model to place). Threshold TWO sentences: one
        # quoted back is the anchor-carrying the reply recipes ask for.
        if [[ "$cval" == "true" ]] && [[ "${DELEGATE_NO_ECHO_CHECK:-}" != "1" ]]; then
          checks_run=$((checks_run + 1))
          context_echoed=$(printf '%s\n' "$context" | split_sentences \
            | echo_matches "$(printf '%s\n' "$output" | split_sentences)")
          context_echoed_n=$(printf '%s' "$context_echoed" | grep -c '')
          if (( context_echoed_n >= 2 )); then
            fail_check no_context_echo "$context_echoed_n distinct sentence(s) of the answer reproduce sentences of the piped context verbatim, e.g. \"$(printf '%s\n' "$context_echoed" | head -n 1 | cut -c1-120)\"" \
              "  The draft restates the facts instead of curating them; carry the anchors inside new sentences."
          fi
        fi
        ;;
      max_context_ratio)
        # A length ceiling relative to the piped context (#487): the reply
        # recipes handed the fact sheet back at input size, and no_context_echo
        # measures echo, not length. A prose rule was tried and withdrawn (it
        # cannot be met on a three-line fact list). Applies only when the
        # context is at least min_context_chars (sibling key, default 400).
        # The ratio is a decimal, compared in awk since bash arithmetic is
        # integer-only.
        if [[ "$cval" =~ ^[0-9]*\.?[0-9]+$ ]]; then
          checks_run=$((checks_run + 1))
          ctx_floor=$(printf '%s\n' "$recipe_checks" | awk '
            { sub(/^[[:space:]]+/, "") }
            index($0, "min_context_chars:") == 1 { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }')
          [[ "$ctx_floor" =~ ^[0-9]+$ ]] || ctx_floor=400
          if (( ${#context} > 0 && ${#context} >= 10#$ctx_floor )); then
            ctx_ratio=$(awk -v o="${#output}" -v c="${#context}" 'BEGIN { printf "%.2f", o / c }')
            if awk -v o="${#output}" -v c="${#context}" -v r="$cval" 'BEGIN { exit !(o / c >= r) }'; then
              fail_check max_context_ratio "the answer is ${#output} chars against ${#context} chars of context (ratio $ctx_ratio >= $cval)" \
                "  The draft runs about as long as its facts; curate them, well under the facts' length, in sentences of your own."
            fi
          fi
        fi
        ;;
      no_unbidden_mention)
        # An @-mention of somebody the caller did not address the reply to.
        # The value names the --var holding the recipient handle, as
        # no_fact_as_question names the ask var; an empty or absent value
        # means there is no recipient, and then any mention is unbidden.
        # Measured 2026-09-22 on two maintainer-review-reply posts to
        # teams-for-linux: neither call passed `recipient`, and both drafts
        # opened by @-mentioning a bystander whose name the piped context
        # carried (the reporter of a referenced issue). Grounding cannot see
        # that, because the name IS in the input; what makes it wrong is that
        # it is not the person being replied to. The recipes say it in prose
        # already ("when it is empty there is no handle and no `@` at all, so
        # address the reader as you"), which is what a check is for once
        # prose has not held. A mention costs a real notification to someone
        # who is not in the thread, so the unit is the handle and one is
        # enough to fail.
        if [[ -n "$cval" ]]; then
          checks_run=$((checks_run + 1))
          # The first value of a key passed twice is the one the template
          # substituted. Every other --var is text the caller asked for word
          # for word (a lead, an opener, a sign-off), so a mention inside it
          # is the caller's, as no_fact_as_question treats caller questions.
          allowed=$(var_value "$cval")
          caller_text=""
          for _kv in ${recipe_vars[@]+"${recipe_vars[@]}"}; do
            [[ "${_kv%%=*}" == "$cval" ]] && continue
            caller_text="${caller_text}${_kv#*=}
"
          done
          # The caller writes the handle with or without the `@`; compare the
          # bare form, lowercased, as GitHub and GitLab resolve them.
          allowed=$(printf '%s' "$allowed" | tr -d '@[:space:]' | tr '[:upper:]' '[:lower:]')
          caller_mentions=$'\n'$(mentions_in "$caller_text")$'\n'
          unbidden=""
          while IFS= read -r mention_tok; do
            [[ -z "$mention_tok" ]] && continue
            [[ -n "$allowed" && "$mention_tok" == "$allowed" ]] && continue
            [[ "$caller_mentions" == *$'\n'"$mention_tok"$'\n'* ]] && continue
            unbidden="${unbidden:+$unbidden }@$mention_tok"
          done < <(mentions_in "$output")
          if [[ -n "$unbidden" && -n "$allowed" ]]; then
            fail_check no_unbidden_mention "the answer mentions $unbidden; the only handle you supplied is @$allowed, and a mention notifies whoever it names"
          elif [[ -n "$unbidden" ]]; then
            fail_check no_unbidden_mention "the answer mentions $unbidden; you supplied no '$cval', so the reply addresses the reader as \"you\" and names nobody"
          fi
        fi
        ;;
      no_fact_as_question)
        # A supplied fact handed back as a question to the reader (#513), the
        # defect STATED-NOT-ASKED forbids and 65 of 132 maintainer-reply
        # rejections described while one carried a failed check. The value
        # names the --var holding the caller's asks, as no_invented_task_list
        # names its authority: a question whose anchors are all in the piped
        # context and none in that var is a fact, not an ask. Context only,
        # never the other --var values, as no_context_echo; a question found
        # verbatim in any --var (an opener, a sign-off) is the caller's and
        # is skipped. Never retried on its own: the spike's validator arm
        # cleared 3 of 13 on a second pass.
        if [[ -n "$cval" ]]; then
          checks_run=$((checks_run + 1))
          authority=$(var_value "$cval" last)
          caller_text=""
          for _kv in ${recipe_vars[@]+"${recipe_vars[@]}"}; do
            caller_text="${caller_text}${_kv#*=}
"
          done
          fact_questions=$(fact_as_question_matches "$output" "$context" "$authority" "$caller_text")
          if [[ -n "$fact_questions" ]]; then
            fail_check no_fact_as_question "a supplied fact comes back as a question to the reader: \"$(printf '%s\n' "$fact_questions" | head -n 1 | cut -c1-120)\"" \
              "  What it asks about is in the piped facts and absent from the '$cval' var: the reader is asked to confirm what the facts already state. State it instead."
          fi
        fi
        ;;
      no_title_line)
        # pr-description's output is a body (#589): 9 of 40 rejected drafts on
        # template dfaad6df0739 opened with a title line, 2 the exemplar's own
        # and 2 with an invented PR number. A leading `type(scope): ...` or
        # `#N type: ...` line is stripped like no_padding_tail's tail, and
        # only when a blank line separates it from a body that follows, so a
        # title glued to prose or standing alone is reported, never guessed at.
        if [[ "$cval" == "true" ]]; then
          checks_run=$((checks_run + 1))
          if printf '%s\n' "$check_first_line" | grep -Eq '^[[:space:]]*(#[0-9]+:?[[:space:]]+)?(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]*\))?!?:[[:space:]]'; then
            new_output=""
            if [[ "${DELEGATE_NO_AUTOFIX:-}" != "1" ]]; then
              new_output=$(printf '%s\n' "$output" | awk '
                !t && !NF { next }
                !t { t = 1; next }
                t == 1 { if (NF) exit; t = 2; next }
                t == 2 && !NF { next }
                { t = 3; print }')
            fi
            if [[ -n "$new_output" ]]; then
              echo "delegate: check 'no_title_line' AUTO-FIXED — stripped a leading title line: \"${check_first_line:0:120}\"" >&2
              output="$new_output"
              check_first_line=$(printf '%s' "$output" | awk 'NF { print; exit }')
              check_last_line=$(printf '%s' "$output" | awk 'NF { l=$0 } END { print l }')
              checks_autofixed=$((checks_autofixed + 1))
            else
              fail_check no_title_line "output opens with a title line: \"${check_first_line:0:120}\""
            fi
          fi
        fi
        ;;
      no_subject_echo)
        # commit-message's subject copied from an exemplar subject (#589):
        # the prompt's own Wrong/Correct subjects or a recent commit passed
        # under echo_guard_vars. subject_echo_match has no floor and splits
        # joined subjects, the two gaps no_example_echo leaves here.
        if [[ "$cval" == "true" && "${DELEGATE_NO_ECHO_CHECK:-}" != "1" ]]; then
          checks_run=$((checks_run + 1))
          subj_echo=$(subject_echo_match "$check_first_line")
          if [[ -n "$subj_echo" ]]; then
            fail_check no_subject_echo "REJECT this draft. Its subject is an example's: \"${check_first_line:0:120}\""
          fi
        fi
        ;;
      min_context_chars)
        # The floor max_context_ratio reads out of the same block (above); a
        # setting, not a check of its own, so it is accepted and does nothing.
        ;;
      no_example_echo)
        # Handled before this loop (on by default); the key is only an opt-out.
        ;;
      *)
        echo "delegate: unknown check '$ckey' in recipe '$recipe' — ignored" >&2
        ;;
    esac
  done <<< "$recipe_checks"
fi
}
