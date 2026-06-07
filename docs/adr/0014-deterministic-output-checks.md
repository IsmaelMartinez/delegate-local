# 14. Deterministic output-constraint checks

Date: 2026-06-06

## Status

Accepted.

## Context

Prompt-based constraints fail to bind formatting rules under greedy decoding, as evidenced by repeated failures to enforce subject length and avoid trailing padding. These errors remain deterministically checkable after generation despite the prompt's inability to prevent them beforehand. The remedy is to move the enforcement lever out of the prompt and into a post-generation check that inspects the finalised output.

The evidence is concrete. In a single working session the `commit-message` recipe emitted a trailing participial padding clause four separate times — the "…, ensuring X" / "…, keeping Y" shape — each one hand-trimmed and logged as a MISS, and the over-72-character subject recurs across the metrics history. The lever tried repeatedly was prompt enumeration: a longer and longer blocklist of forbidden phrases. ADR 0013's predecessor work (PR #264) is the proof that this lever is exhausted — adding more paraphrase examples shipped, and the very next dogfood still produced the rejected shape. Under greedy decoding the model converges to the same failure no matter how many examples the prompt carries.

This is a different axis from the flavor profile in ADR 0013. Flavor decides what the output should look like for a given user; a check verifies the finalised output against a constraint regardless of who is asking. The two compose — `subject_max` reads the same flavor value the prompt's cap uses — but they are separate mechanisms with separate jobs.

## Decision

Recipes may declare a frontmatter `checks:` block, mirroring the existing `inputs:` block. Each indented `name: value` line names a check that `delegate.sh` runs against the finalised output (after `</think>` stripping). The block rides the same `{{key}}` substitution as the prompt template, so a check value can reference a flavor placeholder and stay in lockstep with the prompt — `subject_max: {{flavor_commit_subject_max}}` enforces exactly the cap the prompt advertised.

Two checks ship in the first cut. `subject_max: <int>` fails when the first non-empty output line exceeds the integer. `no_padding_tail: true` fails when the last non-empty line ends on a trailing participial clause, a "This-X" declarative rephrase, or a known restating phrase — the recurring BODY_NO_PADDING signatures, matched by a compact regex kept alongside the prompt's anti-padding enumeration. `commit-message` opts in to both.

Checks are warn-only. A failure prints a `delegate: check '<name>' FAILED — <detail>` line to stderr and contributes a `checks_failed=N` field to the `delegate-meta` line; it never alters the output and never changes the exit code. This is deliberate. Greedy decoding makes a naive re-roll fruitless — the same input yields the same output unless something is perturbed — so auto-correction is neither free nor obviously safe, and is out of scope here. The improvement loop already has a reviewer (the agent or user) reading each output and hand-fixing violations; the value of the check is to make detection deterministic, so an over-long subject or a padding tail can no longer slip past unnoticed. The checks are gated on the same clean-stderr conditions as the meta line, so batch runs (`NO_META`) and failed calls stay quiet.

## Consequences

The recurring length and padding failures are now caught deterministically rather than relying on the reviewer to spot them, which is the concrete win for the highest-frequency MISS classes. The design composes cleanly with the rest of the wrapper: the `checks:` block reuses the frontmatter-extraction and substitution machinery, flavor-aware checks stay consistent with the prompt by construction, and recipes that declare no checks are completely untouched. For `commit-message` the prompt's anti-padding enumeration and the `no_padding_tail` check now act as belt-and-suspenders — the prompt still tries to avoid the shape, and the check catches it when the prompt fails.

The costs are modest and bounded. The padding regex is an approximation: it targets the common offenders and will neither catch every padding shape nor be entirely free of false positives, but warn-only framing keeps a false positive cheap — a stderr line the caller can dismiss. The check surface is new code in `delegate.sh`, covered by tests for both the failure and the clean path.

Deliberately out of scope, and deferred: auto-fix or perturbed re-roll (the warn-first stance above), and a `max_source_overlap` check for verbatim fact-echo, which is the next natural addition. Also out of scope by nature is fact-fabrication — content absent from the source — which a deterministic string check cannot distinguish from good paraphrase; that remains the job of the separate semantic grounding work, not this layer.
