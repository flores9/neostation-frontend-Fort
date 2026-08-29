part of '../sqlite_config_provider.dart';

/// Trivial configuration mutators for [SqliteConfigProvider].
///
/// Each method writes a single field to the in-memory [ConfigModel], persists it
/// via [SqliteConfigService], and notifies listeners (some also push the value to
/// the secondary display). Extracted verbatim from the host, which retains the
/// class declaration, all state, and the scan/secondary-display orchestration.
extension SqliteConfigMutators on SqliteConfigProvider {
  /// Updates the entire list of ROM folders and triggers a configuration save.
  Future<void> updateRomFolders(List<String> romFolders) async {
    _config = _config.copyWith(
      romFolders: romFolders,
      lastScan: DateTime.now(),
    );
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  /// Convenience method to update the primary ROM folder.
  Future<void> updateRomFolder(String path) async {
    if (_config.romFolders.isNotEmpty) {
      final newList = List<String>.from(_config.romFolders);
      newList[0] = path;
      await updateRomFolders(newList);
    } else {
      await addRomFolder(path);
    }
  }

  /// Updates the preferred UI layout mode for game lists.
  Future<void> updateGameViewMode(String gameViewMode) async {
    _config = _config.copyWith(gameViewMode: gameViewMode);
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  /// Updates the preferred UI layout mode for system carousels/grids.
  Future<void> updateSystemViewMode(String systemViewMode) async {
    _config = _config.copyWith(systemViewMode: systemViewMode);
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  /// Updates the preferred grid column density for the systems grid.
  Future<void> updateSystemGridColumns(String systemGridColumns) async {
    _config = _config.copyWith(systemGridColumns: systemGridColumns);
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  /// Updates the preferred grid column density for the games grid.
  Future<void> updateGameGridColumns(String gameGridColumns) async {
    _config = _config.copyWith(gameGridColumns: gameGridColumns);
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  /// Updates the preferred card style for the game carousel ('fanart' or 'box').
  Future<void> updateGameCarouselCardStyle(String cardStyle) async {
    _config = _config.copyWith(gameCarouselCardStyle: cardStyle);
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  /// Toggles the application's fullscreen state.
  Future<void> updateIsFullscreen(bool value) async {
    _config = _config.copyWith(isFullscreen: value);
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  /// Persists the user's ES-DE application folder path. Fort immediately
  /// rescans when a non-empty ES-DE root is selected so exact per-system ROM
  /// paths from ES-DE are present in `user_roms` before metadata import runs.
  Future<void> updateEsdeFolderPath(String path) async {
    final normalized = path.trim();
    _config = _config.copyWith(esdeFolderPath: normalized);
    await SqliteConfigService.saveConfig(_config);
    _notify();

    if (normalized.isNotEmpty && !_isScanning) {
      await scanSystems();
    }
  }

  Future<void> updateHideRecentCard(bool value) async {
    _config = _config.copyWith(hideRecentCard: value);
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  /// Persists the cell span of the "Recently Played" card in the systems grid
  /// ('default' for the 3x2 block, '2x1' for the compact wide card).
  Future<void> updateRecentCardSize(String value) async {
    _config = _config.copyWith(recentCardSize: value);
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  /// Persists whether library tiles show the RetroAchievements badge.
  Future<void> updateShowAchievementsBadge(bool value) async {
    _config = _config.copyWith(showAchievementsBadge: value);
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  /// Persists whether the game action-button legend is hidden (Select + B).
  Future<void> updateLegendHidden(bool value) async {
    _config = _config.copyWith(legendHidden: value);
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  /// Persists the game details card tab last chosen with L1/R1, as the
  /// `DetailTab` enum name, so it carries across games, systems and restarts.
  Future<void> updateGameDetailsTab(String tabName) async {
    if (_config.gameDetailsTab == tabName) return;
    _config = _config.copyWith(gameDetailsTab: tabName);
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  /// Shows or hides [tab] in the header strip and the L1/R1 tab cycle.
  Future<void> updateNavTabHidden(NavTab tab, bool hidden) async {
    final applyHidden = navTabSpec(tab).withHidden;
    if (applyHidden == null) return;

    _config = applyHidden(_config, hidden);
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  Future<void> updateActiveSyncProvider(String providerId) async {
    _config = _config.copyWith(activeSyncProvider: providerId);
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  /// Toggles the visibility of detailed game metadata in the UI.
  Future<void> updateShowGameInfo(bool show) async {
    _config = _config.copyWith(showGameInfo: show);
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  /// Configures whether the application should shut down the host OS upon exit (Arcade/Cabinet mode).
  Future<void> updateBartopExitPoweroff(bool value) async {
    _config = _config.copyWith(bartopExitPoweroff: value);
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  /// Updates whether startup scan is enabled
  Future<void> updateScanOnStartup(bool value) async {
    _config = _config.copyWith(scanOnStartup: value);
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  /// Persists whether the startup scan is followed by a RetroAchievements
  /// match pass over the ROMs it added.
  Future<void> updateRaMatchOnStartup(bool value) async {
    _config = _config.copyWith(raMatchOnStartup: value);
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  /// Persists the global "Show Subfolders" choice and applies it to every
  /// system.
  Future<void> updateSubfolderViewAll(bool value) async {
    _config = _config.copyWith(subfolderViewAll: value);
    await SqliteConfigService.saveConfig(_config);
    await SystemRepository.setSubfolderViewForAll(value);
    await refreshDetectedSystems();
    _notify();
  }

  /// Updates whether hidden files/folders are ignored during ROM scans.
  Future<void> updateIgnoreHiddenFiles(bool ignoreHiddenFiles) async {
    _config = _config.copyWith(ignoreHiddenFiles: ignoreHiddenFiles);
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  /// Updates whether the header clock uses a 12-hour (AM/PM) format.
  Future<void> updateUse12HourClock(bool value) async {
    _config = _config.copyWith(use12HourClock: value);
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  /// Updates whether UI navigation SFX sounds are enabled
  Future<void> updateSfxEnabled(bool value) async {
    _config = _config.copyWith(sfxEnabled: value);
    await SqliteConfigService.saveConfig(_config);
    SfxService().setEnabled(value);
    _secondaryDisplayState?.updateState(sfxEnabled: value);
    _notify();
  }

  /// Updates and persists the UI SFX volume, playing a sound at the new level
  /// so the choice can be heard as it is made.
  Future<void> updateSfxVolume(double value) async {
    final volume = value.clamp(0.0, SfxService.maxVolume).toDouble();
    _config = _config.copyWith(sfxVolume: volume);
    SfxService().setVolume(volume);
    _secondaryDisplayState?.updateState(sfxVolume: volume);
    _notify();
    unawaited(SfxService().playVolumePreview());
    await SqliteConfigService.saveConfig(_config);
  }

  /// Updates the app display language and applies it immediately
  Future<void> updateAppLanguage(String langCode) async {
    _config = _config.copyWith(appLanguage: langCode);
    await SqliteConfigService.saveConfig(_config);
    FlutterLocalization.instance.translate(langCode);
    _notify();
  }

  /// Updates the global audio mute state for game preview videos.
  Future<void> updateVideoSound(bool value) async {
    if (_config.videoSound == value) return;
    _config = _config.copyWith(videoSound: value);
    // ignore: unawaited_futures
    SqliteConfigService.saveConfig(_config);

    if (_secondaryDisplayState != null) {
      final current = _secondaryDisplayState!.value;
      if (current != null) {
        _secondaryDisplayState!.updateState(isVideoMuted: !value);
      }
    }

    _notify();
  }

  Future<void> toggleVideoSound() async {
    await updateVideoSound(!_config.videoSound);
  }

  Future<void> updateNowPlayingDimDelay(int seconds) async {
    _config = _config.copyWith(nowPlayingDimDelay: seconds);
    await SqliteConfigService.saveConfig(_config);
    _secondaryDisplayState?.updateState(nowPlayingDimDelay: seconds);
    _notify();
  }

  Future<void> updateNowPlayingDimLevel(int percent) async {
    final clamped = percent.clamp(0, 100);
    _config = _config.copyWith(nowPlayingDimLevel: clamped);
    await SqliteConfigService.saveConfig(_config);
    _secondaryDisplayState?.updateState(nowPlayingDimLevel: clamped);
    _notify();
  }

  Future<void> updateFanartDimLevel(int percent) async {
    final clamped = percent.clamp(0, 100);
    _config = _config.copyWith(fanartDimLevel: clamped);
    await SqliteConfigService.saveConfig(_config);
    _secondaryDisplayState?.updateState(fanartDimLevel: clamped);
    _notify();
  }

  Future<void> updateDockApps(List<String> apps) async {
    final normalized = ConfigModel.normalizeDock(apps);
    _config = _config.copyWith(dockApps: normalized);
    await SqliteConfigService.saveConfig(_config);
    _secondaryDisplayState?.updateState(dockApps: normalized);
    _notify();
  }

  Future<void> updateDockEnabled(bool enabled) async {
    _config = _config.copyWith(dockEnabled: enabled);
    await SqliteConfigService.saveConfig(_config);
    _secondaryDisplayState?.updateState(dockEnabled: enabled);
    _notify();
  }

  Future<void> updateDockSlotCount(int count) async {
    final clamped = count.clamp(
      ConfigModel.dockMinSlotCount,
      ConfigModel.dockMaxSlotCount,
    );
    _config = _config.copyWith(dockSlotCount: clamped);
    await SqliteConfigService.saveConfig(_config);
    _secondaryDisplayState?.updateState(dockSlotCount: clamped);
    _notify();
  }

  /// Marks the initial application onboarding as completed.
  Future<void> completeSetup() async {
    _config = _config.copyWith(setupCompleted: true);
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  Future<void> updateAutoUpdateApp(bool value) async {
    _config = _config.copyWith(autoUpdateApp: value);
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  Future<void> updateAutoUpdateSystems(bool value) async {
    _config = _config.copyWith(autoUpdateSystems: value);
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  Future<void> updateSystemSortBy(String sortBy) async {
    if (_config.systemSortBy == sortBy) return;
    _config = _config.copyWith(systemSortBy: sortBy);
    _sortDetectedSystems();
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }

  Future<void> updateSystemSortOrder(String order) async {
    if (_config.systemSortOrder == order) return;
    _config = _config.copyWith(systemSortOrder: order);
    _sortDetectedSystems();
    await SqliteConfigService.saveConfig(_config);
    _notify();
  }
}
