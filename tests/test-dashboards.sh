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

# The JSONL fields the scripts write (the sync script enriches feedback rows
# with recipe/tier); a LogQL reference outside this set is a typo or drift.
KNOWN_FIELDS="ts source project tier recipe backend model service \
prompt_chars context_chars output_chars duration_ms queue_wait_ms \
generation_ms exit_status estimated_tokens_avoided kept reason ref_ts \
embedding_dim input_chars eval_tokens prompt_tokens output_bytes session \
verdict_source scaffold \
boundary suggested_recipe delegated body_chars below_floor denied enforce_skipped"

is_known() {
  local needle="$1" f
  for f in $KNOWN_FIELDS; do [[ "$f" == "$needle" ]] && return 0; done
  return 1
}

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

  # 4. Every `unwrap X`, `by (X)`, `| X op` filter and `line_format` `{{.X}}`
  #    reference is a known JSONL field.
  exprs=$(jq -r '[.panels[].targets[]?.expr // ""] | join("\n")' "$dash")
  fields=$(printf '%s\n' "$exprs" \
    | grep -oE 'unwrap [a-z_]+|by \([a-z_]+\)|\| [a-z_]+(=|!=|=~)|\{\{ *\.[a-z_]+ *\}\}' \
    | sed -E 's/^unwrap //; s/^by \(([a-z_]+)\)$/\1/; s/^\| ([a-z_]+).*$/\1/; s/^\{\{ *\.([a-z_]+) *\}\}$/\1/' \
    | sort -u)
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
