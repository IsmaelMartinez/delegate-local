# 4. Optional MCP server is a thin Python wrapper, not a reimplementation

Date: 2026-05-01

## Status

Accepted.

## Context

Phase 5 of the roadmap calls for an "optional MCP server wrapping the
audit and pick-model scripts so non-Claude tools can query them
programmatically rather than shelling out". The Claude Code skill itself
does not need this server — the SKILL.md instructions tell Claude to
shell out to `pick-model.sh` and `delegate.sh` directly. The motivation
is purely interoperability: a Codex / OpenCode / Cursor / custom MCP
client wanting to ask "which tier picks for prose?" without having to
exec a subprocess and parse stdout.

Three implementation options were considered:

The bash route was attractive on aesthetic grounds — the rest of the
runtime is two bash scripts, a third would feel consistent. In practice
MCP is JSON-RPC 2.0 over stdio with rich tool schemas; doing that in
pure bash is a significant amount of fragile parsing code, would
duplicate what the official SDKs already solve, and fights the very
ergonomics MCP exists to provide.

A TypeScript implementation using `@modelcontextprotocol/sdk` works
fine but introduces Node, npm, and a `tsc` step into a repo whose
runtime dependencies are bash, jq, and perl. The cost of adding Node
felt larger than the cost of adding Python, given that Python's MCP
SDK reaches the same quality with roughly half the boilerplate.

A Python implementation using the official `mcp` package and
`FastMCP` decorators turned out to be ~50 lines of code wrapping
`subprocess.run` calls. Python is already on macOS by default and on
every CI runner used by the repo.

## Decision

Implement the MCP server in Python under a self-contained `mcp/`
subdirectory of this repo. The package exposes three tools —
`pick_model`, `audit_models`, and `list_tiers` — each of which is a
thin shell over an existing bash script. No new business logic lives
in the Python code; the bash scripts remain the single source of truth
for tier routing and upgrade-suggestion behaviour.

The `list_tiers` tool parses the `TIERS=...` line in `pick-model.sh`
rather than hardcoding the tier list, so adding or renaming a tier in
one place propagates correctly.

The package is intentionally not published to PyPI. Users who want it
clone the repo and run `pip install -e mcp/`. If a real consumer
materialises and wants a release channel, that is a follow-up; the
roadmap describes this server as optional.

## Consequences

The repo now has a Python toolchain alongside its bash one. CI gains a
second job (`mcp-server`) that installs Python 3.11+ and runs `pytest
mcp/tests/`. The two jobs are independent so a Python failure does not
gate the bash validation pipeline and vice versa.

The wrapper-not-reimplementation rule is load-bearing. If a future
contributor is tempted to reimplement tier routing in Python "for
performance" or "for type safety", they will create two sources of
truth that drift apart at the first preference-list edit. The
`tests/test_server.py` `test_list_tiers_against_real_script` assertion
catches the most likely class of drift (TIERS line being moved or
renamed) but it cannot catch a from-scratch rewrite. The ADR is the
durable signal that the wrapper is the design, not a placeholder.

The MCP server runs `bash` as a subprocess. That is a hard dependency
beyond the Python deps; the README documents it. On Windows hosts the
server will not work without a bash-compatible shell — consistent with
the rest of this repo, which has never targeted Windows.

The decision is reversible. If the wrapper proves too thin to be
useful, or if the bash scripts grow features that are awkward to
expose verbatim, a future ADR can supersede this one and migrate the
implementation. Nothing about the file layout precludes that.
