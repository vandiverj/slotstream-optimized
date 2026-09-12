# Production review — 2026-09-12

This is a local hardening review of the shared ACD application, not a production
certification. The original 30 GB / 78 GB qualification remains historical evidence
for the baseline source. New source hashes identify these boundary fixes separately;
`baseline_source_files` and `qualified_binary_sha256` retain the original identity.
No upstream changes, dependency-version changes, model downloads, profile changes,
or inference arithmetic changes were made. Expert staging now calls the existing
pinned C ownership API directly to avoid a measured Swift callback-wrapper leak.

## Architecture and review coverage

| Area | Entrypoint / ownership / concurrency |
| --- | --- |
| Launch and configuration | `scripts/serve.py` selects either profile, sanitizes inherited environment, runs doctor, checks headroom and execs the shared binary by default; optional supervision bounds restarts. `ModelOptions` validates the plan; `Serve` claims the port before constructing the engine. |
| Engine and inference | `Engine` owns tokenizer, `Qwen4ExpModel`, `Generator`, prefix cache and lazy vision tower. Its generation lock serializes inference and pool resizing. Configure public mutable options before serving; direct low-level model/generator methods are not independently thread-safe. Callbacks must not re-enter the generation lock. |
| Expert and resident weights | `CheckpointIndex` validates shard headers and owns cached file descriptors, closed in deinit. `ResidentWeights` keeps MLX arrays; `ExpertStore` passes aligned staging buffers to MLX with free callbacks. `SlotPool` owns bounded slots, admission state and the optional full-resident map. Batch reads join before staging ownership transfers. |
| Model state | `Layers`, `Model`, `MTP`, `Generate` and the compiled kernels own per-generation KV, indexer, recurrent and draft state. Cache capacity grows in blocks; generation limits bound supported API requests. Speculative recording is cleared. Numerical and expert-admission paths were retained. |
| CPU caches | `NgramStore` caps rows at 400,000 and evicts 10% in FIFO order. Parallel prefetch writes distinct output elements, joins, then mutates the cache serially. `PrefixCache` uses its own lock and entry/token budgets; it is disabled by both saved profiles. MLX allocator retention is capped at 2 GiB. |
| HTTP and dialects | `Server` owns its listener; its lifecycle registry closes accepted sockets after workers release their server references. Up to 32 detached connection threads read bounded bodies; four inference admissions cover parsing, image preparation, generation and delivery. The existing engine lock still serializes GPU inference. `Server+HTTP` owns framing policy and borrows sockets. Ollama, OpenAI and gateway adapters validate their distinct schemas; output/tool splitters are per request. Cancellation is checked between prefill/decode work units. |
| Governor | Only auto-sized launches activate `MemoryGovernor`; fixed profiles do not. A serial dispatch queue owns its lifecycle and policy timestamps. Resizing uses the engine lock; status reads use published snapshots. Stop drains the active callback and must be called outside `Engine.withExclusive`. |
| Downloads and C | `WeightStore`, raw and slotpack downloaders validate sizes/hashes, hold a directory lock, bound HTTP bodies and worker/decode concurrency, join work and invalidate sessions. Part-file descriptors have explicit cleanup. The C codec checks bounded input/output and releases temporary allocations on error branches. Real download recovery was inspected, not exercised against distribution endpoints. |
| Diagnostics and packaging | Reviewed CLI command registration, native catalogue, diagnostics, trace hooks, pinned manifests, build/metallib scripts, health script, profiles, provenance and supplied documentation. Parity/golden/experimental helpers have CLI or SPI callers and were retained. Archived research tools referenced by old source comments are not installation prerequisites. |

## Confirmed defects and changes

Severity reflects this localhost application, not an assumed public deployment.

