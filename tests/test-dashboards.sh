#!/usr/bin/env bash
# Validate the committed Loki dashboards in dashboards/grafana/: valid JSON,
# importable keys, the loki datasource and service stream, every LogQL field
# in the JSONL allowlist, and the panel shapes pinned below. bash-3.2
# portable: no associative arrays, no `grep -P`.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARDS="$REPO/dashboards"

pass=0
fail=0

assert_nonempty() {
  local value="$1" name="$2"
  if [[ -n "$value" && "$value" != "null" ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (empty or null)"; fail=$((fail+1)); fi
}

if [[ ! -d "$DASHBOARDS/grafana" ]]; then
  echo "  FAIL  dashboards/grafana/ directory missing"
  echo; echo "$pass passed, $((fail+1)) failed"; exit 1
fi

# The JSONL fields the writers produce, derived by running them rather than
# kept by hand: the old hand-kept list carried three fields no script writes
# (eval_tokens, prompt_tokens, output_bytes, #565). Each source is a real
# writer run against a mock curl in a scratch git repository: delegate.sh (a
# recipe call, for the recipe and check fields), delegate-feedback.sh (a
# scaffold with a reason and a final, then a hit), and delegate-boundary-hook.sh
# (a denied commit, a below-floor reply and a no-provider fail-open, for
# denied, below_floor and enforce_skipped). The rows are then pushed through
# sync-metrics-to-loki.sh, which enriches feedback rows with the parent's
# recipe, tier and tokens, and the allowlist is the union of keys Loki holds.
# embed.sh rows are not written here: no dashboard queries them, and one that
# starts to fails below as an unknown field.
make_fixture_fields() { # prints the field names, one per line
  local w repo mock
  w=$(mktemp -d); mock="$w/bin"; repo="$w/repo"; mkdir -p "$mock" "$repo"
  cat > "$mock/curl" <<'MOCK'
#!/usr/bin/env bash
out_file="" write_out="" mode=chat
args=("$@")
for a in "$@"; do
  case "$a" in */models) mode=models;; */loki/api/v1/push) mode=push;; */flush) mode=flush;; esac
