#!/usr/bin/env bash
# Validate the committed dashboard JSON files in dashboards/grafana/.
#
# Three assertion families, all bash-3.2-portable (no associative arrays,
# no `grep -P`):
#
# 1. Each .json file under dashboards/grafana/ is valid JSON (jq parses it).
# 2. Each Grafana dashboard JSON has the three top-level keys Grafana
#    requires to import: `title`, `panels`, `schemaVersion`.
# 3. Every attribute name referenced in panels (span.foo.bar, resource.foo,
#    link.span.foo.bar) maps back to an attribute documented in
#    docs/otel-schema.md, so the dashboards cannot reference a name the
#    exporter does not emit.
#
# Plus a small fourth check: the Langfuse README exists (the documentation-
# as-code counterpart to the Grafana JSON for the no-portable-JSON backend).

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARDS="$REPO/dashboards"
SCHEMA="$REPO/docs/otel-schema.md"

pass=0
fail=0

assert_eq() {
  local expected="$1" actual="$2" name="$3"
  if [[ "$expected" == "$actual" ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (expected '$expected', got '$actual')"; fail=$((fail+1)); fi
}

assert_nonempty() {
  local value="$1" name="$2"
  if [[ -n "$value" && "$value" != "null" ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (empty or null)"; fail=$((fail+1)); fi
}

if [[ ! -d "$DASHBOARDS/grafana" ]]; then
  echo "  FAIL  dashboards/grafana/ directory missing"
  fail=$((fail+1))
  echo
  echo "$pass passed, $fail failed"
  exit 1
fi

if [[ ! -f "$SCHEMA" ]]; then
  echo "  FAIL  docs/otel-schema.md missing — cannot validate attribute references"
  fail=$((fail+1))
  echo
  echo "$pass passed, $fail failed"
  exit 1
fi

# Build the set of documented attribute names from the schema doc. The doc
# spells each attribute as `gen_ai.foo.bar` or `delegate.foo.bar` or
# `service.name` in tables and prose; grep -oE pulls every such token. The
# allowlist below filters out tokens that are not real attribute names
# (e.g. `delegate.sh` is a script filename that happens to match the
# pattern). Bash 3.2 has no associative arrays, so the set is a newline-
# delimited string that grep -Fx queries against.
docs_attrs=$(grep -oE '(gen_ai|delegate|service)\.[a-zA-Z_][a-zA-Z0-9_.]*' "$SCHEMA" \
  | sort -u \
  | grep -vxE 'delegate\.sh' \
  | grep -vxE 'gen_ai\.prompt' \
  | grep -vxE 'gen_ai\.completion' \
  | grep -vxE 'delegate\.prompt_text' \
  | grep -vxE 'delegate\.output_text' \
  | grep -vxE 'delegate\.context_text')

# Sanity: at minimum the eight required attributes must be in the docs set.
# A missing one means the schema doc has drifted and the test can't trust
# its allowlist.
required_in_schema=(
  "gen_ai.operation.name"
  "gen_ai.provider.name"
  "gen_ai.request.model"
  "delegate.tier"
  "delegate.exit_status"
  "delegate.feedback.verdict"
  "delegate.queue_wait_ms"
  "delegate.generation_ms"
)
for attr in "${required_in_schema[@]}"; do
  if printf '%s\n' "$docs_attrs" | grep -qxF "$attr"; then
    echo "  PASS  schema doc lists '$attr'"
    pass=$((pass+1))
  else
    echo "  FAIL  schema doc missing '$attr' — cannot validate dashboards against it"
    fail=$((fail+1))
  fi
done

# Iterate each Grafana JSON. Glob expands to the literal pattern when no
# matches exist, so guard against that explicitly.
dash_count=0
shopt -s nullglob
for dash in "$DASHBOARDS/grafana"/*.json; do
  dash_count=$((dash_count+1))
  base=$(basename "$dash")

  # Assertion family 1: valid JSON.
  if jq empty "$dash" >/dev/null 2>&1; then
    echo "  PASS  $base: valid JSON"
    pass=$((pass+1))
  else
    echo "  FAIL  $base: invalid JSON"
    fail=$((fail+1))
    continue
  fi

  # Assertion family 2: top-level keys present and non-empty.
  title=$(jq -r '.title // empty' "$dash")
  assert_nonempty "$title" "$base: top-level .title present"

  schema_version=$(jq -r '.schemaVersion // empty' "$dash")
  assert_nonempty "$schema_version" "$base: top-level .schemaVersion present"

  panel_count=$(jq -r '(.panels // []) | length' "$dash")
  if [[ "$panel_count" =~ ^[0-9]+$ && "$panel_count" -gt 0 ]]; then
    echo "  PASS  $base: top-level .panels is a non-empty array ($panel_count panels)"
    pass=$((pass+1))
  else
    echo "  FAIL  $base: top-level .panels missing or empty"
    fail=$((fail+1))
  fi

  # Assertion family 3: every attribute reference in the panel queries maps
  # to a documented attribute. Pull every `span.X` / `resource.X` /
  # `link.span.X` token from the entire JSON (queries live inside
  # .panels[].targets[].query strings; pulling from the whole file is
  # simpler than walking the structure and catches references in
  # descriptions, titles, and template variables too).
  refs=$(grep -oE '(span|resource|link\.span)\.(gen_ai|delegate|service)\.[a-zA-Z_][a-zA-Z0-9_.]*' "$dash" \
    | sed -E 's/^(span|resource|link\.span)\.//' \
    | sort -u)

  if [[ -z "$refs" ]]; then
    echo "  FAIL  $base: no attribute references found — dashboard is probably broken"
    fail=$((fail+1))
    continue
  fi

  while IFS= read -r attr; do
    [[ -z "$attr" ]] && continue
    if printf '%s\n' "$docs_attrs" | grep -qxF "$attr"; then
      echo "  PASS  $base: '$attr' is documented in docs/otel-schema.md"
      pass=$((pass+1))
    else
      echo "  FAIL  $base: '$attr' is NOT documented in docs/otel-schema.md"
      fail=$((fail+1))
    fi
  done <<< "$refs"
done
shopt -u nullglob

if [[ "$dash_count" -eq 0 ]]; then
  echo "  FAIL  dashboards/grafana/ contains no .json files"
  fail=$((fail+1))
else
  echo "  PASS  dashboards/grafana/ contains $dash_count dashboard(s)"
  pass=$((pass+1))
fi

# Fourth check: the Langfuse README exists. Langfuse has no portable JSON
# format so the file-as-code counterpart is the README, and a missing
# README means the documentation-as-code contract for the Langfuse backend
# has been silently dropped.
if [[ -f "$DASHBOARDS/langfuse/README.md" ]]; then
  echo "  PASS  dashboards/langfuse/README.md exists"
  pass=$((pass+1))
else
  echo "  FAIL  dashboards/langfuse/README.md missing"
  fail=$((fail+1))
fi

echo
echo "$pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
