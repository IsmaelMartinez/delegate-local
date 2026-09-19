#!/usr/bin/env bash
# Recipe frontmatter readers shared by delegate.sh and delegate-boundary-hook.sh,
# so both read the SAME value: a hook-side copy once lacked the shape check and
# the trailing-whitespace strip, and `tier: prose ` failed open there.
# `recipe_tier <file>` prints the declared `tier:`, or nothing. Sourcing has no
# side effects. bash 3.2 portable.

recipe_tier() { # file
  awk '
    BEGIN { in_fm=0 }
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm && /^tier:[[:space:]]*[a-z-]+[[:space:]]*$/ {
      sub(/^tier:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit
    }
  ' "$1" 2>/dev/null
}

# recipe_template_sha <file> — a 12-char sha256 of what shapes the model's
# output: the frontmatter (tier, inputs, checks) and the first fenced block
# under "## Prompt template", the block delegate.sh sends. The prose sections
# ("When to use", "Calibration notes") are left out, so a dated note added
# after a revert does not split the per-template read into a third bucket.
# One helper for delegate.sh (the row's template_sha) and replay-recipe.sh
# (the arm's hash), so the two cannot drift. Empty where shasum is missing.
recipe_template_sha() { # file
  command -v shasum >/dev/null 2>&1 || return 0
  awk '
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; print; next }
    in_fm { print; if (/^---[[:space:]]*$/) in_fm=0; next }
    /^## Prompt template[[:space:]]*$/ { in_section=1; next }
    /^## / && in_section && !in_block { in_section=0 }
    in_section && /^```/ { if (in_block) { exit } in_block=1; next }
    in_section && in_block { print }
  ' "$1" 2>/dev/null | shasum -a 256 | cut -c1-12
}
