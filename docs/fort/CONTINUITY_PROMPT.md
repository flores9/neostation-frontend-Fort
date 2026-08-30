# Continuity prompt - NeoStation Fort

Use this document to resume work in a fresh ChatGPT conversation without mixing NeoStation Fort with ES-DE Companion Fort.

## Project identity

Repository: `flores9/neostation-frontend-Fort`
Upstream: `misobadev/neostation-frontend`
Fork purpose: maintained NeoStation fork, initially focused on robust ES-DE integration for Android handhelds and multi-volume libraries.

This project is completely separate from `flores9/ESDE-Companion-JAA` / ES-DE Companion Fort, although tested UX/contracts from Companion Fort may be adapted deliberately when useful.

## Permanent upstream-maintenance rule

NeoStation Fort must remain maintainable on top of future upstream NeoStation releases.

For every new upstream release:

1. inspect the new upstream tag/commit and compare it with the current Fort base;
2. check whether each Fort feature now exists upstream;
3. prefer the upstream implementation when it satisfies the Fort requirement;
4. keep only the still-needed Fort delta when upstream is partial;
5. port Fort modularly onto the new base when upstream still lacks the feature;
6. rerun contract tests and AYN Thor validation before changing the validated base.

Never keep obsolete Fort patches merely for compatibility with an older fork state. See `UPSTREAM_MAINTENANCE.md`.

## Branch policy

- Keep `main` clean until a release candidate is locally validated.
- R1 development branch: `fort/esde-integration-r1`.
- Initial upstream base SHA: `58e94a65788a800db8805d622fa88dc8bf485877`.
- Bring upstream changes deliberately; do not overwrite Fort work by syncing blindly.

## Current R1 status

A technical ARM64 APK has been built successfully on Windows from commit:

`c69e2742f250f065f18148869647cf260047a838`

The successful build produced:

`dist/NeoStation-Fort-R1/NeoStation-Fort-R1-arm64-v8a.apk`

That APK was built with `-AllowDebugSigning`, so it is a disposable technical validation APK, not the permanent-signed final release.

AYN Thor validation is the active gate. Do **not** merge to `main`, tag, publish a GitHub release, or call R1 final until device validation passes and the user explicitly approves.

Subsequent documentation/tooling commits may move branch HEAD beyond the APK source commit. Always distinguish:

- APK source commit;
- current documentation/tooling branch HEAD.

If a new APK is built, update this section and the release notes/checklist accordingly.

## Authoritative release process

Android release APKs are compiled locally on Windows, not via GitHub Actions, to avoid consuming Actions time.

Normal full gate:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\fort_local_release.ps1 -AllowDebugSigning
```

Use `-SkipTests -SkipAnalyze` only when those gates already passed on the exact same source commit and a retry is solely recovering from an external SDK/tooling failure.

A release is not publishable until format, analyze, tests, ARM64 release build and manual AYN Thor validation pass. Permanent Android signing material stays local and is never committed.

Every approved checkpoint should include source snapshot, APK, SHA-256, docs, roadmap/TODO, continuity prompt, upstream-base information and build status.

Project checkpoint packager:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\fort_package_checkpoint.ps1
```

This packages an already-built APK plus an exact `git archive` source snapshot of current `HEAD`; it never includes `.git`, caches or signing secrets.

## Local toolchain established during R1

- Flutter pinned by `.fvmrc`: `3.47.1`.
- JDK 17 was detected at `C:\Program Files\Eclipse Adoptium\jdk-17.0.20.8-hotspot` on the current build machine.
- Android SDK used by NeoStation Fort: `C:\Android`.
- Android command-line tools available from the older Companion Fort SDK at `%USERPROFILE%\.android\sdk\cmdline-tools\latest\bin\sdkmanager.bat` and can manage packages in `C:\Android` via `--sdk_root`.
- Required NDK for Flutter 3.47.1: `28.2.13676358`.

Do not assume these machine-local paths on another PC; the release script performs its own Java/Flutter detection.

## R1 functional contract

