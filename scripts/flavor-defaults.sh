#!/usr/bin/env bash
# Shipped flavor defaults (ADR 0013, portable recipes). These are the
# industry-standard conventional-commits values — the @commitlint/config-
# conventional type enum and the 72-char git subject convention — NOT the
# maintainer's personal taste, which lives in the maintainer's own profile.sh
# like any other user's ("the maintainer becomes just another profile").
# Run scripts/onboard.sh (or derive-flavor.sh) to derive yours from your own
# git history; a per-user ~/.local/share/delegate-local/profile.sh overrides
# any of these. T4-measured 2026-06-11: the standard list scores identically
# to the previous curated subset (15/18 MLX prose, same residual).
#
# Sourced by load-flavor.sh — never executed directly. Every {{flavor_*}}
# placeholder a recipe uses MUST have its FLAVOR_* default here, or the
# unsubstituted-placeholder guard in delegate.sh will (correctly) refuse.

# commit-message recipe
FLAVOR_COMMIT_SUBJECT_MAX=72
FLAVOR_COMMIT_TYPES="feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert"
# The prompt asks for "1-2 short flowing-prose paragraphs"; 120 words is that
# contract and nothing tighter, so the default only catches a body that has
# run away from what the prompt already asked for. How short a commit body
# should actually be is house style, not a standard — set a tighter value in
# your own profile.sh if your project wants one.
FLAVOR_COMMIT_BODY_MAX_WORDS=120
# The body's STRUCTURAL shape (FLAVOR_COMMIT_BODY_SHAPE) is deliberately not set
# here: load-flavor.sh derives it from the cap above AFTER the profile is read,
# so tightening the cap cannot leave the recipe asking for a shape that does not
# fit inside it. Set it in profile.sh to override the derivation.
