# Package validation

Validated on 2026-09-12 on the 128 GB M5 Max with the existing compatible model files:

- Shared ACD source and both profile identities verified.
- Release build completed using pinned dependencies.
- Native T0 checks: 22 passed, 0 failed, 0 skipped (616 assertions).
- 30 GB launcher: actual OpenAI-compatible completion returned READY.
- 78 GB launcher: actual OpenAI-compatible completion returned READY.
- Runtime logs confirmed compiled gates and adaptive MTP for both profiles;
  full-resident mode off at 152 experts and both at 512 experts.
- Both model processes were stopped after their checks.

The tests exercise the supported profile launcher and packaged API health script.
They supplement the original software quality studies summarized in FINDINGS.md;
a short READY response alone is not model-quality or performance qualification.
No inference source or pinned dependency versions changed during consolidation.

On the work Mac, follow the README build, download, source/native checks and API
check. Hardware-specific memory/performance validation remains pending there.

## Production-boundary review follow-up

The original results above describe the consolidation baseline. The active source
now includes the separately documented fixes in [PRODUCTION_REVIEW.md](PRODUCTION_REVIEW.md).
Historical qualification is not transferred to the modified source by its hash.

Final verification on the same 128 GB machine:

- Pinned release build completed; shared source and both profile identities pass.
- T0: 23 passed, 0 failed, 0 skipped; 656 assertions.
- Launcher regression script: three tests passed. Shell syntax and diff whitespace checks pass.
- Both profiles, sequentially: six short deterministic READY completions each,
  two concurrent first-use image requests each, conflicting lengths rejected
  with 400, oversized headers rejected with 431, 40 truncated-body connections,
  and recovery after a disconnected streaming request.
- Accepted socket descriptors returned to the warm count of 22 after these
  requests for each profile. Processes were terminated with SIGTERM, exited
  without requiring SIGKILL, and their ports could be rebound. This verifies OS
  cleanup after process termination, not graceful in-process draining.
- During six short text calls, RSS ranged from 4,814,208 to 4,814,448 KiB for 30gb
  and 4,533,968 to 4,534,304 KiB for 78gb. After first-use vision plus cancellation
  recovery, RSS was 6,076,704 and 5,430,544 KiB respectively. Loading a retained
  vision tower and warming image/allocator state changes this measurement.
  These are `ps` RSS samples, **not full GPU/physical footprint or profile caps**,
  and neither the short series nor stable descriptor count rules out a leak.
- The C codec passed 6,417 bounded sanitizer cases. Native heap inspection also
  found a small, repeatable ImageIO/CoreGraphics retain cycle; see the review.

Profiles, sampling defaults, dependencies, model arithmetic and performance
thresholds are unchanged. No new whole-workflow timing claim is made. The actual
48 GB machine, long contexts, sustained image traffic, real auto-governor resize
and failure injection still need qualification.

## Bounded-load and cancellation follow-up

The subsequent hardening adds absolute upload/write deadlines, four inference
admissions, a source-image pixel budget, early queued cancellation, interrupted
checkpoint-read retry and atomic supported build/model exclusion. The final
release build passes 23 T0 checks / 685 assertions and six launcher regressions.

A sequential live 30gb failure test confirmed:

- Four admitted streams; a fifth inference received 503 with Retry-After: 1.
  The version endpoint remained responsive during the inference queue.
- Closing the four streams allowed a successful completion in 0.97 seconds.
- 400 conflicting-length requests were rejected, using eight concurrent clients.
- A valid compressed 8192 × 4097 PNG received a pixel-budget error before decode.
- 32 stalled uploads exhausted transport admission, then each received 408;
  all slots recovered in 30.00 seconds and a fresh completion succeeded.
- Numeric file descriptors returned from 22 to 22. Mach physical footprint,
  reported through `/api/ps`, changed from 25,605,329,312 to 25,718,477,288 bytes.
  This approximately 113 MB retained increase includes generation/allocator
  warming; the short run does not classify it as a leak or prove bounded growth.
- SIGTERM stopped the process and its port could be rebound without SIGKILL.

These are finite failure-path checks on the 128 GB review machine, not a prolonged
soak, a maximum-context benchmark or a 48 GB deployment qualification.

### Periodic deterministic quality/timing check

Compared the final binary with a retained binary from the first boundary-hardening
pass, before the deadline/admission/pixel-budget changes. This is an incremental
regression comparison, not a requalification against the original ACD binary.
Each profile ran separately with existing weights: one warm-up, then Python
`safe_mean`, exact structured JSON, and a lock-deadlock explanation. Requests used
fixed seed 42, temperature 0, top_p 1, top_k 0, presence penalty 0, reasoning off
and a 160-token cap. These are test request settings, not changed server defaults.

