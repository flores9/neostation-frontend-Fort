# Compact forum report

I have been testing the current NeoStation code with a large ES-DE Android library and found a few separate integration issues:

1. **ES-DE gamelist is not a source of truth for visibility.** NeoStation scans every physical ROM, so auxiliary files intentionally omitted from `gamelist.xml` still appear as games. Example: CD-i Disc 1 is in ES-DE and has metadata/media, while Disc 2 must stay physically present for disc swapping but is intentionally not in the gamelist. NeoStation shows Disc 2 as a second game with no metadata/media. An optional "ES-DE strict" mode would solve this without deleting or hiding the physical file.

2. **Independent ES-DE systems are sometimes merged as aliases.** Examples include `megadrivejp` under Mega Drive, `saturnjp` under Saturn, regional 32X variants and `snesna`. Because NeoStation stores one ES-DE media directory per app system ID, one regional directory can overwrite the main system's media mapping. Splitting them into independent IDs fixed the media problem in testing.

3. **GX4000 is currently mixed into CPC.** ES-DE defines Amstrad CPC and GX4000 independently, but current `cpc.json` includes GX4000 aliases and there is no independent GX4000 system JSON.

4. **MAME4droid Current/2024 needs richer launcher placeholders.** ES-DE profiles require game directory/system ROM directory, ROM path and sometimes ROM basename/provider inside `cli_params`. NeoStation currently cannot express all of those safely, and path markers embedded inside `cli_params` are not resolved like a standalone `{file.path}` value. Portable placeholders such as `{file.dir}`, `{system.romdir}` and `{file.basename}` would avoid hardcoded storage paths.

I am keeping the custom MediaDirectory/folder-selection cases separate because there are already upstream issues (#456, #204/#211) covering those areas.
