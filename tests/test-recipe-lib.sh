#!/usr/bin/env bash
# Unit tests for scripts/lib/recipe.sh. The golden block pins template_sha:
# a changed hash for an unchanged recipe splits the replay champion and the
# per-template buckets in self-improve.sh, so a refactor of the readers must
# leave every value byte-identical (#559).

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/recipe.sh
. "$REPO/scripts/lib/recipe.sh"

pass=0
fail=0
assert_eq() {
  if [[ "$1" == "$2" ]]; then echo "  PASS  $3"; pass=$((pass+1))
  else echo "  FAIL  $3 (expected '$1', got '$2')"; fail=$((fail+1)); fi
}

if ! command -v shasum >/dev/null 2>&1; then
  echo "  SKIP  shasum not on PATH"; echo; echo "$pass passed, $fail failed"; exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- golden template_sha for every recipe in prompts/ ----------------------
# <recipe> <sha256 of the whole file, 12> <template_sha>, computed on main @
# 26ebba6. A pin applies only while the file is the one it was computed on:
# editing a recipe changes its hash by design, so an edited recipe is
# skipped here rather than failing, and the synthetic fixture below keeps
# pinning the reader's behaviour after every recipe has moved on.
golden='bulk-classify 775def0c320b 7b63da5f5be8
bulk-file-summary c8f6902ce370 fb912cffa833
ci-log-triage efb2e95a6f72 f080363ef100
code-draft 58b48fdb7d43 015fe4d5f44c
commit-message d18922411c42 a20e93b62bab
doc-section 27edc394c9c3 d1d200883f29
file-summary 1b0f3deae30f f68b364cb12c
fix-with-test caee5463af5b 7ab4349174c9
github-issue-body e5dfd0a52b95 477bb405d75d
jira-ticket-description 4b78b6c6b42d 4bdce242d3e8
long-thread-distillation b2db51c09a48 b2db43b9755e
maintainer-reply e1a90860db89 c9444a457a08
maintainer-review-reply 55a995310078 200da2e4317a
miss-theme-cluster a1d7bb36d719 94032a3cd78d
plan-section-intro 3b0f8bc167d2 aa1388882d79
pr-description 3e1e6d59be14 4426d3be28da
pr-review-reply b5f619d7e7f5 3997496bc2ab
release-announcement 12765cfc23da cbf5d01878fd
release-note f018a8de746e 48c1596477d7
roadmap-entry eb06d3894a7f 861d66baccd9
roadmap-status 796e0c868b83 396719894140
semantic-search 2976d489f5fc c6ca70fb8c50
summarise-issue 0616dde6488e 3c9b7cb7ef25'

skipped=0
while read -r name file_sha want; do
  f="$REPO/prompts/$name.md"
  if [[ ! -f "$f" || "$(shasum -a 256 "$f" | cut -c1-12)" != "$file_sha" ]]; then
    skipped=$((skipped+1)); continue
  fi
  assert_eq "$want" "$(recipe_template_sha "$f")" "golden template_sha: $name"
done <<< "$golden"
[[ "$skipped" -gt 0 ]] && echo "  SKIP  $skipped recipe(s) edited since the golden values were computed"

# --- synthetic recipe: pins the reader independently of prompts/ -----------
# Covers the input_quality exclusion (#590), a prose section before the
# template, a heading inside the fence, and a second fence after it.
write_fixture() { # file iq_label check_max
  cat > "$1" <<EOF
---
tier: prose
input_quality:
  why: $2
inputs:
  stdin: string
  why: string?
checks:
  subject_max: $3
---
# fixture

## When to use

Prose the hash must ignore.

## Prompt template

\`\`\`
Summarise.
## not a section end
{{stdin}}
\`\`\`

\`\`\`
second fence, not sent
\`\`\`

## Calibration notes

A dated note.
EOF
}
write_fixture "$tmp/fx.md" one_line_exemplar 72
# The hashed text is the frontmatter minus input_quality, delimiters kept,
# then the first fence's body; e494a353ca02 is that text's sha256.
assert_eq "e494a353ca02" "$(recipe_template_sha "$tmp/fx.md")" "fixture: pinned template_sha"
write_fixture "$tmp/fx-iq.md" titles_only 72
assert_eq "$(recipe_template_sha "$tmp/fx.md")" "$(recipe_template_sha "$tmp/fx-iq.md")" \
  "fixture: an input_quality edit leaves template_sha alone"
write_fixture "$tmp/fx-chk.md" one_line_exemplar 50
if [[ "$(recipe_template_sha "$tmp/fx.md")" != "$(recipe_template_sha "$tmp/fx-chk.md")" ]]; then
  echo "  PASS  fixture: a checks edit changes template_sha"; pass=$((pass+1))
else
  echo "  FAIL  fixture: a checks edit changes template_sha"; fail=$((fail+1))
fi

echo
echo "$pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then exit 1; fi