| Profile | Comparison total | Final total | Change |
| --- | ---: | ---: | ---: |
| 30gb | 13.678 s | 13.547 s | -0.96% |
| 78gb | 3.954 s | 3.939 s | -0.38% |

All six outputs matched their comparison outputs exactly and stopped normally.
The generated Python passed AST restrictions and executed mean/empty-input checks;
the structured JSON matched exactly and the explanation passed content checks.
Differences are below the unchanged 2.5% improvement threshold and consistent with
noise: no speedup or broad quality/performance qualification is claimed. Both
profiles were stopped after checking; builds and models never overlapped.

Final native HTTP heap inspection passed all three selected checks / 85 assertions
and reported zero leaked bytes. macOS warned that process security restricts
inspection. This limited result does not clear the separate measured ImageIO
retain cycle or establish whole-server leak freedom. Final source/profile checks,
both dry-run launchers and diff whitespace checks passed. No model processes were
left running.

## Remaining-risk investigation: PNG integrity and diagnostic ownership

The earlier image-cycle finding was traced to a corrupt IDAT CRC in the supposed
transparent fixture. The PNG compressed bytes themselves decompressed, but their
chunk checksum was invalid. ImageIO created an image lazily; drawing failed onto
white and retained a provider cycle. Thus the former white-pixel assertion was
not sufficient evidence of successful decoding. An independently generated valid
transparent PNG reported zero leaked bytes across 32 isolated draws.

The application now validates PNG chunk bounds and CRCs before ImageIO. The bad
fixture is retained as a rejection test, with a valid transparency fixture and a
colored partial-transparency companion check. No ImageIO cache mode, decoder,
interpolation or normalization arithmetic changed. This adds a linear pass over
encoded PNG bytes with a fixed 256-entry CRC table and no image-sized copy.

Diagnostic router traces now have a 64 MiB encoded-buffer limit and explicit
failure/discard reporting. Writes are atomic; successful record bytes are unchanged.
The recorder is tested independently of environment settings and model allocation.
Supported profile launchers continue to disable tracing.

### Repeated image/text serving

Each profile independently handled four warmups, 30 text and 30 distinct valid
transparent-image requests, and six corrupt-PNG requests (70 requests total).
Valid requests completed normally with READY; corrupt images returned HTTP 400
checksum errors. Every memory sample had 22 numeric descriptors. Both processes
stopped with SIGTERM and released their port.

| Profile | Elapsed including startup | Warm physical footprint | Final footprint | Change |
| --- | ---: | ---: | ---: | ---: |
| 30gb | 71.93 s | 26,891,965,720 bytes | 27,105,089,032 bytes | 213.12 MB |
| 78gb | 25.41 s | 74,330,280,856 bytes | 74,333,442,968 bytes | 3.16 MB |

These are Mach physical-footprint samples, not a throughput benchmark. The 78gb
series stayed within approximately 3.2 MB of warm-up. The 30gb series required a
longer follow-up because its growth could not be classified from this short run.
The two-profile run preceded the diagnostic-only recorder change; tracing was
disabled. No model processes or large builds overlapped.

### Expert staging callback leak

An extended pre-fix 30gb run handled 334 requests over 388.77 seconds: four
warmups, 150 text calls, 150 valid images and 30 rejected corrupt images. All
completed as expected with 22 descriptors throughout. Physical footprint grew
from 26,917,639,568 to 27,184,502,400 bytes. `vmmap -summary` showed increased
malloc usage and allocator-empty regions, with graphics mappings roughly stable.
A live `leaks -quiet PID` scan during that run reported 601,032 leaked allocations
/ 19,233,008 bytes, principally `FinalizerCaptureState` and closure contexts.

The pinned `MLXArray(rawPointer:finalizer:)` implementation uses `passRetained`,
but its trampoline calls `takeUnretainedValue()` and never releases that state;
an unused local release function does not participate. Expert data buffers were
freed by the callback, while callback wrappers accumulated. This distinguishes
the concrete per-buffer leak from the larger allocator-retention measurement.

`adoptStagingBuffer` now calls the existing `mlx_array_new_data_managed` C API.
That delegates to the same managed-payload implementation with the raw pointer
as payload and a capture-free `free` callback. Alignment, buffer sizes, ownership
transfer, eval order and dtype conversion are retained. No pinned dependency or
inference setting changed. Source ownership review and a 128-buffer GPU test
verify valid data through lazy evaluation and exactly-once finalization.

