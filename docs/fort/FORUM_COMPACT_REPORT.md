# Compact forum report

I have been testing the current NeoStation `main` code with a large ES-DE Android library and found a few separate integration issues:

1. **ES-DE gamelist is not a source of truth for visibility.** NeoStation scans every physical ROM, so auxiliary files intentionally omitted from `gamelist.xml` still appear as games. Example: CD-i Disc 1 is in ES-DE and has metadata/media, while Disc 2 must stay physically present for disc swapping but is intentionally not in the gamelist. NeoStation shows Disc 2 as a second game with no metadata/media. An optional "ES-DE strict" mode would solve this without deleting the physical file or changing the user's hidden-game state.

2. **Independent ES-DE systems are sometimes merged as aliases.** Examples include `megadrivejp` under Mega Drive, `saturnjp` under Saturn, regional 32X variants and `snesna`. Because NeoStation stores one ES-DE media directory per app system ID, one regional directory can overwrite the main system's media mapping. Splitting them into independent IDs fixed the media problem in testing.

3. **GX4000 is currently mixed into CPC.** ES-DE defines Amstrad CPC and GX4000 independently, but current `cpc.json` includes GX4000 aliases and there is no independent GX4000 system JSON.

4. **MAME4droid Current/2024 needs richer portable path placeholders.** ES-DE profiles use `%ROMRAW%`, `%GAMEDIRRAW%`, `%ROMPATHRAW%` and `%ROMPROVIDER%` inside `cli_params`. NeoStation currently cannot express all of those faithfully for Android SAF paths. Equivalent placeholders such as `{file.rawpath}`, `{file.dir}`, `{rom.root}` and `{file.basename}` would allow the existing structured Android `package/activity/action/data/extras` JSON form to reproduce ES-DE profiles without hardcoded `/storage/...` paths.

The custom `MediaDirectory` issue (#456) is already fixed in current `main` and is now only a regression test for me. The Android/SD-card ES-DE folder-selection issue #204 is still open, so I would add current-device evidence there instead of opening a duplicate.
