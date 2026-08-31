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

## Branch policy and upstream state

- Keep `main` clean until a release candidate is locally validated.
- Original R1 branch: `fort/esde-integration-r1`.
- Active integration branch: `fort/esde-integration-r1-v0.11.5`.
- Initial upstream-derived Fort base: `58e94a65788a800db8805d622fa88dc8bf485877`.
- Official NeoStation release integrated deliberately: `v0.11.5+127`, tag `e988626b79ac2335463ef7c550884c21531adb21`.
- Upstream integration merge on the active branch: `0e958a9e45d9116748bac54419696b95b0e91644`.
- Functional source checkpoint after the platform-identity/selector work and before documentation-only commits: `8a207d44e99539d76ad795dc53735e38eb831462`.
- Bring upstream changes deliberately; do not overwrite Fort work by syncing blindly.

The `v0.11.5+127` delta from the old Fort base was very small. The ES-DE media-format expansion and Android SAF false-empty fix advertised in the release were already present in the August 28 source base used by Fort. This confirms that the maintained-overlay strategy is working and a new fork is not required for each upstream release.

## Current R1 build status

The last technical ARM64 APK was built successfully on Windows from the **older** commit:

`c69e2742f250f065f18148869647cf260047a838`

It produced:

`dist/NeoStation-Fort-R1/NeoStation-Fort-R1-arm64-v8a.apk`

That APK was built with `-AllowDebugSigning`, so it is a disposable technical validation APK, not the permanent-signed final release.

Critically, that APK predates the current platform-identity and ES-DE selector fixes. Do not use its behavior as evidence that the current branch is fixed or broken until a new APK is built from the active integration branch.

AYN Thor validation is the active gate. Do **not** merge to `main`, tag, publish a GitHub release, or call R1 final until device validation passes and the user explicitly approves.

## Authoritative release process

Android release APKs are compiled locally on Windows, not via GitHub Actions, to avoid consuming Actions time.

