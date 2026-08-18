# Backlog completion: design spec

**Status:** revised after three-agent review
**Date:** 2026-08-18
**Complements** `2026-08-17-provider-agnostic-backend-design.md`, which this spec sequences and finishes.

## Goal

Close every open item on the board, cutting a published (non-draft) release after
each merged PR, without requiring a decision from the maintainer mid-flight.

## Why this spec exists

Executed ad hoc, the remaining work collides. The first draft of this spec asserted
an ordering that contained a circular dependency and seven verification commands that
could never pass. Both were caught in review and are corrected below; the review
findings are recorded in "What review changed" at the end, because the wrong versions
are instructive.

## Two independent release defects, both real

**The draft flag loses tags.** `release-please-config.json` set `"draft": true`. A
draft GitHub release does not create its git tag, and release-please anchors changelog
generation on tags, so a drafted release silently corrupts the *next* changelog.

This was masked for months because releases were published by hand within minutes of
being cut. The decisive case is v0.19.0: release-please created it at
`2026-06-12T06:26:55Z` while v0.18.0 was not published until `06:30:50Z`, four
minutes later. At generation time there was no v0.18.0 tag, and 0.19.0's changelog
came out with 236 entries against 11 commits. Hand-publishing stopped after
2026-06-23; v0.21.0 to v0.23.0 then sat as tagless drafts until 2026-08-18, and
0.24.0 regenerated 314 of 321 commits. Fixed in #367.

