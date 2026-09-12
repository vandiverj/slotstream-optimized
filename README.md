# Slotstream Optimized

A private, standalone copy of Slotstream for running Qwen3.8-Flash-Next locally on Apple Silicon. It saves the selected 78 GB and approximately 30 GB configurations as separate engines. This repository does not track or automatically incorporate upstream Slotstream updates.

| Profile | Engine source | Intended use |
| --- | --- | --- |
| `78gb` | Root `Sources/` | Qualified full-resident configuration on the 128 GB M5 Max. Adaptive MTP, attention blocking, GPU resident expert routing, and compiled GDN gates. |
| `30gb` | `engines/30gb/` | Selected approximately 30 GB reference configuration. Measured on the M5 Max; validation on the 48 GB M4 Pro work machine is still pending. |

These names describe approximate process footprints, not hard memory caps. The 78 GB profile is unsuitable for a 48 GB machine. Both profiles keep conversation caching off and use a 32,768-token context setting; memory and quality qualification do not cover every possible prompt or context length.

## Setup

Use an Apple Silicon Mac with a Swift 6 toolchain, Python 3, and enough SSD space for the full model weights and build dependencies. macOS 26 is the environment used for qualification. The source supports older macOS versions, but those environments have not been qualified here.

Clone this private repository while authenticated to GitHub:

```sh
gh repo clone vandiverj/slotstream-optimized
cd slotstream-optimized
```

Build the profile you need:

```sh
./scripts/build.sh 78gb
# Or, for the smaller configuration:
./scripts/build.sh 30gb
```

Builds use the committed `Package.resolved` files and fetch a checksum-pinned MLX Metal library. They do not download or update Slotstream source. Run builds sequentially and without a model process running. No prebuilt executable or model weights are stored in Git.

## Download the model

Both profiles use the same full model files. The smaller memory profile streams more experts from SSD; it is not a smaller download. Either built executable can download the pinned model:

```sh
.build/release/slotstream pull
# If you built only 30gb:
engines/30gb/.build/release/slotstream pull
```

The default location is `~/.slotstream/models/qwen38-flash-next-mlx-4bit`. Existing model files can be reused by passing their directory when launching. To verify an existing download without downloading anything:

```sh
.build/release/slotstream pull --verify --dir /path/to/qwen38-flash-next-mlx-4bit
```

The download uses the model distribution endpoints pinned in the source. Those external files and Swift dependencies remain necessary; this repository intentionally contains neither weights nor vendored dependency downloads.

## Run

```sh
python3 scripts/serve.py --profile 78gb
# On the smaller-memory machine:
python3 scripts/serve.py --profile 30gb
```

To reuse an existing model directory or change the port:

```sh
python3 scripts/serve.py --profile 78gb --model /path/to/qwen38-flash-next-mlx-4bit --port 11434
```

The launcher selects the matching engine, clears inherited inference overrides, applies the saved settings, and checks available memory before starting. It refuses to start alongside another `slotstream` process. That startup check does not impose a runtime memory cap. Allow headroom for other applications and run only one model instance at a time.

The server listens on `127.0.0.1:11434`. Use the OpenAI-compatible base URL `http://127.0.0.1:11434/v1`, or the Ollama-compatible API at the same host. The model name is `qwen3.8-flash-next:4bit`. Stop the foreground server with Ctrl-C.

To inspect settings without loading weights:

```sh
python3 scripts/serve.py --profile 78gb --dry-run
python3 scripts/serve.py --profile 30gb --dry-run
```

The qualification requests used temperature 0, top_p 1, top_k 0, presence_penalty 0, seed 42, and reasoning disabled. These are request parameters; the launcher does not force them on clients.

## Call from a hook or agent client

The experiment/testing harness is not needed. The model host needs this repository, a built profile, and the downloaded weights. A client only needs to send HTTP requests; it does not need a copy of the weights or engine source.

For example, a hook can call the server directly:

```sh
curl --fail-with-body http://127.0.0.1:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-flash-next:4bit","messages":[{"role":"user","content":"Review this proposed API design: ..."}],"stream":false,"max_tokens":1024,"temperature":0,"top_p":1,"top_k":0,"presence_penalty":0,"seed":42,"reasoning_effort":"none"}'
```

Read the answer from `choices[0].message.content`. The calling hook or agent remains responsible for deciding what context to send and how to use the answer. OpenAI-compatible clients can use the `/v1` base URL.

The server binds to localhost. To call a model running on another Mac, start it there and open an SSH tunnel from the client computer:

```sh
ssh -N -L 11435:127.0.0.1:11434 your-user@model-mac
```

Then call `http://127.0.0.1:11435/v1/chat/completions` on the client. This requires SSH access to the model Mac. The client can run on a different operating system; the model server still requires Apple Silicon macOS.

A Claude Code hook can make this separate HTTP call. Replacing Claude Code's primary model with Qwen is a different integration: this saved server exposes OpenAI/Ollama formats, not `/v1/messages`. That use requires a compatible API adapter and integration testing; see [Claude Code gateway requirements](https://code.claude.com/docs/en/llm-gateway). No such adapter is included here.

## Verify the saved source

```sh
python3 scripts/verify_sources.py
.build/release/slotstream-checks --tier t0
engines/30gb/.build/release/slotstream-checks --tier t0
```

Run only the check commands for profiles you have built. These lightweight checks do not load the model. `provenance/` records exact source hashes and the original qualified executable hashes. Rebuilt executables can have different hashes because compiler versions and build paths differ. Source identity and a passing build do not extend the original hardware or workload qualification.

There are no experiment directories, performance-study results, automatic release workflows, or upstream sync jobs in this repository. The two engines deliberately remain separate: applying the 30 GB settings to the 78 GB executable would not reproduce the saved 30 GB version.

## Attribution

Derived from [Slotstream by Carlos Galarza](https://github.com/carloslfu/slotstream), under the MIT license. The original copyright and permission notice are retained in [LICENSE](LICENSE). Local modifications select the qualified full-resident optimization paths and add profile-specific packaging and launch instructions. This is an independent private repository, not an upstream-maintained release.
