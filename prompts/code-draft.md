---
inputs:
  goal: string
  scope: string
  constraints: string?
  verification: string
---
# code-draft

## When to use

You are doing your own implementation work and want a *divergent, executable*
second opinion on one bounded piece of it — not because this skill owns the
coding (it does not; you do), but because a differently-trained local model
will sometimes propose an approach, or make a mistake, you would not have
generated yourself, and because running its draft answers "does this compile /
pass the test / behave as I assumed" in a way static reasoning cannot. Fire it
only when BOTH hold: (1) a value trigger — the approach is genuinely forked and
you are unsure which way to go, OR executing the draft would teach more than
reasoning about it; AND (2) the bounded guard — a single file or function,
small output, with a concrete verification (a test to run or an explicit
acceptance check) named up front. The draft is always disposable: verify before
keeping anything. This is NOT "delegate all coding" — generic, low-divergence,
easily-self-drafted code does not qualify, because for those the local
round-trip only adds latency. Routes to the `code` tier. See SKILL.md's
"Supervised code drafts" doctrine and ADR 0025.

## Context to gather first

Decide and write down the four parts of the brief before invoking — writing the
brief is the real value engine, because it forces your own clarity whether or
not the model's output is used:

- the GOAL (what the snippet must produce),
- the SCOPE (the single file or function it touches, and nothing wider),
- the CONSTRAINTS (language, style, libraries to use or avoid; may be empty),
- the VERIFICATION (the test to run, or the explicit acceptance criterion).

Gather the surrounding source the draft must fit into and pipe it on stdin:

```bash
sed -n '<start>,<end>p' path/to/file        # the function/section being changed
# or the failing test the draft must satisfy, so the model sees the contract
```

Pipe only what fits the bounded task in a short prompt — this recipe is for one
file or function, not a repo-wide context.

## Prompt template

```
Write a focused code draft for the single bounded task below. Do not invent APIs, file paths, types, or behaviour that are not in the brief or the surrounding source.

GOAL (what to produce): {{goal}}
SCOPE (the single file or function this touches — nothing wider): {{scope}}
CONSTRAINTS (language, style, libraries to use or avoid; may be empty): {{constraints}}
VERIFICATION (how the caller will check this — the test it must pass or the explicit acceptance criterion): {{verification}}

Output rules:
- Output a SINGLE focused snippet — the full function or file section, NOT a unified diff (no @@ hunk headers, no +/- line prefixes). The caller will diff your snippet themselves.
- Stay strictly within SCOPE. Do NOT refactor, rename, reformat, or touch anything the brief did not name.
- Use only APIs, types, and identifiers that appear in the surrounding source below or are named in the brief. If you need something that is not provided, do NOT invent it — leave a single `NEEDS: <what>` comment where it would go.
- Write to satisfy the VERIFICATION literally. Do not add features the brief did not ask for.
- If the task cannot be completed correctly as stated (the verification is contradictory, the scope is impossible without more context), reply with a single line beginning `REFUSE:` explaining why, and output no code.
- Output ONLY the code (a fenced code block is fine). No explanation, no prose before or after, no "Here is".

=== Surrounding source / context (may be empty) ===
{{stdin}}
```

## Variables

- `{{goal}}` — one sentence naming exactly what the snippet must produce. Authored by the agent.
- `{{scope}}` — the single file path or function name the draft is allowed to touch, stated so the model cannot widen it. Authored by the agent.
- `{{constraints}}` — OPTIONAL. Language, style, library, or avoid-this rules. Omit it (the placeholder collapses to empty) when there are none; the template's "may be empty" wording handles the blank.
- `{{verification}}` — the concrete check the draft must satisfy: a test command and its expected result, or an explicit acceptance criterion. Load-bearing — the bounded guard requires a named verification up front. Authored by the agent.
- `{{stdin}}` — the surrounding source the draft must fit into (the function being changed, or the failing test that states the contract), piped in. Optional: when nothing is piped it collapses to empty and the model drafts from the brief alone.

## Invocation

```bash
sed -n '40,80p' src/widget.py | bash scripts/delegate.sh --recipe code-draft \
  --var goal="Implement parse_duration(s) returning seconds as an int" \
  --var scope="the parse_duration function in src/widget.py (do not touch callers)" \
  --var constraints="stdlib only; raise ValueError on malformed input" \
  --var verification="python -m pytest tests/test_widget.py::test_parse_duration must pass" \
  code "Output only the function body as a focused snippet."
```

After the call, apply the snippet yourself, run the named VERIFICATION, and
record the honest verdict: `delegate-feedback.sh --source agent hit` if you kept
the draft as-is, `miss "<reason>"` if it was useless, or
`scaffold "<what it taught>"` if you discarded the code but the divergence or
the executable feedback genuinely improved your final result.

## Anti-hallucination guards (each line addresses a documented code-delegation failure mode)

- "Do not invent APIs, file paths, types, or behaviour … leave a `NEEDS:` comment" — the highest-volume local-model failure is fabricating identifiers that look plausible but don't exist. The explicit escape hatch gives the model somewhere to put the gap instead of inventing.
- "NOT a unified diff (no @@ hunk headers, no +/- line prefixes)" — weak models botch hunk headers and line offsets; a full snippet the caller diffs themselves is reliable where a generated diff is not. Drawn from the SKILL.md note that code-tier models append spurious tokens when extending anchored sequences.
- "Stay strictly within SCOPE … do not refactor, rename, reformat" — without the fence, code models volunteer adjacent "improvements" that blow the bounded guard and force a larger review than the task warranted.
- "If the task cannot be completed correctly … reply with `REFUSE:`" plus the verify-before-keep discipline — the 2026-05-04 adversarial probe in SKILL.md showed a model can refuse in prose and comply with a wrong patch in the same response, so the REFUSE line is advisory and the VERIFICATION is authoritative. The recipe pairs them deliberately.
- "Output ONLY the code … no prose preamble" — without it the model wraps the snippet in "Here is the function:" prose that has to be stripped before the snippet can be applied.

## Expected output shape

```
<a single focused code snippet — the full function or file section named in
 SCOPE, in the language of the surrounding source, using only provided
 identifiers, with a `NEEDS: <x>` comment in place of anything not supplied>
```

or, when the task is not honestly satisfiable:

```
REFUSE: <one line on why — contradictory verification, scope impossible without more context>
```

Verify before recording the verdict: the snippet stays within the named SCOPE,
invents no identifiers (every symbol traces to the brief or the piped source),
and actually passes the named VERIFICATION when applied. A snippet that applies
but fails the verification is treated as a REFUSE — never kept on the strength
of the prose alone.

## Calibration notes

Seeded 2026-06-22 from the supervised-draft-delegation design spec
(`docs/superpowers/specs/2026-06-22-supervised-draft-delegation-design.md`, G2)
and ADR 0025. Unlike the prose recipes, this one ships with no verbatim-HIT
calibration history yet — it is the recipe arm of an explicit experiment. Its
guards are anchored in the documented code-delegation failure modes already in
SKILL.md (invented APIs, the prose/code REFUSE contradiction from the
2026-05-04 adversarial probe, code-tier sequence-extension artefacts), not in
this recipe's own MISS log. The evidence gate (spec G5) measures whether
`hit + scaffold` verdicts on `code-draft` delegations clear a clear-majority
bar over a window of at least ~10 calls; if they do not, ADR 0025's kill path
reverts this recipe and the SKILL.md doctrine while keeping the scaffold verdict.
Record every `code-draft` verdict (`hit` / `miss` / `scaffold`) so that gate has
data — the calibration history below grows from those rows as they accrue.