**The release PR's CI needs manual approval.** Release PRs are authored by
`github-actions[bot]`, and `actions/permissions/fork-pr-contributor-approval` is
`first_time_contributors`, so their `ci` run completes as `action_required` with zero
jobs. This is *independent* of the draft flag: it delays a release rather than
corrupting the next one, and it never blocked the merges that produced the drafts
(PRs #304, #335 and #346 all merged normally). `enforce_admins` is `false` on `main`,
so release PRs merge with `--admin`. The structural fix, a PAT or App token, stays in
#366 as a follow-up rather than a blocker.

## Ordering

```
  T1  release pipeline            DONE, PR #367
  T2  release 0.24.0              proves T1 end to end
  T3  #356 placeholder stand-ins  small, independent; lands BEFORE any test surgery
  T4  embeddings (#357 + #362)    MUST precede T6; see "the circular dependency"
  T5  provider default + mocks    additive; makes the hermeticity risk detectable
  T6  the deletion                subtractive only; any failure is a missed reference
  T7  eval-skill-triggers.sh      own task, not part of T6
  T8  docs, dashboards, ADRs
  T9  #358 boundary hook drafting moment
  T10 #360 install from published skill
  T11 triage #341 / #340 / #361 / #323
  T12 new issue: audit-models.sh regression shipped in #365
```

### The circular dependency, and why T4 moved

The first draft scheduled embeddings last, "after the chat rework". That cannot work.
The deletion task's exit condition is that no `OLLAMA_HOST` remains in `scripts/`, but
`embed.sh:158` is `ollama_host="${OLLAMA_HOST:-http://localhost:11434}"` and `:200`
posts to `"$ollama_host/api/embed"`. Deleting the former orphans the latter, and the
resolution idiom returns a base like `http://localhost:11434/v1`, so `$base/api/embed`
is `/v1/api/embed`, which does not exist. The deletion therefore *forces* the endpoint
change that #362 describes, while #362 was declared to depend on the deletion.

Landing embeddings first breaks the cycle, and it is cheap: Ollama's `/v1/embeddings`
and `/api/embed` return byte-identical vectors for the same probe (768 dims, cosine
0.9999999999999999 measured). The change is one URL and one jq path
(`.embeddings[0]` becomes `.data[0].embedding`).

### Why the deletion is split from the default flip

The load-bearing risk in this whole programme is test hermeticity, and it was
reproduced during review. `tests/run-tests.sh:76` pins `DELEGATE_BACKEND=ollama`
inside `run()`, and `SAFE_PATH` contains the real `/usr/bin/curl`. With only a mock
`ollama` on PATH and no curl mock, `pick-model.sh --dry-run prose` made a real HTTP
call to the live MLX daemon in 43 ms and resolved
`mlx-community/Qwen3.6-35B-A3B-8bit`, which *matches the preference several tests
assert on*. The test passes, satisfied by the developer's daemon rather than by the
fixture. There are 159 mock call sites (113 in `test-delegate.sh`, 31 in
`run-tests.sh`, 15 in `test-embed.sh`); missing any one reproduces this silently.

So T5 flips the default and migrates the mocks while the old path is still reachable
and A/B-testable by setting one variable, and T6 only deletes. A suite failure in T6
is then unambiguously a missed reference rather than a regression in new logic.

## Tasks

Each task states a falsifiable goal and a command that distinguishes "done correctly"
from both "not done" and "deleted rather than migrated". Negative greps alone are
rejected: they pass equally on a correctly migrated tree and a gutted one, so every
subtractive check is paired with a positive one.

### T2 — release 0.24.0

**Goal.** The release PR carries exactly the commits since `v0.23.0` that
release-please is configured to render, and ships as a published release.

**Verify.** Not a naive commit count. Tags point at the release commit itself, which
release-please excludes; `changelog-sections` lists ten types, so any commit outside
them yields no bullet; and a breaking change yields a bullet with no extra commit.

```bash
pr=$(gh pr list --state open --json number,title \
      --jq '.[]|select(.title|startswith("chore(main): release "))|.number')
bullets=$(gh pr diff "$pr" --patch | grep -c '^+\* ')
expected=$(git log --format=%s v0.23.0..origin/main \
            | grep -cE '^(feat|fix|perf|security|deps|refactor|docs|ci|test|chore)(\(.+\))?!?: ')
breaking=$(git log --format=%B v0.23.0..origin/main | grep -c '^BREAKING CHANGE')
test "$bullets" -eq $((expected + breaking))
```

Then, after merge, prove the *goal* rather than one release's state:

```bash
git fetch --tags && git rev-parse -q --verify refs/tags/v0.24.0
test "$(gh release list --limit 30 --json isDraft --jq '[.[]|select(.isDraft)]|length')" -eq 0
```

### T3 — #356, unreplaced placeholder stand-ins

**Goal.** `delegate.sh` refuses a `--var` value that is *entirely* an unreplaced
placeholder, and accepts every value that merely contains angle brackets.

**Design, corrected in review.** The obvious matcher `<[^>]*>` is wrong. Measured
against realistic inputs it flags nearly everything: `if (a < b) { x } else if (c > d)`,
`std::vector<int> v;`, `cmd < in.txt > out.txt`, `<div class="x">hello</div>` and
`foo(a<b, c>d)` all match. Since `--var diff=` is the highest-volume use of the flag,
that matcher would break the primary path.

The real failure mode is narrower: an agent passes the literal placeholder as the
whole value. Match only when the trimmed value is a single bracket token with no
nested brackets, `^<[^<>]*>$`. That accepts every case above and still rejects
`<why this changed>`. Use `grep -E` (a DFA), never bash `[[ =~ ]]` (a backtracking
engine), which is how the linear-time requirement is met concretely.

**Verify.** Both arms, and the false-positive corpus is the point:

```bash
out=$(printf x | bash scripts/delegate.sh --recipe commit-message --var why='<why this changed>' 2>&1); rc=$?
test $rc -ne 0 && printf '%s' "$out" | grep -q 'why'          # rejects, and names the key
for v in 'if (a < b) { x } else if (c > d) { y }' 'std::vector<int> v; if (a < b) return;' \
         'cmd < in.txt > out.txt' '<div class="x">hello</div>' 'foo(a<b, c>d)'; do
  printf x | bash scripts/delegate.sh --recipe summarise-diff --var diff="$v" >/dev/null 2>&1 \
    || echo "FAIL false positive: $v"
done
! grep -n '=~' scripts/delegate.sh | grep -qi 'placeholder\|stand-in'   # no bash regex engine
```

**Resolved during implementation.** `prompts/commit-message.md:151` was expected to
need updating, because `--var type=<type>` is a whole-token placeholder the matcher
rejects. It does not: that line is prose describing the flag's shape, and the
copy-paste invocation block three lines above already uses a real value,
`--var type=feat`. No recipe edit was required. Shipped in #368 with 21 new
assertions, suite 572 to 593.

### T4 — embeddings (#357 and #362 as one PR)

**Goal.** `embed.sh` obtains its vector from `{base}/embeddings` through the same
`--print-resolution` path as chat, and the Ollama-only special-case is gone from both
`embed.sh` and `audit-models.sh`.

**Why one PR.** The special-case is not confined to `embed.sh`.
`scripts/audit-models.sh:53-68` carries its own copy (`tier_backend="ollama"` and the
`[via ollama — embed.sh forces it]` suffix) and `:36-37` hardcodes "The embedding tier
is Ollama-only by design". #357 and #362 edit the same block, so splitting them
guarantees a conflict.

**Scope correction.** #357 asks for the invariant to move *into* `pick-model.sh`. It
cannot live there as stated: `resolve_via_providers` knows only what `GET {base}/models`
reports, and that list is capability-blind. Measured, MLX at `:8080` returns 404 on
`/v1/embeddings` and Docker at `:12434` hangs (curl exit 28, zero bytes). Today the
invariant holds by accident because `nomic-embed-text:latest` appears only in Ollama's
model list; the moment an embedding-named model is converted to MLX, name matching
routes the tier to a 404. Deliver an honest, loud failure from `embed.sh` instead, and
record the capability-probe question as deferred. Note the present behaviour is worse
than #357 describes: `bash scripts/pick-model.sh embedding` currently exits 1 with
*zero output on both streams*, so it fails silently rather than loudly.

**Verify.** A baseline captured on the pre-change commit, with provenance so it cannot
be re-faked, plus both resolution arms:

```bash
PROBE='the quick brown fox jumps over the lazy dog'
# before any edit:
printf '%s' "$PROBE" | bash scripts/embed.sh > /tmp/embed-baseline.json
git rev-parse HEAD > /tmp/embed-baseline.sha
# after:
test "$(cat /tmp/embed-baseline.sha)" != "$(git rev-parse HEAD)"   # baseline is from another commit
printf '%s' "$PROBE" | bash scripts/embed.sh > /tmp/embed-after.json
jq -nr --argjson a "$(cat /tmp/embed-baseline.json)" --argjson b "$(cat /tmp/embed-after.json)" '
  def n(v):(v|map(.*.)|add)|sqrt; def d(x;y):[range(0;x|length)|x[.]*y[.]]|add;
  if ($a|length) != ($b|length) then "FAIL dim" else
  (d($a;$b)/(n($a)*n($b))) | if . >= 0.9999 then "PASS \(.)" else "FAIL cosine \(.)" end end'
# failure arm is loud, not silent:
out=$(DELEGATE_BASE_URL=http://localhost:8080/v1 bash scripts/embed.sh <<< x 2>&1); rc=$?
test $rc -ne 0 && printf '%s' "$out" | grep -qi 'embed'
```

The 0.9999 threshold reflects the measured signal: identical input scores 1.000000, a
near-paraphrase 0.9835, an unrelated sentence 0.3538, and the realistic corruption
modes score 0.918 (input truncated to 60 chars), 0.828 (to 30) and 0.940 (a
`search_query:` prefix injected). The old 0.99 bar would have caught those, but 0.9999
is where the real distribution sits.

### T5 — provider list becomes the default, mocks migrate, empty-output guard

**Goal.** Every dispatch already goes through the OpenAI arm, every test declares its
own provider mock, and a response whose content is empty is reported rather than
returned as silence. `DELEGATE_BACKEND` still exists as an escape hatch, so any
behavioural difference is A/B-testable by setting one variable.

**The empty-output guard, measured.** `scripts/delegate.sh:1319` is
`output=$(jq -r '.choices[0].message.content // ""' < "$body_file")`, and
`finish_reason` is never inspected. Re-measured on 2026-08-18 against all three
daemons, the earlier framing of this was wrong in a way worth correcting: reasoning
does **not** contaminate `content`. Ollama returns it in a separate `reasoning` field,
so the existing jq extraction already keeps it out. The real defect is budget. Ollama
ignores `chat_template_kwargs.enable_thinking:false` (130 characters of reasoning
emitted where MLX and Docker emit none), that reasoning consumes `max_tokens`, and at
`max_tokens:16` the call returns `content:""` with `finish_reason:"length"`. The guard
must therefore key on empty content plus `finish_reason`, and say which it was.

| runtime | honours `enable_thinking:false` | separate `reasoning` field | content at `max_tokens:16` |
|---|---|---|---|
| MLX `:8080` | yes | no | `"ok"`, finish `stop` |
| Docker `:12434` | yes, on 2 of 3 models | no | `"ok"`, finish `stop` |
| Ollama `:11434` | no | yes | `""`, finish `length` |

**Verify.** A hermeticity assertion, not just a pass count, because the suite passing
is exactly what the hermeticity bug produces:

```bash
# no test may reach the real curl without declaring a provider mock
# (mock curl on SAFE_PATH writes to a sniff file; the run fails if it is ever touched)
bash tests/run-tests.sh    | tail -1     # baseline today: 123/123 passed
bash tests/test-delegate.sh | tail -1    # baseline today: 572 passed, 0 failed
bash tests/test-embed.sh   | tail -1     # baseline today: 51 passed, 0 failed
```

The counts must be stated in the PR with a reason for every change, as
`2026-08-17-bounded-dispatch-timeouts.md` already does.

### T6 — the deletion

**Goal.** `DELEGATE_BACKEND`, `OLLAMA_HOST`, `MLX_HOST` and the `POST /api/generate`
branch are gone from live code, and the OpenAI path is demonstrably still there.

**Verify.** Paired, scoped, and excluding files that legitimately contain the strings:

```bash
legacy=$(grep -rE 'DELEGATE_BACKEND|OLLAMA_HOST|MLX_HOST|api/generate' \
           scripts tests --exclude-dir=fixtures | wc -l)
migrated=$(grep -rl 'chat/completions' scripts tests | wc -l)
test "$legacy" -eq 0 && test "$migrated" -ge 6
```

`hooks/` does not exist in this repository; the boundary hook is
`scripts/delegate-boundary-hook.sh`. Four fixtures legitimately contain the strings as
*input data* and must not be rewritten: `tests/fixtures/commit-message/thin-4file.diff`,
`thin-config-only.diff`, `recent_commits.txt` and
`tests/fixtures/doc-section/backend-auto-probe.txt`. Rewriting them invalidates the
benchmark baselines. `scripts/metrics-summary.sh:140` is a comment about pre-2026-05
metric rows and is historically accurate; it stays.

**Live check.** The tier matters: `DELEGATE_STRIP_THINK` defaults off and auto-enables
only for the `reasoning` tier, so a `prose` check must set it explicitly.

```bash
for base in http://localhost:11434/v1 http://localhost:8080/v1 http://localhost:12434/engines/v1; do
  out=$(printf 'Summarise: the cat sat on the mat.' | DELEGATE_BASE_URL="$base" DELEGATE_STRIP_THINK=1 bash scripts/delegate.sh prose)
  test -n "$out" || { echo "FAIL empty: $base"; exit 1; }
  case "$out" in *'</think>'*) echo "FAIL think leak: $base"; exit 1;; esac
done
```

**Files the first draft missed**, all inside the deletion's blast radius:
`tests/test-eval-skill-triggers.sh:321-345` asserts `http://other.host:9999/api/generate`
and the `OLLAMA_HOST` override by name; `tests/bench-commit-message-body.sh:26,28,35`
and `tests/bench-doc-section-padding.sh:38,40,49` sweep backends and hold quality
baselines; `scripts/semantic-search.sh:23`; and
`prompts/long-thread-distillation.md:146` carries `DELEGATE_BACKEND=mlx` as few-shot
content, outside both greps.

### T7 — `eval-skill-triggers.sh` onto the shared driver

**Goal.** The script's `--ollama` arm (`:181-197`) reaches models through the same
resolution path as everything else, instead of `${OLLAMA_HOST}/api/generate`.

**Why it is its own task.** The first draft folded this into the deletion, arguing
`.github/PULL_REQUEST_TEMPLATE.md:17` gates `SKILL.md` changes. That is wrong. Line 17
is conditional on the frontmatter *description* changing; the unconditional gate is
line 16, shape mode, which exits at `scripts/eval-skill-triggers.sh:99-102` before the
`command -v curl` check and performs zero HTTP (verified: `shape: total=41 positive=22
negative=15`, exit 0). Splitting it out removes ~40 lines of unrelated script surface
and a 612-line test file from the largest PR.

### T8 — docs, dashboards and ADRs

**Goal.** Live documentation describes the provider model, and no live doc instructs a
reader to use a deleted endpoint.

**Verify.** Scoped, with generated and archival files excluded, plus a positive
assertion so a gutted tree cannot pass:

```bash
! grep -rEn 'DELEGATE_BACKEND|OLLAMA_HOST|MLX_HOST|api/generate' \
    --exclude-dir=adr --exclude-dir=superpowers \
    docs README.md CLAUDE.md CONTRIBUTING.md ROADMAP.md SKILL.md
test "$(grep -rl 'DELEGATE_BASE_URL' README.md CLAUDE.md docs/*.md | wc -l)" -ge 3
```

`CHANGELOG.md` is generated immutable history (15 hits) and `docs/superpowers/` is a
dated record (32 hits, including this spec); neither may be rewritten, which is why
both are excluded rather than merely mentioned in prose.

**Coverage the first draft missed.** The pattern must include `api/generate`, or
`SKILL.md:62`, `:171` and `:176` (the literal `http://localhost:11434/api/generate`
vision recipe), `docs/adr/0009-qwen3-sampling-override.md:19` and
`docs/otel-schema.md:69` all pass while still documenting a deleted endpoint. The
prior spec's ADR list (0022, 0002, 0006, 0018, 0020) misses 0009;
`docs/adr/0006:21,29` carries two live `MLX_HOST` references. `dashboards/` is in
scope: `delegate-overview.json:727,777`, `delegate-errors.json:809`, and
`dashboards/langfuse/README.md:25`, which asserts "The two-row split (`ollama` versus
`mlx`) matches the auto-default backend's behaviour" and is already false on a
provider-list host.

