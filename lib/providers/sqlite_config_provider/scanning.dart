part of '../sqlite_config_provider.dart';

/// ROM scanning and system detection for [SqliteConfigProvider].
///
/// Owns filesystem ROM scanning (foreground + background), per-system rescans,
/// ROM-folder management, and loading/refreshing the detected/available system
/// lists from the database. Extracted verbatim from the host, which retains the
/// class declaration, all state, lifecycle wiring, and secondary-display logic.
const String _unreachableRomFoldersNotificationId = 'rom-folders-unreachable';
const String _transientRomFolderNotificationId = 'rom-folder-transient';
const String _noRomFoldersNotificationId = 'rom-folders-missing';
const String _safPermissionNotificationId = 'rom-folders-saf-permission';
const String _fortRomPathNotificationPrefix = 'fort-rom-path-unavailable-';

extension SqliteConfigScanning on SqliteConfigProvider {
  Future<void> addRomFolder(String folderPath, {bool scan = true}) async {
    if (folderPath.isEmpty) return;
    if (_config.romFolders.contains(folderPath)) return;
    if (_config.romFolders.length >= 5) return;

    if (isTransientPortalPath(folderPath)) {
      _error =
          'That folder came from a temporary desktop-portal path '
          '($folderPath) and would stop working after a restart. '
          'Pick it again with the built-in folder browser.';
      SqliteConfigProvider._log.w(
        'Rejected transient portal ROM folder: $folderPath',
      );
      GlobalNotificationService().show(
        id: _transientRomFolderNotificationId,
        title: 'ROM folder not added',
        message: _error!,
        type: GlobalNotificationType.error,
      );
      _notify();
      return;
    }

    try {
      _setLoading(true);
      final newList = [..._config.romFolders, folderPath];
      _config = _config.copyWith(
        romFolders: newList,
        lastScan: DateTime.now(),
        setupCompleted: true,
      );
      await SqliteConfigService.saveConfig(_config);
      if (scan) await scanSystems();
      _notify();
    } catch (e) {
      _error = 'Error adding ROM folder: $e';
      SqliteConfigProvider._log.e('$_error');
    } finally {
      _setLoading(false);
    }
  }

  Future<void> removeRomFolder(String folderPath) async {
    try {
      _setLoading(true);
      await GameRepository.deleteRomsByFolderPath(folderPath);
      final newList = _config.romFolders.where((p) => p != folderPath).toList();
      _config = _config.copyWith(romFolders: newList, lastScan: DateTime.now());
      await SqliteConfigService.saveConfig(_config);
      if (newList.isNotEmpty) {
        await scanSystems();
      } else {
        await SystemRepository.updateDetectedSystems([]);
        await _loadDetectedSystems();
      }
      _notify();
    } catch (e) {
      _error = 'Error removing ROM folder: $e';
      SqliteConfigProvider._log.e('$_error');
    } finally {
      _setLoading(false);
    }
  }

  Future<void> _ensureAndroidSafPermissions() async {
    if (!Platform.isAndroid) return;
    final missing = <String>[];
    for (final folder in _config.romFolders) {
      if (!folder.startsWith('content://')) continue;
      final ok = await SafDirectoryService.hasPermission(folder);
      if (!ok) missing.add(folder);
    }
    if (missing.isEmpty) {
      GlobalNotificationService().dismiss(_safPermissionNotificationId);
      return;
    }
    final plural = missing.length == 1 ? '' : 's';
    SqliteConfigProvider._log.w(
      'SAF permission missing for ${missing.length} ROM folder(s): $missing',
    );
    GlobalNotificationService().show(
      id: _safPermissionNotificationId,
      title: 'ROM folder$plural missing storage access',
      message:
          '${missing.length} ROM folder$plural cannot be read. '
          'Re-grant access in Settings > Directories.',
      type: GlobalNotificationType.error,
    );
  }

