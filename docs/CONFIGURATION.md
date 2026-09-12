# ACD configuration reference

ACD is the project baseline selected on 2026-09-12. Both profiles launch the same
source and executable. The letters come from historical experiments:

- A: adaptive MTP, starting at draft depth 1 and selecting depth 1 or 2 from recent acceptance.
- C: attention processing in blocks of 256 tokens.
- D: compiled GDN gate preparation. Compiled norms and compiled expert arithmetic are off.

| Setting |30gb |78gb |
| --- | --- | --- |
| Experts cached per layer |152 |512 |
| Full-resident optimization |off |both |
| Adaptive MTP |on |on |
| Attention block |256 tokens |256 tokens |
| Compiled GDN preparation |gates |gates |
| Prefill chunk |2048 tokens |2048 tokens |
| Expert loading batch |32 |32 |
| I/O queue depth |12 |12 |
| Pool queue depth |32 |32 |
| Maximum context |32768 tokens |32768 tokens |
| Prefix/conversation cache |off |off |
| Startup reclaimable reserve |8GB |20GB |

The profile names describe approximate process footprints, not hard memory caps.
The smaller profile uses the same full weights and streams more experts from SSD.
Full-resident paths require all 512 experts; they are disabled at 152.
The launcher checks reclaimable memory against a conservative estimate plus reserve
(31 GB floor for `30gb`, 82 GB for `78gb`). It clears inherited SLOTSTREAM_, MLX_ and
SS_DEBUG_ settings, refuses another Slotstream process, and starts on localhost.
This preflight does not cap runtime allocation; application activity can change.

Use scripts/serve.py to select the baseline. Running the executable's serve command
without profile settings uses upstream CLI defaults, not this saved configuration.
Settings are stored in profiles/*.json and checked by scripts/verify_sources.py.

Measurements used temperature 0, top_p 1, top_k 0, presence_penalty 0, seed 42 and
reasoning disabled. These are caller-controlled request settings, not forced by
the launcher. Wording differences are acceptable only when quality checks pass.
Future performance comparisons start from the appropriate ACD profile, use the
same task/repository fixture, evaluate complete workflow latency and quality, and
retain normal multitasking observations. The improvement threshold remains 2.5%.