| Severity | Confirmed defect | Fix and evidence |
| --- | --- | --- |
| High | Bitmap CGContext retained a Swift array pointer beyond the implicit `&raw` argument lifetime. | Scope context construction and all drawing inside `withUnsafeMutableBytes`. Preserve allocation size, draw calls, interpolation and float conversion. Existing image checks plus repeated draws verify representative output. |
| Medium | Lazy vision initialization read the stored tower without the lock used to write it. | Remove the unlocked fast-path read. First-use requests serialize on the existing generation lock. Concurrent image smoke requests exercise this path; no ThreadSanitizer proof is claimed. |
| Medium | Governor lifecycle writes could overlap queue callbacks; repeated start could install additional sources. | Start, stop and manual polling use the same serial queue; start is idempotent and sources are stored before resume. Pool status uses the published snapshot. Policy tests pass; real auto-resize pressure tests were not run. |
| Medium | Conflicting Content-Length fields silently selected the last value; unsupported encodings and malformed heads could reach routing. | Reject conflicting/non-decimal/empty lengths, unsupported transfer encodings, invalid request lines and malformed/control-bearing headers. Matching repeated lengths remain accepted. Native framing tests cover these cases. |
| Low | Terminated headers bypassed the advertised 64 KiB limit within the receive buffer. | Enforce the limit on the parsed header; allow the delimiter to straddle reads at the exact limit. Native string and socket boundary tests cover it. |
| Medium | listen errors were ignored and permanent accept errors spun indefinitely. Listener ownership was absent on startup failure. | Throw descriptive errors; retry interrupted/aborted accepts. Server deinit closes its listener; CLI retains ownership until transfer and closes on initialization failure. Connection fallback closes its socket if its weak owner disappeared. |
| Low | Interrupted read syscalls could be mistaken for disconnected clients. | Retry EINTR for header/body reads. Tests exercise truncated-body recovery; signal-driven EINTR injection was not performed. |
| Medium | Build preflight alone allowed a model to start between checking and building. | The build wrapper holds the same exclusive file lock as the model, inherited by its child commands. Validate lock ownership/type/link count and reject symlinks. Seven launcher tests cover contention, cleanup, inherited ownership and unsafe lock files. Arbitrary external runtimes remain outside this protocol. |
| Medium | Slow-drip uploads could indefinitely renew the per-read timeout. | A monotonic 30-second deadline covers the entire head/body; stalled requests receive 408. Native short-deadline tests and 32 live stalled clients exercise recovery. |
| Medium | Partial response writes could indefinitely renew their timeout. | Nonblocking descriptors and a 120-second deadline per send operation bound backpressure. Native full-buffer and closed-peer tests cover timeout and SIGPIPE handling. Darwin socket testing exposed that MSG_DONTWAIT alone was insufficient; explicit O_NONBLOCK fixed the observed hang. |
| Medium | All 32 connection workers could retain prepared inference inputs while waiting on the GPU lock. | Admit at most four inference requests before JSON/image preparation; excess requests receive 503 with Retry-After: 1. Health routes bypass inference admission. Live cancellation/overload checks verify slot recovery. |
| Medium | Encoded-image byte limits allowed compressed inputs with enormous source dimensions. | Validate dimensions before decode/EXIF rotation and cap total source pixels per request at 33,554,432. Native overflow/boundary checks and a valid oversized PNG verify rejection. Accepted-image pixel conversion is unchanged. |
| Low | A disconnected queued request could run vision/state preparation before its first cancellation check. | Check cancellation before prefix-state acquisition and vision evaluation. Live queued-client disconnection checks exercise recovery. |
| Low | Interrupted checkpoint pread was treated as fatal I/O failure. | Retry EINTR without changing successful reads; genuine storage failures still fail fast. Signal injection was not performed. |
| Medium | The corrupt PNG fixture passed the transparency check because lazy decoding failed onto the white background; the framework retained a provider cycle. | Validate PNG chunk bounds and CRCs before ImageIO. Retain corrupt bytes as a rejection test and use a valid transparent fixture for compositing assertions. |
| Low | Diagnostic router tracing buffered without a cap and reported success after a failed write. | Cap encoded buffering at 64 MiB, reject invalid records, atomically write complete traces and explicitly report failure/discard. Eleven assertions cover binary compatibility, capacity, write failure, cleanup and recovery. |
| High | Every expert staging buffer used a pinned MLX Swift finalizer wrapper whose retained capture was never released. A live 30gb scan reported 601,032 leaked allocations / 19,233,008 bytes during repeated serving. | Bypass that Swift wrapper with the existing C managed-buffer API and a capture-free destructor. Keep allocation sizes/alignment, C ownership path and GPU evaluation order unchanged. The pinned dependency is untouched. Native lifetime/byte checks and paired model checks validate the local workaround. |
| Medium | There was no finite graceful shutdown path; immediate signal termination interrupted every active response. | Stop acceptance, drain for 30 seconds, cancel sockets, then enforce a 10-second cleanup deadline. Workers retain descriptor ownership until completion; the registry prevents close/reuse races. |
| High | Initial drain testing exposed engine destruction on a worker after MLX compiler-cache runtime teardown. | Release temporary worker ownership before signaling completion; use weak signal handlers and drain their serial queue before releasing the engine. Final active-stream shutdown exits 0. |
| Medium | Optimized checkpoint traps omitted useful failure text and EOF could be described with an irrelevant errno. | A tested exact-read boundary distinguishes interruption, truncation, range and I/O errors. Emit an explicit fatal log before failing closed in release builds. |
| Medium | Fatal storage/GPU process failures required manual relaunch. | Add opt-in bounded supervision, fresh preflight before each restart, child reaping, stop forwarding and no request replay. Persistent failures exhaust a finite budget. |

