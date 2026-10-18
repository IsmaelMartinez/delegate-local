# What delegate-local taught

delegate-local ran from May to October 2026 as an experiment in letting
Claude hand text work to a model on the same laptop. ADR 0035 records why it
was narrowed to large piped inputs and wound down. This page keeps what the
experiment taught, for whoever picks the idea up again, including this
maintainer. Each point names where the evidence lives; anything archived is
recoverable from commit `a00b2e9`.

## The economics

Measure the net, never the gross. For five months the headline number was
`estimated_tokens_avoided`, the characters that went in and out of the local
model divided by four. It grew steadily and meant almost nothing: it counted
recipe templates Claude never sees, inputs Claude had already read, and
drafts Claude then rewrote. The honest number comes from the transcripts, by
setting what Claude typed and read for each delegation against what it would
have typed without one. Done on 2026-10-18 over 2,159 delegations, it came to
about +20 tokens per call in the most generous reading, and about 1.1M spent
for about 33k saved in the realistic one. A metric that cannot go negative is
not measuring a saving.

Output tokens decide the sign. Claude's output costs about five times its
fresh input and about a hundred times its cached input, so a scheme that adds
a few hundred output tokens per call (a brief, a verdict, a rewrite) to avoid
input tokens loses unless the input it avoids is large and fresh. That is why
the only positive cases were long logs and threads piped straight to the
model, and why the writing recipes, which avoided a few hundred tokens of
drafting, never paid.

