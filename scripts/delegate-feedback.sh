#!/usr/bin/env bash
# Append a hit/miss/scaffold feedback row to the delegate metrics JSONL,
# referencing the `source:"delegate"` row pinned by `--id <otel_span_id>` (or
# `--ts`), or the one row inside the freshness window when no pin is given.
# Feedback rows are keyed by `ref_ts` (and `ref_id`) to the row they judge and
# `metrics-summary.sh` joins them at read time. Every row carries
# verdict_source:"agent", the one verdict tier (ADR 0030).
#
# Usage:  delegate-feedback.sh [--id <otel_span_id>|--ts <iso8601>]
#                              [--source agent] [--final <path>|-]
#                              hit|miss|scaffold [reason words...]
# Env:
#   DELEGATE_LOCAL_DATA_DIR                 per-user data (default ~/.local/share/delegate-local)
#   DELEGATE_METRICS_FILE                   override the metrics path
#   DELEGATE_FEEDBACK_STALE_SECONDS         unpinned lookup window (default 300;
#                                           0 attaches to the newest row unbounded)
#   DELEGATE_FEEDBACK_REPEAT_WINDOW_SECONDS window for the pasted-reason warning
#                                           (default 600; 0 disables)
#   DELEGATE_FEEDBACK_NO_NUDGE=1            silence the MISS-recurrence nudge
#   DELEGATE_FEEDBACK_NUDGE_AT              similar MISSes, this one included,
#                                           that trigger it (default 3)
#   DELEGATE_FEEDBACK_NUDGE_WINDOW_DAYS     lookback for similar MISSes (default 30)
#   DELEGATE_FEEDBACK_SIMILAR_THRESHOLD     Jaccard threshold over content tokens
#                                           (default 0.4)
#   DELEGATE_GITHUB_REPO                    owner/repo for the draft issue command
#                                           (default IsmaelMartinez/delegate-local)
#   DELEGATE_OTEL_ENDPOINT                  POST a feedback span linked to the
#                                           parent delegation (ADR 0007); synchronous
#   DELEGATE_OTEL_TIMEOUT                   default 5
#   DELEGATE_OTEL_VERBOSE=1                 log exporter failures (silent by default)
#   DELEGATE_OTEL_HEADERS                   comma-separated; values url-encoded
#   DELEGATE_OTEL_INCLUDE_CONTENT=1         send the free-text reason on the span;
#                                           off by default, it may carry secrets
# Exit:   0 OK, 1 file/event missing or stale, 2 usage error. OTLP-export
#         failures never change the exit status.

set -uo pipefail

metrics_file="${DELEGATE_METRICS_FILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/metrics.jsonl}"
stale_seconds="${DELEGATE_FEEDBACK_STALE_SECONDS:-300}"
github_repo="${DELEGATE_GITHUB_REPO:-IsmaelMartinez/delegate-local}"

usage() {
  cat >&2 <<'EOF'
usage: delegate-feedback.sh [--id <otel_span_id>|--ts <iso8601>] [--source agent]
                           [--final <path>|-] hit|miss|scaffold [reason words...]
  hit = output kept as-is; miss = rewritten/discarded as useless; scaffold =
  discarded but genuinely useful (a divergent or executable draft that improved
  the final result). scaffold is recorded distinct from both and never fires the
  MISS-recurrence nudge. A miss or scaffold REQUIRES a reason: the agent
  recording its own just-finished delegation always knows why it rewrote the
  draft, and a rejection with no reason counts in every denominator while
  telling the loop nothing.
  --id pins the verdict to one delegate row by its otel_span_id — the value
  delegate.sh prints on its delegate-meta line as id="..." and in the
  verdict nudge. It is the only pin that cannot name two rows: ts has
  second precision and parallel delegations share it, so --ts (kept for
  older callers) refuses when more than one row carries that second.
  Without a pin, the verdict attaches to the one delegate row inside the
  freshness window (default 300 s); with parallel sessions "most recent" is
  routinely someone else's, so two fresh rows refuse and list the
  candidates with their ids, and none refuses as stale. The verdict's
  project is copied from the row it references.
  --source agent is the default and the only value: the agent that used or
  rewrote the draft records the verdict (ADR 0030). The flag is accepted so
  existing callers keep working; --source human is refused, because that
  tier was retired.
  --final stores the text that ACTUALLY shipped (a file path, or - for
  stdin) beside the captured draft, so a MISS carries the concrete
  (generated, shipped) pair instead of only a prose description of the
  difference. This is the signal recipe edits are calibrated from.
  All three flags may appear anywhere on the line, including after the
  reason words. Put `--` before the verdict when the reason itself needs
  to name a flag, e.g. `-- miss "the nudge should say --final"`.
EOF
  exit 2
}

