#!/usr/bin/env bash
# One verdict model (#564): metrics-summary.sh and self-improve.sh read the
# same fixture over the same --days window and must report the same per-recipe
# verdict counts. The fixture carries the joins' edge cases: two delegations
# in one second with a ts-only verdict, an id-pinned hit followed by a newer
# ts-only miss, a revised verdict, a stored ritual verdict, and a ritual
# verdict recorded before the field (counted once `--ritual` has measured it).
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MS="$REPO/scripts/metrics-summary.sh"
SI="$REPO/scripts/self-improve.sh"

pass=0
fail=0
assert_eq() {
  local expected="$1" actual="$2" name="$3"
  if [[ "$expected" == "$actual" ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else printf '  FAIL  %s\n    expected: %s\n    got:      %s\n' "$name" "$expected" "$actual"; fail=$((fail+1)); fi
}

iso_ago() { perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-$ARGV[0]))' "$1"; }

# "recipe kept scaffold rewrote ritual", one line per recipe, sorted.
ms_counts() {
  sed -n '/^Per-recipe (delegate):/,/^$/p' | grep -E '^  [^ ]' | perl -ne '
    next unless /^  (\S+)\s+n=/; my $r = $1;
    my %v = map { $_ => 0 } qw(hits misses scaffold ritual);
    $v{$1} = $2 while /\b(hits|misses|scaffold|ritual)=(\d+)/g;
    print "$r kept=$v{hits} scaffold=$v{scaffold} rewrote=$v{misses} ritual=$v{ritual}\n";' | sort
}
si_counts() {
  sed -n '/^--- per-recipe outcomes/,/^$/p' | grep -E '^  [^ ]' | grep -v '^  (bare)' | perl -ne '
    next unless /^  (\S+)\s+n=/; my $r = $1;
    my %v = map { $_ => 0 } qw(kept scaffold rewrote ritual);
    $v{$1} = $2 while /\b(kept|scaffold|rewrote|ritual)=(\d+)/g;
    print "$r kept=$v{kept} scaffold=$v{scaffold} rewrote=$v{rewrote} ritual=$v{ritual}\n";' | sort
}

echo "== one verdict model: metrics-summary.sh and self-improve.sh agree =="

tmp=$(mktemp -d); mkdir -p "$tmp/drafts"
export DELEGATE_SELF_IMPROVE_STATE="$tmp/state"
T0=$(iso_ago 3100); T1=$(iso_ago 3000); t2=$(iso_ago 2900); t3=$(iso_ago 2800); t4=$(iso_ago 2700)
t5=$(iso_ago 2600); t6=$(iso_ago 2500); t7=$(iso_ago 2400)
RT='Thanks for the report. The crash comes from the tray icon handler, which reads the config before it is loaded. The fix ships in the next release.'
cat > "$tmp/metrics.jsonl" <<EOF
{"ts":"$T1","source":"delegate","recipe":"commit-message","session":"S1","tier":"prose","model":"q","exit_status":0,"otel_span_id":"a1","estimated_tokens_avoided":10}
{"ts":"$T1","source":"delegate","recipe":"commit-message","session":"S1","tier":"prose","model":"q","exit_status":0,"otel_span_id":"b1","estimated_tokens_avoided":10}
{"ts":"$(iso_ago 2990)","source":"feedback","ref_ts":"$T1","kept":false,"reason":"one verdict on a shared second"}
{"ts":"$T0","source":"delegate","recipe":"github-issue-body","session":"S0","tier":"prose","model":"q","exit_status":0,"estimated_tokens_avoided":10}
{"ts":"$T0","source":"delegate","recipe":"github-issue-body","session":"S0","tier":"prose","model":"q","exit_status":0,"estimated_tokens_avoided":10}
{"ts":"$(iso_ago 3090)","source":"feedback","ref_ts":"$T0","kept":false,"reason":"one verdict on a shared second, legacy rows with no id"}
{"ts":"$t2","source":"delegate","recipe":"pr-description","session":"S2","tier":"prose","model":"q","exit_status":0,"otel_span_id":"c1","estimated_tokens_avoided":10}
{"ts":"$(iso_ago 2890)","source":"feedback","ref_ts":"$t2","ref_id":"c1","kept":true}
{"ts":"$(iso_ago 2880)","source":"feedback","ref_ts":"$t2","kept":false,"reason":"changed my mind, ts-only"}
{"ts":"$t3","source":"delegate","recipe":"pr-description","session":"S2","tier":"prose","model":"q","exit_status":0,"otel_span_id":"d1","estimated_tokens_avoided":10}
{"ts":"$(iso_ago 2790)","source":"feedback","ref_ts":"$t3","ref_id":"d1","kept":false,"reason":"first look"}
{"ts":"$(iso_ago 2780)","source":"feedback","ref_ts":"$t3","ref_id":"d1","kept":true}
{"ts":"$t4","source":"delegate","recipe":"pr-description","session":"S2","tier":"prose","model":"q","exit_status":0,"otel_span_id":"e1","estimated_tokens_avoided":10}
{"ts":"$(iso_ago 2690)","source":"feedback","ref_ts":"$t4","ref_id":"e1","kept":false,"scaffold":true,"reason":"kept the frame"}
{"ts":"$t5","source":"delegate","recipe":"maintainer-reply","session":"S3","tier":"prose","model":"q","exit_status":0,"otel_span_id":"f1","draft_file":"f1.draft.txt","estimated_tokens_avoided":10}
{"ts":"$(iso_ago 2590)","source":"feedback","ref_ts":"$t5","ref_id":"f1","kept":false,"reason":"posted my own","final_file":"f1.final.txt","final_preexisting":true}
{"ts":"$t6","source":"delegate","recipe":"maintainer-reply","session":"S3","tier":"prose","model":"q","exit_status":0,"otel_span_id":"g1","draft_file":"g1.draft.txt","inputs_file":"g1.inputs.json","estimated_tokens_avoided":10}
{"ts":"$(iso_ago 2490)","source":"feedback","ref_ts":"$t6","ref_id":"g1","kept":false,"reason":"posted my own before the field","final_file":"g1.final.txt"}
{"ts":"$t7","source":"delegate","recipe":"maintainer-reply","session":"S4","tier":"prose","model":"q","exit_status":0,"otel_span_id":"h1","draft_file":"h1.draft.txt","estimated_tokens_avoided":10}
{"ts":"$(iso_ago 2390)","source":"feedback","ref_ts":"$t7","ref_id":"h1","kept":false,"reason":"rewrote the ask","final_file":"h1.final.txt","final_preexisting":false}
EOF
for s in f1 g1 h1; do printf 'A model draft for %s about something else entirely.\n' "$s" > "$tmp/drafts/$s.draft.txt"; done
printf '%s\n' "$RT" > "$tmp/drafts/f1.final.txt"
printf '%s\n' "$RT" > "$tmp/drafts/g1.final.txt"
jq -nc --arg s "Post this:
$RT" '{recipe:"maintainer-reply", stdin:$s, vars:{}}' > "$tmp/drafts/g1.inputs.json"
printf 'My own reply, nothing like the facts.\n' > "$tmp/drafts/h1.final.txt"

# Before the backfill only the stored tag is ritual: g1 is the miss it recorded.
want_before='commit-message kept=0 scaffold=0 rewrote=1 ritual=0
github-issue-body kept=0 scaffold=0 rewrote=1 ritual=0
maintainer-reply kept=0 scaffold=0 rewrote=2 ritual=1
pr-description kept=1 scaffold=1 rewrote=1 ritual=0'
ms_out=$(bash "$MS" --file "$tmp/metrics.jsonl" --days 7 2>&1)
si_out=$(bash "$SI" --peek --file "$tmp/metrics.jsonl" --days 7 2>&1)
assert_eq "$want_before" "$(printf '%s\n' "$ms_out" | ms_counts)" \
  "metrics-summary: one verdict per delegation, latest wins across id and ts pins"
assert_eq "$want_before" "$(printf '%s\n' "$si_out" | si_counts)" \
  "self-improve: the same counts from the same fixture and window"
assert_eq "$(printf '%s\n' "$ms_out" | ms_counts)" "$(printf '%s\n' "$si_out" | si_counts)" \
  "the two scripts agree before the ritual backfill"

# --ritual measures the verdict recorded before the field and writes the
# sidecar both scripts read, so g1 leaves both rates together.
bash "$SI" --ritual --file "$tmp/metrics.jsonl" > /dev/null 2>&1
assert_eq "present" "$([[ -s "$tmp/ritual-verdicts.tsv" ]] && echo present || echo absent)" \
  "--ritual writes ritual-verdicts.tsv beside the metrics file"
want_after='commit-message kept=0 scaffold=0 rewrote=1 ritual=0
github-issue-body kept=0 scaffold=0 rewrote=1 ritual=0
maintainer-reply kept=0 scaffold=0 rewrote=1 ritual=2
pr-description kept=1 scaffold=1 rewrote=1 ritual=0'
ms_out=$(bash "$MS" --file "$tmp/metrics.jsonl" --days 7 2>&1)
si_out=$(bash "$SI" --peek --file "$tmp/metrics.jsonl" --days 7 2>&1)
assert_eq "$want_after" "$(printf '%s\n' "$ms_out" | ms_counts)" \
  "metrics-summary: a measured ritual verdict counts as ritual after the backfill"
assert_eq "$want_after" "$(printf '%s\n' "$si_out" | si_counts)" \
  "self-improve: the same measured ritual verdict, the same counts"

# Drafts, inputs and finals are pruned after DELEGATE_DRAFT_RETENTION_DAYS: a
# rerun of --ritual once they are gone keeps what the sidecar already held.
rm -f "$tmp/drafts/g1.final.txt" "$tmp/drafts/g1.inputs.json"
bash "$SI" --ritual --file "$tmp/metrics.jsonl" > /dev/null 2>&1
assert_eq 1 "$(grep -c "|g1	" "$tmp/ritual-verdicts.tsv")" \
  "--ritual rerun after the files are pruned keeps the earlier measurement, once"
assert_eq "$want_after" "$(bash "$MS" --file "$tmp/metrics.jsonl" --days 7 2>&1 | ms_counts)" \
  "metrics-summary still counts the pruned verdict as ritual"

# A final the quarantine lists is never ritual, measured or stored.
printf 'g1.final.txt\tneighbour\thook\n' > "$tmp/suspect-finals.tsv"
ms_out=$(bash "$MS" --file "$tmp/metrics.jsonl" --days 7 2>&1)
si_out=$(bash "$SI" --peek --file "$tmp/metrics.jsonl" --days 7 2>&1)
assert_eq "$(printf '%s\n' "$ms_out" | ms_counts)" "$(printf '%s\n' "$si_out" | si_counts)" \
  "the two scripts agree once a measured final is quarantined"
assert_eq "maintainer-reply kept=0 scaffold=0 rewrote=2 ritual=1" "$(printf '%s\n' "$ms_out" | ms_counts | grep '^maintainer-reply')" \
  "a quarantined measured final is not ritual"
rm -rf "$tmp"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
