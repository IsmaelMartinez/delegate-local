#!/usr/bin/env bash
# Text helpers shared by the output checks (lib/checks.sh) and the pair
# scoring (lib/pair-score.sh), so the sentence the evidence bundle names is
# the unit the wrapper's no_context_echo compares (#560). Filters read stdin
# and print one unit per line; nothing here reads a global. Sourcing has no
# side effects. bash 3.2 portable: awk, grep -E, sed -E only.

# echo_normalise — the ONE normalisation both echo checks apply to every
# pattern source and to the output; asymmetry is how no_example_echo failed
# twice. Any new rule goes here and nowhere else. sed -E because the optional
# `(scope)` needs an ERE group; BSD and GNU both take -E. Order matters: the
# label comes off before the type prefix.
echo_normalise() {
  sed -E -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
         -e 's/^[Ww]rong:[[:space:]]*//' -e 's/^[Cc]orrect:[[:space:]]*//' \
         -e 's/^[a-z]+(\([^)]*\))?!?:[[:space:]]*//' \
         -e 's/[[:space:]]*\(#[0-9]+\)$//'
}

# echo_matches — the ONE comparison both echo checks run. Units arrive RAW on
# stdin and in $1 and are normalised here exactly once (echo_normalise is not
# idempotent); pattern units under the 40-char floor are dropped, and the
# distinct answer units that reproduce a pattern unit are printed. Whole-unit,
# fixed-string (grep -F, linear). The caller chooses the unit: lines or sentences.
echo_matches() {
  echo_normalise \
    | awk 'length($0) >= 40' \
    | grep -Fxf - <(printf '%s\n' "$1" | echo_normalise) \
    | sort -u
}

# split_sentences — one unit per line, on newlines and on `.`/`?`/`!` followed
# by whitespace. The terminator is DROPPED on both sides: facts arrive as bare
# lines and the model closes them with a full stop, so keeping it made
# `<fact>` and `<fact>.` different units. Abbreviations split the same way on
# both sides, and a fragment that shape falls under the floor.
split_sentences() {
  awk '{ gsub(/[.?!]+[[:space:]]+/, "\n"); sub(/[.?!]+[[:space:]]*$/, "") } 1'
}

# question_units — the questions of the text on stdin, one per line, each
# ending in its `?`. Split where split_sentences splits, but the terminator is
# KEPT: it is what makes a unit a question. A numbered item's `1. ` prefix
# splits off as a unit of its own, so a MULTI-ASK-SPLIT question arrives bare.
question_units() {
  awk '{ gsub(/[.?!]+[[:space:]]+/, "&\n") } 1' | sed -E 's/[[:space:]]+$//' | grep -E '\?$'
}

# fact_anchors — the anchors of the text on stdin, one per line, sorted
# unique: issue refs, file:line, file names, numbers of two-plus digits,
# snake_case and camelCase identifiers. The spike's scorer regex (#513), in
# ERE; `\b` is honoured by BSD and GNU grep alike. Leftmost-longest keeps
# `#3359` one ref and `test_x.py` one file rather than an identifier.
fact_anchors() {
  grep -oE '#[0-9]+|\b[[:alnum:]_./-]+\.[[:alnum:]_]+:[0-9]+\b|\b[[:alnum:]_-]+\.(py|js|ts|sh|md|toml|json|ya?ml|go|c|h|txt)\b|\b[0-9]{2,}\b|\b[A-Za-z]+_[A-Za-z_]+\b|\b[a-z]+[A-Z][A-Za-z]+\b' \
    | sort -u
}

# content_words — the topic words of the text on stdin, one per line, sorted
# unique: lowercased words of four-plus letters, minus the function words a
# question is built from (modals, pronouns, prepositions). Without that
# subtraction "could", "that" and "your" match the ask on every question and
# exempt it; measured, the fallback below then flags nothing at all.
content_words() {
  tr 'A-Z' 'a-z' | grep -oE '\b[a-z][a-z-]{3,}\b' \
    | grep -vxE 'could|would|should|shall|will|have|does|been|were|being|that|this|these|those|what|which|when|where|whether|your|yours|them|they|their|there|here|each|both|same|other|another|such|some|many|much|most|more|very|else|itself|yourself|with|from|into|onto|upon|about|over|once|only|also|then|than|while|until|before|after|because|since|though|although|make|made|know|want|need|like|able|sure|must|might|please|just|still' \
    | sort -u
}

# mentions_in <text> — the @-mentions of a text, one per line, lowercased and
# deduped. Fenced blocks and inline code spans are dropped first, so a
# `@property` decorator or an `@Override` annotation inside a quoted snippet
# is not a mention. A fence closes, as in CommonMark, only on a bare run of
# its own character at least as long as the one that opened it, so a
# ```python line nested in a four-backtick block does not end the block; a
# fence that never closes is not a block, so its lines are scanned after all,
# as truncated output often leaves one. A scoped package (`@scope/pkg`) is
# dropped by its trailing slash; an email address never matches because its
# `@` is preceded by a word character. The handle class is one bounded
# quantifier and the fence run is counted by a plain loop, so both are linear.
mentions_in() {
  printf '%s\n' "$1" | tr -d '\r' \
    | awk 'function run(s, c,   n) { n = 0; while (substr(s, n + 1, 1) == c) n++; return n }
           { line = $0; sub(/^[[:space:]]*/, "", line); c = substr(line, 1, 1); n = 0
             if (c == "`" || c == "~") n = run(line, c) }
           !fence && n >= 3 { fence = 1; fc = c; fn = n; buf = ""; next }
           fence && c == fc && n >= fn && substr(line, n + 1) ~ /^[[:space:]]*$/ { fence = 0; buf = ""; next }
           fence { buf = buf $0 "\n"; next }
           { print }
           END { if (fence) printf "%s", buf }' \
    | sed 's/`[^`]*`//g' \
    | grep -oE '(^|[^A-Za-z0-9_./@-])@[A-Za-z0-9][A-Za-z0-9_-]{0,38}/?' \
    | grep -v '/$' \
    | sed 's/.*@//' \
    | tr '[:upper:]' '[:lower:]' | sort -u
}
