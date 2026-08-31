import 'dart:io';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/widgets/confirm_action_dialog.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/esde_import_service.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/repositories/config_repository.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/permission_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/services/user_data_location_service.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/widgets/move_user_data_dialog.dart';
import 'package:neostation/widgets/permission_check_wrapper.dart';
import 'package:neostation/widgets/restart_required_dialog.dart';
import 'package:neostation/widgets/tv_directory_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:neostation/utils/adaptive_scroll.dart';
import 'settings_title.dart';
import 'widgets/settings_section_header.dart';
import 'widgets/settings_action_button.dart';

class DirectoriesSettingsContent extends StatefulWidget {
  final bool isContentFocused;
  final int selectedContentIndex;

  const DirectoriesSettingsContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
  });

  @override
  State<DirectoriesSettingsContent> createState() =>
      DirectoriesSettingsContentState();
}

class DirectoriesSettingsContentState
    extends State<DirectoriesSettingsContent> {
  final ScrollController _scrollController = ScrollController();
  final AdaptiveScroller _scroller = AdaptiveScroller();

  /// GlobalKeys for the navigable rows, used to keep the focused row visible
  /// during gamepad navigation.
  final List<GlobalKey> _itemKeys = [];

  /// Grows [_itemKeys] to cover the current navigable-item count.
  void _ensureKeys(int count) {
    while (_itemKeys.length < count) {
      _itemKeys.add(GlobalKey());
    }
  }

  List<String> _currentRomFolders = [];
  String? _currentUserDataPath;
  bool _isLoading = true;

  // Migration progress state (shown inline, no dialog).
  bool _isMigrating = false;
  double _migrationProgress = 0.0;
  String _migrationFile = '';

  // ES-DE import progress state (shown inline, no dialog).
  bool _isImporting = false;
  double _importProgress = 0.0;
  String _importLabel = '';
  EsdeImportResult? _lastEsdeResult;

  static final _log = LoggerService.instance;

  // Flat list of navigable items used for gamepad index tracking.
  // Layout: user_data | rescan | add_rom | remove_rom:N...
  final List<Map<String, dynamic>> _directoryItems = [];

  @override
  void initState() {
    super.initState();
    _loadCurrentPaths();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void scrollToIndex(int index) {
    _scroller.ensureVisibleIndex(
      index,
      keys: _itemKeys,
      controller: _scrollController,
    );
  }

  void _buildDirectoryItems() {
    _directoryItems.clear();

    _directoryItems.add({
      'title': AppLocale.userDataLocation,
      'subtitle': AppLocale.userDataLocationSubtitle,
      'action': 'user_data',
    });

    _directoryItems.add({
      'title': AppLocale.rescanAllFolders,
      'subtitle': AppLocale.rescanAllFoldersSubtitle,
      'action': 'rescan',
    });

    _directoryItems.add({
      'title': AppLocale.addRomFolder,
      'subtitle': AppLocale.romsFolderSubtitle,
      'action': 'add_rom',
    });

    for (final path in _currentRomFolders) {
      _directoryItems.add({
        'title': path,
        'subtitle': AppLocale.pressToRemoveFolder,
        'action': 'remove_rom',
        'path': path,
      });
    }

    _esdeSectionStart = _directoryItems.length;
    _directoryItems.add({
      'title': AppLocale.esdeSelectFolder,
      'subtitle': AppLocale.esdeSelectFolderSubtitle,
      'action': 'esde_select_folder',
    });
    _directoryItems.add({
      'title': AppLocale.esdeRunImport,
      'subtitle': AppLocale.esdeRunImportSubtitle,
      'action': 'esde_run_import',
    });
    _directoryItems.add({
      'title': AppLocale.esdeReset,
      'subtitle': AppLocale.esdeResetSubtitle,
      'action': 'esde_reset',
    });
  }

  int _esdeSectionStart = -1;

  static const Set<String> _esdeActions = {
    'esde_select_folder',
    'esde_run_import',
    'esde_reset',
  };

  /// Fort treats ES-DE as a first-class library source. Selecting or resetting
  /// ES-DE must never depend on a separate NeoStation ROM folder existing.
  /// Only the import action itself needs a configured ES-DE root.
  bool _isEsdeDisabled(String action) {
    if (!_esdeActions.contains(action)) return false;
    return action == 'esde_run_import' && _esdePath.trim().isEmpty;
  }

  Future<void> _loadCurrentPaths() async {
    try {
      final foldersFuture = ConfigRepository.getUserRomFolders();
      final userDataFuture = ConfigService.getUserDataPath();
      _currentRomFolders = await foldersFuture;
      _currentUserDataPath = await userDataFuture;
    } catch (e) {
      _log.e('Failed to load directory configuration: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _buildDirectoryItems();
        });
      }
    }
  }

  Future<void> _handleItemTap(Map<String, dynamic> item) async {
    final action = item['action'] as String;
    if (_isEsdeDisabled(action)) return;
    final configProvider = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    );
    switch (item['action']) {
      case 'user_data':
        await _selectUserDataLocation();
        break;
      case 'rescan':
        await configProvider.scanSystems();
        break;
      case 'add_rom':
        await _selectRomFolder();
        break;
      case 'remove_rom':
        await _removeRomFolder(item['path'] as String);
        break;
      case 'esde_select_folder':
        await _selectEsdeFolder();
        break;
      case 'esde_run_import':
        await _runEsdeImport();
        break;
      case 'esde_reset':
        await _resetEsdeImport();
        break;
    }
  }

  String get _esdePath =>
      context.read<SqliteConfigProvider>().config.esdeFolderPath;

  Future<void> _selectEsdeFolder() async {
    try {
      String? selected;

      if (Platform.isAndroid) {
        final isTV = await PermissionService.isTelevision();
        if (!mounted) return;
        if (isTV) {
          selected = await TvDirectoryPicker.show(context);
        } else {
          try {
            final uri = await PermissionService.requestFolderAccess();
            if (uri != null) {
              final uriStr = uri.toString();
              // ES-DE is a READ SOURCE, not a NeoStation user-data
              // destination. Never use resolveAndroidUserDataPath here: when
              // All-Files access is absent that method deliberately redirects
              // to Android/data/<pkg>/user-data, which silently changes the
              // folder the user selected. Keep the exact selected volume/path.
              selected = UserDataLocationService.safUriToRealPath(uriStr);
              if (selected == null) {
                throw StateError(
                  'The selected Android folder cannot be mapped to a readable '
                  'filesystem path. Grant All files access and select the '
                  'ES-DE folder again.',
                );
              }
            }
          } on PlatformException catch (e) {
            if (e.code == 'PICKER_FAILED' && mounted) {
              selected = await TvDirectoryPicker.show(context);
            }
          }
        }
      } else {
        selected = await TvDirectoryPicker.pickDirectory(
          context,
          dialogTitle: AppLocale.esdeSelectFolder.getString(context),
        );
      }

      if (selected == null || !mounted) return;
      if (selected.endsWith(Platform.pathSeparator)) {
        selected = selected.substring(0, selected.length - 1);
      }

      final root = Directory(selected);
      final looksLikeEsde =
          root.existsSync() &&
          (File('$selected/settings/es_settings.xml').existsSync() ||
              File('$selected/custom_systems/es_systems.xml').existsSync() ||
              Directory('$selected/gamelists').existsSync());
      if (!looksLikeEsde) {
        AppNotification.showNotification(
          context,
          AppLocale.esdeImportNotEsdeFolder.getString(context),
          type: NotificationType.error,
        );
        return;
      }

      final configProvider = context.read<SqliteConfigProvider>();
      await configProvider.updateEsdeFolderPath(selected);
      // Selecting ES-DE can be the first/only library source. Scan immediately
      // so its ROMDirectory/custom systems create ROM provenance before the
      // metadata import tries to match gamelist entries.
      await configProvider.scanSystems();
      if (mounted) await context.read<FileProvider>().refreshEsde();
      if (mounted) setState(() {});
    } catch (e) {
      _log.e('ES-DE folder selection failed: $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          '$e',
          type: NotificationType.error,
        );
      }
    }
  }

  Future<void> _runEsdeImport() async {
    final root = _esdePath;
    if (root.trim().isEmpty) {
      AppNotification.showNotification(
        context,
        AppLocale.esdeImportNoFolder.getString(context),
        type: NotificationType.info,
      );
      return;
    }
    if (_isImporting) return;

    const notificationId = 'esde_import_progress';
    final localeEsdeImporting = AppLocale.esdeImporting.getString(context);
    final localeEsdeImportNotEsdeFolder = AppLocale.esdeImportNotEsdeFolder
        .getString(context);
    final localeEsdeImportNothingFound = AppLocale.esdeImportNothingFound
        .getString(context);
    final localeEsdeImportComplete = AppLocale.esdeImportComplete.getString(
      context,
    );
    final localeEsdeSummaryGames = AppLocale.esdeSummaryGames.getString(
      context,
    );
    final localeEsdeSummarySystems = AppLocale.esdeSummarySystems.getString(
      context,
    );

    setState(() {
      _isImporting = true;
      _importProgress = 0.0;
      _importLabel = '';
      _lastEsdeResult = null;
    });

    GlobalNotificationService().show(
      id: notificationId,
      message: localeEsdeImporting,
      type: GlobalNotificationType.info,
      progress: 0,
    );

    EsdeImportResult? result;
    String? error;
    try {
      result = await EsdeImportService.import(
        root,
        onProgress: (p, label) {
          if (mounted) {
            setState(() {
              _importProgress = p;
              _importLabel = label;
            });
          }
          GlobalNotificationService().update(
            id: notificationId,
            message: label.isEmpty
                ? localeEsdeImporting
                : '$localeEsdeImporting: $label',
            type: GlobalNotificationType.info,
            progress: p,
          );
        },
      );
      if (mounted) await context.read<FileProvider>().refreshEsde();
    } catch (e) {
      error = e.toString();
      _log.e('ES-DE import failed: $e');
    }

    if (error != null) {
      GlobalNotificationService().update(
        id: notificationId,
        message: error,
        type: GlobalNotificationType.error,
        progress: null,
      );
    } else if (result != null) {
      if (!result.gamelistsDirFound) {
        GlobalNotificationService().update(
          id: notificationId,
          message: localeEsdeImportNotEsdeFolder,
          type: GlobalNotificationType.error,
          progress: null,
        );
      } else if (result.gamesImported == 0 && result.systemsMatched == 0) {
        GlobalNotificationService().update(
          id: notificationId,
          message: localeEsdeImportNothingFound,
          type: GlobalNotificationType.info,
          progress: null,
        );
      } else {
        GlobalNotificationService().update(
          id: notificationId,
          message:
              '$localeEsdeImportComplete: '
              '${result.gamesImported} $localeEsdeSummaryGames, '
              '${result.systemsMatched} $localeEsdeSummarySystems',
          type: GlobalNotificationType.success,
          progress: null,
        );
      }
    }

    if (!mounted) return;
    final showSummary =
        error == null &&
        result != null &&
        result.gamelistsDirFound &&
        (result.gamesImported > 0 || result.systemsMatched > 0);
    setState(() {
      _isImporting = false;
      _lastEsdeResult = showSummary ? result : null;
    });
  }

  Future<void> _resetEsdeImport() async {
    if (_isImporting) return;

    final confirmed = await ConfirmActionDialog.show(
      context,
      title: AppLocale.esdeReset.getString(context),
      body: AppLocale.esdeResetConfirmBody.getString(context),
      confirmLabel: AppLocale.esdeReset.getString(context),
      icon: Symbols.restart_alt_rounded,
    );
    if (!confirmed || !mounted) return;

    try {
      final cleared = await EsdeImportService.reset();
      if (mounted) {
        await context.read<SqliteConfigProvider>().updateEsdeFolderPath('');
      }
      if (mounted) await context.read<FileProvider>().refreshEsde();
      if (!mounted) return;
      setState(() => _lastEsdeResult = null);
      AppNotification.showNotification(
        context,
        '${AppLocale.esdeResetComplete.getString(context)} ($cleared)',
        type: NotificationType.info,
      );
    } catch (e) {
      _log.e('ES-DE reset failed: $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          '$e',
          type: NotificationType.error,
        );
      }
    }
  }

  Future<void> _selectRomFolder() async {
    final configProvider = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    );

    if (configProvider.config.romFolders.length >= 5) {
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.maxRomFoldersReached.getString(context),
          type: NotificationType.info,
        );
      }
      return;
    }

    try {
      String? selected;

      if (Platform.isAndroid) {
        final isTV = await PermissionService.isTelevision();
        if (isTV) {
          if (mounted) selected = await TvDirectoryPicker.show(context);
        } else {
          try {
            final uri = await PermissionService.requestFolderAccess();
            selected = uri?.toString();
          } on PlatformException catch (e) {
            if (e.code == 'PICKER_FAILED' && mounted) {
              selected = await TvDirectoryPicker.show(context);
            }
          }
        }
      } else {
        selected = await TvDirectoryPicker.pickDirectory(
          context,
          dialogTitle: AppLocale.selectRomsFolder.getString(context),
        );
      }

      if (selected != null) {
        await configProvider.addRomFolder(selected);
        await _loadCurrentPaths();
      }
    } catch (e) {
      _log.e('ROM folder selection failed: $e');
    }
  }

  Future<void> _removeRomFolder(String path) async {
    final confirmed = await ConfirmActionDialog.show(
      context,
      title: AppLocale.removeRomFolder.getString(context),
      body: AppLocale.removeRomFolderConfirmBody.getString(context),
      confirmLabel: AppLocale.removeRomFolder.getString(context),
      icon: Symbols.folder_delete_rounded,
    );
    if (!confirmed || !mounted) return;

    final configProvider = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    );
    try {
      await configProvider.removeRomFolder(path);
      await _loadCurrentPaths();
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.romFolderRemoved.getString(context),
          type: NotificationType.info,
        );
      }
    } catch (e) {
      _log.e('Failed to remove ROM folder: $e');
    }
  }

  Future<void> _selectUserDataLocation() async {
    try {
      String? selected;

      if (Platform.isAndroid) {
        final isTV = await PermissionService.isTelevision();
        if (!mounted) return;
        if (isTV) {
          selected = await TvDirectoryPicker.show(context);
        } else {
          try {
            final uri = await PermissionService.requestFolderAccess();
            if (uri != null) {
              final uriStr = uri.toString();
              final hasFiles = await PermissionService.hasAllFilesAccess();
              selected =
                  await UserDataLocationService.resolveAndroidUserDataPath(
                    uriStr,
                    hasAllFilesAccess: hasFiles,
                  ) ??
                  UserDataLocationService.safUriToRealPath(uriStr);
            }
          } on PlatformException catch (e) {
            if (e.code == 'PICKER_FAILED' && mounted) {
              selected = await TvDirectoryPicker.show(context);
            }
          }
        }
      } else {
        selected = await TvDirectoryPicker.pickDirectory(
          context,
          dialogTitle: AppLocale.selectUserDataFolder.getString(context),
          initialDirectory: _currentUserDataPath,
        );
      }

      if (selected == null || !mounted) return;
      if (selected.endsWith(Platform.pathSeparator)) {
        selected = selected.substring(0, selected.length - 1);
      }

      final current = _currentUserDataPath;
      if (current == null || selected == current) return;

      final entryCount = await UserDataLocationService.countDirectoryEntries(
        selected,
      );
      if (!mounted) return;
      final proceed = await MoveUserDataDialog.show(
        context,
        fromPath: current,
        toPath: selected,
        destItemCount: entryCount,
      );
      if (!proceed || !mounted) return;

      await _migrateUserData(sourcePath: current, destPath: selected);
    } catch (e) {
      _log.e('User data location selection failed: $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          '${AppLocale.migratingUserDataError.getString(context)}: $e',
          type: NotificationType.error,
        );
      }
    }
  }

  Future<void> _migrateUserData({
    required String sourcePath,
    required String destPath,
  }) async {
    if (!mounted) return;
    String? migrationError;

    setState(() {
      _isMigrating = true;
      _migrationProgress = 0.0;
      _migrationFile = '';
    });

    try {
      final currentMediaPath = await ConfigService.getMediaPath();
      await UserDataLocationService.migrateData(
        sourceUserDataPath: sourcePath,
        sourceMediaPath: currentMediaPath,
        destPath: destPath,
        onProgress: (p, file) {
          if (mounted) {
            setState(() {
              _migrationProgress = p;
              _migrationFile = file;
            });
          }
        },
      );
      await UserDataLocationService.setCustomPath(destPath);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(PermissionCheckWrapper.setupCompletedKey, true);
    } catch (e) {
      migrationError = e.toString();
      _log.e('Migration failed: $e');
    }

    if (mounted) setState(() => _isMigrating = false);

    if (migrationError != null) {
      if (mounted) {
        AppNotification.showNotification(
          context,
          '${AppLocale.migratingUserDataError.getString(context)}: $migrationError',
          type: NotificationType.error,
        );
      }
      return;
    }

    if (mounted) setState(() => _currentUserDataPath = destPath);

    if (mounted) {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const RestartRequiredDialog(),
      );
    }
  }

  int getItemCount() => _directoryItems.length;

  void selectItem(int index) {
    if (index < _directoryItems.length) {
      _handleItemTap(_directoryItems[index]);
    }
  }

  Widget _buildMigrationProgress(ThemeData theme) {
    if (!_isMigrating) return const SizedBox.shrink();
    final pct = _migrationProgress;
    final isCopying = pct < 0.5;
    return Container(
      margin: EdgeInsets.only(bottom: 12.r),
      padding: EdgeInsets.all(12.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
          width: 1.r,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                isCopying
                    ? AppLocale.migratingUserData.getString(context)
                    : '${AppLocale.delete.getString(context)}...',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 10.r,
                  color: theme.colorScheme.primary,
                ),
              ),
              Text(
                '${(pct * 100).toInt()}%',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 10.r,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          SizedBox(height: 8.r),
          ClipRRect(
            borderRadius: BorderRadius.circular(4.r),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 6.r,
              backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.1),
              valueColor: AlwaysStoppedAnimation<Color>(
                theme.colorScheme.primary,
              ),
            ),
          ),
          if (_migrationFile.isNotEmpty) ...[
            SizedBox(height: 4.r),
            Text(
              _migrationFile,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 9.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                fontFamily: 'monospace',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildScanProgress(ThemeData theme, SqliteConfigProvider provider) {
    if (!provider.isScanning) return const SizedBox.shrink();
    return Container(
      margin: EdgeInsets.only(bottom: 12.r),
      padding: EdgeInsets.all(12.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
          width: 1.r,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                provider.scanStatus,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 10.r,
                  color: theme.colorScheme.primary,
                ),
              ),
              Text(
                '${(provider.scanProgress * 100).toInt()}%',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 10.r,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          SizedBox(height: 8.r),
          ClipRRect(
            borderRadius: BorderRadius.circular(4.r),
            child: LinearProgressIndicator(
              value: provider.totalSystemsToScan > 0
                  ? provider.scanProgress
                  : null,
              minHeight: 6.r,
              backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.1),
              valueColor: AlwaysStoppedAnimation<Color>(
                theme.colorScheme.primary,
              ),
            ),
          ),
          if (provider.totalSystemsToScan > 0) ...[
            SizedBox(height: 4.r),
            Text(
              '${AppLocale.scanningSystem.getString(context)} ${provider.scannedSystemsCount} of ${provider.totalSystemsToScan}',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 9.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsTitle(
            title: AppLocale.configureDirectories.getString(context),
            subtitle: AppLocale.configureRomsFolder.getString(context),
          ),
          SizedBox(height: 24.h),
          const Center(child: CircularProgressIndicator()),
        ],
      );
    }

    return Consumer<SqliteConfigProvider>(
      builder: (context, configProvider, child) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SettingsTitle(
              title: AppLocale.configureDirectories.getString(context),
              subtitle: AppLocale.configureRomsFolder.getString(context),
            ),
            SizedBox(height: 12.r),
            _buildMigrationProgress(theme),
            _buildScanProgress(theme, configProvider),
            _buildEsdeProgress(theme),
            _buildEsdeResultSummary(theme),
            Expanded(
              child: Builder(
                builder: (context) {
                  final visualRows = <Map<String, dynamic>>[];
                  for (var i = 0; i < _directoryItems.length; i++) {
                    if (i == 2) {
                      visualRows.add({
                        'header': AppLocale.romDirectories.getString(context),
                      });
                    }
                    if (i == _esdeSectionStart) {
                      visualRows.add({
                        'header': AppLocale.esdeImport.getString(context),
                      });
                    }
                    visualRows.add({'nav': i});
                  }
                  _ensureKeys(_directoryItems.length);

                  return ListView.builder(
                    controller: _scrollController,
                    physics: const ClampingScrollPhysics(),
                    itemCount: visualRows.length,
                    itemBuilder: (context, visualIndex) {
                      final row = visualRows[visualIndex];
                      if (row.containsKey('header')) {
                        return SettingsSectionHeader(
                          label: row['header'] as String,
                        );
                      }

                      final navIndex = row['nav'] as int;
                      final item = _directoryItems[navIndex];
                      final isSelected =
                          widget.isContentFocused &&
                          widget.selectedContentIndex == navIndex;

                      final isRemoveItem = item['action'] == 'remove_rom';
                      final isUserData = item['action'] == 'user_data';
                      final isEsdeDisabled = _isEsdeDisabled(
                        item['action'] as String,
                      );
                      final borderColor = isSelected
                          ? (isRemoveItem
                                ? theme.colorScheme.error
                                : theme.colorScheme.primary)
                          : theme.colorScheme.outline.withValues(alpha: 0);

                      return Opacity(
                        key: _itemKeys[navIndex],
                        opacity: isEsdeDisabled ? 0.4 : 1.0,
                        child: Container(
                          decoration: BoxDecoration(
                            color: isSelected && isRemoveItem
                                ? theme.colorScheme.error.withValues(
                                    alpha: 0.08,
                                  )
                                : theme.cardColor.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(12.r),
                            border: Border.all(
                              color: borderColor,
                              width: isSelected ? 2.r : 1.r,
                            ),
                          ),
                          margin: EdgeInsets.only(bottom: 8.r),
                          child: InkWell(
                            onTap: isEsdeDisabled
                                ? null
                                : () {
                                    SfxService().playNavSound();
                                    _handleItemTap(item);
                                  },
                            borderRadius: BorderRadius.circular(12.r),
                            canRequestFocus: false,
                            focusColor: Colors.transparent,
                            hoverColor: Colors.transparent,
                            highlightColor: Colors.transparent,
                            splashColor: Colors.transparent,
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 12.r,
                                vertical: 8.r,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        _iconFor(item['action'] as String),
                                        color: isSelected
                                            ? (isRemoveItem
                                                  ? theme.colorScheme.error
                                                  : theme.colorScheme.primary)
                                            : theme.colorScheme.onSurface,
                                        size: 20.r,
                                      ),
                                      SizedBox(width: 12.r),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              isRemoveItem
                                                  ? (item['title'] as String)
                                                  : (item['title'] as String)
                                                        .getString(context),
                                              style: theme.textTheme.titleSmall
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: isRemoveItem
                                                        ? 10.r
                                                        : 12.r,
                                                    color: isSelected
                                                        ? (isRemoveItem
                                                              ? theme
                                                                    .colorScheme
                                                                    .error
                                                              : theme
                                                                    .colorScheme
                                                                    .primary)
                                                        : theme
                                                              .colorScheme
                                                              .onSurface,
                                                    fontFamily: isRemoveItem
                                                        ? 'monospace'
                                                        : null,
                                                  ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            SizedBox(height: 2.r),
                                            Text(
                                              (item['subtitle'] as String)
                                                  .getString(context),
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                    color:
                                                        isSelected &&
                                                            isRemoveItem
                                                        ? theme
                                                              .colorScheme
                                                              .error
                                                              .withValues(
                                                                alpha: 0.7,
                                                              )
                                                        : theme
                                                              .colorScheme
                                                              .onSurface
                                                              .withValues(
                                                                alpha: 0.6,
                                                              ),
                                                    fontSize: 9.r,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (isRemoveItem)
                                        SettingsActionButton(
                                          icon: Symbols.delete_outline_rounded,
                                          selected: isSelected,
                                          isDestructive: true,
                                        )
                                      else if (item['action'] == 'add_rom')
                                        SettingsActionButton(
                                          icon: Symbols.add_rounded,
                                          selected: isSelected,
                                        )
                                      else if (item['action'] == 'rescan')
                                        SettingsActionButton(
                                          icon: Symbols.refresh_rounded,
                                          selected: isSelected,
                                        )
                                      else if (isUserData)
                                        SettingsActionButton(
                                          icon: Symbols.edit_rounded,
                                          selected: isSelected,
                                        )
                                      else if (item['action'] ==
                                          'esde_select_folder')
                                        SettingsActionButton(
                                          icon: Symbols.folder_special_rounded,
                                          selected: isSelected,
                                        )
                                      else if (item['action'] ==
                                          'esde_run_import')
                                        SettingsActionButton(
                                          icon: Symbols.download_rounded,
                                          selected: isSelected,
                                        )
                                      else if (item['action'] == 'esde_reset')
                                        SettingsActionButton(
                                          icon: Symbols.restart_alt_rounded,
                                          selected: isSelected,
                                          isDestructive: true,
                                        ),
                                    ],
                                  ),
                                  if (item['action'] == 'esde_select_folder' &&
                                      _esdePath.trim().isNotEmpty) ...[
                                    SizedBox(height: 6.r),
                                    _buildPathChip(theme, _esdePath),
                                  ],
                                  if (isUserData &&
                                      _currentUserDataPath != null) ...[
                                    SizedBox(height: 6.r),
                                    Container(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 8.r,
                                        vertical: 4.r,
                                      ),
                                      decoration: BoxDecoration(
                                        color: theme.colorScheme.primary
                                            .withValues(alpha: 0.06),
                                        borderRadius: BorderRadius.circular(
                                          6.r,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Symbols.folder_rounded,
                                            size: 11.r,
                                            color: theme.colorScheme.primary
                                                .withValues(alpha: 0.5),
                                          ),
                                          SizedBox(width: 6.r),
                                          Expanded(
                                            child: Text(
                                              _currentUserDataPath!,
                                              style: TextStyle(
                                                fontSize: 9.r,
                                                color: theme
                                                    .colorScheme
                                                    .onSurface
                                                    .withValues(alpha: 0.55),
                                                fontFamily: 'monospace',
                                              ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  IconData _iconFor(String action) {
    switch (action) {
      case 'user_data':
        return Symbols.folder_special_rounded;
      case 'rescan':
        return Symbols.refresh_rounded;
      case 'add_rom':
        return Symbols.folder_rounded;
      case 'remove_rom':
        return Symbols.folder_rounded;
      case 'esde_select_folder':
        return Symbols.folder_special_rounded;
      case 'esde_run_import':
        return Symbols.download_rounded;
      case 'esde_reset':
        return Symbols.restart_alt_rounded;
      default:
        return Symbols.folder_rounded;
    }
  }

  Widget _buildPathChip(ThemeData theme, String path) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6.r),
      ),
      child: Row(
        children: [
          Icon(
            Symbols.folder_rounded,
            size: 11.r,
            color: theme.colorScheme.primary.withValues(alpha: 0.5),
          ),
          SizedBox(width: 6.r),
          Expanded(
            child: Text(
              path,
              style: TextStyle(
                fontSize: 9.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                fontFamily: 'monospace',
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEsdeProgress(ThemeData theme) {
    if (!_isImporting) return const SizedBox.shrink();
    final pct = _importProgress;
    return Container(
      margin: EdgeInsets.only(bottom: 12.r),
      padding: EdgeInsets.all(12.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
          width: 1.r,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                AppLocale.esdeImporting.getString(context),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 10.r,
                  color: theme.colorScheme.primary,
                ),
              ),
              Text(
                '${(pct * 100).toInt()}%',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 10.r,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          SizedBox(height: 8.r),
          ClipRRect(
            borderRadius: BorderRadius.circular(4.r),
            child: LinearProgressIndicator(
              value: pct > 0 ? pct : null,
              minHeight: 6.r,
              backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.1),
              valueColor: AlwaysStoppedAnimation<Color>(
                theme.colorScheme.primary,
              ),
            ),
          ),
          if (_importLabel.isNotEmpty) ...[
            SizedBox(height: 4.r),
            Text(
              _importLabel,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 9.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                fontFamily: 'monospace',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEsdeResultSummary(ThemeData theme) {
    final r = _lastEsdeResult;
    if (r == null || _isImporting) return const SizedBox.shrink();
    return Container(
      margin: EdgeInsets.only(bottom: 12.r),
      padding: EdgeInsets.all(12.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12.r),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocale.esdeImportComplete.getString(context),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              fontSize: 11.r,
              color: theme.colorScheme.primary,
            ),
          ),
          SizedBox(height: 4.r),
          Text(
            '${AppLocale.esdeSummarySystemsMatched.getString(context)}: ${r.systemsMatched}   '
            '${AppLocale.esdeSummaryUnmatched.getString(context)}: ${r.systemsUnmatched}   '
            '${AppLocale.esdeSummarySkipped.getString(context)}: ${r.systemsSkipped}\n'
            '${AppLocale.esdeSummaryGamesImported.getString(context)}: ${r.gamesImported}   '
            '${AppLocale.esdeSummaryNoRomMatch.getString(context)}: ${r.gamesUnmatched}\n'
            '${AppLocale.esdeSummaryStatsUpdated.getString(context)}: ${r.statsUpdated}',
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 9.5.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}
