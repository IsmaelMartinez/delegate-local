#!/usr/bin/env bash
# Shipped flavor defaults (ADR 0013): the conventional-commits standard values,
# not the maintainer's taste, which lives in profile.sh like any other user's.
# Sourced by load-flavor.sh, never executed. Every {{flavor_*}} placeholder a
# recipe uses MUST have its FLAVOR_* default here, or the unsubstituted-
# placeholder guard in delegate.sh refuses.

# commit-message recipe
FLAVOR_COMMIT_SUBJECT_MAX=72
FLAVOR_COMMIT_TYPES="feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert"
# 120 words is the "1-2 short paragraphs" the prompt already asks for; how
# short a body should be is house style, set in profile.sh.
FLAVOR_COMMIT_BODY_MAX_WORDS=120
# FLAVOR_COMMIT_BODY_SHAPE is deliberately not set here: load-flavor.sh
# derives it from the cap AFTER the profile is read, so a tightened cap cannot
# leave the recipe asking for a shape that does not fit.
