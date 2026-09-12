# Optimization findings and baseline decision

On2026-09-12 the user selected ACD as the common baseline for30GB and 78 GB.
This is an explicit product decision to maintain one usable engine. It does not
claim that ACD wins every task or that the work Mac has already been tested.

## Evidence retained from the optimization campaign

Tests ran on an M5 Max with 128 GB unified memory under ordinary multitasking.
Software cases used an unchanged original Slotstream repository fixture and
covered programming, cache architecture contracts, and tool-assisted software
product acceptance. Quality gates, tool schema, request limits and task content
were held constant; valid wording differences were allowed.

The 78 GB ACD confirmation (v65) reduced complete workflow time by 8.30% against the
previous selected configuration; all 72 workflows passed quality. This is the
qualified78GB setup retained in the shared engine.

The 30 GB ACD-versus-original-baseline comparison (v66) completed four paired rounds,
24 workflows and32 model calls. All quality checks passed. ACD reduced paired
geometric workflow time by 15.98% (median paired reduction 12.22%). The exploratory
95% time-ratio interval was0.7160–0.9436. Generation medians increased from roughly
22–23 to 27.5–28.9 tokens/second. Prompt-reading speed did not materially improve.
Candidate physical footprint peaked at 30.497 GB. One product case was 16.21% slower;
all observations were retained. The original baseline is now historical only.

The 30 GB component comparison (v67) used the same ACD binary with settings varied
across four balanced rounds:16 sessions,48 workflows,64 model calls. All quality
checks passed. Against full ACD:

| Configuration | Paired geometric workflow time |
| --- | --- |
| Adaptive MTP alone |3.97% less, uncertain |
| Adaptive MTP + attention 256 |0.92% more |
| Adaptive MTP + compiled gates |15.26% more |

Adaptive alone won two of four rounds; median paired reduction was 0.88%, with
95% ratio interval 0.8736–1.0543. It did not establish a reliable replacement.
Adding attention blocking to the gates configuration reduced workflow time by
13.24%; adding it to adaptive alone was 5.09% slower on the point estimate.
The conditional multiplicative interaction ratio was 0.8256 (interval 0.7583–0.9602).
This supports evaluating combinations; it does not establish the mechanism.
Peak physical memory across the component study was 30.536 GB, with no added swap.

## What these results do and do not support

Use ACD for both profiles as the selected baseline. Preserve the original source
identity in provenance/acd.json. No upstream updates are planned. The reviewed
upstream update was not adopted because it regressed original tool/architecture
quality; the code here retains the tested older ACD implementation.

The 2.5% threshold applies to complete workflow improvement with valid answers,
not only token generation rate. Smaller gains are reported. Timing uncertainty,
per-task regressions, startup, prompt reading and memory must remain visible.
A component can help in one combination and hurt in another.

Four repeated rounds and a few source-grounded tasks are not broad statistical
qualification. Bootstrap intervals are exploratory, not adjusted for multiple
comparisons. Normal background load was retained. The actual 48 GB work machine
(probably M4 Pro), other macOS versions, short hook workloads, long contexts and
remote-client latency need their own validation. Future optimization can revisit
adaptive-only versus ACD, but the installed baseline remains ACD until changed.

Historical research, original reports and raw evidence are retained in a separate
local archive. They are not required for installation and are not shipped in this
repository. Disposable candidate builds are removed during consolidation; archived
source/patches and logs preserve context, not a ready-to-run historical benchmark.