# Flags are honoured wherever they appear, before or after the verdict and
# the reason words: parsing that stopped at the verdict recorded reasons
# ending `--final <path>` and stored nothing. `--` ends flag parsing for a
# reason that has to name a flag.
override_ts=""
override_id=""
verdict_source="agent"
final_src=""
positional=()
while (($# > 0)); do
  case "$1" in
    --id)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo 'delegate-feedback: --id requires a value (the row otel_span_id from delegate-meta id="...")' >&2; exit 2
      fi
      override_id="$2"; shift 2;;
    --id=*)
      override_id="${1#--id=}"
      if [[ -z "$override_id" ]]; then
        echo 'delegate-feedback: --id requires a value (the row otel_span_id from delegate-meta id="...")' >&2; exit 2
      fi
      shift;;
    --final)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo 'delegate-feedback: --final requires a path or -' >&2; exit 2
      fi
      final_src="$2"; shift 2;;
    --final=*)
      final_src="${1#--final=}"
      if [[ -z "$final_src" ]]; then
        echo 'delegate-feedback: --final requires a path or -' >&2; exit 2
      fi
      shift;;
    --ts)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo 'delegate-feedback: --ts requires a value' >&2; exit 2
      fi
      override_ts="$2"; shift 2;;
    --ts=*)
      override_ts="${1#--ts=}"
      if [[ -z "$override_ts" ]]; then
        echo 'delegate-feedback: --ts requires a value' >&2; exit 2
      fi
      shift;;
    --source)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo 'delegate-feedback: --source requires a value (agent)' >&2; exit 2
      fi
      verdict_source="$2"; shift 2;;
    --source=*)
      verdict_source="${1#--source=}"
      if [[ -z "$verdict_source" ]]; then
        echo 'delegate-feedback: --source requires a value (agent)' >&2; exit 2
      fi
      shift;;
    -h|--help) usage;;
    --) shift; while (($# > 0)); do positional+=("$1"); shift; done;;
    *) positional+=("$1"); shift;;
  esac
done
# bash 3.2 expands an empty array under `set -u` as unbound, so the `+` form
# is load-bearing: no arguments at all must reach the usage check.
set -- ${positional[@]+"${positional[@]}"}

# One verdict tier (ADR 0030). `--source human` is refused by name so the
# caller knows the tier is retired rather than misspelt.
case "$verdict_source" in
  agent) ;;
  human) echo "delegate-feedback: --source human is no longer a tier — the agent that used the draft records the verdict (ADR 0030); drop the flag" >&2; exit 2 ;;
  *) echo "delegate-feedback: --source must be 'agent' (got '$verdict_source')" >&2; exit 2 ;;
esac

if [[ -n "$final_src" && "$final_src" != "-" && ! -f "$final_src" ]]; then
  echo "delegate-feedback: --final file not found: $final_src" >&2; exit 2
fi
# Two pins name one row twice; if they disagree there is no right answer, and
# if they agree one of them is noise. Refuse rather than pick.
if [[ -n "$override_id" && -n "$override_ts" ]]; then
  echo 'delegate-feedback: pass --id or --ts, not both' >&2; exit 2
fi

[[ $# -ge 1 ]] || usage

# `scaffold` writes kept:false (so a kept-only reader never inflates hit-rate)
# plus scaffold:true; it is not a miss and does not fire the recurrence nudge.
case "$1" in
  hit)      kept=true;  verdict=hit;      is_scaffold=false ;;
  miss)     kept=false; verdict=miss;     is_scaffold=false ;;
  scaffold) kept=false; verdict=scaffold; is_scaffold=true ;;
  *) echo "first arg must be 'hit', 'miss', or 'scaffold' (got '$1')" >&2; usage ;;
esac
shift
reason="$*"

# A rejection with no reason counts in every denominator and tells the loop
# nothing; the agent recording its own just-finished delegation always knows.
if [[ "$kept" == "false" && -z "${reason// }" ]]; then
  echo "delegate-feedback: a '$verdict' needs a reason." >&2
  echo "  It is the only thing that makes the row actionable — the rate it moves" >&2
  echo "  is computed either way. Name what was wrong with the draft:" >&2
  echo "    delegate-feedback.sh $verdict \"dropped every file:line anchor\"" >&2
  echo "  and on a miss or scaffold add --final <path|-> naming what you shipped." >&2
  exit 2
