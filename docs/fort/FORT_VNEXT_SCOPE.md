# NeoStation Fort vNext scope

## Upstream baseline

- Repository: `misobadev/neostation-frontend`
- Branch: official `main`
- Baseline commit: `de7de7d5584c815769817cc74f1745d28800d7be`
- Date verified: 2026-09-05
- This is 26 commits after released beta `v0.11.5+127`.

## Data pack deliverable

- 212 system JSONs.
- 194 ES-DE system names checked for unique ownership.
- Regional/media-sensitive systems split into independent identities.
- GX4000 independent from CPC.
- Accidental aliases `_electron`, `atarist__`, `_bbcmicro` removed.
- Duplicate case-insensitive ownership of `pspminis` and `TurboGrafx-CD` resolved.
- 86/86 MAME4droid profiles regenerated from the supplied ES-DE `es_systems.xml`.
- MAME4droid profiles use structured Android package/activity/action/data/extras instead of a tokenized command string.
- No hardcoded `/storage/...` paths in regenerated MAME4droid commands.
- CD-i remains without M3U by design.

## Code patches

### MAME4droid launcher

Required placeholder contract:

- `{file.rawpath}` — selected ROM real filesystem path / ES-DE `%ROMRAW%`.
- `{file.dir}` — selected ROM parent directory / ES-DE `%GAMEDIRRAW%`.
- `{rom.root}` — configured ROM root inferred from ROM path and system aliases / ES-DE `%ROMPATHRAW%`.
- `{file.basename}` — filename without extension / ES-DE `%ROMPROVIDER%` equivalent.

The placeholders are resolved before the Android Intent is built, so MAME4droid can receive them safely inside a single `cli_params` string extra.

### Strict ES-DE library

Fort behavior: systems successfully imported from a `gamelist.xml` use imported gamelist membership as the visible-library source of truth while ES-DE remains connected. Physical files not listed remain untouched and usable by emulators.

The implementation does not repurpose the user's `is_hidden` state. It uses the existing ES-DE bookkeeping (`esde_media_subdir` plus `esde_media_dir`) as membership evidence, so no database migration is required.

### Custom MediaDirectory

No Fort patch required on this baseline. Upstream #456 is closed and current `main` already includes `EsdeImportService.resolveMediaRoot()` plus tests for ES-DE's configured `MediaDirectory`. Keep this as a Thor regression test only.

## QA gates

- JSON parse and identity audit.
- No duplicate exact/case-insensitive folder ownership.
- MAME profile conversion audit.
- Fort overlay anchors must apply exactly once against the pinned upstream base.
- Dart format / Flutter analyze / full tests.
- Android ARM64 Preview build with package `com.neogamelab.neostation.preview`.
- Device verification: CPC, CD-i, Arcade/MAME; Mega Drive, Saturn, 32X, SNES; strict CD-i Disc 2 visibility; custom MediaDirectory regression.