  Future<void> scanSystems({bool waitForAndroidStorage = false}) async {
    if (_isScanning) {
      SqliteConfigProvider._log.w(
        'Already scanning, ignoring duplicate call...',
      );
      return;
    }

    _setScanning(true);
    _error = null;
    SafDirectoryService.resetFastWalkAvailability();

    final hasFortSources = await ConfigService.hasFortRomSources(
      esdeRoot: _config.esdeFolderPath,
    );
    _isFastScan = _config.romFolders.isEmpty && !hasFortSources;
    SqliteConfigProvider._log.i(
      'scanSystems starting (romFolders=${_config.romFolders.length}, '
      'fortSources=$hasFortSources, fastScan=$_isFastScan)',
    );

    if (Platform.isAndroid) {
      final hasBroadPermissions =
          await PermissionService.hasStoragePermissions();
      final hasSafFolders = _config.romFolders.any(
        (f) => f.startsWith('content://'),
      );
      if (!hasBroadPermissions &&
          !hasSafFolders &&
          _config.romFolders.isNotEmpty) {
        _error =
            'Storage access required. Please select a ROM folder using the file picker.';
        SqliteConfigProvider._log.e('$_error');
        _setScanning(false);
        _notify();
        return;
      }

      for (final path in _config.romFolders) {
        final canAccess = await PermissionService.canAccessDirectory(path);
        if (!canAccess) {
          _error =
              'Cannot access ROM folder: $path. Please check storage permissions.';
          SqliteConfigProvider._log.e('$_error');
          _setScanning(false);
          _notify();
          return;
        }
      }

      try {
        await _ensureAndroidSafPermissions();
      } catch (e) {
        SqliteConfigProvider._log.e(
          'Error checking SAF permissions before scan: $e',
        );
      }

      if (waitForAndroidStorage &&
          await _hasStoredRoms() &&
          !await _waitForAndroidRomFolders()) {
        _scanStatus = 'ROM storage is not ready; existing games were kept.';
        SqliteConfigProvider._log.w(
          'Startup scan skipped because Android ROM storage never became ready',
        );
        _setScanning(false);
        _notify();
        return;
      }
    }

    if (!Platform.isAndroid && _config.romFolders.isNotEmpty) {
      final unreachable = <String>[];
      for (final folder in _config.romFolders) {
        if (!await Directory(folder).exists()) unreachable.add(folder);
      }
      if (unreachable.isNotEmpty && await _hasStoredRoms()) {
        final advice = unreachable.any(isTransientPortalPath)
            ? 'That path came from a temporary desktop-portal grant and '
                  'cannot come back — remove it in Settings > Directories '
                  'and add the folder again.'
            : 'Reconnect the drive, or remove the folder in '
                  'Settings > Directories.';
        final plural = unreachable.length == 1 ? '' : 's';
        _error =
            'Cannot reach ROM folder$plural: ${unreachable.join(', ')}. '
            'Existing games were kept. $advice';
        SqliteConfigProvider._log.e(
          'Scan aborted, ${unreachable.length} unreachable ROM folder(s); '
          'library preserved: ${unreachable.join(', ')}',
        );
        _scanCompleted = true;
        GlobalNotificationService().show(
          id: _unreachableRomFoldersNotificationId,
          title: 'ROM folder$plural unavailable',
          message: _error!,
          type: GlobalNotificationType.error,
        );
        _setScanning(false);
        _notify();
        return;
      }
      if (unreachable.isNotEmpty) {
        SqliteConfigProvider._log.w(
          'Unreachable ROM folder(s) ignored (no stored ROMs): '
          '${unreachable.join(', ')}',
        );
      }
    }

    if (!Platform.isAndroid &&
        _config.romFolders.isEmpty &&
        !hasFortSources &&
        await _hasStoredRoms()) {
      _error =
          'No ROM folder is configured, so there was nothing to scan. '
          'Existing games were kept. Add your ROM folder again in '
          'Settings > Directories.';
      SqliteConfigProvider._log.e(
        'Scan aborted, no ROM folders configured while the library holds '
        'ROMs; library preserved',
      );
      _scanCompleted = true;
      GlobalNotificationService().show(
        id: _noRomFoldersNotificationId,
        title: 'No ROM folder configured',
        message: _error!,
        type: GlobalNotificationType.error,
      );
      _setScanning(false);
      _notify();
      return;
    }

    GlobalNotificationService().dismiss(_unreachableRomFoldersNotificationId);
    GlobalNotificationService().dismiss(_noRomFoldersNotificationId);

    _totalSystemsToScan = 0;
    _scannedSystemsCount = 0;
    _scanProgress = 0.0;
    _scanStatus = 'Please Wait...';

    try {
      await _loadAvailableSystems();
      final bool isFastScan = _isFastScan;
      List<SystemModel> detectedSystems;

      if (Platform.isAndroid) {
        detectedSystems = [];
      } else {
        detectedSystems = await SqliteConfigService.detectSystems(
          romFolders: _config.romFolders,
          availableSystems: _availableSystems,
        );
      }

      List<SystemModel> systemsForMapping = _availableSystems;
      if (isFastScan) {
        final List<String> fastScanFolders = Platform.isAndroid
            ? ['android']
            : [];
        systemsForMapping = _availableSystems.where((s) {
          return fastScanFolders.contains(s.folderName);
        }).toList();
        detectedSystems = detectedSystems
            .where((s) => fastScanFolders.contains(s.folderName))
            .toList();
      }

      if (Platform.isAndroid) {
        final androidSystems = [
          {'folder': 'android'},
          {'folder': 'all'},
        ];
        for (final sysInfo in androidSystems) {
          final sysFolder = sysInfo['folder']?.toString() ?? 'android';
          if (!detectedSystems.any((s) => s.folderName == sysFolder)) {
            try {
              final system = _availableSystems.firstWhere(
                (s) => s.folderName == sysFolder,
                orElse: () =>
                    throw StateError('System not found in available list'),
              );
              detectedSystems = [
                ...detectedSystems,
                system.copyWith(folderName: sysFolder),
              ];
            } catch (e) {
              SqliteConfigProvider._log.e('Failed to inject $sysFolder: $e');
            }
          }
        }
      }

      final now = DateTime.now();
      await ConfigRepository.saveUserConfig(lastScan: now.toIso8601String());
      final systemNames = detectedSystems.map((s) => s.folderName).toList();
      _config = _config.copyWith(
        lastScan: now,
        detectedSystems: Platform.isAndroid
            ? _config.detectedSystems
            : systemNames,
      );

      if (Platform.isAndroid) {
        final Map<String, Map<String, String>> existingFoldersMap =
            await SqliteDatabaseService.getExistingSubdirectories(
              _config.romFolders,
            );
        final Set<String> allExistingFolders = existingFoldersMap.values
            .expand((m) => m.keys.map((k) => k.toLowerCase()))
            .toSet();

        final fortDetectedSystemIds = <String>{};
        for (final system in systemsForMapping) {
          final direct = await ConfigService.getFortSystemRomDirectory(
            system,
            esdeRoot: _config.esdeFolderPath,
          );
          if (direct != null &&
              await ConfigService.isFortRomDirectoryAccessible(direct) &&
              system.id != null) {
            fortDetectedSystemIds.add(system.id!);
          }
        }

        final filteredSystems = systemsForMapping.where((system) {
          if (system.id != null && fortDetectedSystemIds.contains(system.id)) {
            return true;
          }
          final lowerPrimary = system.folderName.toLowerCase();
          if (allExistingFolders.contains(lowerPrimary)) return true;
          for (final altFolder in system.folders) {
            if (allExistingFolders.contains(altFolder.toLowerCase())) {
              return true;
            }
          }
          if (system.folderName == 'android' || system.folderName == 'all') {
            return true;
          }
          return false;
        }).toList();

        SqliteConfigProvider._log.i(
          'AndroidPreFilter: ${allExistingFolders.length} global subfolder(s), '
          '${fortDetectedSystemIds.length} Fort exact system path(s); '
          '${filteredSystems.length} system(s) matched',
        );

        final legacySystems = await SystemRepository.getDetectedSystems();
        final Map<String, SystemModel> combinedMap = {};
        for (final s in filteredSystems) {
          combinedMap[s.id!] = s;
        }
        for (final s in legacySystems) {
          if (!combinedMap.containsKey(s.id)) combinedMap[s.id!] = s;
        }
        _detectedSystems = combinedMap.values.toList();
      } else {
        // Desktop must also surface systems whose exact Fort path bypasses the
        // normal global-root detector.
        for (final system in systemsForMapping) {
          final direct = await ConfigService.getFortSystemRomDirectory(
            system,
            esdeRoot: _config.esdeFolderPath,
          );
          if (direct != null &&
              await ConfigService.isFortRomDirectoryAccessible(direct) &&
              !detectedSystems.any((s) => s.id == system.id)) {
            detectedSystems.add(system);
          }
        }

        final legacySystems = await SystemRepository.getDetectedSystems();
        final Map<String, SystemModel> combinedMap = {};
        for (final s in detectedSystems) {
          combinedMap[s.id!] = s;
        }
        for (final s in legacySystems) {
          if (!combinedMap.containsKey(s.id)) combinedMap[s.id!] = s;
        }
        _detectedSystems = combinedMap.values.toList();
      }

      final skipScan = await GameSessionPersistence.consumeSkipStartupScan();
      if (skipScan) {
        SqliteConfigProvider._log.i(
          'Skipping ROM scan because app was killed during a game session',
        );
      } else {
        _totalSystemsToScan = _detectedSystems.length;
        _scanStatus = 'Scanning ROMs...';
        await _scanRomsInBackground();
      }

      _sortDetectedSystems();
      _scanCompleted = true;
    } catch (e) {
      _error = 'Error scanning ROMs: $e';
      SqliteConfigProvider._log.e('$_error');
    } finally {
      _setScanning(false);
      _notify();
    }
  }

