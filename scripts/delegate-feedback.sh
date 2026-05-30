#!/usr/bin/env bash
# Append a hit/miss feedback event to the delegate metrics JSONL, referencing
# either the most recent `source:"delegate"` line or a caller-pinned ts.
# Lets the caller record whether they actually used the delegated output
# (hit) or had to rewrite/discard it (miss), with an optional one-line
# reason.
#
# The file remains append-only — feedback events join the JSONL as their own
# rows, keyed by `ref_ts` to the delegate event they evaluate. `metrics-
# summary.sh` joins them at read time to compute hit-rate per tier / model.
#
# Usage:  delegate-feedback.sh [--ts <iso8601>] hit|miss [reason words...]
# Env:
#   DELEGATE_METRICS_FILE                 override default metrics path
#   DELEGATE_FEEDBACK_STALE_SECONDS       max age of the implicit "most recent
#                                         delegate row" before this script
#                                         refuses to attach without --ts
#                                         (default 300; set 0 to disable).
#   DELEGATE_FEEDBACK_NO_NUDGE            set to 1 to silence the trigger-on-
#                                         MISS recurrence nudge.
#   DELEGATE_FEEDBACK_NUDGE_AT            minimum total similar MISSes (this
#                                         one included) to trigger the nudge
#                                         (default 3).
#   DELEGATE_FEEDBACK_NUDGE_WINDOW_DAYS   lookback for similar MISS counting
#                                         (default 30).
#   DELEGATE_FEEDBACK_SIMILAR_THRESHOLD   Jaccard similarity (over content
#                                         tokens, stopwords removed) at which
#                                         two MISS reasons are considered
#                                         similar (default 0.4).
#   DELEGATE_OTEL_ENDPOINT                Phase 11 Track A (#134). When set,
#                                         POST a feedback-as-linked-span to
#                                         this OTLP/HTTP traces URL after the
#                                         feedback JSONL row is written. The
#                                         feedback span is a NEW trace whose
#                                         `links` array points back to the
#                                         parent delegation's trace/span IDs
#                                         (per ADR 0007). Off by default.
#                                         The POST is SYNCHRONOUS — a hung
#                                         collector adds up to
#                                         DELEGATE_OTEL_TIMEOUT seconds of
#                                         user-visible latency per feedback
#                                         call. Set DELEGATE_OTEL_VERBOSE=1
#                                         to diagnose, or unset the endpoint
#                                         to disable.
#   DELEGATE_OTEL_TIMEOUT                 default 5. curl --max-time on the
#                                         OTLP POST so a hung collector
#                                         cannot block the script.
#   DELEGATE_OTEL_VERBOSE                 when =1, log exporter failures to
#                                         stderr. Default silent. Use this
#                                         to diagnose suspected exporter
#                                         failures (timeouts, auth, DNS).
#   DELEGATE_OTEL_HEADERS                 optional. Comma-separated
#                                         Header: value pairs for collector
#                                         auth (Grafana Cloud, Langfuse).
#                                         Per OTel SDK convention, values
#                                         containing commas (or any
#                                         reserved char) MUST be url-
#                                         encoded — the script url-decodes
#                                         each value before emitting -H
#                                         flags so the on-wire header is
#                                         the literal original.
#   DELEGATE_OTEL_INCLUDE_CONTENT         Phase 11 Track F (#158). When =1,
#                                         include the free-text
#                                         `delegate.feedback.reason`
#                                         attribute on the feedback span.
#                                         Default unset = redact: only
#                                         metadata (verdict, parent IDs)
#                                         leaves the host. WARNING: the
#                                         reason field is user-authored
#                                         free text and may carry PII,
#                                         API keys, internal URLs, or
#                                         model output excerpts; only
#                                         enable this against trusted
#                                         collectors. See ADR 0007 +
#                                         docs/otel-schema.md.
# Exit:   0 OK, 1 file/event missing or stale, 2 usage error. OTLP-export
#         failures NEVER change the exit status — telemetry is non-fatal.

set -uo pipefail

