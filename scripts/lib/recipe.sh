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
