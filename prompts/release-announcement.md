---
inputs:
  stdin: string
  version: string?
checks:
  no_padding_tail: true
---
# release-announcement

## When to use

You are drafting the narrative intro for a software release announcement — the warm, grounded paragraph or two at the top of a GitHub release page or announcement post that frames what the release is about, from grouped highlights you already have. The output is one or two short flowing-prose paragraphs referring to the major themes by name, no headings and no bullets, in a plain maintainer voice.

Distinct from `release-note.md`, which drafts a *single CHANGELOG bullet* for one merged PR. This recipe writes the human-facing intro narrative across the whole release; `release-note` writes the per-change bullets that sit below it. A typical release uses both: this recipe for the opening narrative, `release-note` (per PR) for the changelog list.

Not for: the full changelog itself (that is per-PR `release-note` work), or marketing copy with hype and calls to action (the recipe deliberately forbids puffery — a release intro is informative, not promotional).

## Context to gather first

```bash
# 1. The grouped highlights — pipe them on stdin as {{stdin}}. Group the
#    user-facing changes by theme, keeping the issue/PR numbers. Author this
#    from the merged PRs since the last release.
cat > "$CLAUDE_JOB_DIR/tmp/highlights.md" <<'EOF'
THEME: <name> — <the user-facing changes in this theme, with #NNN kept>
THEME: <name> — <...>
HEADS-UP: <any behaviour change users should know about>
EOF

# 2. The version string, passed via --var version=... (optional but recommended).
```

Group the highlights by theme before delegating — the model refers to the themes by name, it does not re-group raw PR titles. Keep every issue/PR number in the highlights so the intro can cite them verbatim.

## Prompt template

```
Write a short release-announcement intro for a software release, from the grouped highlights below. Audience: existing users reading a release page. Invent nothing that is not in the highlights.

Rules:
- One or two short paragraphs of flowing prose. No headings, no bullet lists. Refer to the major themes by name.
- Warm, grounded maintainer voice. No marketing puffery, no exclamation marks, no hype adjectives ("amazing", "huge", "game-changing", "exciting").
- Do NOT open with a greeting ("Hi everyone", "Hello"); this is a release note, not a reply.
- Keep every issue/PR number and the version string verbatim from the input. Do not invent version numbers, dates, or changes not listed.
- Avoid em dashes and " -- "; use commas, parentheses, or periods.
- Output ONLY the intro prose. No preamble, no markdown fence, no headings, no closing call-to-action line.
- Stop after the substantive content. Do NOT add a closing sentence that restates the point. Do NOT append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting", "providing", "allowing", "making", "enabling"). Do NOT end with a declarative rephrase ("This means", "This approach", "The result is", "In effect", "Overall", "In summary", "This ensures", "This enables"). Do NOT end with restating phrases ("going forward", "moving forward", "we hope you enjoy"). End on a finite verb introducing new content, or stop.
Wrong: This release focuses on stability and polish, making the app smoother for everyone going forward.
Correct: This release focuses on stability: the sync crash (#812) and the slow cold-cache startup (#790) are both fixed.

=== VERSION (the release name/version, verbatim) ===
{{version}}

=== HIGHLIGHTS (grouped user-facing changes — the only source material) ===
{{stdin}}
```

## Variables

- `{{stdin}}` — the grouped highlights, piped in: the user-facing changes grouped by theme with issue/PR numbers kept, plus any heads-up behaviour changes. No `--var` slot needed.
- `{{version}}` — the release name/version string (e.g. `teams-for-linux v2.10.0`) to cite verbatim. Optional; omit for a version-agnostic intro.

## Invocation

```bash
bash scripts/delegate.sh --recipe release-announcement \
  --var version="teams-for-linux v2.10.0" \
  prose "Two short paragraphs, warm and grounded, no puffery, no em dashes, no exclamation marks. Refer to themes by name, keep the #NNN numbers, invent nothing." \
  < "$CLAUDE_JOB_DIR/tmp/highlights.md"
```

After the call, verify (see Expected output shape) and record the verdict:

