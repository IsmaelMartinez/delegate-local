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
# <recipe> <sha256 of the whole file, 12> <template_sha>: file shas as of
# #569 (calibration notes moved to docs/calibration/); template_sha values
# unchanged since main @ 26ebba6. A pin applies only while the file is the one it was computed on:
# editing a recipe changes its hash by design, so an edited recipe is
# skipped here rather than failing, and the synthetic fixture below keeps
# pinning the reader's behaviour after every recipe has moved on.
golden='bulk-classify 8468f9ad218c 7b63da5f5be8
code-draft 1ce7c3fd334f 015fe4d5f44c
commit-message b3aa9e994d4d a20e93b62bab
doc-section b76ea0f2d48e d1d200883f29
file-summary 33900e387386 f68b364cb12c
fix-with-test eb261fac13b2 7ab4349174c9
github-issue-body 008a8495fbfc 477bb405d75d
maintainer-reply 0064a926a646 c9444a457a08
maintainer-review-reply 6b8ece46ac1b 200da2e4317a
pr-description 72bbe1905655 4426d3be28da
pr-review-reply 66a83a31b44b 3997496bc2ab
release-announcement cacce8316052 cbf5d01878fd
summarise-issue d316bdee43af 3c9b7cb7ef25'

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

# The delimiter lines are hashed as written, and an unclosed frontmatter
# hashes the whole file with no template, as on main before #559: both
# values were computed with main's recipe_template_sha, so a custom recipe
# with `--- ` keeps its hash.
printf -- '--- \ntier: prose\ninput_quality:\n  why: no_diff\n---\t\n# x\n\n## Prompt template\n\n```\nSay {{stdin}}.\n```\n' > "$tmp/trail.md"
assert_eq "872a96670125" "$(recipe_template_sha "$tmp/trail.md")" \
  "fixture: trailing whitespace on the delimiters is hashed as written"
printf -- '---\ntier: prose\ninput_quality:\n  why: no_diff\n# x\n\n## Prompt template\n\n```\nSay {{stdin}}.\n```\n' > "$tmp/unclosed.md"
assert_eq "40c7b42bc92c" "$(recipe_template_sha "$tmp/unclosed.md")" \
  "fixture: an unclosed frontmatter hashes as it did on main"

# --- the readers every caller shares (#559) --------------------------------
assert_eq "stdin string"$'\n'"why string?" "$(recipe_required_inputs "$tmp/fx.md")" \
  "recipe_required_inputs: one 'key type' line per input, the optional '?' kept"
assert_eq "prose" "$(recipe_tier "$tmp/fx.md")" "recipe_tier: reads the frontmatter tier"
assert_eq "Summarise."$'\n'"## not a section end"$'\n'"{{stdin}}" "$(recipe_template "$tmp/fx.md")" \
  "recipe_template: the first fence only, a heading inside it kept"
printf 'tier: prose\n---\n' > "$tmp/nofm.md"
assert_eq "" "$(recipe_fm_block "$tmp/nofm.md")" "recipe_fm_block: nothing when line 1 is not ---"

echo
echo "$pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then exit 1; fi
