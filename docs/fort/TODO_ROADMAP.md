# NeoStation Fort - TODO / roadmap

This is the maintained backlog for Fort-specific ideas. It is intentionally separate from upstream NeoStation's own roadmap. Before implementing an item, always check whether the current upstream release already provides an equivalent feature and prefer upstream when it does.

## Current release gate - R1 ES-DE integration

Status: technical ARM64 APK built successfully from commit `c69e2742f250f065f18148869647cf260047a838`; AYN Thor device validation is still required before permanent signing, merge, tag or public release.

R1 validation focus:

- NeoStation Fort installs side-by-side with upstream NeoStation.
- ES-DE root and configuration are resolved correctly.
- Internal-storage ROM systems are discovered.
- microSD ROM systems are discovered.
- `gamelist.xml` metadata is imported.
- external `MediaDirectory` artwork/video fallback works read-only.
- NeoStation-owned media retains priority.
- per-system ROM/media/gamelist overrides and independent resets work.
- unavailable/removable storage never prunes already-known games.
- native NeoStation configuration remains compatible.

## Upstream maintenance - permanent requirement

Fort is a maintained overlay on NeoStation, not an independent product line that drifts permanently away from upstream.

For every new upstream NeoStation release:

1. Record the new upstream tag/commit and compare it with the Fort base.
2. Review upstream changes before porting Fort.
3. Check every Fort feature for upstream equivalence.
4. Drop or adapt Fort code when upstream now implements the requirement sufficiently.
5. Reapply only the still-needed Fort delta, preferably as modular services/UI integrations/tests.
6. Run upstream-compatible tests plus Fort contract tests.
7. Build and validate again on the AYN Thor before changing the release base.

See `UPSTREAM_MAINTENANCE.md` for the detailed procedure.

## Candidate R2 - library and metadata control

### XML-only library mode

Idea: optionally do not expose games that are outside the ES-DE XML/gamelist sources.

Desired behavior:

- configurable rather than silently changing native NeoStation behavior;
- clear distinction between filesystem scan and XML-authoritative mode;
- multi-root and per-system override aware;
- unavailable SD/permission must not be interpreted as deletion;
- tests must cover XML present, XML absent, stale XML and temporary inaccessible storage.

### Metadata filters

Add rich library filters based on metadata already available/imported, for example:

- genre;
- year;
- developer/publisher;
- players;
- rating;
- favorites and other useful native flags;
- system/platform where useful in global views.

Prefer extending upstream's existing filtering/model infrastructure.

### Custom collections

User-defined collections/playlists spanning systems where the upstream data model allows it.

Requirements to explore:

- manual add/remove;
- ordering;
- persistence/migration;
- interaction with filters/favorites;
- behavior when a source volume is temporarily unavailable.

## Candidate R3 - media and ambient presentation

### Configurable fanart + boxart fallback

Generalize media fallback priorities beyond the initial ES-DE integration. Preserve NeoStation-owned media priority and ES-DE read-only guarantees.

Potential configurable chain per media role:

- preferred native media;
- fanart;
- screenshot/title screen;
- boxart/cover/3D box;
- other mapped ES-DE media where semantically suitable.

Never overwrite ES-DE-owned files.

### Logos / marquees view

Add a view focused on platform/game logos or marquees, using native media first and ES-DE mappings as fallback.

### Music

Ambient/background music mode inspired by ES-DE Companion Fort, but integrated natively into NeoStation's lifecycle and audio behavior rather than copied blindly.

Questions to resolve:

- user-selected folders/playlists;
- shuffle/repeat;
- pause/duck while video or game launches;
- resume behavior;
- persistence after folder changes;
- second-screen coordination.

### Screensaver

Configurable screensaver using library media, with safe lifecycle behavior and explicit interaction with display wake-lock policies.

## Candidate R4 - enhanced second screen

The second screen should become a first-class presentation surface rather than a static auxiliary view.

Desired capabilities:

- prevent the second display from sleeping while the feature is active, without forcing unnecessary wake-locks elsewhere;
- show videos on the second display;
- continue useful media presentation while a game is running where Android/display lifecycle permits it;
- after video playback finishes, return deterministically to the beginning of the fanart/media cycle;
- configurable timing and transitions;
- robust behavior on display disconnect/reconnect;
- no interference with the primary game display.

## Candidate R5 - advanced multi-screen animations

Bring the strongest concepts from ES-DE Companion Fort's multipage/multiscreen presentation into NeoStation Fort, adapted to NeoStation architecture.

Potential scope:

- multiple presentation pages/states;
- configurable widgets/media roles;
- per-page timing;
- transitions/animations;
- touch/controller events to advance/change views;
- video-aware state machine;
- independent primary/secondary-display orchestration.

Do not directly transplant Companion Fort implementation details if NeoStation provides cleaner native integration points. Reuse contracts, tested behavior and UX ideas.

## Engineering rules for every Fort feature

- Upstream first: inspect current NeoStation before implementing.
- Small delta: avoid broad forks of upstream files when an adapter/service can isolate the change.
- Contract tests: Fort behavior must have tests that survive upstream rebases/ports.
- No silent destructive migration.
- No hardcoded device-specific UUIDs or paths.
- Keep ES-DE media read-only.
- Document integration points and upstream assumptions.
- Preserve side-by-side install identity unless deliberately changed.
- Keep secrets/signing material outside Git.
- Every delivery checkpoint must record source commit, upstream base, build/toolchain data and hashes.
