# NeoStation Fort R1 - Candidate release notes

Status: **development / local validation required**. Do not publish as a final release until the Windows build and AYN Thor test plan pass.

Original Fort base: `58e94a65788a800db8805d622fa88dc8bf485877`
Official upstream integrated: `v0.11.5+127` (`e988626b79ac2335463ef7c550884c21531adb21`)
Upstream integration merge: `0e958a9e45d9116748bac54419696b95b0e91644`
Development branch: `fort/esde-integration-r1-v0.11.5`
Functional source checkpoint before documentation-only commits: `8a207d44e99539d76ad795dc53735e38eb831462`

The previously built technical APK is older (`c69e2742f250f065f18148869647cf260047a838`) and **does not contain the platform-identity or ES-DE selector corrections described below**.

## Purpose

R1 makes NeoStation a first-class consumer of an existing ES-DE library instead of assuming ES-DE uses its default ROM/media layout.

The definitive identity rule is:

> **ES-DE determines which library platforms exist. NeoStation system definitions determine how those platforms are emulated. Fort maps the two without turning NeoStation aliases into extra library platforms.**

Examples:

```text
ES-DE amstradcpc -> NeoStation cpc profile
ES-DE gx4000     -> NeoStation cpc profile
```

Both ES-DE platforms may inherit the same emulator profile while keeping separate ROM, gamelist and media namespaces. The canonical NeoStation name `cpc` must not appear as a third platform merely because it is the profile name.

## Upstream 0.11.5+127 integration

Fort now carries the official `v0.11.5+127` delta deliberately on the isolated integration branch. `main` remains untouched.

Most release-note changes relevant to Fort, including the ES-DE media-format expansion and Android SAF false-empty protection, were already present in Fort's original August 28 upstream base. The actual new delta from that base to `v0.11.5+127` was small, which validates the maintained-overlay strategy.

## Added / changed in Fort R1

- ES-DE settings resolver for `settings/es_settings.xml`.
- `ROMDirectory` support.
- `MediaDirectory` support.
- `custom_systems/es_systems.xml` support.
- `%ROMPATH%` expansion without guessing missing bases.
- Per-system absolute ROM paths, including systems split across internal storage and microSD.
- Modern central plus ROM-local `gamelist.xml` discovery.
- Manual per-system Fort overrides for ROM Directory, Media Directory and Gamelist File.
- Independent Reset for each manual override.
- Fort path editor from each system's settings dialog.
- Fort-owned JSON persistence outside upstream SQLite migration numbering.
- Removable-storage protection: an inaccessible exact system source preserves existing ROM rows instead of pruning them.
- ES-DE can be selected and used as the first/only library source; a separate NeoStation ROM folder is no longer required.
- Android ES-DE selection no longer uses NeoStation's user-data destination resolver, preventing the selected source from being silently redirected into `Android/data/<package>/user-data`.
- Platform discovery is evidence-driven. Manual override, explicit ES-DE system declaration, gamelist/media namespace and verified ROM evidence can establish an ES-DE platform; a NeoStation alias alone cannot.
- Migration/reconciliation for old Fort alias-driven platform rows. Known canonical phantom identities such as `cpc` can be removed without deleting ROM rows, favourites, playtime or metadata. Ambiguous sibling ownership is never guessed.
- Regression tests for canonical alias suppression, legitimate sibling systems and safe provenance reconciliation.
- Local PowerShell release build tooling.
- One-time permanent signing setup tooling.
- R1 manual test plan and continuity documentation.

## Media behavior

ES-DE media remains read-only. NeoStation Fort resolves the user's effective ES-DE `MediaDirectory` and consumes artwork/video in place.

NeoStation-owned scraped media keeps upstream's existing visual priority. External fallback order is:

1. manual per-system media override;
2. automatically resolved ES-DE media;
3. normal NeoStation fallback behavior.

The existing mappings remain:

- NeoStation `box2d` -> ES-DE `covers`, then `3dboxes`;
- `wheels` -> `marquees`;
- `screenshots` -> `screenshots`, then `titlescreens`;
- `fanarts` -> `fanart`;
- `videos` -> `videos`.

## ROM and platform behavior

Library platform identity now starts from concrete ES-DE evidence. NeoStation `folder_name`/aliases are used to resolve the emulator profile, not to manufacture additional platforms.

For each concrete ES-DE platform, source priority remains:

1. manual Fort ROM Directory;
2. explicit ES-DE custom-system `<path>`;
3. ES-DE `ROMDirectory/<system>` when present/accessible;
4. compatible normal NeoStation fallback only when no stronger ES-DE identity is being asserted.

Several ES-DE siblings mapped to one emulator profile are scanned together so one sibling cannot prune another sibling's ROM rows.

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

The source changes above have **not yet passed the local release gate**. Required before another technical APK is considered validated:

- Dart format check.
- `flutter analyze`.
- full Flutter tests, including the new ES-DE platform-identity regressions.
- Android ARM64 release build.
- AYN Thor upgrade test over the previous Fort APK to exercise stale-platform reconciliation.
- ES-DE selector test with zero normal NeoStation ROM folders.
- AYN Thor multi-volume ROM test.
- AYN Thor custom `MediaDirectory` test.
- central and ROM-local gamelist tests.
- `amstradcpc`/`gx4000`-style sibling isolation and no canonical duplicate.
- manual override/reset tests.
- microSD unavailable/reconnect preservation test.

See `R1_TEST_PLAN.md`.