```bash
bash scripts/delegate-feedback.sh hit   # or: miss "<reason>"
```

## Anti-hallucination guards (each line addresses a recurring miss-mode)

- "No marketing puffery, no exclamation marks, no hype adjectives" — a release-intro prompt without this guard pulls the prose tier toward announcement-blog register ("We're thrilled to announce..."), which reads wrong in a maintainer's release notes. The named-forbidden-adjectives list is the same enumerated-blocklist discipline the library uses for padding verbs.
- "Do NOT open with a greeting; this is a release note, not a reply" — the model defaults to a conversational opener when handed warm-voice instructions; a release page is not a reply, so the greeting is stripped. (This is the inverse of `maintainer-reply.md`, where a warm opener is preserved — same rule, opposite genre.)
- "Keep every issue/PR number and the version string verbatim ... Do not invent version numbers, dates" — release intros are exactly where a model confabulates a plausible version bump or a release date that was never given; pinning verbatim-only citation keeps it grounded.
- "Avoid em dashes" — the maintainer's house style for release prose (observed verbatim in the real prompts: "Do NOT use em dashes ... use commas, parentheses or periods"). Taste-calibrated; a different adopter can drop this line.
- "Output ONLY the intro prose ... Stop after the substantive content" — the anti-padding block. A release intro is especially prone to a "we hope you enjoy this release" closing flourish; the Wrong/Correct anchor uses domain-neutral content (a sync crash and startup fix) per the library's domain-neutral-anchor convention.

## Expected output shape

```
teams-for-linux v2.10.0 is mostly a stability release. The screen-sharing
rewrite (#812, #819) fixes the black-window problem on Wayland, and the
notification routing changes (#790) stop duplicate tray alerts on multi-account
setups. Packaging moves to the new AppImage runtime, so users on older glibc
distributions should test the AppImage before upgrading their pinned version.
```

Verify before recording verdict: one or two short paragraphs, no headings, no bullets; warm but no puffery, no exclamation marks; no greeting opener; every issue/PR number and the version string verbatim, nothing invented; no em dashes; no preamble, no markdown fence, no closing call-to-action or "we hope you enjoy" flourish.

## Calibration notes

Graduated 2026-06-16 from observed recurring bare-delegation usage rather than from a recorded HIT. A 2026-06-15 analysis of the session-transcript corpus found the release-intro / TL;DR narrative shape recurring (notably across teams-for-linux releases) with no recipe — adjacent to `release-note.md` but a different output shape (a narrative intro, not a single CHANGELOG bullet), so it fell back to the bare `prose` tier each time with the no-puffery and no-em-dash directives re-specified by hand.

The prompt skeleton is lifted from the actual bare prompts used, which had converged on the same guards: "warm and grounded, no marketing puffery, no exclamation marks, no em dashes", "Do not begin with a warm greeting; this is a release note, not a reply", "keep the issue/PR numbers", and "End the second paragraph without a trailing summary sentence that restates the point." Those hand-specified guards are what this recipe makes permanent. The two observed variants — a narrative two-paragraph intro and a TL;DR-with-`**Highlights**`-list — share this prose skeleton; for the list variant, steer the bullet structure through the trailing prompt rather than the recipe (the recipe defaults to the headings-free narrative).

### 2026-06-16 — first dogfood (HIT)

First dogfood against `qwen3.6:35b-a3b-q8_0` (prose tier, Ollama): a two-theme-plus-heads-up highlights block for a delegate-local release. Output was a HIT — two short flowing-prose paragraphs, no headings or bullets, themes referred to by name, the heads-up folded into the second paragraph, the version string cited verbatim, no greeting opener, no puffery, no exclamation marks, no em dashes, and no closing flourish. The verbatim-preservation guard held visibly: a `(#several)` placeholder deliberately left in the input was reproduced character-for-character rather than expanded into an invented PR number. Recorded HIT via `delegate-feedback.sh --source agent`; no recipe change was needed. If a later MISS surfaces a puffery or padding shape not enumerated above, extend the blocklist or the anti-padding anchor with a contrastive one-shot grounded in the failing output, per the library convention.