Normal full gate:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\fort_local_release.ps1 -AllowDebugSigning
```

Use `-SkipTests -SkipAnalyze` only when those gates already passed on the exact same source commit and a retry is solely recovering from an external SDK/tooling failure. The current integration branch has new unvalidated source, so the next run must use the full gate.

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

## Definitive library/emulation identity contract

The platform model was clarified after real-device duplicate-platform evidence.

**ES-DE determines which library platforms exist. NeoStation system JSONs determine how those platforms are emulated. Fort maps the two.**

Examples:

```text
ES-DE amstradcpc -> NeoStation cpc profile
ES-DE gx4000     -> NeoStation cpc profile
```

Rules:

1. A NeoStation `folder_name` or alias is not, by itself, evidence that an ES-DE library platform exists.
2. NeoStation aliases may be used to map an already evidenced ES-DE platform to a canonical emulator profile.
3. Several real ES-DE systems may inherit one NeoStation profile while retaining independent ROM/gamelist/media namespaces.
4. Do not fix duplicates by editing or cloning `assets/systems/*.json` platform definitions.
5. Do not deduplicate merely by display name; two real ES-DE systems may legitimately share/approximate labels.
6. Platform creation must be driven by evidence such as a manual Fort override, explicit ES-DE system definition, central/ROM-local gamelist, ES-DE media namespace, or verified concrete ROM source.
7. If ownership between real sibling platforms is ambiguous, never guess.

The current implementation is in `lib/services/fort_esde_scan_plan_service.dart` plus `lib/services/fort_esde_platform_reconciler.dart`.

Evidence order in the current scan plan is approximately:

```text
manual override
  > explicit ES-DE system declaration
  > gamelist evidence
  > media namespace evidence
  > physically verified ROM directory
```

A weak canonical NeoStation fallback such as `cpc` is suppressed when stronger ES-DE identity evidence such as `amstradcpc` exists.

## Safe reconciliation of duplicate platforms from older Fort APKs

Previous technical builds could persist alias-driven rows in `fort_esde_library_platforms` and `user_roms.fort_esde_system_name`.

Current reconciliation rules:

- never delete `user_roms` merely to clean a Fort platform identity;
- preserve favourites, playtime and game metadata;
- retag old Fort provenance when one concrete ES-DE destination is proven by root/path evidence;
- if a stale canonical NeoStation alias such as `cpc` is known to be a phantom but its sibling ownership cannot be proven, clear only its Fort provenance and remove the phantom overlay row;
- keep non-canonical ambiguous stale provenance rather than guessing;
- allow a later concrete rescan to establish correct ownership.

The first new AYN Thor validation APK should therefore be installed **over the previous Fort technical APK**, not only clean-installed, so this migration path is exercised.

## ES-DE selector correction

The settings screen previously inherited an upstream assumption that ES-DE import required at least one normal NeoStation ROM directory. That is incompatible with Fort.

Current source behavior:

- `Select ES-DE Folder` is enabled even with zero normal NeoStation ROM folders;
- only `Run Import` requires a configured ES-DE root;
- the Android ES-DE selector no longer uses the NeoStation user-data destination resolver, which could redirect a selected source into `Android/data/<package>/user-data`;
- the selected filesystem root is validated as ES-DE using `settings/es_settings.xml`, `custom_systems/es_systems.xml` or `gamelists`;
- selecting a valid ES-DE root triggers the ROM scan needed before metadata matching;
- ES-DE can therefore be the first/only library source.

The setup wizard already requires broad Android storage permission before its folder step and can resolve the selected ES-DE root to a physical path. Raw `content://` ES-DE-root support without a physical-path mapping would require teaching the config/import layers to read the whole ES-DE tree through SAF; that is not claimed as implemented in R1.

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
12. ES-DE may be the only configured library source; a normal NeoStation ROM folder is optional.
13. Library platform identity comes from ES-DE evidence; NeoStation aliases only resolve emulation profiles.
14. Updating from an older Fort build must clean provably phantom canonical platform aliases without deleting games or user metadata.

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

The Fort library overlay keeps concrete ES-DE identity separate from the NeoStation profile:

```text
fort_esde_library_platforms.esde_system_name = concrete ES-DE platform
fort_esde_library_platforms.app_system_id    = canonical NeoStation emulator profile
user_roms.fort_esde_system_name              = concrete Fort/ES-DE provenance
```

This is intentional to reduce upstream schema conflicts while preserving independent sibling namespaces.

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
  -> standard ES-DE fallback behavior
```

ES-DE media is never a write destination.

## R1 implementation now present

Before continuing, inspect actual branch `HEAD` and recent commits rather than trusting this document blindly. Current source includes:

- official NeoStation `v0.11.5+127` integration on the isolated Fort branch;
- ES-DE config resolver and multi-volume tests;
- importer changes for central + ROM-local gamelist discovery;
- MediaDirectory-aware read-time media fallback;
- Fort JSON persistence for per-system overrides;
- exact per-system/multi-sibling scanner integration with no-prune-on-unavailable behavior;
- manual ROM/media/gamelist override integration;
- separate Android applicationId/app name;
- ES-DE-as-only-source settings correction;
- ES-DE-authoritative platform identity instead of alias-driven creation;
- stale canonical alias reconciliation that preserves ROM/user data;
- regression tests for canonical suppression, real sibling preservation and ambiguous migration safety;
- reproducible local release tooling;
- Fort documentation, roadmap and upstream-maintenance strategy.

## Active remaining R1 work

- run the **full local Windows gate** on the current branch: format, analyze, full tests, ARM64 release build;
- fix any compile/analyze/test regressions found by that gate before creating the next technical APK;
- install the next technical APK over the old Fort APK on AYN Thor to test migration;
- verify Settings > Directories can select ES-DE with zero normal ROM folders;
- verify duplicate platform cleanup and legitimate sibling preservation;
- verify media remains platform-scoped;
- verify internal + microSD ROM paths and missing-SD no-prune behavior;
- update test-plan evidence from the device;
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

When resuming, first inspect the current GitHub branch/head, recent commits, Fort docs and the exact APK source commit. Continue from the unfinished **local build/test -> AYN Thor upgrade validation -> signing** gate without asking the user to repeat documented requirements. Check current upstream NeoStation before starting any new Fort feature. Do not publish or merge until validation evidence and explicit approval are available.
