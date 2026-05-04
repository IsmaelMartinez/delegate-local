#!/usr/bin/env bash
# Build the code-edit prompt for one fixture directory. Prints to stdout.
# Uses an Aider-style SEARCH/REPLACE block format with a one-shot example,
# explicit output rules, and a directive-rule cap on scope.

set -euo pipefail

fixture_dir="$1"

task=$(cat "$fixture_dir/task.md")
source=$(cat "$fixture_dir/source.py")
tests=$(cat "$fixture_dir/test_source.py")

cat <<EOF
You are editing a single Python file to make its failing tests pass.

OUTPUT RULES (non-negotiable):
1. Reply with ONE OR MORE SEARCH/REPLACE blocks. No prose, no markdown fences around the whole reply.
2. Each block has exactly this shape:

<<<<<<< SEARCH
<exact lines from source.py, byte-for-byte>
=======
<replacement lines>
>>>>>>> REPLACE

3. The SEARCH section must match source.py exactly, including indentation and blank lines. If the match is ambiguous, include more surrounding lines.
4. Do not modify the test file. Do not add new imports. Do not invent helpers.
5. Keep the change minimal: only edit the lines required to make the failing tests pass.

EXAMPLE
For the input source:

def add(a, b):
    return a - b

A correct reply is:

<<<<<<< SEARCH
def add(a, b):
    return a - b
=======
def add(a, b):
    return a + b
>>>>>>> REPLACE

NOW THE TASK

$task

Current source.py:

$source

Current test_source.py (do not modify):

$tests

Reply with SEARCH/REPLACE blocks only.
EOF
