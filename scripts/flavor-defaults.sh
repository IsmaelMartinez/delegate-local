#!/usr/bin/env bash
# Shipped flavor defaults (ADR 0013, portable recipes). These are the
# industry-standard conventional-commits values — the @commitlint/config-
# conventional type enum and the 72-char git subject convention — NOT the
# maintainer's personal taste, which lives in the maintainer's own profile.sh
# like any other user's ("the maintainer becomes just another profile").
# Run scripts/onboard.sh (or derive-flavor.sh) to derive yours from your own
# git history; a per-user ~/.claude/skills/delegate-local/profile.sh overrides
# any of these. T4-measured 2026-06-11: the standard list scores identically
# to the previous curated subset (15/18 MLX prose, same residual).
#
# Sourced by load-flavor.sh — never executed directly. Every {{flavor_*}}
# placeholder a recipe uses MUST have its FLAVOR_* default here, or the
# unsubstituted-placeholder guard in delegate.sh will (correctly) refuse.

# commit-message recipe
FLAVOR_COMMIT_SUBJECT_MAX=72
FLAVOR_COMMIT_TYPES="feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert"
