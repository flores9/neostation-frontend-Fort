# NeoStation Fort - Upstream maintenance strategy

NeoStation Fort is maintained as a small, testable overlay on top of upstream NeoStation. The upstream application will continue evolving, so Fort must be able to adopt any future upstream release without blindly carrying obsolete custom code.

## Core rule

For every upstream update, ask first: **does upstream now provide this Fort behavior?**

- If yes and behavior is sufficient, adopt upstream and remove or reduce the Fort implementation.
- If partially, keep only the delta needed to satisfy the Fort contract.
- If no, port the Fort feature deliberately onto the new upstream base.

Never preserve a Fort patch merely because it existed in the previous release.

## Version/base record

Every Fort release/checkpoint should record:

- upstream repository and tag/commit;
- Fort branch and commit;
- Flutter/Dart/JDK/Android toolchain versions;
- list of active Fort features;
- list of upstream-equivalent features removed/adapted;
- integration/patch points;
- contract tests;
- device validation result;
- APK/source hashes.

## Update procedure

1. **Freeze the current known-good checkpoint.**
   Keep its delivery ZIP/source commit and validation notes available for comparison.

2. **Inspect upstream changes before merging/rebasing.**
   Review release notes, commits and changes in files touched by Fort.

3. **Create a new integration branch from the selected upstream base.**
   Do not overwrite the previous validated Fort branch.

4. **Build a Fort feature-equivalence matrix.**

   Suggested columns:

   - Fort feature/contract;
   - previous Fort implementation;
   - upstream implementation in new base;
   - status: upstream / partial / Fort required;
   - files/integration points;
   - tests to retain/adapt/remove;
   - migration notes.

5. **Port the smallest necessary delta.**
   Prefer modular services, adapters and focused UI hooks. Avoid copying whole upstream modules unless unavoidable.

6. **Resolve schema/config migrations explicitly.**
   Preserve user data. Do not infer deletion merely from unavailable removable storage or permission loss.

7. **Run quality gates.**
   At minimum:

   - dependency lock verification;
   - formatting;
   - analyzer/static checks;
   - upstream-compatible test suite;
   - all Fort contract tests;
   - Android ARM64 release build.

8. **Validate on AYN Thor.**
   Test the changed upstream behavior and every Fort feature affected by the port.

9. **Only after validation:**
   update continuity/roadmap/release notes, create permanent-signed final build, verify certificate/hash, then merge/tag/release with explicit approval.

## Fort R1 integration areas to watch in future upstream updates

- Android application identity/signing configuration.
- ES-DE config/path resolution.
- ROM scanner and removal/pruning logic.
- gamelist import/metadata merge behavior.
- FileProvider/media resolution and write targets.
- per-system settings UI.
- database/config service interfaces.
- second-screen/display lifecycle as future Fort features are added.

The authoritative list must always come from comparing the actual Fort commit with its upstream base; this document is guidance, not a substitute for the diff.

## Release package principle

Every approved checkpoint should be recoverable without relying on chat history. The delivery ZIP should contain at least:

- installable APK appropriate to that checkpoint;
- source snapshot from the exact Git commit;
- Fort documentation;
- TODO/roadmap;
- continuity prompt;
- build manifest and recent Git history;
- upstream base diff summary;
- SHA-256 manifest;
- build/signing status clearly labelled.

Never include keystores, passwords, `key.properties`, SDK caches, `.git`, build caches or other secrets/local-only material in the source snapshot.
