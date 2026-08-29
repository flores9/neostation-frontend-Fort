# R1 Test Plan - ES-DE integration

Device target: AYN Thor Android, with internal storage plus microSD.

## Preconditions

- Keep the original NeoStation installed; NeoStation Fort must install beside it.
- Do not move or rename the ES-DE library for the tests.
- Preserve a backup of NeoStation Fort user-data before destructive test cases.
- Record the exact Fort commit and APK SHA-256 used.

Reference ES-DE layout used by the primary test case:

```text
ES-DE root: /storage/emulated/0/ES-DE
MediaDirectory: /storage/14F5-471E/ROMs

Internal ROM examples:
/storage/emulated/0/ROMs/<system>/...

microSD ROM examples:
/storage/14F5-471E/ROMs/<system>/...
```

## A. Installation/isolation

- [ ] Fort APK installs while upstream NeoStation is still installed.
- [ ] Android launcher shows `NeoStation Fort` distinctly.
- [ ] Starting Fort does not reuse/overwrite upstream NeoStation app-private data.
- [ ] Uninstalling/reinstalling Fort does not affect upstream NeoStation.

## B. ES-DE settings parsing

- [ ] Select the real ES-DE root.
- [ ] Import detects `MediaDirectory=/storage/14F5-471E/ROMs`.
- [ ] Systems using `%ROMPATH%` resolve against `ROMDirectory`.
- [ ] Systems with absolute `<path>` entries in `custom_systems/es_systems.xml` use those absolute paths.
- [ ] Internal-storage systems and microSD systems can coexist in one import.

## C. Gamelist discovery

Use at least one system for each case.

- [ ] Modern central `ES-DE/gamelists/<system>/gamelist.xml` is found.
- [ ] A system whose gamelist is not present centrally but exists beside its ROMs is found.
- [ ] With `LegacyGamelistFileLocation=true`, ROM-local gamelist has priority.
- [ ] With `LegacyGamelistFileLocation=false`, central gamelist has priority but ROM-local is a defensive fallback when central is absent.
- [ ] A malformed gamelist skips only that system and does not abort the whole import.

## D. ROM discovery - two volumes

- [ ] At least one internal-storage platform appears with all expected games.
- [ ] At least one microSD platform appears with all expected games.
- [ ] Launch path of a sampled internal ROM points to internal storage.
- [ ] Launch path of a sampled microSD ROM points to microSD storage.
- [ ] Re-scan does not duplicate games.
- [ ] Same filename in unrelated systems remains isolated by system.

## E. Media fallback

For at least one game verify:

- [ ] Cover from ES-DE `covers` appears as NeoStation `box2d` fallback.
- [ ] Marquee appears as wheel.
- [ ] Fanart appears.
- [ ] Title screen is accepted when screenshot is absent.
- [ ] Video is found and plays.
- [ ] Nested ROM media subdirectories still resolve.
- [ ] No media file is copied into or overwritten inside the ES-DE tree.
- [ ] A later NeoStation-owned scrape still has upstream priority over automatic ES-DE fallback.

## F. Manual per-platform overrides

For one platform deliberately point each field away from the auto-detected value.

ROM Directory:
- [ ] Manual directory takes priority for that platform only.
- [ ] Other systems remain automatic.
- [ ] Reset restores the ES-DE/native detected route.

Media Directory:
- [ ] Manual media directory takes priority over automatic ES-DE external media.
- [ ] ES-DE-style category folders are accepted.
- [ ] NeoStation-style media folder names are accepted for manual media roots.
- [ ] Reset restores automatic ES-DE media.

Gamelist File:
- [ ] Manually selected XML takes priority even when a central ES-DE gamelist exists.
- [ ] Reset restores automatic gamelist resolution.

- [ ] Changing one field does not clear the other two manual values.

## G. Missing media/removable storage safety

With Fort closed, temporarily remove/unmount the microSD or revoke its directory permission.

- [ ] Starting Fort does not delete previously stored microSD games.
- [ ] A scan reports/records the inaccessible source instead of treating it as an intentionally empty system.
- [ ] Internal-storage games remain available.
- [ ] Reinsert/regrant microSD and rescan: games return without duplicated rows or lost favorites/playtime.

## H. Regression

- [ ] Library using only NeoStation native ROM folders still scans normally.
- [ ] ES-DE with default `downloaded_media` still works.
- [ ] Existing favorites survive import/re-import.
- [ ] Existing NeoStation metadata is not overwritten by lower-priority ES-DE metadata.
- [ ] Reset ES-DE import does not remove NeoStation-owned scraped metadata/media.
- [ ] Game launch works for sampled systems from both volumes.
- [ ] Controller navigation remains functional in system settings.

## Evidence to retain in release ZIP

- APK SHA-256.
- `BUILD_MANIFEST.txt`.
- exact Git commit.
- pass/fail copy of this checklist.
- relevant `app.log` excerpts for any failure.
- screenshots only when they materially document a UI/storage issue.
