#!/usr/bin/env bash
# Recipe frontmatter readers shared by delegate.sh and delegate-boundary-hook.sh.
#
# `recipe_tier <file>` prints the `tier:` a recipe declares, or nothing. It
# is the single-key frontmatter scan delegate.sh has used since #411, moved
# here so the boundary hook reads the SAME value: the hook grew its own copy
# for the #483 provider probe without the `[a-z-]+` shape check or the
# trailing-whitespace strip, so `tier: prose ` routed fine in delegate.sh and
# failed open in the hook (PR #484 review, item I). One expression, two
# callers, no drift.
#
# Sourcing has no side effects. bash 3.2 portable.

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