fi

# The migration hint (#360) is repeated here rather than shared on purpose.
if [[ ! -f "$metrics_file" ]]; then
  echo "metrics file not found: $metrics_file" >&2
  _legacy="$HOME/.claude/skills/delegate-local/metrics.jsonl"
  if [[ -f "$_legacy" ]]; then
    echo "  $_legacy exists with $(grep -c '' "$_legacy" 2>/dev/null || echo 0) rows" >&2
    echo "  migrate it: bash scripts/onboard.sh --migrate-data" >&2
  fi
  exit 1
fi
command -v jq >/dev/null || { echo "jq not on PATH" >&2; exit 2; }

# Shared with delegate.sh and backfill-otel.sh; sourcing has no side effects.
_fb_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/otel.sh
. "$_fb_script_dir/lib/otel.sh"

# Select the delegate row this verdict is about: ONE row, ONE pass, and every
# field the rest of the script needs comes off that same row; two scans with
# the same select once paired caller A's final with sibling B's draft.
#   --id     exact match on otel_span_id, the one key two rows cannot share
#   --ts     rows sharing that second are an ambiguity: refuse and list them
#   window   exactly one delegate row inside the window is the row; more
#            refuses, none is the stale refusal. Taken from this pass, not
#            the last line: ts is the start time, so a long delegation lands
#            after a shorter one it preceded. Cutoff resolved in jq, so no
#            BSD-vs-GNU `date` split.
#   all      STALE_SECONDS=0: the unbounded newest row
# The separator is US (\037), not a tab: tab is IFS whitespace, so `read`
# would collapse an empty recipe field and shift project.
if [[ -n "$override_id" ]]; then
  pin_mode="id"; pin_desc="--id $override_id"
elif [[ -n "$override_ts" ]]; then
  pin_mode="ts"; pin_desc="--ts $override_ts"
elif [[ "$stale_seconds" -gt 0 ]]; then
  pin_mode="window"; pin_desc="the last ${stale_seconds}s"
else
  pin_mode="all"; pin_desc="the metrics file"
