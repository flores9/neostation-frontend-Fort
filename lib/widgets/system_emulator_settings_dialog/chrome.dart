part of '../system_emulator_settings_dialog.dart';

/// Dialog chrome for the settings dialog.
extension _Chrome on _SystemEmulatorSettingsDialogState {
  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(
              Theme.of(context).colorScheme.secondary,
            ),
          ),
          SizedBox(height: 12.r),
          Text(
            AppLocale.loadingEmulators.getString(context),
            style: TextStyle(
              fontSize: 12.r,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(24.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.error_outline_rounded,
              size: 48.r,
              color: Theme.of(context).colorScheme.error,
            ),
            SizedBox(height: 12.r),
            Text(
              _errorMessage ?? AppLocale.anErrorOccurred.getString(context),
              style: TextStyle(
                fontSize: 12.r,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 18.r),
            ElevatedButton(
              onPressed: _loadCores,
              style:
                  ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.secondary,
                    padding: EdgeInsets.symmetric(
                      horizontal: 20.r,
                      vertical: 8.r,
                    ),
                  ).copyWith(
                    overlayColor: WidgetStateProperty.all(Colors.transparent),
                  ),
              child: Text(AppLocale.retry.getString(context)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openFortPaths() async {
    SfxService().playNavSound();
    final config = context.read<SqliteConfigProvider>().config;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _FortSystemPathsDialog(
        system: _system,
        esdeRoot: config.esdeFolderPath,
      ),
    );
    if (!mounted) return;
    context.read<SqliteDatabaseProvider>().loadGamesForSystem(
      _system.folderName,
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
      decoration: const BoxDecoration(color: Colors.transparent),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocale.systemSettings.getString(context),
                  style: TextStyle(
                    fontSize: 12.r,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                SizedBox(height: 1.r),
                Text(
                  widget.system.realName,
                  style: TextStyle(
                    fontSize: 10.r,
                    fontWeight: FontWeight.w500,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          Tooltip(
            message: 'Fort paths: ROMs, media and gamelist',
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                canRequestFocus: false,
                focusColor: Colors.transparent,
                hoverColor: Colors.transparent,
                highlightColor: Colors.transparent,
                splashColor: Colors.transparent,
                borderRadius: BorderRadius.circular(8.r),
                onTap: _openFortPaths,
                child: Container(
                  padding: EdgeInsets.all(6.r),
                  child: Icon(
                    Symbols.folder_open_rounded,
                    size: 18.r,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(width: 4.r),
          Material(
            color: Colors.transparent,
            child: InkWell(
              canRequestFocus: false,
              focusColor: Colors.transparent,
              hoverColor: Colors.transparent,
              highlightColor: Colors.transparent,
              splashColor: Colors.transparent,
              borderRadius: BorderRadius.circular(8.r),
              focusNode: _headerCloseButtonFocusNode,
              onTap: () {
                SfxService().playBackSound();
                Navigator.of(context).pop();
              },
              child: Container(
                padding: EdgeInsets.all(6.r),
                child: Icon(
                  Symbols.close_rounded,
                  size: 18.r,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabsHeader() {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.1),
          ),
        ),
      ),
      child: Row(
        children: [
          Padding(
            padding: EdgeInsets.only(right: 8.r),
            child: Image.asset(
              'assets/images/gamepad/Xbox_LB_bumper.png',
              height: 24.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              colorBlendMode: BlendMode.srcIn,
            ),
          ),
          _buildTabItem(0, AppLocale.general.getString(context)),
          if (_availableTabs.contains(1)) ...[
            SizedBox(width: 16.r),
            _buildTabItem(1, AppLocale.emulators.getString(context)),
          ],
          SizedBox(width: 16.r),
          _buildTabItem(2, AppLocale.appearance.getString(context)),
          if (_availableTabs.contains(3)) ...[
            SizedBox(width: 16.r),
            _buildTabItem(3, AppLocale.hiddenGames.getString(context)),
          ],
          const Spacer(),
          Padding(
            padding: EdgeInsets.only(left: 8.r),
            child: Image.asset(
              'assets/images/gamepad/Xbox_RB_bumper.png',
              height: 24.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              colorBlendMode: BlendMode.srcIn,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabItem(int index, String label) {
    final bool isSelected = _currentTab == index;
    return InkWell(
      canRequestFocus: false,
      focusColor: Colors.transparent,
      hoverColor: Colors.transparent,
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,
      onTap: () {
        SfxService().playNavSound();
        rebuild(() => _currentTab = index);
      },
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 8.r),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: isSelected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
              width: 2.r,
            ),
          ),
        ),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 10.r,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.5),
            letterSpacing: 0.5.r,
          ),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.all(10.r),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                GamepadControl(
                  iconPath: 'assets/images/gamepad/Xbox_D-pad_ALL.png',
                  label: AppLocale.navigate.getString(context),
                  backgroundColor: theme.colorScheme.tertiary,
                  textColor: theme.colorScheme.onPrimary,
                ),
              ],
            ),
          ),
          SizedBox(width: 8.r),
          GamepadControl(
            iconPath: 'assets/images/gamepad/Xbox_B_button.png',
            label: AppLocale.close.getString(context),
            backgroundColor: theme.colorScheme.error,
            textColor: theme.colorScheme.onError,
            onTap: () {
              SfxService().playBackSound();
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }
}

/// Fort-only per-system path editor. Kept in this `part` so the upstream
/// settings dialog does not need new imports or a new LB/RB tab.
class _FortSystemPathsDialog extends StatefulWidget {
  final SystemModel system;
  final String? esdeRoot;

  const _FortSystemPathsDialog({required this.system, required this.esdeRoot});

  @override
  State<_FortSystemPathsDialog> createState() => _FortSystemPathsDialogState();
}

class _FortSystemPathsDialogState extends State<_FortSystemPathsDialog> {
  late final TextEditingController _romController;
  late final TextEditingController _mediaController;
  late final TextEditingController _gamelistController;
  Map<String, String?> _snapshot = const {};
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _romController = TextEditingController();
    _mediaController = TextEditingController();
    _gamelistController = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _romController.dispose();
    _mediaController.dispose();
    _gamelistController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final snapshot = await ConfigService.getFortSystemPathSnapshot(
      widget.system,
      esdeRoot: widget.esdeRoot,
    );
    if (!mounted) return;
    setState(() {
      _snapshot = snapshot;
      _romController.text = snapshot['romManual'] ?? '';
      _mediaController.text = snapshot['mediaManual'] ?? '';
      _gamelistController.text = snapshot['gamelistManual'] ?? '';
      _loading = false;
    });
  }

  Future<void> _resetField(String field) async {
    setState(() => _saving = true);
    try {
      if (field == 'rom') {
        await ConfigService.setFortSystemRomOverride(
          widget.system.folderName,
          null,
        );
        _romController.clear();
        await context.read<SqliteConfigProvider>().rescanSystemSilent(
          widget.system,
        );
      } else if (field == 'media') {
        await ConfigService.setFortSystemMediaOverride(
          widget.system.folderName,
          null,
        );
        _mediaController.clear();
      } else {
        await ConfigService.setFortSystemGamelistOverride(
          widget.system.folderName,
          null,
        );
        _gamelistController.clear();
      }
      final snapshot = await ConfigService.getFortSystemPathSnapshot(
        widget.system,
        esdeRoot: widget.esdeRoot,
      );
      if (mounted) setState(() => _snapshot = snapshot);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final previousRom = _snapshot['romManual'];
      await ConfigService.setFortSystemRomOverride(
        widget.system.folderName,
        _romController.text,
      );
      await ConfigService.setFortSystemMediaOverride(
        widget.system.folderName,
        _mediaController.text,
      );
      await ConfigService.setFortSystemGamelistOverride(
        widget.system.folderName,
        _gamelistController.text,
      );

      final newRom = _romController.text.trim().isEmpty
          ? null
          : _romController.text.trim();
      if (previousRom != newRom) {
        await context.read<SqliteConfigProvider>().rescanSystemSilent(
          widget.system,
        );
      }

      if (!mounted) return;
      Navigator.of(context).pop();
      AppNotification.showNotification(
        context,
        'Fort paths saved. Manual values take priority; re-run ES-DE import '
        'after changing the gamelist.',
        type: NotificationType.success,
      );
    } catch (e) {
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        'Could not save Fort paths: $e',
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    required String autoKey,
    required String resetField,
    required String hint,
  }) {
    final auto = _snapshot[autoKey];
    final manual = controller.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(bottom: 14.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 12.r, fontWeight: FontWeight.w600),
                ),
              ),
              if (manual)
                TextButton(
                  onPressed: _saving ? null : () => _resetField(resetField),
                  child: const Text('Reset'),
                ),
            ],
          ),
          TextField(
            controller: controller,
            enabled: !_saving,
            style: TextStyle(fontSize: 11.r),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              helperMaxLines: 2,
              helperText: auto == null || auto.isEmpty
                  ? 'Automatic: NeoStation/default'
                  : 'Automatic ES-DE: $auto',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 620.r, maxHeight: 520.r),
        child: Padding(
          padding: EdgeInsets.all(18.r),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Fort paths - ${widget.system.realName}',
                      style: TextStyle(
                        fontSize: 16.r,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 6.r),
                    Text(
                      'Leave a field empty to use automatic detection. '
                      'A manual value is authoritative only for this platform.',
                      style: TextStyle(
                        fontSize: 10.r,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.65),
                      ),
                    ),
                    SizedBox(height: 16.r),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            _field(
                              label: 'ROM Directory',
                              controller: _romController,
                              autoKey: 'romAuto',
                              resetField: 'rom',
                              hint: '/storage/.../ROMs/system',
                            ),
                            _field(
                              label: 'Media Directory',
                              controller: _mediaController,
                              autoKey: 'mediaAuto',
                              resetField: 'media',
                              hint: '/storage/.../ROMs/system',
                            ),
                            _field(
                              label: 'Gamelist File',
                              controller: _gamelistController,
                              autoKey: 'gamelistAuto',
                              resetField: 'gamelist',
                              hint: '/storage/.../gamelist.xml',
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 10.r),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: _saving
                              ? null
                              : () => Navigator.of(context).pop(),
                          child: const Text('Cancel'),
                        ),
                        SizedBox(width: 8.r),
                        FilledButton(
                          onPressed: _saving ? null : _save,
                          child: Text(_saving ? 'Saving...' : 'Save'),
                        ),
                      ],
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