metrics_file="${DELEGATE_METRICS_FILE:-$HOME/.claude/skills/delegate-local/metrics.jsonl}"
stale_seconds="${DELEGATE_FEEDBACK_STALE_SECONDS:-300}"

usage() {
  cat >&2 <<'EOF'
usage: delegate-feedback.sh [--ts <iso8601>] hit|miss [reason words...]
  Without --ts, the verdict attaches to the most recent delegate row in
  the metrics JSONL — but only if that row is fresh (default 300 s).
  Pass --ts to pin the verdict to a specific delegate row when metrics
  were off, or the delegation was killed before its row was written, or
  enough time has passed that the most recent row is no longer "yours".
EOF
  exit 2
}

# Argument parsing — flags come first, then verdict, then reason.
override_ts=""
while (($# > 0)); do
  case "$1" in
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
    -h|--help) usage;;
    --) shift; break;;
    *) break;;
  esac
done

[[ $# -ge 1 ]] || usage

case "$1" in
  hit)  kept=true ;;
  miss) kept=false ;;
  *) echo "first arg must be 'hit' or 'miss' (got '$1')" >&2; usage ;;
esac
shift
reason="$*"

[[ -f "$metrics_file" ]] || { echo "metrics file not found: $metrics_file" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not on PATH" >&2; exit 2; }

# Convert ISO 8601 (Y-m-dTH:M:SZ) to epoch seconds. Cross-platform: BSD
# date (macOS) and GNU date have incompatible flag sets; perl Time::Local
# is already a project runtime dep and gives one code path that works on
# both. Returns nothing and exits 1 on a malformed ts so the caller can
# fall back gracefully.
iso_to_epoch() {
  perl -MTime::Local=timegm -e '
    my $ts = shift @ARGV;
    if ($ts =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/) {
      print timegm($6, $5, $4, $3, $2-1, $1);
    } else {
      exit 1;
    }
  ' "$1"
}

# OTel ID generation and the OTLP/HTTP feedback-span emission live in
# scripts/lib/otel.sh — shared with delegate.sh and backfill-otel.sh (Track E,
# #157). The lib defines otel_gen_id, emit_otel_feedback_span,
# emit_otel_feedback_span_with_ids, and the deterministic-ID helper.
# emit_otel_feedback_span carries the Track F redaction behaviour
# (DELEGATE_OTEL_INCLUDE_CONTENT=1 to include the free-text reason; default
# omits it). Sourcing has no side effects.
_fb_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/otel.sh
. "$_fb_script_dir/lib/otel.sh"

if [[ -n "$override_ts" ]]; then
  # Validate that the override matches an actual delegate row. Without
  # this check, a typoed --ts would silently attach to a non-existent
  # delegation, which the metrics-summary join would then drop.
  match=$(jq -r --arg ts "$override_ts" \
    'select((.source // "delegate") == "delegate" and .ts == $ts) | .ts' \
    "$metrics_file" | head -n 1)
  if [[ -z "$match" || "$match" == "null" ]]; then
    echo "delegate-feedback: --ts $override_ts does not match any delegate row in $metrics_file" >&2
    exit 1
  fi
  ref_ts="$override_ts"
  # Capture model + trace/span IDs + recipe from the pinned delegate row so
  # the OTel feedback span (Phase 11 Track A) can name the parent and
  # carry delegate.recipe (#187). Empty fields are tolerated — the parent
  # IDs and recipe are absent when the row pre-dates the exporter
  # (Track E #157 backfills the IDs later) or when the delegation was a
  # bare-tier call without --recipe.
  parent_meta=$(jq -r --arg ts "$override_ts" \
    'select((.source // "delegate") == "delegate" and .ts == $ts)
     | [(.otel_trace_id // ""), (.otel_span_id // ""), (.model // ""), (.recipe // "")]
     | @tsv' \
    "$metrics_file" | head -n 1)
else
  # Find the most recent delegate event ts. Stream the JSONL through jq
  # (no `-s` slurp) and pipe the matching ts column through `tail -n 1`.
  # Parens around `(.source // "delegate")` are load-bearing — see git
  # history for the precedence trap.
  ref_ts=$(jq -r 'select((.source // "delegate") == "delegate") | .ts' "$metrics_file" | tail -n 1)
  if [[ -z "$ref_ts" || "$ref_ts" == "null" ]]; then
    echo "no recent delegate event found in $metrics_file" >&2
    exit 1
  fi
  # Look up the matched delegate row's trace/span IDs, model, and recipe
  # for the OTel feedback-as-linked-span (Phase 11 Track A) plus the
  # delegate.recipe attribute (#187). Rows that pre-date the exporter
  # return empty strings for the IDs; the OTel emission code path treats
  # empty parent IDs as "no link" and still emits the feedback span
  # (Track E #157 backfills the parent IDs later). Bare-tier delegations
  # return empty recipe and the attribute is omitted from the payload.
  parent_meta=$(jq -r --arg ts "$ref_ts" \
    'select((.source // "delegate") == "delegate" and .ts == $ts)
     | [(.otel_trace_id // ""), (.otel_span_id // ""), (.model // ""), (.recipe // "")]
     | @tsv' \
    "$metrics_file" | tail -n 1)
  # Stale-window check: refuse to silently attach to a row that almost
  # certainly isn't the delegation the caller meant. The 5-minute default
  # bounds "I just delegated" without forcing tight clock discipline; set
  # DELEGATE_FEEDBACK_STALE_SECONDS=0 to disable for back-compat scripts.
  if [[ "$stale_seconds" -gt 0 ]]; then
    ref_epoch=$(iso_to_epoch "$ref_ts" 2>/dev/null || true)
    now_epoch=$(perl -e 'print time')
    if [[ -n "$ref_epoch" ]] && (( now_epoch - ref_epoch > stale_seconds )); then
      age=$(( now_epoch - ref_epoch ))
      cat >&2 <<MSG
delegate-feedback: most recent delegate row is ${age}s old (> ${stale_seconds}s).
  ts=$ref_ts is likely not the delegation you mean. Pass --ts <iso8601>
  to pin the verdict explicitly, or set DELEGATE_FEEDBACK_STALE_SECONDS=0
  to disable this check.
MSG
      exit 1
    fi
  fi
fi

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Main repo basename, even inside a git worktree (delegate_project_name from
# lib/otel.sh, sourced above) — so a verdict recorded in a worktree attributes
# to the same repo as the delegation it scores.
feedback_project=$(delegate_project_name)

# Build the feedback row. `reason` is omitted when the caller didn't supply
# one so empty-string entries don't pollute future filters.
if [[ -n "$reason" ]]; then
  jq -nc --arg ts "$ts" --arg ref "$ref_ts" --argjson kept "$kept" --arg reason "$reason" --arg project "$feedback_project" \
    '{ts:$ts, source:"feedback", ref_ts:$ref, kept:$kept, reason:$reason} + (if $project != "" then {project:$project} else {} end)' \
    >> "$metrics_file"
else
  jq -nc --arg ts "$ts" --arg ref "$ref_ts" --argjson kept "$kept" --arg project "$feedback_project" \
    '{ts:$ts, source:"feedback", ref_ts:$ref, kept:$kept} + (if $project != "" then {project:$project} else {} end)' \
    >> "$metrics_file"
fi

verdict_word=$([[ "$kept" == "true" ]] && echo "HIT" || echo "MISS")

# Emit OTel feedback-as-linked-span (Phase 11 Track A #134). The split
# variables come from the parent_meta TSV captured during the ref_ts lookup
# above. Empty fields are tolerated — emit_otel_feedback_span omits the
# `links` array when the parent IDs are unknown (row pre-dates the exporter)
# and omits delegate.recipe (#187) when the parent was a bare-tier call.
# delegate.project is the basename of the repo the verdict was recorded in
# (same derivation as delegate.sh), so per-project calibration dashboards can
# scope feedback spans the same way they scope delegation spans.
parent_trace_id=""
parent_span_id=""
parent_model=""
parent_recipe=""
if [[ -n "${parent_meta:-}" ]]; then
  IFS=$'\t' read -r parent_trace_id parent_span_id parent_model parent_recipe <<< "$parent_meta"
fi
verdict_lower=$([[ "$kept" == "true" ]] && echo "hit" || echo "miss")
emit_otel_feedback_span "$ts" "$verdict_lower" "$reason" "$parent_trace_id" "$parent_span_id" "$parent_model" "$parent_recipe" "$feedback_project"

echo "$verdict_word recorded against delegate ts=$ref_ts${reason:+ ($reason)}"

# Trigger-on-MISS nudge — when a MISS is recorded and the reason has token
# overlap with N-1 or more recent MISSes already in the JSONL, surface a
# draft `prompt-pattern` issue command so the calibration discipline the
# README documents has a runtime nudge to back it. Issue #88. The matcher
# scores Jaccard similarity over content tokens (lowercased, stopwords
# stripped, length ≥ 3) and only runs on MISS so HIT recording stays quiet.
# The just-appended row is excluded from the count by ts so the matcher
# does not see itself.
if [[ "$kept" == "false" && "${DELEGATE_FEEDBACK_NO_NUDGE:-0}" != "1" && -n "$reason" ]]; then
  nudge_at="${DELEGATE_FEEDBACK_NUDGE_AT:-3}"
  window_days="${DELEGATE_FEEDBACK_NUDGE_WINDOW_DAYS:-30}"
  similar_threshold="${DELEGATE_FEEDBACK_SIMILAR_THRESHOLD:-0.4}"
  window_secs=$((window_days * 86400))

  # Perl rather than awk because the matcher needs JSON parsing, set
  # arithmetic, and floating-point Jaccard — all messy in awk and clean
  # in Perl, which is already a project runtime dep (see iso_to_epoch
  # above, scripts/delegate.sh, the score-t3.sh stdev calc). Inputs on
  # the command line; the JSONL streams in on stdin. Output is one
  # `SIMILAR_COUNT=<n>` line plus one `<ts>\t<reason>` line per match.
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
      next unless $j->{ts};
      next if $j->{ts} eq $self_ts;             # skip the just-appended row
      if ($window_secs > 0 && $j->{ts} =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/) {
        my $epoch = timegm($6, $5, $4, $3, $2-1, $1);
        next if ($now - $epoch) > $window_secs;
      }
      my @h_t = toks($j->{reason} // "");
      next unless @h_t;
      # Inclusion-exclusion: |A ∪ B| = |A| + |B| - |A ∩ B|. Avoids the
      # per-row anonymous-hash merge the earlier draft used; both @new_t
      # and @h_t are already deduped by toks().
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
    # The nudge triggers when this MISS plus prior similars hits nudge_at:
    #   similar_count is "prior similar MISSes" (excludes self)
    #   total including this one = similar_count + 1
    if [[ -n "$similar_count" ]] && (( similar_count + 1 >= nudge_at )); then
      total=$((similar_count + 1))
      cat >&2 <<NUDGE_HEADER
NOTE: this MISS plus ${similar_count} prior similar one(s) in the last ${window_days}d = ${total} total.
Recent matches (most recent first):
NUDGE_HEADER
      echo "$matcher_out" | awk -F'\t' 'NF==2 {printf "  - %s: %s\n", $1, $2}' >&2
      cat >&2 <<NUDGE_FOOTER
Consider filing a prompt-pattern issue so the recipe library tracks the gap:
  gh issue create --repo IsmaelMartinez/delegate-local \\
    --label prompt-pattern \\
    --title "<recipe-name>: <one-line pattern summary>" \\
    --body "See .github/ISSUE_TEMPLATE/prompt-pattern.md — paste the matched MISS reasons above, the prompt, the model output, and a suggested fix if known."
Silence this nudge for one call with DELEGATE_FEEDBACK_NO_NUDGE=1.
NUDGE_FOOTER
    fi
  fi
fi