**The `SKILL.md:42` behavioural change and its tension.** Line 42 reads "If `ollama`
is not on PATH or `ollama list` is empty, do the work yourself and mention why", so on
a Docker-only host an agent stops delegating entirely. It must become provider-aware.
But the frontmatter description at `SKILL.md:2` also names "Ollama or MLX", and the
prior spec requires that string stay byte-identical; changing it trips the
`--ollama` recall gate. Resolve explicitly: line 42 is in scope for this task, the
frontmatter description is **not**, and Docker-host trigger coverage becomes a
separate follow-up with its own recall measurement.

`eval-skill-triggers.sh` cannot verify line 42 in any case: its trigger surface is the
frontmatter description alone, and line 42 is in the body. Verify it directly:

```bash
sed -n '/do the work yourself and mention why/p' SKILL.md | grep -qi 'ollama' && exit 1
```

### T9 — #358, boundary hook and the drafting moment

**Goal.** The hook records the drafting moment for write-then-post bodies.

**Constraint.** `scripts/delegate-boundary-hook.sh` is a PreToolUse hook with a Bash
matcher, so a `Write` tool call never invokes it. The "scripted sequence" must be
synthesised JSON payloads on stdin, which is the idiom
`tests/test-delegate-boundary-hook.sh` already uses across 134 assertions.

