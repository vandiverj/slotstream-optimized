# Slotstream Optimized — ACD baseline

Run Qwen3.8-Flash-Next locally on Apple Silicon using one ACD engine and two memory
profiles. ACD enables adaptive MTP,256-token attention blocks and compiled GDN gates.
This is an independent private copy of Slotstream; upstream updates are not tracked.

| Profile | Intended machine | Expert cache |
| --- | --- | --- |
| `30gb` |48GB work Mac; validation there pending |152 experts per layer, SSD streaming |
| `78gb` |128GB M5 Max; qualified here |512 experts per layer, full-resident paths |

Both profiles use the same executable and full model. Memory names are approximate
footprints, not hard caps. Use30gb on the 48 GB machine. Model weights are **not included**
and are downloaded separately from the model distribution source.

## Install on the work Mac

Requirements: Apple Silicon, Python 3, Git, and a Swift 6 toolchain. Install Xcode
Command Line Tools with `xcode-select --install` if needed, then check
`swift --version` and `python3 --version`. macOS 26 was tested; other supported macOS
versions have not been qualified. Allow roughly 110 GB for model files plus extra
space for download staging and build dependencies.

Clone while authenticated to this private GitHub repository (GitHub CLI shown):

```sh
gh repo clone vandiverj/slotstream-optimized
cd slotstream-optimized
./scripts/build.sh 30gb
```

Alternatively use your authenticated Git client or extract the source archive.
Build once: `build.sh 30gb` and `build.sh 78gb` produce the same ACD executable.
Dependencies use the committed Package.resolved; the build fetches a checksum-pinned
MLX Metal library. It does not fetch Slotstream updates or model weights.
Build without a model process running.

Download the model separately using the built downloader:

```sh
.build/release/slotstream pull
```

This downloads from the distribution endpoints pinned in source into
`~/.slotstream/models/qwen38-flash-next-mlx-4bit`. Both profiles use these files.
To verify separately obtained compatible weights:

```sh
.build/release/slotstream pull --verify --dir /path/to/qwen38-flash-next-mlx-4bit
```

Start the 30 GB ACD baseline:

```sh
python3 scripts/serve.py --profile 30gb
```

For an existing model directory, or the larger profile:

```sh
python3 scripts/serve.py --profile 30gb --model /path/to/qwen38-flash-next-mlx-4bit
python3 scripts/serve.py --profile 78gb --model /path/to/qwen38-flash-next-mlx-4bit
```

These are alternatives: run only one instance. Stop it with Ctrl-C. The launcher
applies ACD settings, clears inherited inference overrides and checks memory
headroom. A failed headroom check means free memory before retrying. Startup
headroom is not a runtime cap. Direct `slotstream serve` uses CLI defaults, so use
the profile launcher for this baseline.

## Check the installation

```sh
python3 scripts/verify_sources.py
.build/release/slotstream-checks --tier t0
python3 scripts/serve.py --profile 30gb --dry-run
```

With the server running, from another terminal:

```sh
python3 scripts/check_api.py
```

Expect `API check passed` and a short answer. This checks connectivity and a real
completion; it does not qualify every software task or the full context limit.
If the port is occupied, use `serve.py --port 11435` and
`check_api.py --base-url http://127.0.0.1:11435`.

## Use from a hook or agent harness

No experimental harness is needed. The model host needs this package, its build
and the separate weights. A client needs only HTTP access.

OpenAI-compatible base URL: `http://127.0.0.1:11434/v1`.
Ollama-compatible API: `http://127.0.0.1:11434`.
Model name: `qwen3.8-flash-next:4bit`.

```sh
curl --fail-with-body http://127.0.0.1:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-flash-next:4bit","messages":[{"role":"user","content":"Review this proposed API design: ..."}],"stream":false,"max_tokens":1024,"temperature":0,"top_p":1,"top_k":0,"presence_penalty":0,"seed":42,"reasoning_effort":"none"}'
```

Read `choices[0].message.content`. The caller supplies repository context and
controls how the answer is used. Sampling parameters are request settings; the
launcher does not force them. Both profiles have prefix caching disabled and a
32768-token maximum context setting.

The server binds to localhost. From another machine, use an SSH tunnel:

```sh
ssh -N -L 11435:127.0.0.1:11434 your-user@model-mac
```

Then call `http://127.0.0.1:11435/v1/chat/completions`. A Claude Code hook can make
this separate HTTP request. The server does not expose Anthropic `/v1/messages`;
replacing a primary model through that protocol would require an adapter, which
is not included.

## Configuration and findings

- [Exact profiles and baseline policy](docs/CONFIGURATION.md)
- [Consolidated performance findings and limitations](docs/FINDINGS.md)
- [Package validation](docs/VALIDATION.md)
- [Verification commands](docs/TESTING.md)
- [Production review and remaining risks](docs/PRODUCTION_REVIEW.md)
- [Source provenance](provenance/acd.json)

The 30 GB ACD software study passed all original quality checks on this M5 Max;
validation on the actual 48 GB work Mac remains pending. Rebuilt binary hashes can
differ by compiler/build path. Source identity and a successful build do not
extend the original hardware qualification.

This package contains one source tree, two profiles, installation/health scripts,
license and documentation. It contains no model weights, experiment configurations,
raw benchmark histories or candidate builds. No upstream-sync or deployment job
is configured. Existing clones with an old `engines/30gb/.build` may delete that
obsolete build directory after updating; both profiles now use the root build.

## Attribution

Derived from [Slotstream by Carlos Galarza](https://github.com/carloslfu/slotstream)
under the MIT license. Original attribution and permission are retained in
[LICENSE](LICENSE). Local modifications implement the selected ACD paths and
provide standalone packaging. This is not an upstream-maintained release.
