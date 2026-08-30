import 'dart:io';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/permission_service.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/user_data_location_service.dart';
import 'package:neostation/services/screenshot_service.dart';
import 'package:neostation/providers/theme_provider.dart';
import 'package:neostation/providers/neo_assets_provider.dart';
import 'package:neostation/services/neo_assets_service.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/services/esde_import_service.dart';
import 'package:neostation/services/global_notification_service.dart';
import '../providers/sqlite_config_provider.dart';
import '../utils/gamepad_nav.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import '../widgets/tv_directory_picker.dart';
import '../widgets/folder_not_empty_dialog.dart';
import '../models/secondary_display_state.dart';

/// Initial configuration wizard for the first time the app is opened
class SetupWizard extends StatefulWidget {
  final VoidCallback onComplete;

  const SetupWizard({super.key, required this.onComplete});

  @override
  State<SetupWizard> createState() => _SetupWizardState();
}

class _SetupWizardState extends State<SetupWizard> with WidgetsBindingObserver {
  int _currentStep = 0;
  bool _isSelectingFolder = false;
  bool _isSelectingUserDataFolder = false;
  String? _selectedFolder;
  String? _selectedUserDataPath;
  String? _selectedEsdePath;
  SecondaryDisplayState? _secondaryDisplayState;

  // --- ES-DE import step state (optional step after scanning) ---
  bool _isImportingEsde = false;
  double _esdeProgress = 0.0;
  String _esdeLabel = '';
  EsdeImportResult? _esdeResult;

  // --- Art-pack step state (optional final step) ---
  bool _isDownloadingArt = false;

  /// Whether All-Files (storage) access is currently granted.
  bool _storageGranted = false;

  /// Whether the screenshot/return accessibility service is currently granted.
  /// Both are re-checked whenever the app resumes (the user grants them in
  /// system Settings, so we can't observe the change synchronously).
  bool _accessibilityGranted = false;

  /// Whether a secondary display is present. The accessibility (Screen Return)
  /// grant only makes sense on dual-screen devices, so we hide it otherwise.
  bool _hasSecondaryDisplay = false;

  /// Whether the accessibility grant should be offered at all.
  bool get _needsAccessibility => Platform.isAndroid && _hasSecondaryDisplay;

  /// Whether the accessibility requirement is satisfied — either it's granted,
  /// or it doesn't apply on this device.
  bool get _accessibilityDone => !_needsAccessibility || _accessibilityGranted;

  /// True once setup is being finalised, so the per-frame secondary-display
  /// push stops re-asserting `setupWizardActive` and the dock can come in.
  bool _finishing = false;

  static final _log = LoggerService.instance;

  GamepadNavigation? _gamepadNav;

  // Step indices. Android has two extra steps (Permissions + Accessibility)
  // that don't exist on desktop; the getters resolve to -1 there so a
  // comparison against a real (>= 0) step never matches.
  //   Android: 0=UserData, 1=Permissions, 2=Folder, 3=Scanning,
  //            4=EsdeImport, 5=ArtPack
  //   Desktop: 0=UserData, 1=Folder, 2=Scanning, 3=EsdeImport, 4=ArtPack
  // The Permissions step covers both All-Files access and the accessibility
  // (Screen Return) service.
  int get _stepUserData => 0;
  int get _stepPermissions => Platform.isAndroid ? 1 : -1;
  int get _stepFolder => Platform.isAndroid ? 2 : 1;
  int get _stepScanning => Platform.isAndroid ? 3 : 2;
  int get _stepEsde => Platform.isAndroid ? 4 : 3;
  int get _stepArtPack => Platform.isAndroid ? 5 : 4;

