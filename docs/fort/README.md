# NeoStation Fort

NeoStation Fort is a maintained fork of `misobadev/neostation-frontend` focused first on robust ES-DE interoperability for Android handhelds and multi-volume libraries.

## Repository policy

- Upstream: `misobadev/neostation-frontend`
- Fort fork: `flores9/neostation-frontend-Fort`
- `main` stays clean until a Fort release is validated.
- Development happens on `fort/*` branches.
- GitHub Actions are not the authoritative Android build path for Fort releases. Release APKs are built and validated locally on Windows with `tools/fort_local_release.ps1`.
- No signing secrets, keystores or passwords are committed.
- Every Fort release must publish source, release notes, validation evidence, APK, SHA-256 hashes and a delivery ZIP containing the operational documentation.

## R1 contract: ES-DE integration

R1 must support all of the following without moving or copying the user's ES-DE library:

1. Parse `settings/es_settings.xml`.
2. Honor `ROMDirectory`.
3. Honor `MediaDirectory`.
4. Parse `custom_systems/es_systems.xml`.
5. Resolve `%ROMPATH%` without guessing when its base is unknown.
6. Support systems placed on different storage volumes.
7. Discover modern central gamelists under `gamelists/<system>/gamelist.xml`.
8. Discover ROM-local `gamelist.xml` files when ES-DE legacy/custom layouts use them.
9. Keep ES-DE media read-only and use it as fallback artwork/video.
10. Support independent manual per-system overrides for ROM directory, media directory and gamelist file.
11. Manual values override automatic ES-DE/native discovery for the corresponding path only.
12. Resetting one manual value restores automatic resolution without affecting the other two.
13. Missing/unmounted/removable storage must never be interpreted as an intentional empty library and must not cause stored ROM rows to be pruned.
14. NeoStation Fort must be installable beside upstream NeoStation on Android.

## Path precedence

Configuration precedence is field-specific:

```text
Manual per-system override
  -> ES-DE per-system/custom resolution
  -> ES-DE global setting
  -> NeoStation native/default discovery
```

ROM, media and gamelist paths are deliberately independent. A system may have ROMs in internal storage, media on microSD and its gamelist in the ES-DE application directory.

For displayed artwork, NeoStation-owned scraped media keeps upstream's existing first priority; the Fort manual media root is the highest-priority external source, followed by automatically resolved ES-DE media.

## Fort-owned configuration

Per-system manual path overrides are stored outside upstream SQLite migrations:

```text
<NeoStation Fort user-data>/fort/system-path-overrides.json
```

This prevents Fort from claiming upstream migration numbers and makes future upstream rebases/merges safer.

## Android identity

Fort uses:

```text
applicationId = com.neogamelab.neostation.fort
app name      = NeoStation Fort
```

The upstream Java/Kotlin namespace remains unchanged to preserve native source and method-channel compatibility. Fort therefore installs beside upstream NeoStation with separate app-private data.

## Local release build

See [BUILD_LOCAL_WINDOWS.md](BUILD_LOCAL_WINDOWS.md). The release script produces an ARM64 APK and a self-contained delivery ZIP under `dist/`.
