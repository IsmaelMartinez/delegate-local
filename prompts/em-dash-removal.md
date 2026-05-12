# em-dash-removal

## When to use

The user wants to remove em-dashes from prose (typically a blog post, doc, or maintainer reply) and replace each with the most natural alternative — a period, comma, semicolon, or pair of parentheses depending on the surrounding context — while leaving every other wording, paragraph break, and frontmatter element intact. The transform is one-pass: each em-dash gets the substitution that best preserves the original meaning at that location.

Not for: rewriting the prose itself, tightening prose for concision (use `polish-reply.md`), or generic style edits that change voice or register. This recipe assumes the source is finished prose and only the em-dash punctuation needs to change.

## Context to gather first

```bash
# The source text — pipe it on stdin as {{stdin}}. Typical sources:
# a markdown file with the article, or a paragraph from a doc:
cat path/to/article.md
```

The recipe takes the source via `{{stdin}}` and emits the rewritten version on stdout. No per-call `--var` slots beyond stdin.

## Prompt template

```
Rewrite this text to remove every em-dash (—) and replace it with the most natural alternative at each location: a period, comma, semicolon, or pair of parentheses. Choose the substitution that best preserves the original meaning at that location.

RULES:

- Preserve every contraction exactly as written. Do NOT expand "it's" to "it is", "isn't" to "is not", "you've" to "you have", "you're" to "you are", "we're" to "we are", "don't" to "do not", "doesn't" to "does not", "I'd" to "I would", or any similar contraction. This is non-negotiable: contractions carry the casual voice and expanding them is a regression.

- When em-dashes enclose a parenthetical list, the pattern is `X — A, B, C — Y` and the correct substitution is parentheses: `X (A, B, C), Y`. Do NOT replace both em-dashes with commas in this pattern — that would collapse the parenthetical into a flat ambiguous list. The two em-dashes act as opening and closing brackets; preserve that role.

- Do not change any wording outside the em-dash substitution. Do not rephrase, summarise, expand, or paraphrase any sentence. Preserve every word, every clause, every paragraph break exactly.

- Do not change frontmatter (YAML between `---` markers at the top of the file), code fences, or quoted text. Substitute em-dashes inside ordinary prose only.

- Output the rewritten text only. No preamble, no "Here's the revised text:", no markdown fence around the output.

Wrong: `the AI — CLAUDE.md, the loop, manual review — you're not using a tool`
       → `the AI, CLAUDE.md, the loop, manual review, you're not using a tool`  (parenthetical collapsed into flat list, AND `you're` decontracted)

Correct: `the AI — CLAUDE.md, the loop, manual review — you're not using a tool`
       → `the AI (CLAUDE.md, the loop, manual review), you're not using a tool`  (parenthetical preserved with parens, contraction intact)

=== Source text ===
{{stdin}}
```

## Variables

- `{{stdin}}` — the source text, piped in. No `--var` slot needed.

## Invocation

```bash
cat path/to/article.md | bash scripts/delegate.sh --recipe em-dash-removal \
  prose "Preserve every contraction. Use parentheses for the parenthetical-list pattern."
```

The trailing prompt arg is the reinforcement instruction; the recipe template carries the structural directives and the contrastive Wrong/Correct example.

## Anti-hallucination guards (each line addresses a real past MISS)

- "Preserve every contraction exactly as written" with explicit enumeration — addresses the decontraction failure mode observed in issue #107: prose-tier models on `qwen3.6:35b-a3b-q8_0` expand `it's` → `it is`, `you're` → `you are`, etc. non-deterministically across stylistically similar inputs even when "do not change wording" was in the prompt. The bare negation didn't bind; the enumerated list does. Same v5/v7 directive-rule pattern that closed the `(#NN)` gap in `commit-message.md`.

- "When em-dashes enclose a parenthetical list..." with the explicit `X — A, B, C — Y` → `X (A, B, C), Y` mapping — addresses the parenthetical-list-collapse failure mode also observed in issue #107: the model replaces both em-dashes with commas, producing a flat ambiguous list (`X, A, B, C, Y`) that loses the parenthetical structure. The Wrong/Correct one-shot at the bottom of the template reinforces the rule with a concrete example drawn from the original session.

- "Do not change any wording outside the em-dash substitution" — generic preservation directive. The contraction and parenthetical-list guards address the two confirmed sub-patterns; this catches other unenumerated regressions (synonym swaps, sentence reordering).

- "Do not change frontmatter..." — addresses the markdown-document case where YAML between `---` markers should pass through verbatim. The em-dash inside a `---` frontmatter line is a YAML delimiter, not prose, and a naive substitution would break the parser.

- "Output the rewritten text only..." — without this, the model wraps in `Here's the revised text:` prose that has to be stripped.

## Expected output shape

The full input text, paragraph for paragraph, with every em-dash replaced by the substitution that best preserves meaning at that location. No surrounding meta-prose. Length matches the input within a token or two.

Verify before recording verdict: scan the output for any contraction that has been expanded (`it is`, `we are`, `you have`, `does not`, etc. in places where the source had the contraction) and any parenthetical-list pattern that has been flattened. A diff against the original is the most reliable check.

## Calibration notes

This recipe originates from issue #107, filed 2026-05-12 by a cross-repo session using `prose` tier (resolved to `qwen3.6:35b-a3b-q8_0`) to remove em-dashes from a series of ~750-word blog articles. Two distinct failure modes recurred:

- **Decontraction** — `it's` → `it is`, `isn't` → `is not`, `you've` → `you have`, `you're` → `you are`, `we're` → `we are`, `don't` → `do not`, `doesn't` → `does not`, `I'd` → `I would`. Non-deterministic across calls in the same session despite identical prompt template (article 3 kept contractions, article 2 expanded them throughout). Collapses a casual/personal voice into a formal register.

- **Parenthetical-list collapse** — input `you've built enough harness around the AI — CLAUDE.md, the research-then-spike loop, manual review, CI gates — you're not using a tool any more` produced output `you've built enough harness around the AI, CLAUDE.md, the research-then-spike loop, manual review, CI gates, you're not using a tool any more`. The output parses as a five-item list rather than as "the AI" with "(CLAUDE.md, research-then-spike, manual review, CI gates)" as parenthetical examples of harness.

Both regressions were caught by diff-against-original review in the affected session and corrected by hand. The recipe codifies the two suggested directive rules from the issue, plus the v5/v7-pattern contrastive Wrong/Correct one-shot example built from the exact failing input.

The issue also asks whether the behaviour is size-dependent — `qwen3.6:35b-a3b-q8_0` is an MoE with 35B total / ~3B active. Running the same em-dash-removal task against larger installed models (`qwen3-next:80b-a3b-instruct-q8_0`, `qwen3.5:122b-a10b-q4_K_M`) would settle whether the directive rules are necessary at every prose-tier model, or just at the small-active-parameter tier-leader. A future T-fixture (T7 candidate) would make this measurement reproducible.