1. Read `ES-DE/settings/es_settings.xml`.
2. Honor `ROMDirectory` and `MediaDirectory` independently.
3. Read `ES-DE/custom_systems/es_systems.xml`.
4. Resolve `%ROMPATH%`; never guess it if the base is unavailable.
5. Support ROMs distributed between AYN Thor internal storage and microSD.
6. Find both central and ROM-local `gamelist.xml` files.
7. Reuse ES-DE media in place, read-only.
8. Manual per-platform overrides: ROM directory, media directory, gamelist file.
9. Each manual field wins over its automatic equivalent and can be reset independently.
10. Missing removable storage/permission must preserve stored games rather than prune them.
11. Fort must be installable beside upstream NeoStation.

## User's real ES-DE environment

Known setting:

```xml
<string name="MediaDirectory" value="/storage/14F5-471E/ROMs" />
<bool name="LegacyGamelistFileLocation" value="false" />
```

ES-DE root is normally under internal storage. ROMs are split between internal storage and microSD using ES-DE system paths. The concrete microSD UUID in the current device is `14F5-471E`.

Do not hardcode those paths in product logic; they are test fixtures/examples only.

## Fort configuration design

Automatic ES-DE resolution is implemented by `lib/services/esde_config_resolver.dart`.

Manual per-system overrides are deliberately outside upstream SQLite migrations:

```text
<NeoStation Fort user-data>/fort/system-path-overrides.json
```

Service: `lib/services/fort_system_path_service.dart`.

This is intentional to reduce future conflicts with upstream database schema versions.

## Android fork identity

```text
namespace      = com.neogamelab.neostation
applicationId  = com.neogamelab.neostation.fort
app name       = NeoStation Fort
```

Keep namespace compatibility unless native source is migrated deliberately. The unique applicationId is required so Fort can coexist with upstream NeoStation and use separate app-private data/signing.

## Media precedence

NeoStation-owned scraped artwork retains upstream display priority. Among external sources:

```text
manual per-system media root
  -> automatically resolved ES-DE MediaDirectory
  -> standard ES-DE downloaded_media fallback
```

ES-DE media is never a write destination.

## R1 implementation now present

Before continuing, inspect actual branch `HEAD` and recent commits rather than trusting this document blindly. R1 currently includes:

- ES-DE config resolver and multi-volume tests;
- importer changes for central + ROM-local gamelist discovery;
- MediaDirectory-aware read-time media fallback;
- POSIX/Android ES-DE path handling independent of Windows host separators;
- Fort JSON persistence for per-system overrides;
- exact per-system ROM scanner integration with no-prune-on-unavailable behavior;
- manual ROM/media/gamelist override integration;
- per-platform UI for ROM/media/gamelist with detected/automatic values and independent reset;
- separate Android applicationId/app name;
- read-only ES-DE media/write-destination contract tests;
- host-aware Windows test gate with deterministic batching/isolation;
- reproducible local release tooling;
- technical ARM64 APK built successfully;
- Fort documentation, roadmap and upstream-maintenance strategy.

Active remaining R1 work:

- AYN Thor device validation;
- especially verify SAF/removable-SD behavior for ES-DE absolute `/storage/<UUID>/...` paths;
- update completed test plan/release notes after device evidence;
- permanent Fort signing only after technical validation;
- verify permanent certificate/hash;
- merge/tag/release only with explicit approval.

## Future roadmap already captured

See `TODO_ROADMAP.md`. Current ideas include:

- optional XML/gamelist-authoritative library mode: do not show games outside XML sources;
- metadata filters;
- custom collections;
- configurable fanart/boxart and broader media fallback;
- logos/marquees view;
- music;
- screensaver;
- enhanced second screen that stays awake, supports video and useful presentation while gaming;
- deterministic return from video to the beginning of the fanart/media cycle;
- advanced multi-screen pages/transitions inspired by ES-DE Companion Fort but adapted to NeoStation architecture.

## Resume instruction

When resuming, first inspect the current GitHub branch/head, recent commits, Fort docs and the exact APK source commit. Continue from the unfinished device-validation/signing gate without asking the user to repeat documented requirements. Check current upstream NeoStation before starting any new Fort feature. Do not publish or merge until validation evidence and explicit approval are available.
