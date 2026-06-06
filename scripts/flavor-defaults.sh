#!/usr/bin/env bash
# Shipped flavor defaults (ADR 0013, portable recipes). These reproduce the
# style values the recipes carried inline before the flavor split, so a user
# with no profile.sh gets byte-identical prompts — back-compat is the contract.
# A per-user ~/.claude/skills/delegate-local/profile.sh overrides any of these;
# scripts/derive-flavor.sh generates one from the user's own git history.
#
# Sourced by load-flavor.sh — never executed directly. Every {{flavor_*}}
# placeholder a recipe uses MUST have its FLAVOR_* default here, or the
# unsubstituted-placeholder guard in delegate.sh will (correctly) refuse.

# commit-message recipe
FLAVOR_COMMIT_SUBJECT_MAX=72
FLAVOR_COMMIT_TYPES="feat, fix, ci, docs, chore, refactor, test"