  /// The art-pack step is always the final step of the wizard.
  bool get _isLastStep => _currentStep == _stepArtPack;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeSteps();
    _initGamepad();
    if (Platform.isAndroid) {
      _secondaryDisplayState = SecondaryDisplayState.instance;
      _hasSecondaryDisplay =
          _secondaryDisplayState!.value?.isSecondaryActive ?? false;
      _secondaryDisplayState!.addListener(_onSecondaryStateChanged);
      _refreshPermissionStates();
    }
  }

  /// Keeps [_hasSecondaryDisplay] in sync so the accessibility row appears the
  /// moment a secondary display reports in (it may connect after the wizard
  /// first builds).
  void _onSecondaryStateChanged() {
    final has = _secondaryDisplayState?.value?.isSecondaryActive ?? false;
    if (has != _hasSecondaryDisplay && mounted) {
      setState(() => _hasSecondaryDisplay = has);
    }
  }

  /// Re-polls both permission states (storage + accessibility). Called on
  /// resume so the Permissions step reflects grants the user just made in
  /// system Settings.
  Future<void> _refreshPermissionStates() async {
    final storage = await PermissionService.hasAllFilesAccess();
    final access = await ScreenshotService.isAccessEnabled();
    if (mounted &&
        (storage != _storageGranted || access != _accessibilityGranted)) {
      setState(() {
        _storageGranted = storage;
        _accessibilityGranted = access;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && Platform.isAndroid) {
      _refreshPermissionStates();
      if (_currentStep == _stepPermissions) _gamepadNav?.activate();
    }
  }

  void _initGamepad() {
    _gamepadNav = GamepadNavigation(
      onSelectItem: () {
        if (_isSelectingFolder || _isSelectingUserDataFolder) return;
        if (_isImportingEsde || _isDownloadingArt) return;
        if (_isLastStep) {
          final neoAssets = context.read<NeoAssetsProvider>();
          if (neoAssets.loading &&
              !neoAssets.hasActiveTheme &&
              neoAssets.themes.isEmpty) {
            return;
          }
        }
        if (_currentStep == _stepScanning) {
          final provider = Provider.of<SqliteConfigProvider>(
            context,
            listen: false,
          );
          if (provider.scanCompleted) _handleMainAction();
        } else {
          _handleMainAction();
        }
      },
      onBack: () {
        _handleSkip();
      },
    );
    _gamepadNav?.initialize();
    _gamepadNav?.activate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _secondaryDisplayState?.removeListener(_onSecondaryStateChanged);
    _gamepadNav?.dispose();
    super.dispose();
  }

  void _updateSecondaryScreen(int bgColor, bool isOled) {
    if (_secondaryDisplayState == null) return;
    _secondaryDisplayState!.updateState(
      setupWizardActive: !_finishing,
      systemName: AppLocale.welcomeNeoStation.getString(context),
      useFluidShader: true,
      backgroundColor: bgColor,
      isOled: isOled,
      isGameSelected: false,
      clearFanart: true,
      clearScreenshot: true,
      clearWheel: true,
      clearVideo: true,
      clearImageBytes: true,
      clearGameId: true,
    );
  }

  void _handleSkip() {
    if (_currentStep == _stepPermissions &&
        _storageGranted &&
        _needsAccessibility &&
        !_accessibilityGranted) {
      setState(() => _currentStep = _stepFolder);
      return;
    }

    if (_currentStep == _stepFolder) {
      setState(() => _currentStep = _stepScanning);
      final provider = Provider.of<SqliteConfigProvider>(
        context,
        listen: false,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        provider.scanSystems();
      });
      return;
    }

    if (_currentStep == _stepEsde) {
      setState(() => _currentStep = _stepArtPack);
      return;
    }
    if (_currentStep == _stepArtPack) {
      _finishSetup();
      return;
    }
  }

  void _initializeSteps() {
    ConfigService.getUserDataPath().then((p) {
      if (mounted) setState(() => _selectedUserDataPath = p);
    });
  }

  int get _totalSteps => Platform.isAndroid ? 6 : 5;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeProvider = Provider.of<ThemeProvider>(context);
    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;
    final isOled = themeProvider.isOled;
    final bgColor = theme.scaffoldBackgroundColor;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateSecondaryScreen(bgColor.toARGB32(), isOled);
    });

    return Scaffold(
      backgroundColor: bgColor,
      body: Stack(
        children: [
          if (!isOled)
            Positioned.fill(
              child: Builder(
                builder: (context) {
                  final bg = Theme.of(context).scaffoldBackgroundColor;
                  return Container(decoration: BoxDecoration(color: bg));
                },
              ),
            ),
          SafeArea(
            child: isLandscape
                ? _buildLandscapeLayout(theme)
                : _buildPortraitLayout(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildPortraitLayout(ThemeData theme) {
    return Center(
      child: Container(
        constraints: BoxConstraints(maxWidth: 600.w),
        padding: EdgeInsets.all(32.r),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(32.r),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.2),
            width: 1.5,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              'assets/images/logo_transparent.png',
              width: 120.r,
              height: 120.r,
            ),
            SizedBox(height: 24.r),
            Text(
              AppLocale.welcomeNeoStation.getString(context),
              style: TextStyle(
                fontSize: 28.r,
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 12.r),
            Text(
              AppLocale.letsGetSetup.getString(context),
              style: TextStyle(
                fontSize: 16.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 48.r),
            _buildProgressIndicator(theme),
            SizedBox(height: 32.r),
            Expanded(child: _buildStepContent(theme)),
            SizedBox(height: 24.r),
            _buildNavigationButtons(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildLandscapeLayout(ThemeData theme) {
    return Padding(
      padding: EdgeInsets.all(16.r),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Container(
              padding: EdgeInsets.all(24.r),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(24.r),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  width: 1.r,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Image.asset(
                    'assets/images/logo_transparent.png',
                    width: 64.r,
                    height: 64.r,
                  ),
                  SizedBox(height: 12.r),
                  Text(
                    AppLocale.welcomeNeoStation.getString(context),
                    style: TextStyle(
                      fontSize: 14.r,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 8.r),
                  Text(
                    AppLocale.letsGetSetup.getString(context),
                    style: TextStyle(
                      fontSize: 10.r,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 16.r),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: _buildVerticalProgressIndicator(theme),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(width: 16.r),
          Expanded(
            flex: 3,
            child: Container(
              padding: EdgeInsets.all(16.r),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(24.r),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.05),
                  width: 1.r,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Expanded(
                    child: Center(
                      child: Container(
                        constraints: BoxConstraints(maxWidth: 400.w),
                        child: _buildStepContent(theme),
                      ),
                    ),
                  ),
                  SizedBox(height: 8.r),
                  _buildNavigationButtons(theme),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVerticalProgressIndicator(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(_totalSteps, (index) {
        final isCompleted = index < _currentStep;
        final isCurrent = index == _currentStep;
        return Column(
          children: [
            Container(
              width: 24.r,
              height: 24.r,
              decoration: BoxDecoration(
                color: isCompleted || isCurrent
                    ? theme.colorScheme.primary
                    : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(
                  color: isCompleted || isCurrent
                      ? theme.colorScheme.primary
                      : theme.colorScheme.primary.withValues(alpha: 0.3),
                  width: 2.r,
                ),
              ),
              child: Center(
                child: isCompleted
                    ? Icon(
                        Symbols.check_rounded,
                        color: Colors.white,
                        size: 14.r,
                      )
                    : Text(
                        '${index + 1}',
                        style: TextStyle(
                          fontSize: 10.r,
                          fontWeight: FontWeight.bold,
                          color: isCurrent
                              ? Colors.white
                              : theme.colorScheme.primary.withValues(
                                  alpha: 0.5,
                                ),
                        ),
                      ),
              ),
            ),
            if (index < _totalSteps - 1)
              Container(
                width: 2.r,
                height: 18.r,
                color: isCompleted
                    ? theme.colorScheme.primary
                    : theme.colorScheme.primary.withValues(alpha: 0.2),
              ),
          ],
        );
      }),
    );
  }

  Widget _buildProgressIndicator(ThemeData theme) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(_totalSteps, (index) {
          final isCompleted = index < _currentStep;
          final isCurrent = index == _currentStep;
          return Row(
            children: [
              Container(
                width: 40.r,
                height: 40.r,
                decoration: BoxDecoration(
                  color: isCompleted || isCurrent
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isCompleted || isCurrent
                        ? theme.colorScheme.primary
                        : theme.colorScheme.primary.withValues(alpha: 0.3),
                    width: 2.r,
                  ),
                ),
                child: Center(
                  child: isCompleted
                      ? Icon(
                          Symbols.check_rounded,
                          color: Colors.white,
                          size: 24.r,
                        )
                      : Text(
                          '${index + 1}',
                          style: TextStyle(
                            fontSize: 18.r,
                            fontWeight: FontWeight.bold,
                            color: isCurrent
                                ? Colors.white
                                : theme.colorScheme.primary.withValues(
                                    alpha: 0.5,
                                  ),
                          ),
                        ),
                ),
              ),
              if (index < _totalSteps - 1)
                Container(
                  width: 40.r,
                  height: 2.r,
                  color: isCompleted
                      ? theme.colorScheme.primary
                      : theme.colorScheme.primary.withValues(alpha: 0.2),
                ),
            ],
          );
        }),
      ),
    );
  }

  Widget _buildStepContent(ThemeData theme) {
    if (_currentStep == _stepUserData) return _buildUserDataLocationStep(theme);
    if (_currentStep == _stepPermissions) return _buildPermissionStep(theme);
    if (_currentStep == _stepFolder) return _buildFolderSelectionStep(theme);
    if (_currentStep == _stepScanning) return _buildScanningStep(theme);
    if (_currentStep == _stepEsde) return _buildEsdeStep(theme);
    if (_currentStep == _stepArtPack) return _buildArtPackStep(theme);
    return Container();
  }

  Widget _buildUserDataLocationStep(ThemeData theme) {
    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;
    final iconSize = isLandscape ? 48.r : 80.r;
    final titleSize = isLandscape ? 14.r : 24.r;
    final textSize = isLandscape ? 10.r : 14.r;
    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Symbols.folder_special_rounded,
            size: iconSize,
            color: _selectedUserDataPath != null
                ? theme.colorScheme.primary
                : theme.colorScheme.primary.withValues(alpha: 0.6),
          ),
          SizedBox(height: isLandscape ? 16.r : 24.r),
          Text(
            AppLocale.userDataLocation.getString(context),
            style: TextStyle(
              fontSize: titleSize,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: isLandscape ? 8.r : 16.r),
          Text(
            AppLocale.userDataLocationSubtitle.getString(context),
            style: TextStyle(
              fontSize: textSize,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              height: 1.3,
            ),
            textAlign: TextAlign.center,
          ),
          if (_selectedUserDataPath != null) ...[
            SizedBox(height: isLandscape ? 8.r : 16.r),
            Container(
              padding: EdgeInsets.all(10.r),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8.r),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Symbols.folder_rounded,
                    size: 16.r,
                    color: theme.colorScheme.primary,
                  ),
                  SizedBox(width: 8.r),
                  Expanded(
                    child: Text(
                      _selectedUserDataPath!,
                      style: TextStyle(
                        fontSize: 11.r,
                        color: theme.colorScheme.onSurface,
                        fontFamily: 'monospace',
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],
          SizedBox(height: isLandscape ? 12.r : 20.r),
          OutlinedButton(
            onPressed: _isSelectingUserDataFolder
                ? null
                : () => _selectUserDataLocationWizard(),
            style: OutlinedButton.styleFrom(
              padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 10.r),
              side: BorderSide(
                color: theme.colorScheme.primary.withValues(alpha: 0.5),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12.r),
              ),
            ),
            child: _isSelectingUserDataFolder
                ? SizedBox(
                    width: 18.r,
                    height: 18.r,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.r,
                      color: theme.colorScheme.primary,
                    ),
                  )
                : Text(
                    AppLocale.selectUserDataFolder.getString(context),
                    style: TextStyle(
                      fontSize: textSize,
                      color: theme.colorScheme.primary,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _selectUserDataLocationWizard() async {
    setState(() => _isSelectingUserDataFolder = true);
    _gamepadNav?.deactivate();
    try {
      String? selected;
      if (Platform.isAndroid) {
        final isTV = await PermissionService.isTelevision();
        if (isTV) {
          if (mounted) selected = await TvDirectoryPicker.show(context);
        } else {
          try {
            final uri = await PermissionService.requestFolderAccess();
            if (uri != null) {
              selected = UserDataLocationService.safUriToRealPath(
                uri.toString(),
              );
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
          initialDirectory: _selectedUserDataPath,
        );
      }
      if (selected == null || !mounted) return;
      if (selected.endsWith(Platform.pathSeparator)) {
        selected = selected.substring(0, selected.length - 1);
      }
      if (selected == _selectedUserDataPath) return;
      final entryCount = await UserDataLocationService.countDirectoryEntries(
        selected,
      );
      if (!mounted) return;
      if (entryCount > 0) {
        final proceed = await FolderNotEmptyDialog.show(
          context,
          path: selected,
          itemCount: entryCount,
        );
        if (!proceed || !mounted) return;
      }
      await UserDataLocationService.setCustomPath(selected);
      if (!mounted) return;
      final configProvider = Provider.of<SqliteConfigProvider>(
        context,
        listen: false,
      );
      await configProvider.reinitialize();
      if (mounted) setState(() => _selectedUserDataPath = selected);
    } catch (e) {
      _log.e('User data location selection failed in wizard: $e');
    } finally {
      if (mounted) setState(() => _isSelectingUserDataFolder = false);
      _gamepadNav?.activate();
    }
  }

  Widget _buildPermissionStep(ThemeData theme) {
    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;
    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildPermissionRow(
            theme,
            icon: Symbols.security_rounded,
            title: AppLocale.storagePermission.getString(context),
            description: AppLocale.storagePermissionDesc.getString(context),
            granted: _storageGranted,
            isLandscape: isLandscape,
          ),
          if (_needsAccessibility) ...[
            SizedBox(height: isLandscape ? 12.r : 20.r),
            _buildPermissionRow(
              theme,
              icon: Symbols.settings_accessibility_rounded,
              title: AppLocale.screenReturnAccess.getString(context),
              description: AppLocale.screenReturnAccessDesc.getString(context),
              granted: _accessibilityGranted,
              isLandscape: isLandscape,
              hint: AppLocale.screenReturnAccessHint.getString(context),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPermissionRow(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String description,
    required bool granted,
    required bool isLandscape,
    String? hint,
  }) {
    final iconSize = isLandscape ? 28.r : 40.r;
    final titleSize = isLandscape ? 13.r : 18.r;
    final textSize = isLandscape ? 9.r : 13.r;
    return Container(
      padding: EdgeInsets.all(isLandscape ? 12.r : 16.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(
          color: granted
              ? Colors.green.withValues(alpha: 0.5)
              : theme.colorScheme.onSurface.withValues(alpha: 0.1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: iconSize,
            color: granted ? Colors.green : theme.colorScheme.primary,
          ),
          SizedBox(width: isLandscape ? 12.r : 16.r),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: titleSize,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                SizedBox(height: 4.r),
                Text(
                  granted ? AppLocale.enabled.getString(context) : description,
                  style: TextStyle(
                    fontSize: textSize,
                    color: granted
                        ? Colors.green
                        : theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    height: 1.3,
                  ),
                ),
                if (!granted && hint != null) ...[
                  SizedBox(height: 6.r),
                  Text(
                    hint,
                    style: TextStyle(
                      fontSize: textSize,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.primary,
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(width: isLandscape ? 8.r : 12.r),
          Icon(
            granted
                ? Symbols.check_circle_rounded
                : Symbols.radio_button_unchecked_rounded,
            size: isLandscape ? 20.r : 26.r,
            color: granted
                ? Colors.green
                : theme.colorScheme.onSurface.withValues(alpha: 0.3),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderSelectionStep(ThemeData theme) {
    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;
    final iconSize = isLandscape ? 48.r : 80.r;
    final titleSize = isLandscape ? 14.r : 24.r;
    final textSize = isLandscape ? 10.r : 14.r;
    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Symbols.folder_open_rounded,
            size: iconSize,
            color: _selectedFolder != null
                ? Colors.green
                : theme.colorScheme.primary,
          ),
          SizedBox(height: isLandscape ? 16.r : 24.r),
          Text(
            AppLocale.selectRomFolder.getString(context),
            style: TextStyle(
              fontSize: titleSize,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
          SizedBox(height: isLandscape ? 8.r : 16.r),
          Text(
            _selectedFolder != null
                ? '${_selectedEsdePath != null ? 'ES-DE' : AppLocale.romFolderSelected.getString(context)}\n\n$_selectedFolder'
                : AppLocale.chooseRomFolderDesc.getString(context),
            style: TextStyle(
              fontSize: textSize,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              height: 1.3,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildScanningStep(ThemeData theme) {
    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;
    final containerSize = isLandscape ? 48.r : 80.r;
    final iconSize = isLandscape ? 24.r : 48.r;
    final titleSize = isLandscape ? 16.r : 24.r;
    final textSize = isLandscape ? 12.r : 14.r;
    return Consumer<SqliteConfigProvider>(
      builder: (context, provider, child) {
        return SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: containerSize,
                height: containerSize,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(containerSize / 2),
                ),
                child: Center(
                  child: provider.scanCompleted
                      ? Icon(
                          Symbols.check_circle_rounded,
                          color: Colors.green,
                          size: iconSize,
                        )
                      : SizedBox(
                          width: iconSize,
                          height: iconSize,
                          child: CircularProgressIndicator(
                            color: theme.colorScheme.primary,
                            strokeWidth: 3.r,
                          ),
                        ),
                ),
              ),
              SizedBox(height: isLandscape ? 4.r : 24.r),
              Text(
                provider.scanCompleted
                    ? AppLocale.wizardScanComplete.getString(context)
                    : AppLocale.scanningRoms.getString(context),
                style: TextStyle(
                  fontSize: titleSize,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              SizedBox(height: isLandscape ? 4.r : 16.r),
              Text(
                provider.scanStatus.isNotEmpty
                    ? provider.scanStatus
                    : AppLocale.scanningSystemsRoms.getString(context),
                style: TextStyle(
                  fontSize: textSize,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  height: 1.3,
                ),
                textAlign: TextAlign.center,
              ),
              if (provider.totalSystemsToScan > 0 &&
                  !provider.scanCompleted) ...[
                SizedBox(height: isLandscape ? 4.r : 32.r),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8.r),
                  child: LinearProgressIndicator(
                    value: provider.scanProgress,
                    minHeight: 8.r,
                    backgroundColor: theme.colorScheme.primary.withValues(
                      alpha: 0.1,
                    ),
                    valueColor: AlwaysStoppedAnimation<Color>(
                      theme.colorScheme.primary,
                    ),
                  ),
                ),
                SizedBox(height: 8.r),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      AppLocale.ofSystems
                          .getString(context)
                          .replaceFirst(
                            '{scanned}',
                            provider.scannedSystemsCount.toString(),
                          )
                          .replaceFirst(
                            '{total}',
                            provider.totalSystemsToScan.toString(),
                          ),
                      style: TextStyle(
                        fontSize: textSize - 2.r,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.6,
                        ),
                      ),
                    ),
                    Text(
                      '${(provider.scanProgress * 100).toInt()}%',
                      style: TextStyle(
                        fontSize: textSize - 2.r,
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],
              if (provider.scanCompleted) ...[
                SizedBox(height: isLandscape ? 4.r : 32.r),
                Container(
                  padding: EdgeInsets.all(isLandscape ? 12.r : 16.r),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12.r),
                    border: Border.all(
                      color: Colors.green.withValues(alpha: 0.3),
                      width: 1.r,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Symbols.check_circle_rounded,
                        color: Colors.green,
                        size: isLandscape ? 20.r : 24.r,
                      ),
                      SizedBox(width: 12.r),
                      Expanded(
                        child: Text(
                          '${AppLocale.foundSystemsWithGames.getString(context).replaceFirst('{count}', provider.detectedRealSystems.length.toString())}\n${AppLocale.wizardTapNextToContinue.getString(context)}',
                          style: TextStyle(
                            fontSize: textSize,
                            color: Colors.green[700],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildEsdeStep(ThemeData theme) {
    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;
    final iconSize = isLandscape ? 48.r : 80.r;
    final titleSize = isLandscape ? 16.r : 24.r;
    final textSize = isLandscape ? 12.r : 14.r;
    final result = _esdeResult;
    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            result != null
                ? Symbols.check_circle_rounded
                : Symbols.download_for_offline_rounded,
            size: iconSize,
            color: result != null ? Colors.green : theme.colorScheme.primary,
          ),
          SizedBox(height: isLandscape ? 16.r : 24.r),
          Text(
            AppLocale.wizardEsdeStepTitle.getString(context),
            style: TextStyle(
              fontSize: titleSize,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: isLandscape ? 8.r : 16.r),
          Text(
            AppLocale.wizardEsdeStepDesc.getString(context),
            style: TextStyle(
              fontSize: textSize,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              height: 1.3,
            ),
            textAlign: TextAlign.center,
          ),
          if (_selectedEsdePath != null) ...[
            SizedBox(height: isLandscape ? 8.r : 14.r),
            Text(
              _selectedEsdePath!,
              style: TextStyle(
                fontSize: textSize - 2.r,
                color: theme.colorScheme.primary,
                fontFamily: 'monospace',
              ),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (_isImportingEsde) ...[
            SizedBox(height: isLandscape ? 12.r : 28.r),
            SizedBox(
              width: 220.r,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8.r),
                child: LinearProgressIndicator(
                  value: _esdeProgress > 0 ? _esdeProgress : null,
                  minHeight: 8.r,
                  backgroundColor: theme.colorScheme.primary.withValues(
                    alpha: 0.1,
                  ),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
            if (_esdeLabel.isNotEmpty) ...[
              SizedBox(height: 8.r),
              Text(
                _esdeLabel,
                style: TextStyle(
                  fontSize: textSize - 2.r,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
          if (result != null) ...[
            SizedBox(height: isLandscape ? 12.r : 28.r),
            Container(
              padding: EdgeInsets.all(isLandscape ? 12.r : 16.r),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(
                  color: Colors.green.withValues(alpha: 0.3),
                  width: 1.r,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Symbols.check_circle_rounded,
                    color: Colors.green,
                    size: isLandscape ? 20.r : 24.r,
                  ),
                  SizedBox(width: 12.r),
                  Flexible(
                    child: Text(
                      '${AppLocale.esdeImportComplete.getString(context)}\n'
                      '${result.gamesImported} ${AppLocale.esdeSummaryGames.getString(context)}, '
                      '${result.systemsMatched} ${AppLocale.esdeSummarySystems.getString(context)}',
                      style: TextStyle(
                        fontSize: textSize,
                        color: Colors.green[700],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildArtPackStep(ThemeData theme) {
    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;
    final iconSize = isLandscape ? 48.r : 80.r;
    final titleSize = isLandscape ? 16.r : 24.r;
    final textSize = isLandscape ? 12.r : 14.r;
    return Consumer<NeoAssetsProvider>(
      builder: (context, neoAssets, child) {
        final hasTheme = neoAssets.hasActiveTheme;
        final unavailable = neoAssets.themes.isEmpty;
        return SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                hasTheme
                    ? Symbols.check_circle_rounded
                    : Symbols.palette_rounded,
                size: iconSize * 0.7,
                color: hasTheme ? Colors.green : theme.colorScheme.primary,
              ),
              SizedBox(height: isLandscape ? 10.r : 16.r),
              Text(
                AppLocale.wizardArtPackTitle.getString(context),
                style: TextStyle(
                  fontSize: titleSize,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: isLandscape ? 6.r : 12.r),
              Text(
                hasTheme
                    ? AppLocale.wizardArtPackInstalled.getString(context)
                    : unavailable
                    ? AppLocale.wizardArtPackUnavailable.getString(context)
                    : AppLocale.wizardArtPackDesc.getString(context),
                style: TextStyle(
                  fontSize: textSize,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  height: 1.3,
                ),
                textAlign: TextAlign.center,
              ),
              if (!hasTheme && !unavailable && !neoAssets.downloading) ...[
                Builder(
                  builder: (context) {
                    final recommended = neoAssets.themes.firstWhere(
                      (t) => !t.isAi,
                      orElse: () => neoAssets.themes.first,
                    );
                    final previewUrl = NeoAssetsTheme.normalizePreviewUrl(
                      recommended.previewUrl,
                    );
                    if (previewUrl.isEmpty) return const SizedBox.shrink();
                    final thumbWidth = isLandscape ? 120.r : 150.r;
                    return Padding(
                      padding: EdgeInsets.only(top: isLandscape ? 10.r : 16.r),
                      child: Container(
                        width: thumbWidth,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10.r),
                          border: Border.all(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.3,
                            ),
                            width: 1.r,
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(9.r),
                          child: AspectRatio(
                            aspectRatio: 4 / 3,
                            child: Image.network(
                              previewUrl,
                              fit: BoxFit.cover,
                              loadingBuilder: (_, child, progress) =>
                                  progress == null
                                  ? child
                                  : Container(color: theme.colorScheme.surface),
                              errorBuilder: (_, _, _) => Container(
                                color: theme.colorScheme.surface,
                                child: Icon(
                                  Symbols.image_rounded,
                                  size: 24.r,
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: 0.3,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
              if (neoAssets.downloading) ...[
                SizedBox(height: isLandscape ? 12.r : 28.r),
                SizedBox(
                  width: 220.r,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8.r),
                    child: LinearProgressIndicator(
                      value: neoAssets.downloadProgress > 0
                          ? neoAssets.downloadProgress
                          : null,
                      minHeight: 8.r,
                      backgroundColor: theme.colorScheme.primary.withValues(
                        alpha: 0.1,
                      ),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
                SizedBox(height: 8.r),
                Text(
                  '${(neoAssets.downloadProgress * 100).toInt()}%',
                  style: TextStyle(
                    fontSize: textSize,
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<String?> _resolveSelectedAndroidPath(String uriStr) async {
    final hasFiles = await PermissionService.hasAllFilesAccess();
    return await UserDataLocationService.resolveAndroidUserDataPath(
          uriStr,
          hasAllFilesAccess: hasFiles,
        ) ??
        UserDataLocationService.safUriToRealPath(uriStr);
  }

  bool _looksLikeEsdeRoot(String candidate) {
    try {
      final root = Directory(candidate);
      if (!root.existsSync()) return false;
      return File('$candidate/settings/es_settings.xml').existsSync() ||
          File('$candidate/custom_systems/es_systems.xml').existsSync() ||
          Directory('$candidate/gamelists').existsSync();
    } catch (_) {
      return false;
    }
  }

  Future<void> _runWizardEsdeImport() async {
    if (_isImportingEsde) return;

    // Reuse a root already selected/detected in the earlier folder step. Only
    // open the ES-DE picker when setup has no ES-DE root yet.
    String? selected = _selectedEsdePath;
    final configured = context
        .read<SqliteConfigProvider>()
        .config
        .esdeFolderPath;
    if ((selected == null || selected.isEmpty) &&
        configured != null &&
        configured.trim().isNotEmpty) {
      selected = configured.trim();
    }

    if (selected == null || selected.isEmpty) {
      _gamepadNav?.deactivate();
      try {
        if (Platform.isAndroid) {
          final isTV = await PermissionService.isTelevision();
          if (!mounted) return;
          if (isTV) {
            selected = await TvDirectoryPicker.show(context);
          } else {
            try {
              final uri = await PermissionService.requestFolderAccess();
              if (uri != null) {
                selected = await _resolveSelectedAndroidPath(uri.toString());
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
      } finally {
        _gamepadNav?.activate();
      }
    }

    if (selected == null || !mounted) return;
    if (selected.endsWith(Platform.pathSeparator)) {
      selected = selected.substring(0, selected.length - 1);
    }
    if (!_looksLikeEsdeRoot(selected)) {
      GlobalNotificationService().show(
        id: 'esde_import_progress',
        message: AppLocale.esdeImportNotEsdeFolder.getString(context),
        type: GlobalNotificationType.error,
      );
      return;
    }

    setState(() => _selectedEsdePath = selected);

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

    await context.read<SqliteConfigProvider>().updateEsdeFolderPath(selected);

    setState(() {
      _isImportingEsde = true;
      _esdeProgress = 0.0;
      _esdeLabel = '';
    });

    const notificationId = 'esde_import_progress';
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
        selected,
        onProgress: (p, label) {
          if (mounted) {
            setState(() {
              _esdeProgress = p;
              _esdeLabel = label;
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
      _log.e('Wizard ES-DE import failed: $e');
    }

    if (!mounted) return;
    final matched =
        error == null &&
        result != null &&
        result.gamelistsDirFound &&
        (result.gamesImported > 0 || result.systemsMatched > 0);

    setState(() {
      _isImportingEsde = false;
      _esdeResult = matched ? result : null;
    });

    if (error != null) {
      GlobalNotificationService().update(
        id: notificationId,
        message: error,
        type: GlobalNotificationType.error,
        progress: null,
      );
    } else if (result != null && !result.gamelistsDirFound) {
      GlobalNotificationService().update(
        id: notificationId,
        message: localeEsdeImportNotEsdeFolder,
        type: GlobalNotificationType.error,
        progress: null,
      );
    } else if (!matched) {
      GlobalNotificationService().update(
        id: notificationId,
        message: localeEsdeImportNothingFound,
        type: GlobalNotificationType.info,
        progress: null,
      );
    } else {
      final importResult = result;
      GlobalNotificationService().update(
        id: notificationId,
        message:
            '$localeEsdeImportComplete: ${importResult.gamesImported} '
            '$localeEsdeSummaryGames, ${importResult.systemsMatched} '
            '$localeEsdeSummarySystems',
        type: GlobalNotificationType.success,
        progress: null,
      );
    }
  }

  Future<void> _downloadWizardArtPack() async {
    if (_isDownloadingArt) return;
    final neoAssets = context.read<NeoAssetsProvider>();
    final themes = neoAssets.themes;
    if (themes.isEmpty) return;
    final recommended = themes.firstWhere(
      (t) => !t.isAi,
      orElse: () => themes.first,
    );
    final systemFolders = context
        .read<SqliteConfigProvider>()
        .availableSystems
        .where((s) => s.folderName != 'all-background')
        .map((s) => s.folderName)
        .toList();
    setState(() => _isDownloadingArt = true);
    try {
      await neoAssets.downloadAndApplyTheme(recommended.folder, systemFolders);
    } catch (e) {
      _log.e('Wizard art pack download failed: $e');
    }
    if (!mounted) return;
    setState(() => _isDownloadingArt = false);
    await _finishSetup();
  }

  Widget _buildNavigationButtons(ThemeData theme) {
    final isInScanningStep = _currentStep == _stepScanning;
    if (isInScanningStep) {
      return Consumer<SqliteConfigProvider>(
        builder: (context, provider, child) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              ElevatedButton(
                onPressed: provider.scanCompleted
                    ? () => _handleMainAction()
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: theme.colorScheme.onPrimary,
                  padding: EdgeInsets.symmetric(
                    horizontal: 20.r,
                    vertical: 12.r,
                  ),
                  elevation: 4,
                  shadowColor: theme.colorScheme.primary.withValues(alpha: 0.4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16.r),
                  ),
                  disabledBackgroundColor: theme.colorScheme.primary.withValues(
                    alpha: 0.3,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      'assets/images/gamepad/Xbox_A_button.png',
                      width: 20.r,
                      height: 20.r,
                      color: theme.colorScheme.onPrimary,
                    ),
                    SizedBox(width: 8.r),
                    Text(
                      AppLocale.next.getString(context),
                      style: TextStyle(
                        fontSize: 14.r,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      );
    }

    final showSkip =
        _currentStep == _stepEsde ||
        _currentStep == _stepArtPack ||
        (Platform.isAndroid &&
            (_currentStep == _stepFolder ||
                (_currentStep == _stepPermissions &&
                    _storageGranted &&
                    _needsAccessibility &&
                    !_accessibilityGranted)));
    return Consumer<NeoAssetsProvider>(
      builder: (context, neoAssets, child) {
        final artLoading =
            _currentStep == _stepArtPack &&
            !neoAssets.hasActiveTheme &&
            neoAssets.themes.isEmpty &&
            neoAssets.loading;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            if (showSkip)
              TextButton(
                onPressed: () => _handleSkip(),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.symmetric(
                    horizontal: 16.r,
                    vertical: 8.r,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      'assets/images/gamepad/Xbox_B_button.png',
                      width: 20.r,
                      height: 20.r,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                    SizedBox(width: 8.r),
                    Text(
                      AppLocale.skipForNow.getString(context),
                      style: TextStyle(
                        fontSize: 12.r,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.6,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else
              SizedBox(width: 64.r),
            ElevatedButton(
              onPressed:
                  (_isSelectingFolder ||
                      _isImportingEsde ||
                      _isDownloadingArt ||
                      artLoading)
                  ? null
                  : () => _handleMainAction(),
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
                padding: EdgeInsets.symmetric(horizontal: 20.r, vertical: 12.r),
                elevation: 4,
                shadowColor: theme.colorScheme.primary.withValues(alpha: 0.4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16.r),
                ),
                disabledBackgroundColor: theme.colorScheme.primary.withValues(
                  alpha: 0.3,
                ),
              ),
              child: (_isSelectingFolder || artLoading)
                  ? SizedBox(
                      width: 20.r,
                      height: 20.r,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.r,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          theme.colorScheme.onPrimary,
                        ),
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Image.asset(
                          'assets/images/gamepad/Xbox_A_button.png',
                          width: 20.r,
                          height: 20.r,
                          color: theme.colorScheme.onPrimary,
                        ),
                        SizedBox(width: 8.r),
                        Text(
                          _getButtonText(),
                          style: TextStyle(
                            fontSize: 14.r,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  String _getButtonText() {
    if (_currentStep == _stepUserData) return AppLocale.next.getString(context);
    if (_currentStep == _stepPermissions) {
      if (!_storageGranted || !_accessibilityDone) {
        return AppLocale.grantAccess.getString(context);
      }
      return AppLocale.next.getString(context);
    }
    if (_currentStep == _stepFolder)
      return AppLocale.selectFolder.getString(context);
    if (_currentStep == _stepEsde) {
      return _esdeResult != null
          ? AppLocale.next.getString(context)
          : AppLocale.esdeRunImport.getString(context);
    }
    if (_currentStep == _stepArtPack) {
      final neoAssets = context.read<NeoAssetsProvider>();
      final canDownload =
          !neoAssets.hasActiveTheme && neoAssets.themes.isNotEmpty;
      return canDownload
          ? AppLocale.wizardDownloadArtPack.getString(context)
          : AppLocale.finish.getString(context);
    }
    return AppLocale.next.getString(context);
  }

  Future<void> _handleMainAction() async {
    if (_currentStep == _stepUserData) {
      setState(() => _currentStep = _currentStep + 1);
      if (Platform.isAndroid) {
        _refreshPermissionStates().then((_) {
          if (mounted &&
              _currentStep == _stepPermissions &&
              _storageGranted &&
              _accessibilityDone) {
            setState(() => _currentStep = _stepFolder);
          }
        });
      }
      return;
    }
    if (_currentStep == _stepPermissions) {
      await _handlePermissionAction();
      return;
    }
    if (_currentStep == _stepFolder) {
      await _selectFolder();
      return;
    }
    if (_currentStep == _stepScanning) {
      setState(() => _currentStep = _stepEsde);
      return;
    }
    if (_currentStep == _stepEsde) {
      if (_esdeResult != null) {
        setState(() => _currentStep = _stepArtPack);
      } else {
        await _runWizardEsdeImport();
      }
      return;
    }
    if (_currentStep == _stepArtPack) {
      final neoAssets = context.read<NeoAssetsProvider>();
      final canDownload =
          !neoAssets.hasActiveTheme && neoAssets.themes.isNotEmpty;
      if (canDownload) {
        await _downloadWizardArtPack();
      } else {
        await _finishSetup();
      }
    }
  }

  Future<void> _handlePermissionAction() async {
    if (_storageGranted && _accessibilityDone) {
      setState(() => _currentStep = _stepFolder);
      return;
    }
    _gamepadNav?.deactivate();
    try {
      if (!_storageGranted) {
        final success = await PermissionService.requestAllFilesAccess();
        if (success && mounted) {
          context.read<SqliteConfigProvider>().refreshAllFilesAccess();
          setState(() => _storageGranted = true);
        }
      } else {
        await ScreenshotService.openAccessSettings();
      }
    } catch (e) {
      _log.e('Error requesting permissions: $e');
    } finally {
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) _gamepadNav?.activate();
    }
  }

  Future<void> _selectFolder() async {
    if (_currentStep != _stepFolder) return;
    setState(() => _isSelectingFolder = true);
    _gamepadNav?.deactivate();

    try {
      final configProvider = Provider.of<SqliteConfigProvider>(
        context,
        listen: false,
      );
      String? result;
      String? resolvedPath;

      if (Platform.isAndroid) {
        final isTV = await PermissionService.isTelevision();
        if (isTV) {
          if (mounted) result = await TvDirectoryPicker.show(context);
          resolvedPath = result;
        } else {
          try {
            final uri = await PermissionService.requestFolderAccess();
            if (uri != null) {
              result = uri.toString();
              resolvedPath = await _resolveSelectedAndroidPath(result);
            }
          } on PlatformException catch (e) {
            if (e.code == 'PICKER_FAILED' && mounted) {
              result = await TvDirectoryPicker.show(context);
              resolvedPath = result;
            }
          }
        }
      } else {
        result = await TvDirectoryPicker.pickDirectory(
          context,
          dialogTitle: AppLocale.selectRomFolder.getString(context),
        );
        resolvedPath = result;
      }

      if (result != null && mounted) {
        final esdeCandidate = resolvedPath?.trim();
        final selectedEsde =
            esdeCandidate != null &&
            esdeCandidate.isNotEmpty &&
            _looksLikeEsdeRoot(esdeCandidate);

        if (selectedEsde) {
          await configProvider.updateEsdeFolderPath(esdeCandidate);
          _selectedEsdePath = esdeCandidate;
          _log.i('Setup wizard recognized ES-DE root: $esdeCandidate');
        } else {
          if (Platform.isAndroid) {
            await configProvider.addRomFolder(result, scan: false);
          } else {
            await configProvider.addRomFolder(result, scan: false);
          }
        }

        if (!mounted) return;
        setState(() {
          _selectedFolder = selectedEsde ? esdeCandidate : result;
          _isSelectingFolder = false;
          _currentStep++;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          configProvider.scanSystems();
        });
      } else if (mounted) {
        setState(() => _isSelectingFolder = false);
      }
    } catch (e) {
      _log.e('Error selecting folder: $e');
      if (mounted) setState(() => _isSelectingFolder = false);
    } finally {
      _gamepadNav?.activate();
    }
  }

  Future<void> _finishSetup() async {
    _finishing = true;
    final configProvider = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    );
    final savedFolder = configProvider.config.romFolder;
    final savedEsde = configProvider.config.esdeFolderPath;
    if ((savedFolder == null || savedFolder.isEmpty) &&
        (savedEsde == null || savedEsde.isEmpty)) {
      _log.w(
        'Warning: neither a ROM folder nor an ES-DE root was saved in config!',
      );
    }
    await configProvider.saveConfig();
    widget.onComplete();
  }
}
