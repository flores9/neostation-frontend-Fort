# Continuity prompt - NeoStation Fort

Use this document to resume work in a fresh ChatGPT conversation without mixing NeoStation Fort with ES-DE Companion Fort.

## Project identity

Repository: `flores9/neostation-frontend-Fort`
Upstream: `misobadev/neostation-frontend`
Fork purpose: maintained NeoStation fork, initially focused on robust ES-DE integration for Android handhelds and multi-volume libraries.

This project is completely separate from `flores9/ESDE-Companion-JAA` / ES-DE Companion Fort.

## Branch policy

- Keep `main` clean until a release candidate is locally validated.
- R1 development branch: `fort/esde-integration-r1`.
- Initial upstream base SHA: `58e94a65788a800db8805d622fa88dc8bf485877`.
- Bring upstream changes deliberately; do not overwrite Fort work by syncing blindly.

## Authoritative release process

Android release APKs are compiled locally on Windows, not via GitHub Actions, to avoid consuming Actions time.

Use:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\fort_local_release.ps1
```

A release is not publishable until format, analyze, tests, ARM64 release build and manual AYN Thor validation pass. Permanent Android signing material stays local and is never committed.

Every published release must include source/tag, APK, SHA-256, release notes and a delivery ZIP with the Fort documentation, continuity prompt and completed test plan.

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
namespace     = com.neogamelab.neostation
applicationId = com.neogamelab.neostation.fort
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

## Current implementation checkpoints

Before continuing, inspect the head of `fort/esde-integration-r1` rather than trusting this document blindly. At the time this continuity file was introduced, the branch already contained:

- ES-DE config resolver and multi-volume tests.
- importer changes for central + ROM-local gamelist discovery.
- MediaDirectory-aware read-time media fallback.
- Fort JSON persistence for per-system overrides.
- manual media override loading in FileProvider.
- separate Android applicationId/app name.
- local PowerShell release tooling and Fort documentation.

Still verify/complete before R1:

- exact per-system ROM scanner integration with no-prune-on-unavailable behavior;
- manual gamelist override integration;
- per-platform UI for ROM/media/gamelist with detected source + reset;
- analyzer/test/build fixes from the first local compilation;
- version/tag/release notes;
- final local signed APK, completed Thor test plan and delivery ZIP;
- merge into fork main only after validation.

## Resume instruction

When resuming, first inspect current GitHub branch/head, recent commits, open diffs and docs. Continue the unfinished R1 contract without asking the user to repeat already documented requirements. Do not publish a release or merge to main until local validation evidence is available.
