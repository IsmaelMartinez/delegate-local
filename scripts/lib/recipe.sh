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
# and shapes nothing the model sees (#590). A `verify:` line is left out for
# the same reason: it runs a check on the draft afterwards (#661).
# One helper for delegate.sh (the row's template_sha) and replay-recipe.sh
# (the arm's hash), so the two cannot drift; tests/test-recipe-lib.sh pins
# its value for every recipe. Empty where shasum is missing.
recipe_template_sha() { # file
  command -v shasum >/dev/null 2>&1 || return 0
  # The delimiter lines go in as written, trailing whitespace and all, and an
  # unclosed frontmatter runs to the end of the file with no template after
  # it (awk exits 1), so no recipe's hash moved when the readers were shared.
  {
    awk '
      NR==1 { if (/^---[[:space:]]*$/) { in_fm=1; print; next } exit }
      /^input_quality:[[:space:]]*$/ { in_iq=1; next }
      in_iq && /^[[:space:]]+[^[:space:]]/ { next }
      in_fm && /^verify:/ { in_iq=0; next }
      { in_iq=0; print; if (/^---[[:space:]]*$/) { closed=1; exit } }
      END { if (in_fm && !closed) exit 1 }
    ' "$1" 2>/dev/null && recipe_template "$1"
  } | shasum -a 256 | cut -c1-12
}

# recipe_verify <file> — `true` when the frontmatter sets `verify: true`
# (#661): delegate.sh then runs verify-draft.sh on the call's draft.
recipe_verify() { # file
  recipe_fm_block "$1" | awk '/^verify:[[:space:]]*true[[:space:]]*$/ { print "true"; exit }'
}

# recipe_verify_input — the {facts, draft} verify-draft.sh scores, from two
# JSON values on stdin: a recipe call's structured inputs (the inputs.json
# delegate.sh stores) then the draft as a JSON string. The facts are the
# piped stdin then every --var value in key order, newline-joined; the
# positional prompt and the rendered template are not facts (docs/verify.md).
# One expression for delegate.sh's inline check and verify-draft.sh --id.
recipe_verify_input() {
  jq -sc '{facts: (([.[0].stdin // ""] + ((.[0].vars // {}) | to_entries | sort_by(.key) | map(.value))) | join("\n")),
           draft: .[1]}'
}