**Verify.** Name the observable rather than saying "trips":

```bash
m=$(mktemp)
echo '{"tool_name":"Bash","tool_input":{"command":"gh pr create --body-file /tmp/body.md"},"cwd":"'$PWD'"}' \
  | DELEGATE_METRICS_FILE=$m bash scripts/delegate-boundary-hook.sh 2>/tmp/err
test "$(grep -c '"state":"pre-drafted"' $m)" -eq 1 && test ! -s /tmp/err
echo '{"tool_name":"Bash","tool_input":{"command":"gh pr create --body \"inline prose\""},"cwd":"'$PWD'"}' \
  | DELEGATE_METRICS_FILE=$m bash scripts/delegate-boundary-hook.sh 2>/tmp/err2
test "$(grep -c '"delegated":false' $m)" -eq 1 && test -s /tmp/err2
```

### T10 — #360, install from the published skill

**Goal.** The documented install path does not symlink the development checkout.

**Prerequisite the first draft missed.** There is nothing to install *from*:
`.claude-plugin/` contains only `plugin.json`, with no `marketplace.json`. That file
must exist before this task can be written at all. `CLAUDE_CONFIG_DIR` appears nowhere
in the tree and is not honoured by `scripts/init.sh` or `scripts/onboard.sh`, so the
verification redirects `HOME` instead. All three install docs
(`docs/install-claude-code.md:17`, `install-codex.md:17`, `install-opencode.md:17`)
currently prescribe the `ln -s "$PWD/delegate-local"` this task removes.