Verification after this change:

- Release build passed; T0: 24 checks / 704 assertions; T1: three checks /
  150 assertions. Launcher regressions: six tests passed.
- Full native T0 heap scan: zero leaked bytes, with macOS inspection restrictions.
- Native staging ownership heap scan: no FinalizerCaptureState leaks; one
  32-byte NSArray leak originates in Metal device enumeration. The pinned C++
  `load_device()` keeps the result of `MTL::CopyAllDevices()` without releasing
  it; this startup finding is distinct from per-staging-buffer growth and remains
  unchanged. The result is not a completely clean GPU heap scan.

A paired deterministic comparison used the saved binary immediately before the
staging workaround as control, with the same Python/JSON/locking tasks and request
settings described above. All six output comparisons were exact and quality
checks passed. No performance threshold was relaxed.

| Profile | Control total | Fixed total | Change |
| --- | ---: | ---: | ---: |
| 30gb | 13.837 s | 13.745 s | -0.67% |
| 78gb | 3.948 s | 3.955 s | 0.17% |

These small differences are consistent with noise; no speedup is claimed.

### Matched run after the staging fix

The final binary completed the same 334 requests in 380.25 seconds,
including memory inspection (not a throughput benchmark). All valid completions
and corrupt-image rejections passed. Descriptors remained 22 at every sample;
SIGTERM exited without SIGKILL and the port was released.

- Live heap inspection at the end reported **two residual allocations totaling
  48 bytes**, one unidentified 32-byte allocation and one 16-byte NSArray. It
  did not show the former accumulation of staging callback wrappers. This is
  not a zero-leak result; macOS again warned of restricted inspection.
- `vmmap` malloc-zone allocated bytes stayed near **73.2–73.4 MB**, and allocation
  count changed from 322,252 to 322,461. In the pre-fix matched run, allocated
  bytes rose from 73.7 to 101.9 MB and count from 334,726 to 1,252,325.
- Physical footprint changed from 26,891,670,904 to 27,156,715,160 bytes. It had stable intervals
  but also allocator jumps. Malloc fragmentation/retained space increased from
  approximately 84.1 to 195.3 MB, with additional allocator-empty regions. This
  supports separating allocator retention from the repaired callback-object
  leak; it does not prove a hard bound on total memory for other workloads.

The local finalizer workaround is retained based on source-level ownership
analysis, native destructor/data tests, live heap evidence and paired quality/
timing checks. Allocation sizes/alignment, numerical evaluation, both ACD
profiles and dependency versions are unchanged. No cache-clearing or allocator
policy change was used to manufacture a lower footprint.

Remaining qualification includes multi-hour mixed/context-heavy traffic, malformed
formats beyond PNG checksums, allocation/storage failure injection, graceful
in-process draining and the actual 48 GB machine. The small residual heap findings
remain recorded rather than being interpreted as a clean full-server scan.

## Shutdown and process recovery qualification

Native regression gates pass 26 T0 checks / 725 assertions and three T1 checks /
150 assertions. Six launcher and six supervisor process tests pass. The new
native cases cover grace/cancellation/descriptor ownership, interrupted and
partial reads, real temporary-file truncation, error reporting and range overflow.
Supervisor cases cover finite retries, reaping before restart, preflight refusal,
signal forwarding, successful exit and killing an unresponsive fake child.

Live checks used the unchanged 30gb profile and a temporary one-shot syscall
interposer. No weight files were modified: one actual safetensors pread returned
EIO, and a separate test delayed one read for 90 seconds. The interposer was
validated against a fake file first and was not incorporated into the application.

- An uncached request hit EIO, failed without a success response, and the
  supervisor reloaded a fresh process. The replacement returned READY after
  7.63 seconds. Optimized precondition traps initially omitted the error text;
  explicit fatal logging was added and verified in the successful rerun.
- SIGABRT simulated fatal process loss. A replacement returned READY after
  12.73 seconds. This verifies process recovery, not a real Metal OOM or driver reset.
- SIGTERM to the supervisor during a 256-token streaming request allowed the
  stream to reach its terminal event, then exited 0 in 8.10 seconds. No restart
  followed the stop request, and the port could be rebound.
- Initial draining exposed a teardown crash: a worker retained the engine until
  pthread cleanup after the C++ compiler cache had begun destruction. Worker
  references now end before completion is signaled, and weak signal handlers
  are drained on their serial queue before engine release. The final live case
  exited cleanly; no dependency or compiled-kernel policy was changed.
