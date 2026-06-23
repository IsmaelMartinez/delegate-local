#!/usr/bin/env bash
# Validate the committed Loki-powered dashboard JSON in dashboards/grafana/.
#
# The dashboards query Loki (LogQL over the delegate metrics JSONL, pushed by
# scripts/sync-metrics-to-loki.sh) rather than Tempo, because Loki can chart
# the full history while Tempo indexes by ingestion time. The assertions pin
# that contract:
#
# 1. Each .json under dashboards/grafana/ is valid JSON (jq parses it).
# 2. Each dashboard has the keys Grafana needs to import: title, panels,
#    schemaVersion — and a `project` template variable.
# 3. Every panel target uses datasource.uid "loki" and selects the
#    service="delegate-local" stream.
# 4. Every JSONL field referenced by a LogQL `unwrap X` / `| json | X` clause
#    is in the known JSONL field allowlist, so a dashboard cannot chart a
#    field the exporter never writes.
# 5. The calibration dashboard keeps a per-recipe HIT-rate panel (`by (recipe)`).
# 6. The Langfuse README (no-portable-JSON backend) still exists.
#
# bash-3.2 portable: no associative arrays, no `grep -P`.

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

# Allowlist of JSONL field names the dashboards may reference. These are the
# fields scripts/delegate.sh, delegate-feedback.sh, embed.sh and the eval
# harness write to metrics.jsonl (plus recipe/tier, which the sync script
# enriches onto feedback rows from the parent delegation). A LogQL reference
# to anything outside this set is almost certainly a typo or schema drift.
KNOWN_FIELDS="ts source project tier recipe backend model service \
prompt_chars context_chars output_chars duration_ms queue_wait_ms \
generation_ms exit_status estimated_tokens_avoided kept reason ref_ts \
embedding_dim input_chars eval_tokens prompt_tokens output_bytes session"

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

  # 4. Field allowlist: pull every `unwrap X`, `by (X)`, `| X(=|!=|=~)` filter,
  #    and `line_format` `{{.X}}` reference from the panel exprs and confirm each
  #    is a known JSONL field. Scanning line_format too means a typo'd field in a
  #    logs panel (e.g. `{{.resaon}}`) is caught, not just the metric filters.
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

  # 5. Single-value-per-category panels (bargauge, piechart) MUST use instant
  #    queries. As RANGE queries with a `[$__range]` selector they would return
  #    ~the full-range total at every step, and the panel's "sum" reduce would
  #    then add all those steps together — inflating every value by the step
  #    count (e.g. a 61 K total shown as 8.8 M per bar). Instant evaluates once.
  # `.. | objects` (recursive descent) rather than `.panels[]` so panels nested
  # inside Grafana row panels are validated too, not just top-level ones.
  range_reduced=$(jq -r '[.. | objects | select(.type=="bargauge" or .type=="piechart") | select((.targets // []) | any((.queryType // "range") != "instant")) | .title] | join(", ")' "$dash")
  if [[ -z "$range_reduced" ]]; then
    echo "  PASS  $base: bargauge/piechart panels use instant queries"; pass=$((pass+1))
  else
    echo "  FAIL  $base: bargauge/piechart panel(s) not instant (step-sum inflation risk): $range_reduced"; fail=$((fail+1))
  fi

  # 5b. Those same panels MUST also set reduceOptions.values=true. An instant
  #    `sum by (label) (...)` comes back as a `numeric-multi` frame; with
  #    values:false the bargauge/piechart applies its reduce calc ACROSS the
  #    series and collapses them into a single bar/slice (e.g. all projects
  #    summed into one 50 K bar). values:true renders every series value as its
  #    own bar/slice — the one-bar-per-label breakdown these panels exist for.
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

# 5. The calibration dashboard keeps a per-recipe HIT-rate panel. Per-recipe
#    HIT-rate is the load-bearing calibration signal (#187); the sync script
#    enriches feedback rows with the parent recipe so this is a LogQL
#    `by (recipe)` group-by. Pin it so a future edit cannot silently drop it.
CALIBRATION="$DASHBOARDS/grafana/delegate-calibration.json"
if [[ -f "$CALIBRATION" ]]; then
  per_recipe=$(jq -r '[.panels[] | select((.targets // []) | map(.expr // "") | join(" ") | (contains("by (recipe)") and contains("kept=")))] | length' "$CALIBRATION" 2>/dev/null)
  if [[ "$per_recipe" -ge 1 ]]; then
    echo "  PASS  delegate-calibration.json: per-recipe HIT-rate panel present"; pass=$((pass+1))
  else
    echo "  FAIL  delegate-calibration.json: no per-recipe (by (recipe)) HIT-rate panel"; fail=$((fail+1))
  fi
else
  echo "  FAIL  delegate-calibration.json missing"; fail=$((fail+1))
fi

# 5c. The per-recipe HIT-rate panel is a percentunit ratio time series. Its
#     legend reduce MUST NOT be `sum`: summing a fractional per-step ratio over
#     every step in the range adds the steps together and the percentunit unit
#     then multiplies by 100, surfacing impossible values like 5955%. A ratio
#     legend reduces with mean/lastNotNull (each bounded in [0,1]), never sum.
#     Same step-sum inflation class as the bargauge/pie fix (#249), different
#     surface (a timeseries legend calc instead of a panel-level reduce).
if [[ -f "$CALIBRATION" ]]; then
  recipe_sum_calc=$(jq -r '[.panels[] | select((.targets // []) | map(.expr // "") | join(" ") | (contains("by (recipe)") and contains("kept="))) | .options.legend.calcs // [] | index("sum")] | map(select(. != null)) | length' "$CALIBRATION" 2>/dev/null)
  if [[ "$recipe_sum_calc" == "0" ]]; then
    echo "  PASS  delegate-calibration.json: per-recipe HIT-rate legend reduce is not sum (no step-sum inflation)"; pass=$((pass+1))
  else
    echo "  FAIL  delegate-calibration.json: per-recipe HIT-rate panel legend uses sum (5955%-style step-sum inflation on a ratio)"; fail=$((fail+1))
  fi
fi

# 5d. The canary-failure stat panel MUST key on the exit code delegate.sh
#     actually writes for a pre-flight canary/preflight-timeout stall. That is
#     exit_status=3 (scripts/delegate.sh `emit_failure 3` then `exit 3` on the
#     DELEGATE_PREFLIGHT_TIMEOUT path); exit_status=2 is validation/usage only
#     and never reaches metrics.jsonl, so a panel keyed to 2 always reads 0.
ERRORS="$DASHBOARDS/grafana/delegate-errors.json"
if [[ -f "$ERRORS" ]]; then
  canary_expr=$(jq -r '[.panels[] | select((.title // "") | test("[Cc]anary")) | .targets[0].expr // ""] | join(" ")' "$ERRORS" 2>/dev/null)
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
