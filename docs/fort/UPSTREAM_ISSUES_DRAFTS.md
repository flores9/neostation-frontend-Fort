# NeoStation upstream issues — Fort validation notes

Baseline verified against official `main` commit `de7de7d5584c815769817cc74f1745d28800d7be` (2026-09-05).

These drafts separate confirmed upstream behavior from Fort-only data-pack problems. Existing upstream issues are referenced instead of duplicated.

---

## 1. [FEATURE] Optional strict ES-DE library mode: use `gamelist.xml` as the visible-library source of truth

### Problem
NeoStation scans the physical ROM directories independently from ES-DE and then uses `gamelist.xml` only to enrich matching ROMs with metadata/media. This means files that intentionally exist on disk but are intentionally absent from the ES-DE gamelist still appear as separate NeoStation games.

### Reproducible example
Philips CD-i library:

- `7th Guest, The ... (Disc 1 of 2) ... 01.chd`
- `7th Guest, The ... (Disc 2 of 2) ... 02.chd`

Both CHDs must physically remain on the device because the emulator may request Disc 2 during play. ES-DE intentionally has only Disc 1 in `gamelist.xml`, so the frontend presents one game and Disc 2 remains an auxiliary file.

NeoStation scans both CHDs. Disc 1 matches ES-DE and receives metadata/media; Disc 2 is also displayed as another game without metadata/media.

### Expected behavior
Add an optional ES-DE mode where, for systems with a valid imported `gamelist.xml`:

- physical scanning still locates the files;
- only ROMs present in that system's `gamelist.xml` are exposed in the visible library;
- unlisted files remain physically untouched and available to emulators;
- disabling/resetting ES-DE restores normal NeoStation directory-scan visibility.

This should be a separate ES-DE visibility state, not `is_hidden`, so it does not overwrite the user's own hidden-game choices.

### Why this is useful beyond multidisc
The same pattern applies to BIOS/helper files, alternate discs, utility files and curated ES-DE libraries where the physical folder contains more files than the frontend intentionally exposes.

---

## 2. [BUG] Independent ES-DE systems are merged as aliases, causing wrong system identity and media routing

### Problem
Some NeoStation system JSONs assign multiple independent ES-DE `<name>` values to one NeoStation system. The ES-DE importer stores one `esde_media_dir` per NeoStation `app_system_id`, so importing another ES-DE directory mapped to the same ID can overwrite the media directory of the first one.

### Confirmed examples
The official current `md.json` assigns `megadrivejp` as a folder alias of `md`, even though ES-DE treats `megadrive` and `megadrivejp` as independent systems.

The same class of problem was reproduced for:

- Mega Drive / `megadrivejp`
- Saturn / `saturnjp`
- Sega 32X / `sega32xjp` / `sega32xna`
- Super Nintendo / `snesna`

Observed database state before splitting identities included mappings such as:

- `md -> megadrivejp`
- `sat -> saturnjp`
- `32x -> sega32xna`
- `snes -> snesna`

This made the main system search artwork under the regional system's media directory.

### Expected behavior
When ES-DE defines separate system names that may have separate `gamelist.xml` and media trees, NeoStation should give them separate system identities rather than aliases of one `app_system_id`.

A useful validation rule would be: one exact ES-DE `<name>` should resolve to exactly one NeoStation system, and independent ES-DE names should not share the same `esde_media_dir` state.

---

## 3. [BUG] Amstrad GX4000 is merged into Amstrad CPC instead of being an independent ES-DE system

### Problem
Official current `cpc.json` includes `gx4000` and `amstrad-gx4000` in the CPC folder aliases. There is no independent `gx4000.json` in current upstream.

ES-DE defines Amstrad CPC and Amstrad GX4000 as independent systems. When GX4000 is only an alias of CPC, platform-specific configuration, metadata/media routing and emulator choices cannot be represented independently.

### Expected behavior
Create a separate GX4000 system identity and remove its ES-DE folder names from CPC.

This is likely the same architectural issue as the regional-platform identity problem above, but GX4000 is a clearer example because it is a distinct platform rather than only a regional variant.

---

## 4. [BUG] MAME4droid Current/2024 launch arguments cannot faithfully represent ES-DE launch profiles

### Problem
ES-DE Android MAME4droid profiles use more than the selected ROM path. Typical commands need:

- `ACTION_VIEW`
- `cli_params`
- `-rompath '%GAMEDIRRAW%;%ROMPATHRAW%/<system>'`
- media parameters such as `-flop1`, `-cart`, `-cdrom`, `-cass`, etc.
- `%DATA%` with a MAME machine name (`cpc6128`, `cdimono1`, ...)
- or `%ROMPROVIDER%` for arcade/software-list entries.

NeoStation currently exposes `{file.path}`, `{file.uri}` and `{file.localuri}`, but not equivalents for the ROM parent/system directory or ROM provider basename.

There is also a second problem: `{file.path}` is converted to a `neostation-realpath:` marker, while Android's marker resolver is designed for a value that starts with the marker. In a MAME4droid string extra such as:

`cli_params = "-rompath ... -flop1 'neostation-realpath:content://...'"`

the marker is embedded inside a larger value, so it is not resolved before the intent is sent.

### Reproduced examples
Amstrad CPC ES-DE command conceptually requires:

`-rompath '<game-dir>;<system-rom-dir>' -flop1 '<rom-path>'`, data `cpc6128`.

Philips CD-i requires:

`-rompath '<game-dir>;<system-rom-dir>' -cdrom '<rom-path>'`, data `cdimono1`.

Arcade/software-list entries require the ROM provider/basename as the data value rather than the ROM URI.

### Expected behavior
Add portable placeholders such as:

- `{file.dir}`
- `{system.romdir}`
- `{file.basename}`

and resolve path markers even when embedded inside string extras such as `cli_params`.

No system JSON should need a device-specific `/storage/...` path.

---

## Existing upstream issues — add evidence rather than duplicate

### #456 — custom ES-DE `MediaDirectory`
Current upstream import code still has logic based around `downloaded_media`. Our device testing confirms that respecting the custom `MediaDirectory` configured in `settings/es_settings.xml` is necessary when ROM/media storage is moved. Fort should carry this fix until upstream closes it.

### #204 — ES-DE folder selection / SD-card layout
Already covers ES-DE import failing with non-default storage layouts. Do not open a duplicate. Retest folder selection on the latest `main` and add Android evidence there if it still fails.

### #211 — ES-DE media not applied after import
Related historical report. The media-dir identity overwrite described in issue draft #2 is a more specific root cause for some platforms, so cross-link rather than duplicate generic symptoms.

---

## Not ready to report as confirmed upstream bug

### Multi-disc organizer with disc-specific tags
NeoStation's organizer removes the `Disc N` token but retains the rest of the filename when generating its grouping key. Therefore files such as:

- `Game (Disc 1 of 2) [DISC-SPECIFIC-ID-01].chd`
- `Game (Disc 2 of 2) [DISC-SPECIFIC-ID-02].chd`

produce different group keys.

This is a real code-level risk, but our CD-i example is intentionally not an M3U workflow because the tested CD-i emulators do not support that setup. Reproduce on an M3U-capable platform before filing it upstream.