- With an in-flight read stalled for 90 seconds, SIGTERM drained for 30 seconds,
  cancelled sockets and exhausted the additional 10-second cleanup window.
  The process exited 124 after 40.16 seconds, the request failed, and the port
  was released. No successful inference was fabricated from incomplete work.

The supervisor is opt-in (`--supervise`), preserves profile arguments, and never
replays interrupted requests. It stops after three restarts or a failed fresh
preflight. During loading/recovery, connections may be refused. A corrupt model,
permanent device failure or unkillable OS task is outside this recovery guarantee.

### Shutdown/read-boundary timing screen

The first paired screen preserved all six outputs but measured +2.70% total time
for 30gb and +0.01% for 78gb. The borderline 30gb result triggered a balanced
follow-up with three runs per binary in candidate/control, control/candidate,
candidate/control order. All outputs and quality checks remained identical.
Mean totals were 17.763 seconds for control and 17.967 seconds for the candidate
(+1.15%). The original result is retained rather than discarded. This
screen does not establish identical latency or a speedup; the existing 2.5%
threshold was not relaxed. The later opt-in progress watchdog is verified
separately, and remains disabled in baseline-profile qualification runs.

### Bounded context and sustained-serving qualification

Sequential runs on the review machine used the unchanged saved 30gb and 78gb
profiles, deterministic request sampling, no prefix cache and no fault injector.
Each served for at least 15 minutes. A varied-record retrieval workload placed
facts at different prompt positions; actual tokenizer counts were 8,004, 16,045
and 31,104 tokens. Each profile also repeated the 8,004-token retrieval twice.
All ten retrievals returned the exact expected code. Deliberately oversized
requests returned HTTP 400 on both profiles.

| Measure | 30gb | 78gb |
| --- | ---: | ---: |
| Serving duration | 904.68 s | 900.22 s |
| Short successful requests | 136 | 131 |
| 8,004-token request | 14.57 s | 13.25 s |
| 16,045-token request | 32.16 s | 30.26 s |
| 31,104-token request | 88.42 s | 70.41 s |
| Peak sampled physical footprint | 30.13 GB | 77.49 GB |
| Final physical footprint | 27.30 GB | 74.68 GB |
| Final descriptors | 22 | 22 |
| Shutdown exit | 0 | 0 |

Physical footprint was sampled every two seconds; these are sampled peaks, not
allocation bounds or allocated-heap measurements. One transient extra descriptor
in 30gb coincided with the monitoring connection; final measurement followed
monitor shutdown. Neither run tripped its test memory guard, recorded a request
failure, nor left its port occupied. This does not establish leak freedom,
exhaustive context quality, multi-hour stability or suitability on a 48 GB Mac.

These soak runs used the shutdown/read-boundary build before the optional
watchdog source addition. The final watchdog build has separate targeted evidence
below; the 15-minute results must not be attributed to that later binary.

### Final optional-watchdog verification

The final release build passed T0 (26 checks / 734 assertions) and T1
(3 checks / 150 assertions). Launcher tests passed 7/7 and supervisor tests 6/6.
With the 30gb profile, opt-in supervision and a deliberately short 15-second
progress timeout, a one-shot 90-second checkpoint-read stall caused exit 75 and
fresh-process recovery in 22.83 seconds. A subsequent 26,040-token retrieval
completed correctly in 65.92 seconds in the same replacement process: progressing
prefill did not trigger the watchdog despite exceeding 15 seconds total. SIGTERM
during a streaming request then delivered the terminal event and exited 0 in
7.94 seconds, without restart; the port was released.

An initial watchdog harness used an oversized context fixture. It was correctly
rejected with HTTP 400 after successful stall recovery; the fixture was reduced
before the complete successful rerun. No application limit was relaxed.

The watchdog is disabled in default launches. Its enabled path was tested with
30gb; 78gb received the preceding shutdown/context qualification, not a repeat of
this fault-injection workload. Actual GPU OOM, driver reset, permanent disk loss,
multi-hour serving and 48 GB hardware remain unqualified. The simulated blocking
read and SIGABRT exercise recovery mechanics, not every GPU failure mode.

The final model-free T0 `leaks -quiet -atExit` run passed all 734 assertions
and reported 0 leaked bytes, subject to macOS restricted-process inspection.
This does not supersede the separate residual live-model/GPU heap findings.

Final watchdog-test binary SHA-256: `426af83f50f17df2f6d16e31d3dfcc39188f7229bdb315763520e302ae41a1ad`.