  Future<bool> _hasStoredRoms() async {
    final db = await SqliteService.getDatabase();
    final rows = await db.rawQuery('SELECT EXISTS(SELECT 1 FROM user_roms)');
    return rows.isNotEmpty && rows.first.values.first == 1;
  }

  Future<bool> _waitForAndroidRomFolders() async {
    const retryDelay = Duration(seconds: 3);
    const maxAttempts = 10;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final folders = await SqliteDatabaseService.getExistingSubdirectories(
        _config.romFolders,
      );
      if (folders.values.any((subdirectories) => subdirectories.isNotEmpty)) {
        return true;
      }

      for (final system in _availableSystems) {
        final direct = await ConfigService.getFortSystemRomDirectory(
          system,
          esdeRoot: _config.esdeFolderPath,
        );
        if (direct != null &&
            await ConfigService.isFortRomDirectoryAccessible(direct)) {
          return true;
        }
      }

      if (attempt < maxAttempts) {
        _scanStatus = 'Waiting for ROM storage ($attempt/$maxAttempts)...';
        _notify();
        await Future<void>.delayed(retryDelay);
      }
    }
    return false;
  }

  Future<void> _scanRomsInBackground() async {
    if (_isScanningRoms) return;
    _isScanningRoms = true;

    try {
      final systemsToScan = List<SystemModel>.from(_detectedSystems);
      final rootFoldersMap =
          await SqliteDatabaseService.getExistingSubdirectories(
            _config.romFolders,
          );
      const batchSize = 1;
      const scanPhaseWeight = 0.95;

      for (int i = 0; i < systemsToScan.length; i += batchSize) {
        final endIndex = (i + batchSize < systemsToScan.length)
            ? i + batchSize
            : systemsToScan.length;
        final batch = systemsToScan.sublist(i, endIndex);
        _scanStatus = '${batch.map((s) => s.realName).join(', ')}...';
        _notify();

        await Future.wait(
          batch.map(
            (system) => _scanSystemRoms(system, rootFoldersMap: rootFoldersMap),
          ),
        );

        _scannedSystemsCount += batch.length;
        final scanPhaseProgress = _totalSystemsToScan == 0
            ? 1.0
            : _scannedSystemsCount / _totalSystemsToScan;
        _scanProgress = (scanPhaseProgress * scanPhaseWeight).clamp(
          0.0,
          scanPhaseWeight,
        );
        _notify();
        if (endIndex < _detectedSystems.length) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      _scanStatus = 'Updating systems list...';
      _scanProgress = scanPhaseWeight;
      _notify();

      final allSystems = await SystemRepository.getAllSystems();
      final systemsToKeep = <SystemModel>[];
      int emulatorSystemsWithGamesCount = 0;
      final virtualSystems = ['android', 'music', 'all', 'steam'];
      final allExistingFolders = rootFoldersMap.values
          .expand((m) => m.keys.map((k) => k.toLowerCase()))
          .toSet();
      final hiddenBySystem = await GameRepository.getHiddenRomCountsBySystem();

      for (final system in allSystems) {
        if (system.folderName == 'all') continue;
        final romCount = await SystemRepository.getRomCountForSystem(
          system.id!,
        );

        bool hasFolderWhenNonRecursive = false;
        if (!system.recursiveScan) {
          final direct = await ConfigService.getFortSystemRomDirectory(
            system,
            esdeRoot: _config.esdeFolderPath,
          );
          if (direct != null &&
              await ConfigService.isFortRomDirectoryAccessible(direct)) {
            hasFolderWhenNonRecursive = true;
          } else {
            final lowerPrimary = system.folderName.toLowerCase();
            if (allExistingFolders.contains(lowerPrimary)) {
              hasFolderWhenNonRecursive = true;
            } else {
              for (final altFolder in system.folders) {
                if (allExistingFolders.contains(altFolder.toLowerCase())) {
                  hasFolderWhenNonRecursive = true;
                  break;
                }
              }
            }
          }
        }

        final bool isAndroidVirtual =
            (system.folderName == 'android' && Platform.isAndroid);
        if (romCount > 0 || hasFolderWhenNonRecursive || isAndroidVirtual) {
          final visibleRomCount = romCount - (hiddenBySystem[system.id!] ?? 0);
          systemsToKeep.add(system.copyWith(romCount: visibleRomCount));
          if (romCount > 0 && !virtualSystems.contains(system.folderName)) {
            emulatorSystemsWithGamesCount++;
          }
        }
      }

      if (emulatorSystemsWithGamesCount > 0) {
        final allSystem = allSystems.firstWhere((s) => s.folderName == 'all');
        final romCount = await SystemRepository.getRomCountForSystem(
          allSystem.id!,
        );
        systemsToKeep.add(allSystem.copyWith(romCount: romCount));
      }

      final db = await SqliteService.getDatabase();
      final favResult = await db.rawQuery(
        "SELECT COUNT(*) as count FROM user_roms WHERE is_favorite = 1 AND app_system_id != 'music'",
      );
      final hasFavorites =
          (int.tryParse(favResult.first['count'].toString()) ?? 0) > 0;
      if (hasFavorites) {
        try {
          final favSystem = allSystems.firstWhere(
            (s) => s.folderName == SystemFolderNames.favorites,
          );
          systemsToKeep.add(favSystem);
        } catch (_) {}
      }

      final folderNames = systemsToKeep.map((s) => s.folderName).toList();
      await SystemRepository.updateDetectedSystems(folderNames);
      await _refreshDetectedSystemsFromDatabase();
      _scanStatus = 'ROMs Scanned';
      _scanProgress = 1.0;
      _notify();
    } catch (e) {
      SqliteConfigProvider._log.e('Error scanning ROMs: $e');
      _scanStatus = 'Error scanning ROMs';
      _notify();
    } finally {
      _isScanningRoms = false;
    }
  }

  Future<ScanSummary> _scanSystemRoms(
    SystemModel system, {
    Map<String, Map<String, String>>? rootFoldersMap,
  }) async {
    try {
      // Fort treats ES-DE folder names as concrete library platforms while
      // retaining NeoStation's canonical system id as the emulation profile.
      // Resolve every ES-DE sibling for this profile and scan all of their ROM
      // roots in ONE SqliteDatabaseService pass. The upstream scanner performs
      // orphan cleanup once per call; doing one call per sibling would let the
      // second source incorrectly delete the first source's rows.
      final fortSources = await FortEsdeScanPlanService.resolve(
        system,
        esdeRoot: _config.esdeFolderPath,
      );

      if (fortSources.isNotEmpty) {
        final unavailable = <FortEsdeScanSource>[];
        for (final source in fortSources) {
          if (!await ConfigService.isFortRomDirectoryAccessible(
            source.romDirectory,
          )) {
            unavailable.add(source);
          }
        }

        if (unavailable.isNotEmpty) {
          final existingTotal = system.id == null
              ? system.romCount
              : await SystemRepository.getRomCountForSystem(system.id!);
          final missing = unavailable
              .map((source) => '${source.esdeSystemName}: ${source.romDirectory}')
              .join(', ');
          SqliteConfigProvider._log.w(
            'Fort grouped ROM source unavailable for ${system.realName}: '
            '$missing. Existing database rows are preserved.',
          );
          GlobalNotificationService().show(
            id: '$_fortRomPathNotificationPrefix${system.folderName}',
            title: '${system.realName} ROM storage unavailable',
            message:
                'At least one ES-DE platform mapped to this emulator profile '
                'cannot be read. Existing games were kept; reconnect storage '
                'or re-grant access.',
            type: GlobalNotificationType.error,
          );
          return ScanSummary(
            added: 0,
            removed: 0,
            total: existingTotal,
            systemName: system.realName,
          );
        }

        GlobalNotificationService().dismiss(
          '$_fortRomPathNotificationPrefix${system.folderName}',
        );

        final scanRoots = <String>[];
        final exactMaps = <String, Map<String, String>>{};
        for (final source in fortSources) {
          await FortEsdeLibraryService.upsertPlatform(
            esdeSystemName: source.esdeSystemName,
            appSystemId: system.id!,
            displayName: source.displayName,
            romDirectory: source.romDirectory,
            mediaDirectory: source.mediaDirectory,
            gamelistFile: source.gamelistFile,
            theme: source.theme,
            platformTags: source.platformTags,
          );

          if (!scanRoots.contains(source.romDirectory)) {
            scanRoots.add(source.romDirectory);
          }
          exactMaps
              .putIfAbsent(source.romDirectory, () => <String, String>{})
              [source.esdeSystemName.toLowerCase()] = source.romDirectory;
        }

        final summary = await SqliteDatabaseService.scanSystemRoms(
          system,
          scanRoots,
          ignoreHiddenFiles: _config.ignoreHiddenFiles,
          rootFoldersMap: exactMaps,
        );
        final tagged = await FortEsdeLibraryService.reconcileRomProvenance();
        SqliteConfigProvider._log.i(
          'Fort grouped ScanResult[${system.realName}] '
          'sources=${fortSources.map((s) => s.esdeSystemName).join(',')}: '
          'added=${summary.added} removed=${summary.removed} '
          'total=${summary.total} provenanceTagged=$tagged',
        );
        await refreshSystem(system, rootFoldersMap: exactMaps);
        if (system.folderName == 'steam') {
          SteamScraperService.scrapeSteamGames();
        }
        return summary;
      }

      final direct = await ConfigService.getFortSystemRomDirectory(
        system,
        esdeRoot: _config.esdeFolderPath,
      );

      if (direct != null) {
        final accessible = await ConfigService.isFortRomDirectoryAccessible(
          direct,
        );
        if (!accessible) {
          final existingTotal = system.id == null
              ? system.romCount
              : await SystemRepository.getRomCountForSystem(system.id!);
          SqliteConfigProvider._log.w(
            'Fort ROM source unavailable for ${system.realName}: $direct. '
            'Existing database rows are preserved.',
          );
          GlobalNotificationService().show(
            id: '$_fortRomPathNotificationPrefix${system.folderName}',
            title: '${system.realName} ROM storage unavailable',
            message:
                'The configured per-system ROM path cannot be read. '
                'Existing games were kept; reconnect storage or re-grant access.',
            type: GlobalNotificationType.error,
          );
          return ScanSummary(
            added: 0,
            removed: 0,
            total: existingTotal,
            systemName: system.realName,
          );
        }

        GlobalNotificationService().dismiss(
          '$_fortRomPathNotificationPrefix${system.folderName}',
        );
        final aliases = <String>{system.folderName, ...system.folders};
        final exactMap = <String, String>{
          for (final alias in aliases) alias.toLowerCase(): direct,
        };
        final summary = await SqliteDatabaseService.scanSystemRoms(
          system,
          [direct],
          ignoreHiddenFiles: _config.ignoreHiddenFiles,
          rootFoldersMap: {direct: exactMap},
        );
        SqliteConfigProvider._log.i(
          'Fort ScanResult[${system.realName}] source=$direct: '
          'added=${summary.added} removed=${summary.removed} total=${summary.total}',
        );
        await refreshSystem(system, rootFoldersMap: {direct: exactMap});
        if (system.folderName == 'steam') {
          SteamScraperService.scrapeSteamGames();
        }
        return summary;
      }

      if (_config.romFolders.isEmpty && system.folderName != 'android') {
        return ScanSummary(
          added: 0,
          removed: 0,
          total: system.romCount,
          systemName: system.realName,
        );
      }

      final summary = await SqliteDatabaseService.scanSystemRoms(
        system,
        _config.romFolders,
        ignoreHiddenFiles: _config.ignoreHiddenFiles,
        rootFoldersMap: rootFoldersMap,
      );

      SqliteConfigProvider._log.i(
        'ScanResult[${system.realName}]: added=${summary.added} '
        'removed=${summary.removed} total=${summary.total}',
      );
      await refreshSystem(system, rootFoldersMap: rootFoldersMap);
      if (system.folderName == 'steam') {
        SteamScraperService.scrapeSteamGames();
      }
      return summary;
    } catch (e) {
      SqliteConfigProvider._log.e('Error scanning ${system.realName}: $e');
      return ScanSummary(
        added: 0,
        removed: 0,
        total: system.romCount,
        systemName: system.realName,
      );
    }
  }

  Future<void> refreshSystem(
    SystemModel system, {
    Map<String, Map<String, String>>? rootFoldersMap,
  }) async {
    try {
      final updatedSystem = await SystemRepository.getSystemByFolderName(
        system.folderName,
      );
      if (updatedSystem == null) {
        SqliteConfigProvider._log.w(
          'System ${system.folderName} not found in DB during refresh',
        );
        return;
      }

      bool hasFolderWhenNonRecursive = false;
      if (!updatedSystem.recursiveScan) {
        final direct = await ConfigService.getFortSystemRomDirectory(
          updatedSystem,
          esdeRoot: _config.esdeFolderPath,
        );
        if (direct != null &&
            await ConfigService.isFortRomDirectoryAccessible(direct)) {
          hasFolderWhenNonRecursive = true;
        } else {
          final effectiveRootFoldersMap =
              rootFoldersMap ??
              await SqliteDatabaseService.getExistingSubdirectories(
                _config.romFolders,
              );
          final allExistingFolders = effectiveRootFoldersMap.values
              .expand((m) => m.keys.map((k) => k.toLowerCase()))
              .toSet();
          final lowerPrimary = updatedSystem.folderName.toLowerCase();
          if (allExistingFolders.contains(lowerPrimary)) {
            hasFolderWhenNonRecursive = true;
          } else {
            for (final altFolder in updatedSystem.folders) {
              if (allExistingFolders.contains(altFolder.toLowerCase())) {
                hasFolderWhenNonRecursive = true;
                break;
              }
            }
          }
        }
      }

      final totalRomCount = await SystemRepository.getRomCountForSystem(
        updatedSystem.id!,
      );
      final bool shouldKeep =
          totalRomCount > 0 ||
          hasFolderWhenNonRecursive ||
          (updatedSystem.folderName == 'android' && Platform.isAndroid) ||
          updatedSystem.folderName == 'all' ||
          updatedSystem.folderName == SystemFolderNames.favorites;

      if (shouldKeep) {
        await SystemRepository.addDetectedSystem(
          updatedSystem.id!,
          updatedSystem.folderName,
        );
      } else {
        await SystemRepository.removeDetectedSystem(updatedSystem.id!);
      }

      final index = _detectedSystems.indexWhere(
        (s) => s.folderName == system.folderName,
      );
      if (index != -1) {
        if (shouldKeep) {
          final currentSystem = _detectedSystems[index];
          _detectedSystems[index] = updatedSystem.copyWith(
            imageVersion: currentSystem.imageVersion + 1,
          );
        } else {
          _detectedSystems.removeAt(index);
        }
        _notify();
      } else if (shouldKeep) {
        await _refreshDetectedSystemsFromDatabase();
        _notify();
      }
    } catch (e) {
      SqliteConfigProvider._log.e(
        'Error updating system state for ${system.realName}: $e',
      );
    }
  }

  Future<void> selectRomFolder({
    bool scan = true,
    BuildContext? context,
  }) async {
    try {
      String? result;
      if (Platform.isAndroid) {
        final isTV = await PermissionService.isTelevision();
        if (isTV && context != null && context.mounted) {
          result = await TvDirectoryPicker.show(context);
        } else {
          try {
            final uri = await PermissionService.requestFolderAccess();
            result = uri?.toString();
          } on PlatformException catch (e) {
            if (e.code == 'PICKER_FAILED' &&
                context != null &&
                context.mounted) {
              result = await TvDirectoryPicker.show(context);
            }
          }
        }
      } else if (context != null && context.mounted) {
        result = await TvDirectoryPicker.pickDirectory(
          context,
          dialogTitle: 'Select ROM Folder',
        );
      } else {
        result = await FilePicker.getDirectoryPath(
          dialogTitle: 'Select ROM Folder',
        );
      }
      if (result != null) await addRomFolder(result, scan: scan);
    } catch (e) {
      SqliteConfigProvider._log.e('Error selecting rom folder: $e');
    }
  }

  Future<void> rescanSystem(SystemModel system) async {
    final hasDirect =
        await ConfigService.getFortSystemRomDirectory(
          system,
          esdeRoot: _config.esdeFolderPath,
        ) !=
        null;
    if (_config.romFolders.isEmpty && !hasDirect) return;

    try {
      _setLoading(true);
      await _scanSystemRoms(system);
    } catch (e) {
      _error = 'Error rescanning ${system.realName}: $e';
      SqliteConfigProvider._log.e('$_error');
    } finally {
      _setLoading(false);
      _notify();
    }
  }

  Future<void> refreshAllFilesAccess() async {
    if (!Platform.isAndroid) return;
    try {
      final hasAccess = await PermissionService.hasAllFilesAccess();
      if (hasAccess != _hasAllFilesAccess) {
        _hasAllFilesAccess = hasAccess;
        _notify();
      }
    } catch (e) {
      SqliteConfigProvider._log.e(
        'Error refreshing all files access in provider: $e',
      );
    }
  }

  Future<ScanSummary> rescanSystemSilent(SystemModel system) async {
    final hasDirect =
        await ConfigService.getFortSystemRomDirectory(
          system,
          esdeRoot: _config.esdeFolderPath,
        ) !=
        null;
    if (_config.romFolders.isEmpty && !hasDirect) {
      return ScanSummary(
        added: 0,
        removed: 0,
        total: 0,
        systemName: system.realName,
      );
    }

    try {
      _isSilentScanning = true;
      _silentScannedSystem = system;
      _lastScanSummary = null;
      _notify();
      final summary = await _scanSystemRoms(system);
      _lastScanSummary = summary;
      return summary;
    } catch (e) {
      SqliteConfigProvider._log.e(
        'Error rescanning silent ${system.realName}: $e',
      );
      return ScanSummary(
        added: 0,
        removed: 0,
        total: system.romCount,
        systemName: system.realName,
      );
    } finally {
      _isSilentScanning = false;
      _silentScannedSystem = null;
      _notify();
    }
  }

  Future<void> clearConfig() async {
    try {
      _setLoading(true);
      await SqliteConfigService.clearUserConfig();
      _config = ConfigModel.empty;
      _detectedSystems = [];
      _scanCompleted = false;
      _totalSystemsToScan = 0;
      _scannedSystemsCount = 0;
      _scanProgress = 0.0;
      _scanStatus = '';
    } catch (e) {
      _error = 'Error clearing config: $e';
      SqliteConfigProvider._log.e('$_error');
    } finally {
      _setLoading(false);
      _notify();
    }
  }

  Future<Map<String, int>> getQuickStats() async {
    try {
      return await SystemRepository.getSystemStats();
    } catch (e) {
      SqliteConfigProvider._log.e('Error getting stats: $e');
      return {};
    }
  }

  Future<void> _loadConfig() async {
    _config = await SqliteConfigService.loadConfig();
    if (_detectedSystems.isNotEmpty) _sortDetectedSystems();
  }

  Future<void> _loadAvailableSystems() async {
    _availableSystems = await SqliteConfigService.loadAvailableSystems();
  }

  Future<void> reloadSystemDefinitions() async {
    await Future.wait([_loadAvailableSystems(), _loadAvailableEmulators()]);
    _notify();
  }

  Future<void> _loadHiddenSystems() async {
    try {
      _hiddenSystems = await SystemRepository.getHiddenSystems();
    } catch (e) {
      SqliteConfigProvider._log.e('Error loading hidden systems: $e');
      _hiddenSystems = {};
    }
  }

  Future<void> toggleSystemHidden(String folderName) async {
    final isNowHidden = !_hiddenSystems.contains(folderName);
    if (isNowHidden) {
      _hiddenSystems = {..._hiddenSystems, folderName};
    } else {
      _hiddenSystems = _hiddenSystems.where((f) => f != folderName).toSet();
    }
    await SystemRepository.setSystemHidden(folderName, isNowHidden);
    _notify();
  }

  Future<void> _loadAvailableEmulators() async {
    _availableEmulators = await SqliteConfigService.loadAvailableEmulators();
  }

  Future<void> _loadDetectedSystems() async {
    try {
      final systems = await SystemRepository.getDetectedSystems();
      _detectedSystems = systems;
      _sortDetectedSystems();
      SqliteConfigProvider._log.i(
        'Detected systems loaded from DB: ${systems.length}',
      );
      for (var s in systems) {
        SqliteConfigProvider._log.d(' - ${s.folderName}: ${s.romCount} ROMs');
      }
      final systemNames = systems.map((s) => s.folderName).toList();
      if (_config.detectedSystems.length != systemNames.length) {
        _config = _config.copyWith(detectedSystems: systemNames);
      }
      _notify();
    } catch (e) {
      SqliteConfigProvider._log.e('Error loading detected systems: $e');
    }
  }

  Future<void> refreshDetectedSystems() async {
    await _loadDetectedSystems();
  }

  Future<void> _refreshDetectedSystemsFromDatabase() async {
    try {
      _detectedSystems = await SystemRepository.getDetectedSystems();
      _sortDetectedSystems();
    } catch (e) {
      SqliteConfigProvider._log.e('Error updating systems from DB: $e');
    }
  }

  void _sortDetectedSystems() {
    if (_detectedSystems.isEmpty) return;
    final sortBy = _config.systemSortBy;
    final isAsc = _config.systemSortOrder == 'asc';
    final priorityMap = <String, int>{
      'all': 1,
      'favorites': 2,
      'music': 3,
      'android': 4,
    };

    _detectedSystems.sort((a, b) {
      final pA = priorityMap[a.folderName] ?? 999;
      final pB = priorityMap[b.folderName] ?? 999;
      if (pA != pB) return pA.compareTo(pB);
      if (pA != 999) return 0;

      int comparison = 0;
      if (sortBy == 'year') {
        comparison = (a.launchDate ?? '9999').compareTo(b.launchDate ?? '9999');
      } else if (sortBy == 'manufacturer') {
        comparison = (a.manufacturer ?? '').toLowerCase().compareTo(
          (b.manufacturer ?? '').toLowerCase(),
        );
        if (comparison == 0) {
          comparison = (a.launchDate ?? '9999').compareTo(
            b.launchDate ?? '9999',
          );
        }
      } else if (sortBy == 'manufacturer_type') {
        comparison = (a.manufacturer ?? '').toLowerCase().compareTo(
          (b.manufacturer ?? '').toLowerCase(),
        );
        if (comparison == 0) {
          comparison = (a.type ?? '').toLowerCase().compareTo(
            (b.type ?? '').toLowerCase(),
          );
        }
        if (comparison == 0) {
          comparison = (a.launchDate ?? '9999').compareTo(
            b.launchDate ?? '9999',
          );
        }
      } else {
        comparison = a.realName.toLowerCase().compareTo(
          b.realName.toLowerCase(),
        );
      }
      return isAsc ? comparison : -comparison;
    });
  }
}