done
if [[ $mode == models ]]; then
  case " $* " in
    *:8080/*) printf '{"object":"list","data":[{"id":"qwen3.6:35b-a3b-q8_0","object":"model"}]}'; exit 0;;
  esac
  exit 7
fi
i=0
while (( i < ${#args[@]} )); do
  case "${args[$i]}" in
    -o) out_file="${args[$((i+1))]}"; i=$((i+1));;
    -w) write_out="${args[$((i+1))]}"; i=$((i+1));;
  esac
  i=$((i+1))
done
if [[ $mode == push ]]; then cat > "$(dirname "$0")/push.json"; printf 204; exit 0; fi
if [[ $mode == flush ]]; then exit 0; fi
cat > /dev/null
body='{"choices":[{"message":{"content":"Add a thing\n\nBecause reasons.\n"},"finish_reason":"stop"}]}'
if [[ -n "$out_file" ]]; then printf '%s' "$body" > "$out_file"; else printf '%s' "$body"; fi
[[ -n "$write_out" ]] && printf '%s' "${write_out//%\{time_starttransfer\}/0.001}"
exit 0
MOCK
  chmod +x "$mock/curl"
  ( cd "$repo" && git init -q . && git config user.email t@t.t && git config user.name t \
    && : > f && git add f && git commit -qm init ) >/dev/null 2>&1
  (
    export PATH="$mock:$PATH" DELEGATE_BASE_URL=http://localhost:8080/v1 DELEGATE_LOCAL_CONFIG=/dev/null
    export DELEGATE_METRICS_FILE="$w/metrics.jsonl" DELEGATE_LOCAL_DATA_DIR="$w/data"
    export CLAUDE_CODE_SESSION_ID=fixture-session DELEGATE_NO_PREFLIGHT=1
    unset DELEGATE_PROJECT DELEGATE_BOUNDARY_MODE DELEGATE_BOUNDARY_ENFORCE DELEGATE_LOCAL_NO_METRICS
    cd "$repo" || exit 1
    long=$(printf 'The sandbox flag in src/main.js is the cause, not your distro. %.0s' 1 2 3 4 5)
    hook() {
      jq -nc --arg cmd "$1" --arg cwd "$repo" \
        '{hook_event_name:"PreToolUse", tool_name:"Bash", cwd:$cwd, session_id:"fixture-hook-session", tool_input:{command:$cmd}}' \
        | DELEGATE_BOUNDARY_MIN_CHARS= bash "$REPO/scripts/delegate-boundary-hook.sh" >/dev/null 2>&1
    }
    # The hook rows come first: a delegation already recorded for the project would credit them.
    hook "git commit -m \"$long\""                                          # denied
    hook 'gh pr comment 12 --body "LGTM, thanks!"'                          # below_floor
    DELEGATE_BASE_URL=http://localhost:1/v1 hook "git commit -m \"$long\""  # enforce_skipped
    echo ctx | bash "$REPO/scripts/delegate.sh" --recipe commit-message \
      --var recent_commits=a --var diff_stat="f | 1" --var why=w prose msg >/dev/null 2>&1
    id=$(jq -r 'select(.source=="delegate") | .otel_span_id' "$w/metrics.jsonl" | head -1)
    printf 'shipped text\n' > "$w/final.txt"
    bash "$REPO/scripts/delegate-feedback.sh" --id "$id" --final "$w/final.txt" scaffold "edited before shipping" >/dev/null 2>&1
    bash "$REPO/scripts/delegate-feedback.sh" --id "$id" hit >/dev/null 2>&1
    PATH="$mock:/usr/bin:/bin:/usr/sbin:/sbin" bash "$REPO/scripts/sync-metrics-to-loki.sh" --full \
      --metrics-file "$w/metrics.jsonl" --state-file "$w/state" --loki-url http://loki.invalid >/dev/null 2>&1
  )
  jq -r '.streams[].values[][1] | fromjson | keys[]' "$mock/push.json" 2>/dev/null | sort -u
  rm -rf "$w"
}
KNOWN_FIELDS=$(make_fixture_fields)
n_known=$(printf '%s\n' "$KNOWN_FIELDS" | grep -c .)
# One field per source proves each writer ran: recipe (delegate), kept
# (feedback), enforce_skipped (the fail-open hook row).
missing_src=""
for f in recipe kept scaffold denied below_floor enforce_skipped; do
  printf '%s\n' "$KNOWN_FIELDS" | grep -qxF "$f" || missing_src="$missing_src $f"
done
if [[ -z "$missing_src" ]]; then
  echo "  PASS  field allowlist derived from writer-produced rows ($n_known fields; delegate, feedback and opportunity rows)"; pass=$((pass+1))
else
  echo "  FAIL  field allowlist derivation lacks:$missing_src ($n_known fields; a writer did not run)"; fail=$((fail+1))
fi

is_known() {
  local needle="$1"
  # Loki's own label, set when a stage fails (`| __error__=""` drops those
  # samples after an unwrap); it is not a JSONL field.
  [[ "$needle" == "__error__" ]] && return 0
  printf '%s\n' "$KNOWN_FIELDS" | grep -qxF "$needle"
}

# Every field a LogQL expression reads: `unwrap X`, `by (X)`, a `| X op` or
# `or X op` filter (the `or` form: `kept="true" or scaffold="true"`), and a
# line_format `{{.X}}`; one name per line.
logql_fields() { # exprs on stdin
  grep -oE 'unwrap [a-z_]+|by \([a-z_]+\)|(\||or) +[a-z_]+ *(=~|!~|!=|=)|\{\{ *\.[a-z_]+ *\}\}' \
    | sed -E 's/^unwrap //; s/^by \(([a-z_]+)\)$/\1/; s/^(\||or) +([a-z_]+).*$/\2/; s/^\{\{ *\.([a-z_]+) *\}\}$/\1/' \
    | sort -u
}

# The checker has to see what the hand-kept list let through: a field no
# writer produces, in the pipe and in the `or` position.
bad=$(printf '%s\n' '{service="delegate-local"} | json | eval_tokens!="" | kept="true" or bogus_field="x"' \
  | logql_fields | while IFS= read -r f; do is_known "$f" || printf '%s ' "$f"; done)
if [[ "$bad" == *eval_tokens* && "$bad" == *bogus_field* ]]; then
  echo "  PASS  checker flags an unwritten field in a pipe filter and in an 'or' filter"; pass=$((pass+1))
else
  echo "  FAIL  checker missed an unwritten field (flagged: '$bad')"; fail=$((fail+1))
fi

dash_count=0
shopt -s nullglob
for dash in "$DASHBOARDS/grafana"/*.json; do
  dash_count=$((dash_count+1))
  base=$(basename "$dash")

  # 1. Valid JSON.
  if jq empty "$dash" >/dev/null 2>&1; then
    echo "  PASS  $base: valid JSON"; pass=$((pass+1))
  else
    echo "  FAIL  $base: invalid JSON"; fail=$((fail+1)); continue
  fi

  # 2. Required top-level keys + project variable.
  assert_nonempty "$(jq -r '.title // empty' "$dash")" "$base: .title present"
  assert_nonempty "$(jq -r '.schemaVersion // empty' "$dash")" "$base: .schemaVersion present"
  panel_count=$(jq -r '(.panels // []) | length' "$dash")
  if [[ "$panel_count" =~ ^[0-9]+$ && "$panel_count" -gt 0 ]]; then
    echo "  PASS  $base: .panels non-empty ($panel_count panels)"; pass=$((pass+1))
  else
    echo "  FAIL  $base: .panels missing or empty"; fail=$((fail+1))
  fi
  has_project=$(jq -r '[.templating.list[]? | select(.name=="project")] | length' "$dash")
  if [[ "$has_project" -ge 1 ]]; then
    echo "  PASS  $base: project template variable present"; pass=$((pass+1))
  else
    echo "  FAIL  $base: project template variable missing"; fail=$((fail+1))
  fi

  # 3. Every panel target points at the Loki datasource and selects the
  #    delegate-local service.
  bad_ds=$(jq -r '[.panels[].targets[]? | select((.datasource.uid // "") != "loki")] | length' "$dash")
  if [[ "$bad_ds" == "0" ]]; then
    echo "  PASS  $base: all targets use datasource.uid \"loki\""; pass=$((pass+1))
  else
    echo "  FAIL  $base: $bad_ds target(s) not on datasource.uid \"loki\""; fail=$((fail+1))
  fi
  bad_svc=$(jq -r '[.panels[].targets[]? | select((.expr // "") | contains("service=\"delegate-local\"") | not)] | length' "$dash")
  if [[ "$bad_svc" == "0" ]]; then
    echo "  PASS  $base: all queries select service=\"delegate-local\""; pass=$((pass+1))
  else
    echo "  FAIL  $base: $bad_svc query(ies) do not select service=\"delegate-local\""; fail=$((fail+1))
  fi

  # 3b. No query folds the pre-rename project name into delegate-local: that
  #     project is absent from the live corpus, so every label_replace was
  #     dead weight on each per-project query (#565).
  stale=$(jq -r '[.panels[].targets[]?.expr // "" | select(contains("delegate-to-ollama"))] | length' "$dash")
  if [[ "$stale" == "0" ]]; then
    echo "  PASS  $base: no query folds the retired delegate-to-ollama project name"; pass=$((pass+1))
  else
    echo "  FAIL  $base: $stale query(ies) still label_replace the retired delegate-to-ollama project"; fail=$((fail+1))
  fi

  # 4. Every `unwrap X`, `by (X)`, `| X op` filter and `line_format` `{{.X}}`
  #    reference is a known JSONL field.
  exprs=$(jq -r '[.panels[].targets[]?.expr // ""] | join("\n")' "$dash")
  fields=$(printf '%s\n' "$exprs" | logql_fields)
  dash_field_fail=0
  while IFS= read -r fld; do
    [[ -z "$fld" ]] && continue
    if ! is_known "$fld"; then
      echo "  FAIL  $base: LogQL references unknown JSONL field '$fld'"
      fail=$((fail+1)); dash_field_fail=1
    fi
  done <<< "$fields"
  if [[ "$dash_field_fail" == "0" ]]; then
    echo "  PASS  $base: all LogQL field references are known JSONL fields"; pass=$((pass+1))
  fi

  # 5. bargauge/piechart panels use instant queries: a range query returns
  #    the full-range total at every step and the sum reduce adds the steps.
  #    `.. | objects` reaches panels nested inside Grafana row panels.
  range_reduced=$(jq -r '[.. | objects | select(.type=="bargauge" or .type=="piechart") | select((.targets // []) | any((.queryType // "range") != "instant")) | .title] | join(", ")' "$dash")
  if [[ -z "$range_reduced" ]]; then
    echo "  PASS  $base: bargauge/piechart panels use instant queries"; pass=$((pass+1))
  else
    echo "  FAIL  $base: bargauge/piechart panel(s) not instant (step-sum inflation risk): $range_reduced"; fail=$((fail+1))
  fi

  # 5b. Those panels also set reduceOptions.values=true, or the reduce
  #    collapses every series into one bar/slice.
  collapse=$(jq -r '[.. | objects | select(.type=="bargauge" or .type=="piechart") | select((.options.reduceOptions.values // false) != true) | .title] | join(", ")' "$dash")
  if [[ -z "$collapse" ]]; then
    echo "  PASS  $base: bargauge/piechart panels show all values (no series collapse)"; pass=$((pass+1))
  else
    echo "  FAIL  $base: bargauge/piechart panel(s) reduceOptions.values!=true (series-collapse risk): $collapse"; fail=$((fail+1))
  fi
done
shopt -u nullglob

if [[ "$dash_count" -eq 0 ]]; then
  echo "  FAIL  dashboards/grafana/ contains no .json files"; fail=$((fail+1))
else
  echo "  PASS  dashboards/grafana/ contains $dash_count dashboard(s)"; pass=$((pass+1))
fi

# 5. The calibration dashboard keeps a per-recipe adoption-rate panel (#187):
#    a `by (recipe)` group-by is what makes a bad recipe visible.
CALIBRATION="$DASHBOARDS/grafana/delegate-calibration.json"
if [[ -f "$CALIBRATION" ]]; then
  per_recipe=$(jq -r '[.panels[] | select((.targets // []) | map(.expr // "") | join(" ") | (contains("by (recipe)") and contains("kept=")))] | length' "$CALIBRATION" 2>/dev/null)
  if [[ "$per_recipe" -ge 1 ]]; then
    echo "  PASS  delegate-calibration.json: per-recipe adoption-rate panel present"; pass=$((pass+1))
  else
    echo "  FAIL  delegate-calibration.json: no per-recipe (by (recipe)) adoption-rate panel"; fail=$((fail+1))
  fi
else
  echo "  FAIL  delegate-calibration.json missing"; fail=$((fail+1))
fi

# 5f. The Overview dashboard keeps a trigger-rate panel (#483) that filters
#     out below_floor (not drafting) and denied (never posted) rows.
OVERVIEW="$DASHBOARDS/grafana/delegate-overview.json"
if [[ -f "$OVERVIEW" ]]; then
  trigger_panel=$(jq -r '[.panels[] | select((.targets // []) | map(.expr // "") | join(" ")
      | (contains("source=\"opportunity\"") and contains("delegated=\"true\"")
         and contains("below_floor!=\"true\"") and contains("denied!=\"true\"")))] | length' "$OVERVIEW" 2>/dev/null)
  if [[ "$trigger_panel" -ge 1 ]]; then
    echo "  PASS  delegate-overview.json: trigger-rate panel present, excluding below-floor and denied rows"; pass=$((pass+1))
  else
    echo "  FAIL  delegate-overview.json: no trigger-rate panel on the opportunity stream with the below_floor/denied exclusions"; fail=$((fail+1))
  fi
  # The ratio gauge divides by the eligible count; a range or project with
  # none would render NaN without a noValue (PR #484 review, item L).
  nan_gauge=$(jq -r '[.panels[] | select(.type == "gauge") | select((.targets // []) | map(.expr // "") | join(" ") | contains("source=\"opportunity\"")) | select((.fieldConfig.defaults.noValue // "") == "") | .title] | join(", ")' "$OVERVIEW" 2>/dev/null)
  if [[ -z "$nan_gauge" ]]; then
    echo "  PASS  delegate-overview.json: trigger-rate gauge sets noValue (no NaN on an empty denominator)"; pass=$((pass+1))
  else
    echo "  FAIL  delegate-overview.json: trigger-rate gauge without noValue (NaN on an empty denominator): $nan_gauge"; fail=$((fail+1))
  fi
else
  echo "  FAIL  delegate-overview.json missing"; fail=$((fail+1))
fi

# 5c. The adoption-rate legend must not reduce with `sum`: summing a per-step
#     ratio over the range and multiplying by 100 shows values like 5955%.
if [[ -f "$CALIBRATION" ]]; then
  recipe_sum_calc=$(jq -r '[.. | objects | select((.targets // []) | map(.expr // "") | join(" ") | (contains("by (recipe)") and contains("kept="))) | .options.legend.calcs // [] | index("sum")] | map(select(. != null)) | length' "$CALIBRATION" 2>/dev/null)
  if [[ "$recipe_sum_calc" == "0" ]]; then
    echo "  PASS  delegate-calibration.json: per-recipe adoption-rate legend reduce is not sum (no step-sum inflation)"; pass=$((pass+1))
  else
    echo "  FAIL  delegate-calibration.json: per-recipe adoption-rate panel legend uses sum (5955%-style step-sum inflation on a ratio)"; fail=$((fail+1))
  fi
fi

# 5e. Scaffold is the common verdict, so the calibration dashboard keeps a
#     usable-rate panel (hit or scaffold) beside the hit-only ones; without it
#     the largest verdict class shows up in no rate at all.
if [[ -f "$CALIBRATION" ]]; then
  usable_re='kept="true" or scaffold="true"'
  for title in "Usable rate" "Usable rate by recipe" "Usable rate by project"; do
    n=$(jq -r --arg t "$title" --arg re "$usable_re" '[.panels[] | select(.title == $t) | select((.targets // []) | length > 0 and all(.expr // "" | contains($re)))] | length' "$CALIBRATION" 2>/dev/null)
    if [[ "$n" == "1" ]]; then
      echo "  PASS  delegate-calibration.json: \"$title\" counts scaffold beside hit"; pass=$((pass+1))
    else
      echo "  FAIL  delegate-calibration.json: no \"$title\" panel whose queries all count scaffold as usable"; fail=$((fail+1))
    fi
  done
  n=$(jq -r --arg re "$usable_re" '[.panels[] | select(.title | test("rate trend")) | .targets[]? | select(.legendFormat == "usable rate" and (.expr // "" | contains($re)))] | length' "$CALIBRATION" 2>/dev/null)
  if [[ "$n" == "1" ]]; then
    echo "  PASS  delegate-calibration.json: the rate trend carries a usable-rate series"; pass=$((pass+1))
  else
    echo "  FAIL  delegate-calibration.json: the rate trend has no usable-rate series counting scaffold"; fail=$((fail+1))
  fi
  # A scaffold-only rate gauge: its numerator is scaffold and never kept.
  n=$(jq -r '[.panels[] | select(.title == "Scaffold rate" and .type == "gauge") | .targets[0].expr // "" | select(contains("scaffold=\"true\"") and (contains("kept=") | not))] | length' "$CALIBRATION" 2>/dev/null)
  if [[ "$n" == "1" ]]; then
    echo "  PASS  delegate-calibration.json: \"Scaffold rate\" gauge counts scaffold alone"; pass=$((pass+1))
  else
    echo "  FAIL  delegate-calibration.json: no \"Scaffold rate\" gauge whose numerator is scaffold alone"; fail=$((fail+1))
  fi
  # Tokens avoided by verdict: each panel sums the enriched feedback rows'
  # tokens for all three verdicts, never the delegate stream (that is the
  # gross figure the Overview already shows).
  for title in "Tokens avoided by verdict" "Tokens avoided by verdict over time"; do
    n=$(jq -r --arg t "$title" '[.panels[] | select(.title == $t) | [.targets[] | select((.expr | contains("source=\"feedback\"")) and (.expr | contains("unwrap estimated_tokens_avoided"))) | .legendFormat] | sort | select(. == ["hit","miss","scaffold"])] | length' "$CALIBRATION" 2>/dev/null)
    if [[ "$n" == "1" ]]; then
      echo "  PASS  delegate-calibration.json: \"$title\" splits feedback-row tokens into hit, scaffold and miss"; pass=$((pass+1))
    else
      echo "  FAIL  delegate-calibration.json: \"$title\" missing or not split into hit, scaffold and miss over feedback-row tokens"; fail=$((fail+1))
    fi
  done
fi

# 5d. The canary-failure panel keys on exit_status=3, the code delegate.sh
#     writes for a canary stall; exit 2 is usage only and never reaches metrics.
ERRORS="$DASHBOARDS/grafana/delegate-errors.json"
if [[ -f "$ERRORS" ]]; then
  canary_expr=$(jq -r '[.. | objects | select((.title // "") | test("[Cc]anary")) | .targets?.[0].expr // ""] | join(" ")' "$ERRORS" 2>/dev/null)
  if printf '%s' "$canary_expr" | grep -q 'exit_status="3"' \
     && ! printf '%s' "$canary_expr" | grep -q 'exit_status="2"'; then
    echo "  PASS  delegate-errors.json: canary panel keys exit_status=3 (the real canary code)"; pass=$((pass+1))
  else
    echo "  FAIL  delegate-errors.json: canary panel does not key exit_status=3 (delegate.sh writes 3 on the preflight stall)"; fail=$((fail+1))
  fi
else
  echo "  FAIL  delegate-errors.json missing"; fail=$((fail+1))
fi

# 6. Langfuse README (no portable JSON format, so the file-as-code counterpart
#    is the README).
if [[ -f "$DASHBOARDS/langfuse/README.md" ]]; then
  echo "  PASS  dashboards/langfuse/README.md exists"; pass=$((pass+1))
else
  echo "  FAIL  dashboards/langfuse/README.md missing"; fail=$((fail+1))
fi

echo
echo "$pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then exit 1; fi
