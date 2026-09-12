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

## Serving boundaries

Both profiles share these resource policies; they do not change sampling or ACD:

- At most 32 open connection workers and four admitted inference requests,
  including preparation and response delivery. GPU inference remains serialized.
  Excess requests receive HTTP 503 with `Retry-After: 1`; health routes bypass
  inference admission while a transport slot is available.
- Headers are limited to 64 KiB and bodies to 32 MiB. Uploads have a total
  30-second deadline, after which the server returns HTTP 408.
- Each response write (each chunk for streams) has a 120-second deadline under
  backpressure. This is not a total generation deadline.
- Source images have a combined budget of 33,554,432 pixels per request, checked
  before decoding/rotation. Oversized images receive HTTP 400 and must be resized
  by the caller. This admits one full 8K image. The budget corresponds to 128 MiB
  at four bytes per pixel, not a hard decoder or process allocation cap.

The stricter limits prevent slow clients and compressed image inputs from
retaining disproportionate resources. Accepted inputs retain the existing image
processing and numerical behavior. The supported build wrapper and model binary
hold the same exclusive process lock; direct external build/model tools must
still be kept separate manually.

PNG inputs also require intact chunk framing and CRCs before ImageIO decoding.
Corrupt PNGs return HTTP 400 instead of risking a blank image being interpreted
as valid input. Other formats retain their existing validation.

Diagnostic `SLOTSTREAM_ROUTER_TRACE` remains disabled by supported launchers.
For direct diagnostic callers, encoded buffering is capped at 64 MiB per flush.
Overflow or invalid records discard the entire trace rather than writing partial
scientific data. `flush()` reports that failure, clears state for the next trace,
and reports file-write errors explicitly. Existing output files are retained when
an invalid/oversized trace is discarded; only a reported successful flush replaces
them. The binary record format is unchanged.

## Shutdown and failure recovery

Once the HTTP listener is ready, SIGINT/SIGTERM stop acceptance and allow existing
connections up to 30 seconds to finish. The server then shuts down outstanding
sockets, allowing another 10 seconds for workers to observe cancellation and
release their inputs. Successful draining exits 0. A stuck computation that
cannot finish cleanup exits 124 rather than hanging indefinitely. Signals during
model initialization retain the ordinary process-termination behavior.

The supported launcher still executes the server directly by default. Add
`--supervise` for bounded recovery:

```sh
python3 scripts/serve.py --profile 30gb --supervise
python3 scripts/serve.py --profile 78gb --supervise
```

Run only one of these. Supervision waits for a failed child to exit, then performs
fresh process/headroom checks before restarting the same profile. It permits at
most three restarts, delayed 5, 10 and 20 seconds, per supervisor invocation.
Persistent failures stop with a nonzero exit. A failed preflight also stops rather
than trying to force the model into insufficient memory. A normal exit or stop
request is never restarted. Stop the supervisor PID; it forwards the signal and
allows 45 seconds before killing an unresponsive child.

Recovery creates a fresh process; it does not recover a partially evaluated GPU
graph, replay requests, or preserve in-memory inference state. Interrupted clients
may receive a disconnect, and connections during restart may be refused. Clients
must decide whether retrying their operation is safe. Genuine checkpoint I/O
errors log their cause and fail closed; unreadable or truncated tensors are never
turned into successful output. This cannot repair corrupt weights, a persistent
hardware/driver failure or an OS-level unkillable process. No model files are
modified by recovery.

For a process that remains alive while inference stops advancing, an optional
progress watchdog is available:

```sh
python3 scripts/serve.py --profile 30gb --supervise --stall-timeout-seconds 180
```

The default is 0 (disabled). Choose a timeout above the longest legitimate pause
on the target hardware, including model preparation, a prefill chunk and the
120-second network-write allowance. This is a progress timeout, not a total
request-duration limit. Prefill/decode cancellation checkpoints renew it; merely
queuing another request does not. On expiration the server logs the stall and
exits 75, allowing supervised fresh-process recovery. Shutdown disables the
watchdog and uses its separate drain/cleanup deadlines. A watchdog cannot repair
an OS/driver hang that prevents the server's control thread from running.
