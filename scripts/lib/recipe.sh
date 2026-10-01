#!/usr/bin/env bash
# Recipe readers shared by delegate.sh, delegate-boundary-hook.sh,
# replay-recipe.sh and self-improve.sh, so every caller reads the SAME value:
# a hook-side copy once lacked the shape check and the trailing-whitespace
# strip, and `tier: prose ` failed open there. Sourcing has no side effects.
# bash 3.2 portable.

# recipe_fm_block <file> — the frontmatter's lines, without the `---`
# delimiters: nothing unless line 1 is `---`, and up to the next `---` (or the
# end of the file). Every frontmatter key is read from this.
recipe_fm_block() { # file
  awk '
    NR==1 { if (/^---[[:space:]]*$/) next; exit }
    /^---[[:space:]]*$/ { exit }
    { print }
  ' "$1" 2>/dev/null
}

# recipe_template <file> — the first fenced block under "## Prompt template",
# the text delegate.sh sends. The `/^## /` section end is gated on
# `!in_block` so a heading inside the fenced block does not close it.
recipe_template() { # file
  awk '
    /^## Prompt template[[:space:]]*$/ { in_section=1; next }
    /^## / && in_section && !in_block { in_section=0 }
    in_section && /^```/ {
      if (in_block) { exit }
      in_block=1; next
    }
    in_section && in_block { print }
  ' "$1" 2>/dev/null
}

# recipe_required_inputs <file> — the frontmatter `inputs:` block as one
# `key type` line per declared input, flat `key: type` pairs only, parsed
# with awk so there is no yq dependency. An optional input keeps its `?`
# suffix (`ask string?`), so a caller wanting only the required keys skips
# those; delegate.sh needs both to type-check what was passed.
recipe_required_inputs() { # file
  recipe_fm_block "$1" | awk '
    /^inputs:[[:space:]]*$/ { in_inputs=1; next }
    in_inputs && /^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*[a-zA-Z?]+[[:space:]]*$/ {
      sub(/^[[:space:]]+/, ""); sub(/:[[:space:]]*/, " "); sub(/[[:space:]]+$/, ""); print; next
    }
    in_inputs && /^[a-zA-Z_]/ { in_inputs=0 }
  '
}

# recipe_tier <file> — the declared `tier:`, or nothing.
recipe_tier() { # file
  recipe_fm_block "$1" | awk '
    /^tier:[[:space:]]*[a-z-]+[[:space:]]*$/ {
      sub(/^tier:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit
    }
  '
}

# recipe_template_sha <file> — a 12-char sha256 of what shapes the model's
# output: the frontmatter (tier, inputs, checks) between its `---` lines and
# the recipe_template block. The prose sections ("When to use", "Calibration
# notes") are left out, so a dated note added after a revert does not split
# the per-template read into a third bucket.
# The `input_quality:` block is left out too: it judges the caller's inputs
# and shapes nothing the model sees (#590).
# One helper for delegate.sh (the row's template_sha) and replay-recipe.sh
# (the arm's hash), so the two cannot drift; tests/test-recipe-lib.sh pins
# its value for every recipe. Empty where shasum is missing.
recipe_template_sha() { # file
  command -v shasum >/dev/null 2>&1 || return 0
  {
    if head -n 1 "$1" 2>/dev/null | grep -q '^---[[:space:]]*$'; then
      echo '---'
      recipe_fm_block "$1" | awk '
        /^input_quality:[[:space:]]*$/ { in_iq=1; next }
        in_iq && /^[[:space:]]+[^[:space:]]/ { next }
        { in_iq=0; print }
      '
      echo '---'
    fi
    recipe_template "$1"
  } | shasum -a 256 | cut -c1-12
}
