# Standalone ACD baseline

This private repository has one ACD engine in Sources/ and two runtime profiles.
The user selected ACD as the baseline for both 30 GB and 78 GB on 2026-09-12.
Do not restore the old30GB engine or sync/merge upstream updates.
Preserve LICENSE and original attribution. Keep model weights, experiment harnesses,
raw benchmark histories, generated builds, credentials and local paths out of Git.

ACD means adaptive MTP, attention 256, compiled GDN gates. Both profiles use the
same binary.30GB uses 152 experts and full-resident mode off;78GB uses 512 and both.
Profiles and scripts/serve.py are the supported entrypoint; raw CLI defaults do
not select ACD. provenance/acd.json pins source identity. Source changes require
new evidence and intentional provenance updates; a build is not qualification.

Read README.md, docs/CONFIGURATION.md and docs/FINDINGS.md. Build once with
scripts/build.sh (either profile argument uses the same engine). Verify with
scripts/verify_sources.py and .build/release/slotstream-checks --tier t0.
Never overlap model processes or a model and a large build; check headroom first.
48GB work-Mac qualification is pending. No automatic deployment or release jobs.