fi
# Banked once: the freshness cutoff here and the repeat-reason cutoff below
# both count back from the same instant.
now_epoch=$(jq -n 'now | floor')
candidates=$(jq -r --arg mode "$pin_mode" --arg id "$override_id" --arg ts "$override_ts" \
  --argjson cutoff "$(( now_epoch - stale_seconds ))" \
  'select((.source // "delegate") == "delegate")
   | select(if $mode == "id" then .otel_span_id == $id
            elif $mode == "ts" then .ts == $ts
            elif $mode == "window" then ((.ts // "") | fromdateiso8601?) >= $cutoff
            else true end)
   | [.ts, (.otel_span_id // ""), (.otel_trace_id // ""), (.model // ""), (.recipe // ""), (.project // ""), (.draft_file // "")]
   | join("\u001f")' \
  "$metrics_file")
[[ "$pin_mode" == "all" ]] && candidates=$(printf '%s\n' "$candidates" | tail -n 1)
n_candidates=$(printf '%s' "$candidates" | grep -c '')

if (( n_candidates == 0 )); then
  case "$pin_mode" in
    id|ts)
      echo "delegate-feedback: $pin_desc does not match any delegate row in $metrics_file" >&2
      exit 1 ;;
    window)
      # Nothing inside the window: refuse rather than silently attach to a
      # row that is probably not the delegation the caller meant.
      newest=$(jq -r 'select((.source // "delegate") == "delegate") | .ts' "$metrics_file" | tail -n 1)
      if [[ -z "$newest" || "$newest" == "null" ]]; then
        echo "no recent delegate event found in $metrics_file" >&2
        exit 1
      fi
      age=$(jq -rn --arg t "$newest" '($t | fromdateiso8601?) as $e | if $e == null then "?" else ((now | floor) - $e | tostring) end')
      cat >&2 <<MSG
delegate-feedback: most recent delegate row is ${age}s old (> ${stale_seconds}s).
  ts=$newest is likely not the delegation you mean. Pass --id <otel_span_id>
  (delegate-meta prints it as id="...") to pin the verdict explicitly, or set
  DELEGATE_FEEDBACK_STALE_SECONDS=0 to disable this check.
MSG
      exit 1 ;;
    *)
      echo "no recent delegate event found in $metrics_file" >&2
      exit 1 ;;
  esac
fi
if (( n_candidates > 1 )); then
  cat >&2 <<MSG
delegate-feedback: $n_candidates delegate rows match $pin_desc, so the row this
  verdict is about is ambiguous. Pass --id <otel_span_id> naming it
  (delegate-meta prints it as id="..."):
MSG
  printf '%s\n' "$candidates" | awk -F "$(printf '\037')" '{ printf "    %s  %s  %s  %s\n", ($2 == "" ? "-" : $2), $1, ($5 == "" ? "(bare)" : $5), ($6 == "" ? "-" : $6) }' >&2
  exit 1
fi
IFS=$'\037' read -r ref_ts ref_id parent_trace_id parent_model parent_recipe feedback_project parent_draft <<< "$candidates"
parent_span_id="$ref_id"

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --final: store the text that actually shipped beside the captured draft
# (<stem>.final.txt next to <stem>.draft.txt), the pair recipe edits are
# calibrated from. Local, never transmitted; failure to write is non-fatal.
final_file=""
final_source=""
drafts_dir="$(dirname "$metrics_file")/drafts"
# Named after the DRAFT the selected row points at, not after ref_ts: ref_ts
# has second precision and parallel delegations share it, so a ts-derived
# name would overwrite another delegation's shipped text. The ts fallback is
# for rows with no draft, which cannot collide with a real draft's suffixed
# name. Untrusted: it comes out of a JSONL file and becomes part of a path
# this script writes, so a bare *.draft.txt filename only.
case "$parent_draft" in
  *.draft.txt) [[ "$parent_draft" == */* || "$parent_draft" == .* ]] && parent_draft="" ;;
  *) parent_draft="" ;;
esac

if [[ -n "$final_src" ]]; then
  if [[ -n "$parent_draft" ]]; then
    final_stem="${parent_draft%.draft.txt}"
  else
    final_stem="$(printf '%s' "$ref_ts" | tr -d ':-')-nodraft"
  fi
  # Never overwrite an existing final (#474): a second final on the stem is
  # the boundary hook's capture or another verdict's, so each further one
  # takes the next free number and the row names the file it wrote. The name
  # is claimed by the open: `set -C` makes `>` fail on an existing file at
  # the redirect, before `cat` runs, so stdin is untouched on a failed claim.
  # Claim and copy are two steps because they fail for different reasons: an
  # existing name means try the next number, anything else ends the loop.
  # 700 on the directory, 600 on the file, written under `umask 077`.
  if mkdir -p "$drafts_dir" 2>/dev/null; then
    chmod 700 "$drafts_dir" 2>/dev/null || true
    final_n=1
    while :; do
      if (( final_n == 1 )); then final_name="$final_stem.final.txt"; else final_name="$final_stem.final.$final_n.txt"; fi
      if ( umask 077; set -C; : > "$drafts_dir/$final_name" ) 2>/dev/null; then
        if [[ "$final_src" == "-" ]]; then
          cat > "$drafts_dir/$final_name" 2>/dev/null && final_file="$final_name"
        else
          cat "$final_src" > "$drafts_dir/$final_name" 2>/dev/null && final_file="$final_name"
        fi
        [[ -n "$final_file" ]] || rm -f "$drafts_dir/$final_name"
        break
      fi
      [[ -e "$drafts_dir/$final_name" ]] || break
      final_n=$((final_n + 1))
    done
    [[ -n "$final_file" ]] && chmod 600 "$drafts_dir/$final_file" 2>/dev/null
  fi
  if [[ -z "$final_file" ]]; then
    echo "delegate-feedback: could not store --final text (verdict still recorded)" >&2
  elif (( final_n > 1 )); then
    # Worth a line, because an existing final usually means this is not the
    # delegation the caller thinks it is.
    echo "delegate-feedback: $final_stem.final.txt already exists (a final was already stored against ts=$ref_ts); this one is stored as $final_file" >&2
  fi
elif [[ -n "$parent_draft" && "$kept" == "false" ]]; then
  # No --final, but the boundary hook may have stored what was posted under
  # the draft's stem: a credited post IS the delegation's shipped form, and
  # this is the only capture path for the inline-posted reply recipes. An
  # explicit --final always wins and is stored beside this file. `final_source`
  # marks a pair inferred from a post; a bare final an earlier verdict vouched
  # for with --final must not be relabelled, which that earlier row's lack of
  # the `posted` marker tells apart.
  adopt_name="${parent_draft%.draft.txt}.final.txt"
  if [[ -f "$drafts_dir/$adopt_name" ]]; then
    final_file="$adopt_name"
    vouched=$(jq -r --arg ts "$ref_ts" --arg f "$adopt_name" \
      'select(.source == "feedback" and .ref_ts == $ts and .final_file == $f and (.final_source // "") != "posted") | .ts' \
      "$metrics_file" | head -n 1)
    [[ -z "$vouched" ]] && final_source="posted"
  fi
fi

# A rejection whose reason is byte-identical to one recorded minutes ago on
# another delegation is a sweep pasting one verdict (#487): warn with the
# count and write the row anyway, since refusing would leave the batch
# untracked. Only prior REJECTIONS on OTHER delegations count; a second
# verdict on the same row is a revision, not a sweep. 0 is the OFF switch
# here, the opposite of STALE_SECONDS, because a zero-width lookback has
# nothing to compare against.
repeat_window="${DELEGATE_FEEDBACK_REPEAT_WINDOW_SECONDS:-600}"
if [[ ! "$repeat_window" =~ ^[0-9]+$ ]]; then
  echo "delegate-feedback: DELEGATE_FEEDBACK_REPEAT_WINDOW_SECONDS='$repeat_window' is not a number of seconds; using 600" >&2
  repeat_window=600
fi
if [[ "$kept" == "false" && -n "$reason" ]] && (( repeat_window > 0 )); then
  repeat_n=$(jq -r --arg r "$reason" --arg ref "$ref_ts" --arg refid "$ref_id" --argjson cutoff "$(( now_epoch - repeat_window ))" \
    'select(.source == "feedback" and (.kept == false) and (.reason // "") == $r
            and ((.ts // "") | fromdateiso8601?) >= $cutoff
            and (if ($refid != "" and (.ref_id // "") != "") then (.ref_id != $refid) else ((.ref_ts // "") != $ref) end)) | .ts' \
    "$metrics_file" | grep -c '')
  if (( repeat_n > 0 )); then
    if (( repeat_window % 60 == 0 )); then repeat_desc="$((repeat_window / 60)) min"; else repeat_desc="${repeat_window}s"; fi
    echo "delegate-feedback: this reason was already recorded $repeat_n time(s) in the last $repeat_desc — a sweep pasting one verdict teaches the loop nothing; record what THIS draft did" >&2
  fi
fi

# One jq call; optional fields are appended only when present. `project` is
# the referenced row's, never the cwd's, so the verdict lands where the
# delegation did whatever shell records it. `ref_id` is written beside
# `ref_ts` as the key two delegations cannot share.
jq -nc --arg ts "$ts" --arg ref "$ref_ts" --arg refid "$ref_id" --argjson kept "$kept" --argjson scaffold "$is_scaffold" --arg reason "${reason:-}" --arg project "$feedback_project" --arg vsource "$verdict_source" --arg final "$final_file" --arg finalsrc "$final_source" \
  '{ts:$ts, source:"feedback", ref_ts:$ref} + (if $refid != "" then {ref_id:$refid} else {} end) + {kept:$kept} + (if $scaffold then {scaffold:true} else {} end) + (if $reason != "" then {reason:$reason} else {} end) + (if $project != "" then {project:$project} else {} end) + {verdict_source:$vsource} + (if $final != "" then {final_file:$final} else {} end) + (if $finalsrc != "" then {final_source:$finalsrc} else {} end)' \
  >> "$metrics_file"

case "$verdict" in
  hit)      verdict_word="HIT" ;;
  miss)     verdict_word="MISS" ;;
  scaffold) verdict_word="SCAFFOLD" ;;
esac

# emit_otel_feedback_span omits `links` when the parent IDs are unknown and
# delegate.recipe when the parent was a bare-tier call.
emit_otel_feedback_span "$ts" "$verdict" "$reason" "$parent_trace_id" "$parent_span_id" "$parent_model" "$parent_recipe" "$feedback_project" "$verdict_source"

echo "$verdict_word recorded against delegate ts=$ref_ts${reason:+ ($reason)}"

# Trigger-on-MISS nudge (#88): Jaccard similarity over content tokens against
# recent MISS reasons, on MISS only. The just-appended row is excluded by ts.
if [[ "$verdict" == "miss" && "${DELEGATE_FEEDBACK_NO_NUDGE:-0}" != "1" && -n "$reason" ]]; then
  nudge_at="${DELEGATE_FEEDBACK_NUDGE_AT:-3}"
  window_days="${DELEGATE_FEEDBACK_NUDGE_WINDOW_DAYS:-30}"
  similar_threshold="${DELEGATE_FEEDBACK_SIMILAR_THRESHOLD:-0.4}"
  window_secs=$((window_days * 86400))

  # Perl rather than awk: the matcher needs JSON parsing and floating-point
  # Jaccard. Output is one `SIMILAR_COUNT=<n>` line plus `<ts>\t<reason>` per match.
  matcher_out=$(perl -MJSON::PP -MTime::Local=timegm -e '
    use strict; use warnings;
    my ($new_reason, $threshold, $window_secs, $self_ts) = @ARGV;
    my $now = time;
    my %STOP = map { $_ => 1 } qw(
      the a an and or but is was were be been being am are
      for to from with on in of at by into onto out up down
      this that these those it its also too just only very
      has have had do does did can could should would shall
      will may might must about against some any all most
      more less few many much over under above below than then
      not no nor so yet still already even either neither
      such same other another own here there where when how why
    );
    sub toks {
      my $s = lc(shift // "");
      my %seen;
      grep { length >= 3 && !$STOP{$_} && !$seen{$_}++ }
        grep { length } split /\W+/, $s;
    }
    my @new_t = toks($new_reason);
    my %new_set = map { $_ => 1 } @new_t;
    if (!@new_t) { print "SIMILAR_COUNT=0\n"; exit 0; }

    my $similar = 0;
    my @rows;
    while (my $line = <STDIN>) {
      my $j = eval { decode_json($line) };
      next unless ref $j eq "HASH";
      next unless ($j->{source} // "") eq "feedback";
      next if  $j->{kept};                      # only MISS rows
      next if  $j->{scaffold};                  # scaffold is useful, not a miss
      next unless $j->{ts};
      next if $j->{ts} eq $self_ts;             # skip the just-appended row
      if ($window_secs > 0 && $j->{ts} =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/) {
        my $epoch = timegm($6, $5, $4, $3, $2-1, $1);
        next if ($now - $epoch) > $window_secs;
      }
      my @h_t = toks($j->{reason} // "");
      next unless @h_t;
      # Inclusion-exclusion; both token lists are already deduped by toks().
      my $inter = 0; for my $t (@h_t) { $inter++ if $new_set{$t} }
      my $union = scalar(@new_t) + scalar(@h_t) - $inter;
      next if $union == 0;
      my $jac = $inter / $union;
      if ($jac >= $threshold) {
        $similar++;
        my $r = $j->{reason} // "";
        $r =~ s/\s+/ /g;
        $r = substr($r, 0, 100) . (length($r) > 100 ? "…" : "");
        push @rows, sprintf("%s\t%s", $j->{ts}, $r);
      }
    }
    print "SIMILAR_COUNT=$similar\n";
    for (@rows) { print "$_\n" }
  ' "$reason" "$similar_threshold" "$window_secs" "$ts" < "$metrics_file" 2>/dev/null) || matcher_out=""

  if [[ -n "$matcher_out" ]]; then
    similar_count=$(echo "$matcher_out" | awk -F= '/^SIMILAR_COUNT=/ {print $2}')
    # similar_count excludes self, so the total including this one is +1.
    if [[ -n "$similar_count" ]] && (( similar_count + 1 >= nudge_at )); then
      total=$((similar_count + 1))
      cat >&2 <<NUDGE_HEADER
NOTE: this MISS plus ${similar_count} prior similar one(s) in the last ${window_days}d = ${total} total.
Recent matches (most recent first):
NUDGE_HEADER
      echo "$matcher_out" | awk -F'\t' 'NF==2 {printf "  - %s: %s\n", $1, $2}' >&2
      cat >&2 <<NUDGE_FOOTER
Consider filing a prompt-pattern issue so the recipe library tracks the gap:
  gh issue create --repo ${github_repo} \\
    --label prompt-pattern \\
    --title "<recipe-name>: <one-line pattern summary>" \\
    --body "See .github/ISSUE_TEMPLATE/prompt-pattern.md — paste the matched MISS reasons above, the prompt, the model output, and a suggested fix if known."
Silence this nudge for one call with DELEGATE_FEEDBACK_NO_NUDGE=1.
NUDGE_FOOTER
    fi
  fi
fi