## Structural improvements

HTTP framing was moved unchanged after its first passing regression run into
`Server+HTTP.swift`. The reader no longer requires an Engine instance, allowing
real socket tests without model allocation. The shell build entrypoint delegates
subprocess and lock ownership to a small standard-library Python wrapper. No
transport framework, public library signature, dependency version change or
inference refactor was introduced.
`ImageContainer` isolates pure PNG validation from image drawing, and the package-only
`RouterTraceRecorder` permits bounded-buffer and file-failure checks without a model.
`docs/TESTING.md` now describes the actual shipped catalogue instead of leaving
its referenced testing document absent.

`ServerLifecycle` makes connection ownership, drain completion and progress policy
explicit without moving inference off its existing serialized path. `CheckpointRead`
isolates exact-read/error behavior for injected and real-file tests. The optional
Python supervisor owns child lifetime and retry policy outside the GPU process.

## Evidence and limits

- Baseline: source/profile verification and 22 T0 checks / 616 assertions passed.
- Final release build: `./scripts/build.sh 30gb`, using the existing pinned
  dependencies and cached metallib. Both profiles use that same build.
- Final T0: 26 checks / 734 assertions, no failures or skips.
- Launcher regressions: `python3 scripts/test_launchers.py`, seven tests passed.
- Supervisor regressions: `python3 scripts/test_supervisor.py`, six tests passed.
- C codec: a local `clang -fsanitize=address,undefined -g -O1` harness exercised
  6,417 round-trip, truncation and mutation cases without sanitizer findings.
  This finite corpus is not exhaustive fuzzing or proof of codec safety.
- The native HTTP subset under `leaks -quiet -atExit --
  .build/release/slotstream-checks --tier t0 --filter http` reported zero leaks.
  The tool warned that process security restricts inspection; this is not proof
  that the server or all concurrency paths are leak-free.
- Initial full T0 leak scans reported an ImageIO/CoreGraphics provider cycle
  (33 allocations / 4,544 bytes, later 49 / 7,872). The isolated 32-decode
  reproduction retained 962 allocations / 136,256 bytes. Follow-up found that
  the supposedly transparent fixture had a corrupt IDAT CRC: drawing failed
  onto the prefilled white background, allowing the transparency check to pass.
  An independently constructed valid transparent PNG reported zero leaks under
  the same 32-decode probe. PNG framing/CRC validation now rejects the original
  corrupt fixture before ImageIO; the transparency test uses a valid fixture.
  The original corrupt bytes remain as a rejection regression. Full T0 after
  that fix reported zero leaked bytes (with the same macOS inspection caveat).
  No decoder, caching or interpolation workaround was adopted.
- The T1 Metal staging-ownership, sampler and vision-splice suite passed three
  checks / 150 assertions. The staging check validates data through lazy GPU
  evaluation and exactly-once finalization of 128 transferred buffers.
- Sequential profile smoke checks use existing local weights, real completions,
  malformed heads, interrupted bodies, a disconnected streaming request and
  port rebinding after termination. See VALIDATION.md for final runtime results.
- The earlier staging-fix deterministic comparison on both profiles preserved
  outputs. The later shutdown/read-boundary screen measured +1.15% in the
  balanced 30gb follow-up and +0.01% in the 78gb pair (see VALIDATION.md). This
  comparison uses the first hardening pass as its control, not the original
  qualified binary.
