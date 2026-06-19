# Code-generation fan-out — design spec

Status: Draft (brainstormed 2026-06-19, pending implementation plan).
Scope: Consumer A of the delegation-rethink initiative. Fan-out delegated single-file code patches, using a director-provided failing test as the oracle. The debiasing second-opinion layer (Consumer B) is a separate, later spec.

## Background and motivation

Fan-out, drawing N samples and keeping the best, previously looked like a dead end for this skill, but that result was confounded. The local MLX server had a bug that ignored per-request seeds, so the N samples came back byte-identical. That bug is fixed and validated upstream (mlx-lm PR #1331, tracked in our issue #323), so local fan-out now produces genuinely diverse samples: on Ollama today, and on MLX once the fix ships.

The deeper lesson from our own measurements is that fan-out only converts to value when a trustworthy selector picks the winning sample. Prose has no such oracle, which is why our prose fixtures showed no lift even after diversity was restored. Code generation does: the test suite is a perfect, automatic selector. So the first place to make local fan-out pay is single-file code patches with a provided failing test. We draw N diverse patches, keep one that passes the test, and escalate to a stronger model only if all of them fail, never returning an unverified patch. This also widens what we delegate from text to code and reuses the just-merged verify-and-escalate gate (ADR 0020) as the failure fallback.

## Goals and non-goals

The goal is to make local fan-out finally pay on a task class that has a hard oracle, code patches selected by a real test, and to measure honestly whether best-of-N beats single-shot by a meaningful margin. A secondary goal is to widen what we delegate from text to code without ever shipping an unverified change.

Out of scope for this iteration, each a deliberate later step gated on this one paying: multi-file patches, generated tests, multi-model fan-out, non-Python languages, and the debiasing layer.

## Design

### Architecture and flow

Two pieces stay deliberately separate. `apply-and-test.sh` is the oracle and already exists: hand it a source directory and a patch, it applies the patch to a throwaway copy, runs pytest, and emits `VERDICT: PASS|FAIL|...`. The new `fanout-patch.sh` is the orchestrator and owns only the fan-out logic. The split matters because the oracle is the trustworthy part, so it stays untouched and independently tested, while the orchestrator is where the new, riskier logic lives.

The flow is a single pass with a fallback. The director hands the orchestrator a source directory and the real failing test. It resolves the code-tier model through `pick-model.sh`, builds the patch prompt from the `fix-with-test` recipe, then runs the fan-out: for seeds one through N it calls that same warm model at temperature above zero, so each seed yields a genuinely different candidate patch. Each candidate goes through `apply-and-test.sh`, and the orchestrator collects the verdicts. If at least one candidate makes the test pass, it selects one (the smallest diff, as a tie-break toward the least invasive fix) and returns it. If all N fail, it escalates: a few samples on the strong model through the same oracle. If one of those passes, it returns that; if not, it hands back to the director with the closest failing attempt and a clear "no passing patch" verdict. The invariant across every path is that nothing is returned as done unless it actually passed the test in a clean copy, so the worst case is "no patch," never "a broken patch that looks fine."

The only new touch outside the orchestrator and the recipe is a small `DELEGATE_SEED` passthrough in `delegate.sh`, which does not expose a per-request seed today. Because the seed only works on Ollama right now (MLX is broken until #1331 ships), the fan-out defaults to the Ollama backend, with a warning if it ever runs on MLX that diversity will be degraded.

### Error handling and safety

The fan-out loop treats every per-sample failure as just a failed sample, never a crash. A candidate that does not parse, does not apply cleanly, or times out under pytest all come back from the oracle as a non-PASS verdict and simply do not win. Because `apply-and-test.sh` applies each patch to its own throwaway copy of the source, candidates cannot contaminate each other, so there is no ordering or cleanup fragility in the orchestrator.

The interesting edge is REFUSE. The recipe gives each sample an explicit hatch to say "this task cannot be done honestly," which is the right response when the failing test is itself wrong or self-contradictory. One stray REFUSE among working samples is noise, but if a majority of the samples refuse, that is a strong signal the test is bad, and the right move is to hand back to the director with "samples refused, the test may be wrong" rather than burn an escalation trying to satisfy a broken oracle. The skill already learned the matching trap: a model can refuse in prose and still emit a patch, so the rule is that the oracle is authoritative and the prose is advisory. A patch wins if and only if it actually passes the test, regardless of what its prose said. The one nuance surfaced in the output: if a patch passes but a majority of other samples refused, the result flags that so the director sanity-checks whether the test is the right thing to be passing.

When everything fails even after escalation, the orchestrator returns the closest failing attempt plus its verdict and hands back, never a silent dead end. Cost stays bounded by construction: N cheap samples plus a small fixed M escalation samples, each with the oracle's own pytest timeout, so worst-case latency is capped.

The hard boundary is safety. The oracle runs pytest with full user privileges and no sandbox, which is fine for the one use it is designed for and dangerous for anything else. So `fanout-patch.sh` is strictly for the director's own tasks over author-controlled source and tests, the same rule the skill already states for the apply-and-test loop. It never takes untrusted source, an externally-supplied test, or model output from anywhere but our own locally-chosen models. That constraint lives in the tool's docs and is refused at the boundary, not left implicit.

### Testing and measurement

Two kinds of testing do different jobs. The first is ordinary unit coverage for the orchestrator, `tests/test-fanout-patch.sh`, following the repo's pattern of mocking `delegate.sh` and `apply-and-test.sh` on a restricted PATH so results are deterministic. It asserts the designed behaviours: it selects a passer when one exists, picks the smallest diff when several pass, escalates to the strong model when all cheap samples fail and returns that pass, hands back with "test may be wrong" when a majority refuse, returns the closest attempt when everything fails, and trusts the oracle over the prose so a refuse-worded sample whose patch passes still counts. The small `DELEGATE_SEED` passthrough gets a matching assertion in `test-delegate.sh` that the seed reaches the backend payload.

The second answers whether fan-out pays, and it is a measurement harness under `experiments/`, not a unit test. It runs a fixture suite of buggy-source-plus-failing-test cases and reports single-shot pass-rate versus best-of-N pass-rate on the code model, plus escalation rate, latency, and percent handed back. The load-bearing part is the lesson this initiative is built on: the fixtures must have genuine single-shot headroom. If the model already nails every fixture single-shot, best-of-N cannot lift anything and we would falsely conclude "ceiling" or "no value," exactly the trap T5 and T6 fell into. So fixture selection is deliberate, code-fix tasks the model gets right only sometimes, roughly the forty-to-eighty-percent single-shot band, because that is the only regime where drawing more diverse samples can convert into more passes. We measure on Ollama where the seed works, and because seeds now genuinely vary we run repeats and report the distribution rather than a single point.

## Success criteria

The go/no-go is the measured lift: best-of-N pass-rate minus single-shot pass-rate over a fixture suite with genuine single-shot headroom. If best-of-N clears single-shot by roughly 0.2 to 0.3, the mechanism pays and earns the right to widen. If it does not, it is shelved with the evidence written down, the same way cheap-first was. The secondary metrics that bound the cost are escalation rate, latency per fix, and the percentage of cases handed back unfixed.

## Decisions from the design conversation

1. Oracle source: the director provides a real failing test. Not generated, because a wrong generated test silently certifies a wrong patch.
2. Patch surface: single-file for the first version.
3. Diversity: N seeds on one warm code model at temperature above zero. Not multi-model yet.
4. Failure path: escalate to a strong model when all cheap samples fail, then hand back. Never ship an unverified patch.
5. Structure: a new `fanout-patch.sh` orchestrator plus a `fix-with-test` recipe, composing `apply-and-test.sh` (oracle) and `pick-model.sh` (routing), with a small `DELEGATE_SEED` passthrough in `delegate.sh`. Ollama backend until #1331 ships MLX per-request seeds.

## Open questions and future work

Once the first version pays, the natural widenings in order are multi-file patches, then a few seeds across a couple of models for architectural diversity. Consumer B, the debiasing second-opinion layer, reuses the same fan-out primitive but aggregates disagreement instead of running tests, and gets its own spec. If ties under the smallest-diff selection rule turn out to be common, a secondary tie-break (for example, preferring the patch that touches the fewest functions) can be added then rather than now.
