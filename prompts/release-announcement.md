---
tier: prose
inputs:
  stdin: string
  version: string?
checks:
  no_padding_tail: true
---
# release-announcement

## When to use

You are drafting the narrative intro for a software release announcement — the warm, grounded paragraph or two at the top of a GitHub release page or announcement post that frames what the release is about, from grouped highlights you already have. The output is one or two short flowing-prose paragraphs referring to the major themes by name, no headings and no bullets, in a plain maintainer voice.

This recipe writes the human-facing intro narrative across the whole release, not the per-change bullets that sit below it. For those, use a bare `prose`-tier delegation per change, as SKILL.md describes for a shape with no recipe.

Not for: the full changelog itself (per-change bullets are a bare `prose`-tier delegation), or marketing copy with hype and calls to action (the recipe deliberately forbids puffery — a release intro is informative, not promotional).

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
  "Two short paragraphs, warm and grounded, no puffery, no em dashes, no exclamation marks. Refer to themes by name, keep the #NNN numbers, invent nothing." \
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

The dated calibration history for this recipe lives in [`docs/calibration/release-announcement.md`](../docs/calibration/release-announcement.md); add each new entry there.