- The matched 334-request post-fix 30gb run kept allocated heap near 73.2–73.4 MB
  and descriptors at 22. Final live heap inspection reported two residual
  allocations / 48 bytes, without the prior growing callback-wrapper population.
  Physical footprint still increased with allocator-retained/fragmented regions;
  see VALIDATION.md for the separate measures and limits.
- Sequential 15-minute context/serving runs passed on both profiles, including
  exact retrieval through 31,104 prompt tokens, repeated retrieval, over-limit
  rejection and clean shutdown. Both finished at 22 descriptors; sampled peaks
  were 30.13 GB and 77.49 GB. These runs precede the optional watchdog addition;
  see VALIDATION.md for evidence scope.
- No performance thresholds or original quality checks were weakened. No new
  end-to-end performance qualification, 48 GB machine test, exhaustive context study,
  ThreadSanitizer run, multi-hour soak, live downloader fault injection, disk
  exhaustion or GPU allocation-failure test was performed.

## Remaining risks and deliberate limits

1. **Image decoder coverage:** the reproduced corrupt-PNG cycle is prevented
   at the input boundary. PNG CRC validation is not a complete decoder validator;
   corrupt compressed data with recomputed checksums and malformed non-PNG formats
   still depend on ImageIO. Finite native leak checks and repeated serving do not
   establish leak freedom across formats or macOS versions.
2. **Aggregate load:** four admitted inferences and 32 bounded transport bodies
   reduce retained inputs but are not a hard process memory cap. A source-pixel
   count is not a limit on every decoder allocation. The 120-second deadline is
   per response write/chunk, not a total generation deadline; long generations
   and slowly consumed streams can still occupy capacity. There is no queue
   fairness or maximum inference wall-time guarantee.
3. **Storage/GPU failure:** real I/O failures still terminate the process rather
   than allowing partially filled tensors to run. Errors now identify EOF/range/
   errno and log explicitly in release builds. Opt-in supervision restarts failed
   processes with fresh preflight and a three-restart budget; no requests are
   replayed. An optional inference-progress watchdog handles live-process stalls
   with a caller-selected timeout; its default remains disabled. It cannot repair corrupt weights or a persistent driver/hardware
   failure. Real EIO injection and a fatal-process signal were tested; actual GPU
   OOM, driver reset and OS-level unkillable hangs were not induced.
4. **Shutdown:** ready servers drain connections for 30 seconds, then cancel
   sockets and allow 10 seconds for cleanup; success exits 0 and stuck work exits
   124. Worker and signal ownership is released before engine/runtime teardown.
   Active-stream drain and a deliberately stalled read were tested. Signals
   during initialization still use ordinary immediate process termination. The
   saved profiles disable elastic resizing; shutdown under active auto-governor
   pressure remains unqualified.
5. **Packaging:** the supported build and model share an atomic lock, but
   arbitrary external model runtimes or direct Swift builds do not participate.
   Cached metallib files are reused without a fresh wheel checksum check; the
   downloaded wheel path is checksum-pinned. Trusted local artifacts remain required.
6. **Diagnostic-only behavior:** router traces now cap encoded buffering at
   64 MiB, discard an incomplete trace explicitly, validate record dimensions and
   report write failures. Supported launchers still disable tracing. Other debug
   helpers retain internal-index assumptions and are not untrusted public APIs.
7. **Residual heap findings:** final live-model inspection reports two small
   allocations totaling 48 bytes whose ownership is unresolved under restricted
   inspection. Separately, native GPU heap inspection reports one
   32-byte NSArray allocation originating in MTLCopyAllDevices. The pinned device-enumeration implementation retains the returned array;
   this is a startup allocation, distinct from per-request growth. No staging
   capture leaks appear in the new native ownership probe. The small Metal
   finding remains distinct and is not claimed fixed; macOS restricts inspection.
8. **Trust boundary:** loopback and CORS restrictions are not authentication.
   Trusted local callers, stable compatible model files and adequate headroom
   remain operating assumptions. Error envelopes differ by dialect and by early
   framing failure; this review preserves existing public response schemas.

A passing short run does not establish production readiness, absence of leaks,
absence of races or unchanged latency on all workloads.