**Verify.**

```bash
tmp=$(mktemp -d); HOME="$tmp" bash -c '<the documented install command>'
! grep -rl "$PWD" "$tmp"
! find "$tmp" -type l -lname "*$PWD*" | grep -q .
```

### T11 — triage the remainder

#341 (monthly Ollama audit) and #340 (baseline overdue) are recurring reminders whose
premise changes once T4 and T6 land. #361 has its benchmark evidence posted, including
an explicit "don't adopt for prose or long-context", and needs a decision, not code.
#323 is an upstream `mlx-lm` defect (ml-explore/mlx-lm#1245) this repo cannot fix.

**Verify.**

```bash
for n in 323 340 341 361; do
  s=$(gh issue view $n --json state --jq .state)
  c=$(gh issue view $n --json comments --jq '[.comments[]|select(.createdAt >= "2026-08-18")]|length')
  case "$s:$c" in CLOSED:*) echo "OK $n closed";; OPEN:0) echo "FAIL $n untouched";; OPEN:*) echo "OK $n commented";; esac
done
```

### T12 — file the regression that shipped in #365

`scripts/pick-model.sh:181-186` short-circuits on `DELEGATE_BASE_URL` before reading
`DELEGATE_BACKEND`, so `audit-models.sh:25` (`export DELEGATE_BACKEND="$backend"`) and
`:67` are silently ignored under a provider list. The embedding forcing at `:60-62`
does nothing and the printed claim is stale. Reproduced:

