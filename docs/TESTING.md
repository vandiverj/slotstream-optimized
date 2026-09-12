# Verification

Run one model process at a time. Never run a large build alongside a model.
Check process activity and memory headroom before starting; use the supported
profile launcher for model runs. Neither the native T0 suite nor the launcher
regressions download weights.

```sh
python3 scripts/verify_sources.py
./scripts/build.sh 30gb
.build/release/slotstream-checks --tier t0
.build/release/slotstream-checks --tier t1
python3 scripts/test_launchers.py
python3 scripts/test_supervisor.py
python3 scripts/serve.py --profile 30gb --dry-run
python3 scripts/serve.py --profile 78gb --dry-run
```

`build.sh 78gb` selects the same engine. Source edits require an intentional
provenance update; preserve `baseline_source_files` and the historical qualified
binary hash. A new active source hash is not new performance qualification.

The launcher regression script has seven tests; the supervisor adds six model-free
process tests for retry bounds, child reaping, preflight refusal and stop cleanup.
Launcher checks include build/model lock contention,
child-process lock inheritance, failure cleanup and unsafe lock-file rejection and watchdog argument validation.
The HTTP native checks cover malformed framing, absolute upload deadlines,
nonblocking writes under backpressure and peer closure without model allocation.

The shipped catalogue uses a plain native executable rather than XCTest. T0
contains model-free policy, parsing, image and local OS/socket checks. T1 contains
small MLX staging-ownership, sampler and vision-splice checks and requires Metal. T2–T4 names are
reserved in the runner but currently have no catalogue entries; selecting an
empty tier fails instead of reporting success. Model parity and other heavyweight
checks are separate CLI subcommands; inspect `slotstream --help` before running.
There is no automatic CI or release job configured in this private package.

For a running supported profile, `python3 scripts/check_api.py` verifies a real
completion. Stop it before launching the other profile. This health check does
not qualify model quality, context capacity, cancellation latency or performance.

Optional native heap inspection (without a model):

```sh
leaks -quiet -atExit -- .build/release/slotstream-checks --tier t0 --filter http
leaks -quiet -atExit -- .build/release/slotstream-checks --tier t0
```

The earlier corrupt-PNG retain cycle is now rejected before ImageIO and the full
T0 heap scan reports zero leaked bytes on the review machine. This is finite
evidence under macOS inspection restrictions; see [the review](PRODUCTION_REVIEW.md).
Do not reinterpret a nonzero future leak result as a passing leak check.