The orchestrator already holds the substance of anything it writes. A commit
message, a review reply or an issue body needs Claude's knowledge of what
changed and why, so Claude has to put that knowledge into the brief, and a
brief good enough to draft from is about as long as the draft. The biggest
quality gain the reply recipes ever had was asking the caller to write the
lead sentence itself (#531): proof that the value was in what Claude wrote,
not in what the model added. Delegation helps when the model knows something
the orchestrator does not, which for a summariser means the input Claude has
not read.

Context protection now has a cheaper route. A Claude Code subagent on a small
cloud model reads a flood of logs or files in its own context and returns a
summary, with better quality than a local model and no resident weights. What
a local model alone offers is that the content never leaves the machine.

## Quality and calibration

Extraction outruns taste. ADR 0023 saw it in June (extraction recipes near
90%, prose recipes near 70% under the verdict definitions of the time) and it
held to the end: a model copying facts out of its input is reliable, a model
matching a voice and avoiding padding is not. Recipe effort went the other
way, into the taste-calibrated prose recipes, and did not close the gap.

Wording edits stopped moving the rate early. Five template spikes on
2026-09-27 produced no replay ACCEPT, and most of the later calibration
records are inconclusive replays. What did move the rate was the input
(passing the diff, passing the lead sentence) and honest tagging (ritual
delegations whose shipped text was already in the input, #588), not the
prompt.

A recipe's own rule can be the defect. The reply recipes restated the
reporter's problem because a guard told them to carry every anchor from the
input: drafts carried 40-100% of the anchors, shipped replies 6%. Read a
recurring miss against the recipe's instructions before blaming the model.

Example lines leak. On long inputs a recipe returned its own Wrong/Correct
example verbatim. Writing anchors as angle-bracket skeletons (`<subject>:
<change>`) makes a leak visible and rarer.

Closed prompts work, open prompts invent. "List the lines matching",
"Extract these fields as JSON", "Classify each item into one of these
buckets" were reliable throughout; "find anything interesting" and "suggest
improvements" produced confident findings that did not survive a check.
Priority-ordered hard rules with keyword triggers moved the model where an
example alone did not, a REFUSE hatch turned impossible tasks into honest
refusals, and deterministic output checks with a single retry caught
padding and echo cheaply (ADRs 0014, 0017, 0029).

Loops on the same model do not converge. A critic or judge pass over the same
local model oscillated, structured output enforced shape and nothing else,
and agent frameworks around the wrapper added no quality (ADR 0031).

Rates across a corpus reset are different measurements. The June hit rate of
about 80% and the September and October shipped-as-is rate of 2-20% a week
used different verdict definitions and different judges (ADR 0028 reset the
corpus; #624 defined a scaffold as an edited draft). Quote the N beside every
rate, compare only within one definition, and read one session's rows in
order before trusting a rollup: two real bugs (#503 and the #511 retry-cap
leak) were invisible in the aggregate and obvious in a sequence.

## Enforcement and verdicts

Enforcement creates ritual. The boundary hook denied an undrafted commit or
comment until a delegation existed, so sessions delegated one-line merge and
test subjects only to throw the draft away; in the last window 21 of 56
edited commit drafts were exactly that. Ritual tagging (#588) kept those out
of the hit rate, but nothing kept them out of the cost.

A verdict per call costs more than it teaches. Recording a hit, scaffold or
miss after each delegation took 1,969 commands, about 308k tokens and about
6 hours of session time, more than any single recipe, and the calibration it
fed did not raise the rate. Making the agent the judge (ADR 0030) was right
for a fully automatic loop; the loop itself was the expense. A future
experiment should sample verdicts, or score drafts offline against what
shipped, rather than ask for one on every call.

## Latency and the machine

Load time, not generation, is what a delegation waits for. About 85% of
wall-clock was time to first byte, a cold model on its first call stalls a
short canary, and a recipe that looked like it hung (ADR 0027) was a cold
load. Keep the one model resident, never alternate two on a shared server
(each switch is a reload of about ten seconds), and treat the first call
after a restart as slow.

What a session waits for is Claude. Measured on 2026-10-11, slow turns were
about 96% Claude thinking and writing; on 2026-10-18 a delegation added about
20 s (9 s in `delegate.sh`, about 11 s composing and running its verdict)
against a generation median under 4 s.

Active parameters set the cost, not total size. A mixture-of-experts model
with 3-4B active parameters prefilled at about 3,000 tokens/s and generated
fast enough; 1-2B active halved the GPU time and failed the writing (ADR
0034). Vendor benchmarks measure agentic work this skill never did and were
no guide. A 122B model in 65 GB once pushed a 128 GB laptop into memory
pressure and macOS killed Docker; keep resident weights to about half of
RAM.

Resident weights are not heat. An idle model holding 28 GB draws next to no
power; on this machine the heat came from endpoint security scanning every
spawned process and written file, multiplied by parallel agent jobs. Cap
parallel fan-outs, and cap the server's prompt cache (`--prompt-cache-bytes`),
which otherwise grows to 10 GB.

## Engineering habits worth keeping

Run every new assertion against the unfixed tree and read why it fails. Twice
an assertion passed for the wrong reason and read as proof.

Diff scripted edits against the base before committing. A `sed` splice once
corrupted a shebang and 260 assertions still passed.

Copy a script before running it for a long job. Bash reads a script as it
runs, so editing it in a worktree mid-run changes what runs.

Give timing tests a virtual clock. Sleep-based duration checks flaked under
background load; a clock seam fixed them where wider margins did not.

Check usage before archiving. Two earlier clean-ups removed complete, used
features (the OpenTelemetry spans, the embeddings) and had to restore them.
This wind-down is backed by usage data for every recipe it removes.

Keep the runtime path small. What lasted best was the first design: two
shell scripts, a preference list and a pipe (ADR 0001). Everything that grew
around it existed to calibrate the writing recipes, and it went with them.

## How to measure it again

The 2026-10-18 measurement used three read-only passes, with no model run.
The net cost pass joins each `delegate.sh` and `delegate-feedback.sh`
invocation in the main and subagent transcripts (matched on the script name
followed by its flags) to its tool result by `tool_use_id`, and sets the
characters typed and read against the caller input recorded in each call's
`inputs.json` (before #585 on 2026-09-26, `prompt_chars` already contains
stdin). The draft survival pass compares each stored draft with its stored
final by shared content words. The prefill pass reads the server log's
timestamped "Prompt processing progress" lines per model. A revival should
start by running the same passes on its own corpus, and by checking the
signposts in ADR 0035 against current models, prices and harness features.