```
DELEGATE_BACKEND=auto -> in effect: provider
The embedding tier is Ollama-only by design (scripts/embed.sh posts to /api/embed)
```

Open an issue rather than folding it into another PR, since it is a shipped regression
and deserves its own history. It is fixed incidentally by T4.

## Release policy

Cut a release after each merged PR, not one batched release at the end. Releases are
published, never drafts.

## Out of scope

Replacing release-please, changing the repository's Actions approval policy, and
issuing a PAT (all in #366). Capability probing in `pick-model.sh` (deferred by T4).
Docker-host trigger-eval coverage and the `SKILL.md` frontmatter description (deferred
by T8).

## What review changed

Three agents reviewed the first draft. The corrections worth remembering:

The ordering contained a **circular dependency**: the deletion could not meet its own
exit condition without the embeddings change that was scheduled after it. Embeddings
moved to T4.

The claimed **T8-depends-on-T7 blocker was not real**. The PR template's
`eval-skill-triggers.sh --ollama` gate is conditional on the frontmatter description,
and the unconditional gate is shape mode, which performs zero HTTP.

**Seven verification commands could never pass.** `hooks/` does not exist; the doc grep
matched 77 lines including 15 in generated `CHANGELOG.md` and 4 in the spec defining
the check; `grep -c` exits 1 on no match and aborts a `set -e` block; the PyYAML
one-liner fails because PyYAML is installed only in `mcp/.venv`.

**Every negative grep was delete-blind** and now has a positive counterpart.

**T3's matcher design was wrong**, flagging nearly every realistic diff.

The **empty-output finding was mis-stated**: reasoning never contaminated `content`;
the defect is budget exhaustion.

The **draft-flag mechanism was challenged** as an unverified hypothesis, on the
grounds that a constant flag cannot explain an alternating outcome. It survived: the
mediating variable is whether the previous release was hand-published in time, and
release timestamps confirm it.
