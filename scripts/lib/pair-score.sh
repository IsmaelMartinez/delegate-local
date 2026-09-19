#!/usr/bin/env bash
# Pair-scoring helpers shared by self-improve.sh (the evidence bundle) and
# replay-recipe.sh (the offline gate), so a rejection's DROPPED list and a
# replay's dropped count are the same measurement. Sourcing has no side
# effects. bash 3.2 portable: awk, grep -E, sed -E only.

# The feedback-to-delegation join, interpolated into every jq program that
# reads verdicts. Keyed on otel_span_id first and ts second (#481): ts is
# second-precision and INDEX(.ts) kept one row per second, so a verdict on
# the other sibling was filed under the wrong recipe. `pkey` collapses
# several verdicts on one delegation to the latest. A feedback row with
# neither ref_id nor ref_ts is skipped everywhere (`referenced`), as
# metrics-summary.sh skips it: keyed on the empty reference, every such row
# would share one pkey.
parent_join='
  def referenced: .source == "feedback" and (.ref_id != null or .ref_ts != null);
  (map(select((.source // "delegate") == "delegate" and .ts != null))) as $dl
  | (($dl | INDEX("ts:" + .ts)) + ($dl | map(select(.otel_span_id != null)) | INDEX("id:" + .otel_span_id))) as $d
  | def parent: $d["id:" + (.ref_id // "")] // $d["ts:" + (.ref_ts // "")];
  def pkey: parent as $p
    | if $p == null then (if (.ref_id // "") != "" then "id:" + .ref_id else "ts:" + .ref_ts end)
      elif $p.otel_span_id != null then "id:" + $p.otel_span_id
      else "ts:" + $p.ts end;
  def latest_verdicts: [.[] | select(referenced)] | sort_by(.ts) | INDEX(pkey) | [.[]];
'

# salient <file> — one salient token per line, deduped, lowercased: a
# backticked span, an issue ref, a dotted identifier or path, or a number of
# two or more digits. Extraction is literal or a flat alternation, so it is
# linear. DROPPED / INVENTED are set differences over these.
salient() {
  [[ -f "$1" ]] || return 0
  {
    grep -oE '`[^`]+`' "$1" 2>/dev/null | tr -d '`'
    grep -oE '#[0-9]+' "$1" 2>/dev/null
    grep -oE '[A-Za-z0-9_][A-Za-z0-9_-]*\.[A-Za-z0-9_]+[A-Za-z0-9_.:/-]*' "$1" 2>/dev/null
    grep -oE '[0-9]+' "$1" 2>/dev/null | awk 'length($0) >= 2'
  } | tr '[:upper:]' '[:lower:]' | sed 's/[.,;:)]*$//' | awk 'NF' | sort -u
}

# absent_from <file> — filter: reads salient tokens on stdin and prints the
# ones that do not occur in <file> as a case-insensitive substring. The
# extraction above is asymmetric between a backticked span and the same
# name written bare (`inLocale()` yields a token, inLocale() yields none),
# so a set difference alone reported four inventions on a 2026-09-19 draft
# whose every name was in the context. A token that is in the text, however
# it was written, was neither dropped nor invented.
absent_from() {
  local tok
  while IFS= read -r tok; do
    [[ -n "$tok" ]] || continue
    grep -qiF -- "$tok" "$1" 2>/dev/null || printf '%s\n' "$tok"
  done
}

# list_markers <file> — how many lines open with a list marker. grep -c
# prints 0 and exits 1 on no match, so a `|| echo 0` fallback would append a
# second zero.
list_markers() {
  local n
  [[ -f "$1" ]] || { echo 0; return 0; }
  n=$(grep -cE '^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]' "$1" 2>/dev/null)
  echo "${n:-0}"
}

# paragraphs <file> — how many blank-line-separated blocks. With
# list_markers it is the shape signal: a draft of one paragraph where three
# or more shipped is the collapse pr-description showed on 10 of 10 pairs on
# 2026-09-19 (drafts of 1 paragraph against shipped bodies of 3 to 7).
paragraphs() {
  [[ -f "$1" ]] || { echo 0; return 0; }
  awk 'BEGIN { RS=""; n=0 } { n++ } END { print n }' "$1" 2>/dev/null
}

# shape_mismatch <a> <b> — 1 when the two texts differ in shape: one is a
# list and the other prose, or one is a single paragraph and the other three
# or more. Symmetric, so a kept case scores a candidate that adds structure
# the same as one that removes it.
shape_mismatch() {
  local am bm ap bp
  am=$(list_markers "$1"); bm=$(list_markers "$2")
  ap=$(paragraphs "$1"); bp=$(paragraphs "$2")
  if { (( am > 0 )) && (( bm == 0 )); } || { (( bm > 0 )) && (( am == 0 )); }; then echo 1; return 0; fi
  if { (( ap == 1 )) && (( bp >= 3 )); } || { (( bp == 1 )) && (( ap >= 3 )); }; then echo 1; return 0; fi
  echo 0
}

# sentences — stdin to one sentence per line, terminator dropped, normalised,
# under the 40-char floor discarded: the unit, normalisation and floor
# no_context_echo applies in delegate.sh (split_sentences, echo_normalise,
# echo_matches), so the sentence the bundle names is the one the wrapper
# would have flagged. The sed is echo_normalise's, rule for rule and in its
# order: trim, the Wrong:/Correct: label, the commit type prefix, a trailing
# (#NNN). Not shared with delegate.sh because its helpers sit inside the
# checks region.
sentences() {
  awk '{ gsub(/[.?!]+[[:space:]]+/, "\n"); sub(/[.?!]+[[:space:]]*$/, "") } 1' \
    | sed -E -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
             -e 's/^[Ww]rong:[[:space:]]*//' -e 's/^[Cc]orrect:[[:space:]]*//' \
             -e 's/^[a-z]+(\([^)]*\))?!?:[[:space:]]*//' \
             -e 's/[[:space:]]*\(#[0-9]+\)$//' \
    | awk 'length($0) >= 40'
}
