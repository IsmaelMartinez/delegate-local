# Calibration history for [`prompts/pr-review-reply.md`](../../prompts/pr-review-reply.md)

## Calibration notes

Initial recipe drafted 2026-05-10 from the address-pr-comments skill's per-comment reply contract. The 2026-05-10 session posted 8 such replies by hand across PRs #73, #76, #77 — those replies are the shape anchor.

### 2026-05-10 dogfood: HIT verbatim on first attempt

First-pass against `qwen3.6:35b-a3b-q8_0` (prose tier) on a real reviewer comment from PR #73 (the unsubstituted-placeholder finding). Reply produced was: `Applied in \`8b3424a\`. The check now records which placeholder names the original template required and compares against the set of names satisfied by --var (and {{stdin}} when applicable), instead of grepping the post-substitution string.` — exact opener, one sentence, no flattery, no echo. Posted-by-hand equivalent was nearly identical wording. HIT, no edits needed.

### 2026-05-10 dogfood: graceful degradation when {{comment}} is empty

Second batch on PR #80 used a buggy `gh api` invocation that passed an empty string for `{{comment}}` on two of three replies. The recipe correctly produced opener-only output (`Applied in \`2b7308d\`.`) rather than fabricating a descriptive clause from the verdict alone. The third reply, with all vars populated, produced the full "Applied in `<hash>`. <clause>" shape. This is a useful fail-safe property: when context is missing, the recipe degrades to the minimum-information valid reply rather than inventing context. The opener-only form is technically allowed by the spec ("at most one short clause") even though the descriptive clause is the more useful default.

### 2026-08-27 recalibration: the one-clause cap was the reason the recipe was never used

The `pr-review-comment` boundary had fired 49 times, 19 of them on 2026-08-27
alone, and had never once been credited: 0/49 delegated, 0 pre-drafted. The
recipe it names had been called once in the corpus's lifetime and that call was
rewritten.

The cause was not that review replies are too short to be worth delegating. The
23 replies actually posted on PRs #440-#452 measure min 43, p25 230, median
312, p75 472, max 562 characters, and only 4 of the 23 are under 100. The
recipe permitted the opener "and at most one short clause... No additional
sentences beyond the opener and that single clause", which is roughly 150
characters. The opener contract held on 21 of the 23 — 19 exact `Applied in
`<hash>`.`, one `Partially applied in`, one `Not applied —`, plus two that
continued with a comma instead of a full stop and one reporting a finding that
did not reproduce, for which the contract offers no opener. So the opener was
broadly right and the cap was wrong: 19 of 23 replies could not have been
produced by the recipe the boundary kept naming.

Measured before and after at temperature 0 on the prose tier
(`mlx-community/Qwen3.6-35B-A3B-8bit`) against two real Copilot comments from
PRs #446 and #450, each with the same `fix_summary` both times:

| input | before | after | posted by hand |
| --- | --- | --- | --- |
| #446, retry accounting (4 facts supplied) | 145 chars, 1 fact | 605 chars, 4 facts | 482 chars, 4 facts |
| #450, `--body-file /dev/zero` (4 facts supplied) | 116 chars, 1 fact | 291 chars, 3 facts | 472 chars, 4 facts |

Both "before" outputs kept the opener and dropped every piece of evidence,
which is precisely the reply the agent then had to write by hand. Both "after"
outputs kept the exact opener, invented no anchor, and used no list.

One caveat worth carrying: on the #446 input, whose `fix_summary` was already
written as four polished sentences, the output tracks those sentences almost
verbatim — the recipe reshapes evidence, it does not compress it. The #450
input, four rough note-shaped lines, is the one where it synthesises. Write
`fix_summary` as notes rather than as prose and the recipe earns its call.

### 2026-10-08 — `verify: true` (#661)

The frontmatter gains `verify: true`, so `delegate.sh` runs the draft verifier on every call of this recipe and reports a flag on stderr and on the row (`docs/checks.md`). Nothing the model sees changes and the key is left out of `template_sha`, so the hash and the per-template history carry on unbroken and no replay applies. The #660 read-out behind the choice of recipes is in `docs/verify.md`.
