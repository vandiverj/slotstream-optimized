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
