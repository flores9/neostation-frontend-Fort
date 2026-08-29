# NeoStation Fort R1 - Candidate release notes

Status: **development / local validation required**. Do not publish as a final release until the Windows build and AYN Thor test plan pass.

Upstream base: `58e94a65788a800db8805d622fa88dc8bf485877`
Development branch: `fort/esde-integration-r1`

## Purpose

R1 makes NeoStation a first-class consumer of an existing ES-DE library instead of assuming ES-DE uses its default ROM/media layout.

## Added

- ES-DE settings resolver for `settings/es_settings.xml`.
- `ROMDirectory` support.
- `MediaDirectory` support.
- `custom_systems/es_systems.xml` support.
- `%ROMPATH%` expansion without guessing missing bases.
- Per-system absolute ROM paths, including systems split across internal storage and microSD.
- Modern central plus ROM-local `gamelist.xml` discovery.
- Manual per-system Fort overrides for:
  - ROM Directory
  - Media Directory
  - Gamelist File
- Independent Reset for each manual override.
- Fort path editor from each system's settings dialog.
- Fort-owned JSON persistence outside upstream SQLite migration numbering.
- Removable-storage protection: an inaccessible exact system source preserves existing ROM rows instead of pruning them.
- Local PowerShell release build tooling.
- One-time permanent signing setup tooling.
- R1 manual test plan and continuity documentation.

## Media behavior

ES-DE media remains read-only. NeoStation Fort resolves the user's effective ES-DE `MediaDirectory` and consumes artwork/video in place.

NeoStation-owned scraped media keeps upstream's existing visual priority. External fallback order is:

1. manual per-system media override;
2. automatically resolved ES-DE media;
3. no external asset / normal NeoStation fallback behavior.

The existing mappings remain:

- NeoStation `box2d` -> ES-DE `covers`, then `3dboxes`;
- `wheels` -> `marquees`;
- `screenshots` -> `screenshots`, then `titlescreens`;
- `fanarts` -> `fanart`;
- `videos` -> `videos`.

## ROM behavior

For each platform the exact source priority is:

1. manual Fort ROM Directory;
2. explicit ES-DE custom-system `<path>`;
3. ES-DE `ROMDirectory/<system>` when present/accessible;
4. normal NeoStation global ROM roots.

A valid exact source is scanned by the existing NeoStation scanner, preserving upstream extension rules, recursion, M3U handling, deduplication and specialized metadata extraction.

## Gamelist behavior

For each system:

1. a manual Fort Gamelist File is authoritative;
2. ES-DE's configured/expected gamelist locations are probed;
3. with legacy mode enabled, ROM-local gamelist is preferred;
4. otherwise central ES-DE gamelist is preferred and ROM-local remains a fallback.

Selecting/changing the ES-DE root triggers a ROM scan first so metadata import can match ROMs from all resolved volumes.

## Android identity

R1 uses `com.neogamelab.neostation.fort` and launcher name `NeoStation Fort`, allowing it to coexist with upstream NeoStation and use separate app-private data.

## Validation still required

- Dart format check.
- `flutter analyze`.
- full Flutter tests.
- Android ARM64 release build.
- permanent-signature build/update test.
- AYN Thor multi-volume ROM test.
- AYN Thor custom MediaDirectory test.
- central and ROM-local gamelist tests.
- manual override/reset tests.
- microSD unavailable/reconnect preservation test.

See `R1_TEST_PLAN.md`.
