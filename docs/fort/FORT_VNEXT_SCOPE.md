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
- No hardcoded `/storage/...` paths in regenerated MAME4droid commands.
- CD-i remains without M3U by design.

## Code patches

### MAME4droid launcher

Required placeholder contract:

- `{file.path}` — selected ROM real path.
- `{file.dir}` — selected ROM parent directory.
- `{system.romdir}` — system directory derived from ROM path/system aliases.
- `{file.basename}` — filename without extension / ES-DE `%ROMPROVIDER%` equivalent.

Android must resolve path markers embedded inside a larger string extra (`cli_params`) or pre-resolve external-storage SAF paths before building the intent.

### Strict ES-DE library

Fort behavior: systems successfully imported from a `gamelist.xml` can use gamelist membership as the visible-library source of truth. Physical files not listed remain untouched and usable by emulators.

The implementation must not repurpose the user's `is_hidden` state.

### Custom MediaDirectory

Carry/reapply the working Fort behavior that resolves ES-DE's configured `MediaDirectory` instead of assuming `<ES-DE>/downloaded_media`, until upstream issue #456 is fixed.

## QA gates

- JSON parse and identity audit.
- No duplicate exact/case-insensitive folder ownership.
- MAME profile conversion audit.
- Dart format / Flutter analyze / tests.
- Android Preview build from the pinned upstream SHA + Fort commits.
- Device verification: CPC, CD-i, Arcade/MAME; Mega Drive, Saturn, 32X, SNES; strict CD-i Disc 2 visibility.
