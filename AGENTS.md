# Standalone optimized Slotstream

This private repository contains two pinned engines, not an upstream-tracking fork.
Do not sync or merge upstream updates. Preserve LICENSE and original attribution.
Do not add experiment directories, benchmark histories, local binaries, model weights,
credentials, or machine-specific paths to Git.

The root Sources and Package files are the qualified 78 GB engine. engines/30gb
contains the distinct 30 GB reference engine. Never substitute one for the other.
Profiles and scripts/serve.py hold the exact launch settings; avoid incidental changes.
provenance/*.json records source identity. An intentional engine change requires a
new qualification and provenance update; a successful build alone is not qualification.

Build sequentially with scripts/build.sh PROFILE. Run scripts/verify_sources.py and
.build/release/slotstream-checks --tier t0 (or the corresponding 30 GB path).
Never overlap model processes or run a large build alongside an owned model process.
Check reclaimable memory before heavy work. Keep model downloads outside Git.
No automated deployment or upstream release workflow is configured.
