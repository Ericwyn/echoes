import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart'
    show getSaveLocation, XTypeGroup;
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/design/echo_design.dart';
import '../../../core/constants/app_identity.dart';
import '../../../core/services/desktop_close_settings.dart';
import '../../../core/services/update_checker.dart';
import '../../../core/utils/logger.dart';
import '../../../data/models/music_library.dart';
import '../../../data/models/server_address.dart';
import '../../../data/sources/local_storage.dart';
import '../../library/pages/edit_library_page.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/crossfade_provider.dart';
import '../../../providers/library_provider.dart';
import '../../../providers/music_provider.dart';
import '../../../providers/player_appearance_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../providers/playlist_provider.dart';
import '../../../providers/theme_provider.dart';
import '../widgets/echo_settings_components.dart';
import '../widgets/route_selection_sheet.dart';
import 'audio_quality_page.dart';
import 'background_playback_page.dart';
import 'cache_management_page.dart';
import 'cover_providers_page.dart';
import 'lyrics_providers_page.dart';
import 'playback_stats_page.dart';
import 'theme_settings_page.dart';

const _buildSource = String.fromEnvironment(
  'ECHO_BUILD_SOURCE',
  defaultValue: '本地构建',
);
const _buildCommit = String.fromEnvironment('ECHO_BUILD_COMMIT');
const _buildFlutterVersion = String.fromEnvironment('ECHO_FLUTTER_VERSION');

/// 全屏设置页
class AppSettingsPage extends ConsumerStatefulWidget {
  const AppSettingsPage({super.key});

  @override
  ConsumerState<AppSettingsPage> createState() => _AppSettingsPageState();
}

class _AppSettingsPageState extends ConsumerState<AppSettingsPage> {
  bool _isExportingLogs = false;
  bool _isCheckingUpdate = false;
  bool _exitOnDesktopClose = false;

  bool get _saveLogsToFile =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  bool get _showDesktopCloseSetting =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;
  bool get _showDesktopLibraryActions =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  void initState() {
    super.initState();
    if (_showDesktopCloseSetting) unawaited(_loadDesktopCloseSetting());
  }

  Future<void> _loadDesktopCloseSetting() async {
    try {
      final exitOnClose = await DesktopCloseSettings.shouldExitOnClose();
      if (mounted) setState(() => _exitOnDesktopClose = exitOnClose);
    } catch (error) {
      Logger.warnWithTag(
        'DESKTOP',
        'cannot load close behavior setting',
        error,
      );
    }
  }

  Future<void> _exportLogs() async {
    setState(() => _isExportingLogs = true);

    try {
      final logContent = await Logger.exportLogsWithHistory();
      if (logContent.isEmpty) {
        _showMessage('暂无日志可导出');
        return;
      }

      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final fileName = 'echoes_log_$timestamp.txt';
      final logFile = XFile.fromData(
        utf8.encode(logContent),
        mimeType: 'text/plain',
        name: fileName,
      );
      if (_saveLogsToFile) {
        final location = await getSaveLocation(
          suggestedName: fileName,
          acceptedTypeGroups: const [
            XTypeGroup(label: '日志文本', extensions: ['txt']),
          ],
          confirmButtonText: '保存',
        );
        if (location == null) return;

        await logFile.saveTo(location.path);
        Logger.infoWithTag('LOG_EXPORT', 'saved diagnostic logs to file');
        _showMessage('日志已保存至 ${location.path}', kind: EchoMessageKind.success);
        return;
      }

      await Share.shareXFiles(
        [logFile],
        subject: '${echoDisplayName()} 日志导出 $timestamp',
        fileNameOverrides: [fileName],
      );

      Logger.infoWithTag(
        'LOG_EXPORT',
        'exported ${Logger.bufferedLineCount} lines to share payload'
            '${kIsWeb ? " (web)" : ""}',
      );
    } catch (error) {
      Logger.errorWithTag('LOG_EXPORT', 'export failed', error);
      _showMessage('日志导出失败: $error', kind: EchoMessageKind.error);
    } finally {
      if (mounted) setState(() => _isExportingLogs = false);
    }
  }

  Future<void> _checkForUpdates() async {
    setState(() => _isCheckingUpdate = true);

    try {
      final result = await UpdateChecker.check();
      if (!mounted) return;

      if (result.hasUpdate) {
        _showUpdateSheet(result);
      } else {
        _showMessage(
          '当前已是最新版本 (${result.currentVersion})',
          kind: EchoMessageKind.success,
        );
      }
    } catch (error) {
      _showMessage('检查更新失败: $error', kind: EchoMessageKind.error);
    } finally {
      if (mounted) setState(() => _isCheckingUpdate = false);
    }
  }

  void _showUpdateSheet(UpdateCheckResult result) {
    showEchoBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => EchoBottomSheet(
        title: '发现新版本',
        subtitle: '${result.currentVersion} → ${result.latestVersion}',
        constrainToAvailableHeight: true,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _SettingsInfoLine(label: '当前版本', value: result.currentVersion),
              _SettingsInfoLine(label: '最新版本', value: result.latestVersion),
              if (result.releaseNotes != null &&
                  result.releaseNotes!.isNotEmpty) ...<Widget>[
                SizedBox(height: sheetContext.echoSpacing.sm),
                const EchoDivider(),
                SizedBox(height: sheetContext.echoSpacing.md),
                const EchoSectionHeader(title: '更新说明'),
                SizedBox(height: sheetContext.echoSpacing.xs),
                Text(
                  result.releaseNotes!,
                  style: sheetContext.echoTypography.body.copyWith(
                    color: sheetContext.echoColors.muted,
                  ),
                ),
              ],
              if (result.assets.isNotEmpty) ...<Widget>[
                SizedBox(height: sheetContext.echoSpacing.sm),
                const EchoDivider(),
                SizedBox(height: sheetContext.echoSpacing.md),
                const EchoSectionHeader(
                  title: '下载文件',
                  description: '选择适合当前设备的安装文件。',
                ),
                SizedBox(height: sheetContext.echoSpacing.xs),
                for (final asset in result.assets)
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: sheetContext.echoSpacing.xs,
                    ),
                    child: EchoActionRow(
                      icon: AppIcons.download,
                      title: asset.name,
                      subtitle:
                          '${(asset.size / (1024 * 1024)).toStringAsFixed(1)} MB',
                      trailing: Icon(
                        AppIcons.chevronRight,
                        size: 20,
                        color: sheetContext.echoColors.muted,
                      ),
                      onPressed: () => _openUrl(asset.downloadUrl),
                    ),
                  ),
              ],
              SizedBox(height: sheetContext.echoSpacing.lg),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: sheetContext.echoSpacing.xs,
                runSpacing: sheetContext.echoSpacing.xs,
                children: <Widget>[
                  EchoButton.ghost(
                    label: '稍后再说',
                    onPressed: () => Navigator.of(sheetContext).pop(),
                  ),
                  if (result.releaseUrl != null)
                    EchoButton.primary(
                      label: '前往下载',
                      leadingIcon: AppIcons.download,
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        _openUrl(result.releaseUrl!);
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _showMessage(
    String message, {
    EchoMessageKind kind = EchoMessageKind.info,
  }) {
    if (!mounted) return;
    showEchoMessage(context, message, kind: kind);
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    final library = authState.currentLibrary;
    final librariesAsync = ref.watch(librariesProvider);
    final activeAddress = ref.watch(activeAddressProvider);
    final autoFallback = ref.watch(autoFallbackProvider);
    final themeSettings = ref.watch(themeSettingsProvider);
    final dynamicPlayerBackground = ref.watch(dynamicPlayerBackgroundProvider);
    final crossfadeMs = ref.watch(crossfadeDurationMsProvider);
    final availableLibraries = librariesAsync.valueOrNull;
    final switchDescription = librariesAsync.when(
      data: (libraries) => libraries.length > 1
          ? '已保存 ${libraries.length} 个音乐库'
          : libraries.isEmpty
          ? '当前没有可切换的音乐库'
          : '当前仅有一个音乐库',
      loading: () => '正在读取音乐库列表',
      error: (error, stackTrace) => '音乐库列表读取失败，点击重试',
    );

    final VoidCallback? switchLibraryAction;
    if (availableLibraries != null && availableLibraries.isNotEmpty) {
      switchLibraryAction = () =>
          _showLibrarySheet(availableLibraries, library);
    } else if (librariesAsync.hasError) {
      switchLibraryAction = () => ref.invalidate(librariesProvider);
    } else {
      switchLibraryAction = null;
    }

    final Widget switchLibraryTrailing;
    if (librariesAsync.isLoading) {
      switchLibraryTrailing = const EchoSkeleton.circle(size: 20);
    } else if (librariesAsync.hasError) {
      switchLibraryTrailing = Icon(
        AppIcons.refresh,
        size: 20,
        color: context.echoColors.error,
      );
    } else {
      switchLibraryTrailing = Icon(
        AppIcons.chevronDown,
        size: 20,
        color: context.echoColors.muted,
      );
    }

    return EchoScaffold(
      topBar: EchoTopBar.back(context: context, title: '设置'),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: ListView(
            key: const PageStorageKey<String>('echo-app-settings-scroll'),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(
              context.echoSpacing.md,
              context.echoSpacing.sm,
              context.echoSpacing.md,
              context.echoSpacing.xxl + context.echoShellBottomObstruction,
            ),
            children: <Widget>[
              EchoSettingsSection(
                title: '音乐库与服务器',
                description: '查看当前连接，也可以切换或编辑已经保存的音乐库。',
                children: <Widget>[
                  _ServerSummary(
                    library: library,
                    activeAddress: activeAddress,
                  ),
                  SizedBox(height: context.echoSpacing.sm),
                  EchoSettingRow(
                    icon: AppIcons.library,
                    title: '切换音乐库',
                    value: library?.name ?? '未选择',
                    description: switchDescription,
                    trailing: switchLibraryTrailing,
                    onPressed: switchLibraryAction,
                  ),
                  EchoSettingRow(
                    icon: AppIcons.edit,
                    title: '编辑当前音乐库',
                    value: library?.name ?? '未选择',
                    description: library == null
                        ? '选择音乐库后可编辑服务器与认证信息。'
                        : '管理服务器地址、认证方式与音乐库能力。',
                    onPressed: library == null
                        ? null
                        : () => Navigator.of(context).push<void>(
                            EchoPageRoute<void>(
                              context: context,
                              builder: (_) =>
                                  EditLibraryPage(libraryId: library.id),
                            ),
                          ),
                  ),
                  if (_showDesktopLibraryActions) ...<Widget>[
                    EchoSettingRow(
                      icon: AppIcons.add,
                      title: '添加音乐库',
                      description: '连接另一台服务器或另一个账户',
                      onPressed: () => unawaited(
                        GoRouter.of(context).push<void>('/login?add=true'),
                      ),
                    ),
                    EchoSettingRow(
                      icon: AppIcons.route,
                      title: '切换线路',
                      value: activeAddress?.label ?? '自动选择',
                      description: '手动锁定线路，或重新检测延迟',
                      onPressed: () => showRouteSelectionSheet(context),
                    ),
                  ],
                ],
              ),
              SizedBox(height: context.echoSpacing.xl),
              EchoSettingsSection(
                title: '播放与外观',
                description: '这些选择会立即应用到当前设备。',
                children: <Widget>[
                  EchoToggleSettingRow(
                    icon: AppIcons.route,
                    title: '线路自动回退',
                    description: '手动线路不可用时，自动切换到其他可用线路。',
                    value: autoFallback,
                    onChanged: (value) async {
                      ref.read(autoFallbackProvider.notifier).state = value;
                      ref.read(addressPoolProvider).autoFallback = value;
                      await LocalStorage.setAutoFallback(value);
                    },
                  ),
                  if (!kIsWeb &&
                      defaultTargetPlatform == TargetPlatform.android)
                    EchoSettingRow(
                      icon: AppIcons.timer,
                      title: '后台播放',
                      description: '检查电池优化、省电模式与熄屏播放限制',
                      onPressed: () =>
                          _pushPage(const BackgroundPlaybackPage()),
                    ),
                  EchoSettingRow(
                    icon: AppIcons.palette,
                    title: '主题设置',
                    value:
                        '${_themeModeText(themeSettings.mode)} · ${_colorHex(themeSettings.seedColor)}',
                    description: '明暗模式与 Echo 强调色',
                    onPressed: () => _pushPage(const ThemeSettingsPage()),
                  ),
                  EchoToggleSettingRow(
                    icon: AppIcons.image,
                    title: '封面动态背景',
                    description: '播放器背景跟随封面取色；关闭后使用当前主题颜色。',
                    value: dynamicPlayerBackground,
                    onChanged: (value) => unawaited(
                      ref
                          .read(dynamicPlayerBackgroundProvider.notifier)
                          .setEnabled(value),
                    ),
                  ),
                  EchoSettingRow(
                    icon: AppIcons.quality,
                    title: '音质设置',
                    description: '按网络选择播放码率',
                    onPressed: () => _pushPage(const AudioQualityPage()),
                  ),
                  EchoSettingRow(
                    icon: AppIcons.timer,
                    title: '切歌淡入淡出',
                    value: _crossfadeLabel(crossfadeMs),
                    description: '设置相邻曲目之间的交叉衰减时长。',
                    onPressed: () => _showCrossfadeSheet(crossfadeMs),
                  ),
                  if (_showDesktopCloseSetting)
                    EchoSettingRow(
                      icon: AppIcons.close,
                      title: '关闭窗口后',
                      value: _exitOnDesktopClose ? '退出应用' : '托盘运行',
                      description: _exitOnDesktopClose
                          ? '退出前会询问是否暂停未完成的本地下载。'
                          : '托盘可用时隐藏并继续播放；托盘不可用时最小化。',
                      onPressed: _showDesktopCloseBehaviorSheet,
                    ),
                  EchoSettingRow(
                    icon: AppIcons.lyrics,
                    title: '歌词提供商',
                    description: '调整获取顺序与启用状态',
                    onPressed: () => _pushPage(const LyricsProvidersPage()),
                  ),
                  EchoSettingRow(
                    icon: AppIcons.image,
                    title: '封面提供商',
                    description: '调整获取顺序并配置 Fanart.tv',
                    onPressed: () => _pushPage(const CoverProvidersPage()),
                  ),
                ],
              ),
              SizedBox(height: context.echoSpacing.xl),
              EchoSettingsSection(
                title: '存储与数据',
                description: '管理本机缓存，并查看音乐库与播放统计。',
                children: <Widget>[
                  EchoSettingRow(
                    icon: AppIcons.storage,
                    title: '缓存管理',
                    description: '音频、图片与歌词缓存',
                    onPressed: () => _pushPage(const CacheManagementPage()),
                  ),
                  EchoSettingRow(
                    icon: AppIcons.analytics,
                    title: '统计信息',
                    description: '音乐库、播放、收藏与缓存统计',
                    onPressed: () => _pushPage(const PlaybackStatsPage()),
                  ),
                ],
              ),
              SizedBox(height: context.echoSpacing.xl),
              EchoSettingsSection(
                title: '诊断与更新',
                description: '导出本机诊断日志，或检查 GitHub Releases。',
                children: <Widget>[
                  EchoSettingRow(
                    icon: AppIcons.fileText,
                    title: '导出日志',
                    description: '共缓存 ${Logger.bufferedLineCount} 条日志',
                    semanticLabel: _isExportingLogs
                        ? (_saveLogsToFile ? '导出日志，正在保存文件' : '导出日志，正在准备分享文件')
                        : null,
                    trailing: _isExportingLogs
                        ? const EchoSkeleton.circle(size: 20)
                        : null,
                    onPressed: _isExportingLogs ? null : _exportLogs,
                  ),
                  EchoSettingRow(
                    icon: AppIcons.refresh,
                    title: '检查更新',
                    description: '从 GitHub Releases 检查最新版本',
                    semanticLabel: _isCheckingUpdate
                        ? '检查更新，正在连接 GitHub Releases'
                        : null,
                    trailing: _isCheckingUpdate
                        ? const EchoSkeleton.circle(size: 20)
                        : null,
                    onPressed: _isCheckingUpdate ? null : _checkForUpdates,
                  ),
                  EchoSettingRow(
                    icon: AppIcons.info,
                    title: '关于',
                    description: '版本、构建与应用信息',
                    onPressed: () => unawaited(_showAboutSheet()),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _pushPage(Widget page) {
    Navigator.of(
      context,
    ).push(EchoPageRoute<void>(context: context, builder: (context) => page));
  }

  Future<void> _showLibrarySheet(
    List<MusicLibrary> libraries,
    MusicLibrary? currentLibrary,
  ) async {
    await showEchoBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => EchoBottomSheet(
        title: '切换音乐库',
        subtitle: '选择后会刷新当前音乐库的内容与播放状态。',
        constrainToAvailableHeight: true,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final library in libraries)
                EchoChoiceRow(
                  title: library.name,
                  description: library.addresses.firstOrNull?.url ?? '未配置服务器地址',
                  selected: library.id == currentLibrary?.id,
                  icon: AppIcons.library,
                  onPressed: () {
                    final alreadySelected = library.id == currentLibrary?.id;
                    Navigator.of(sheetContext).pop();
                    if (!alreadySelected) _switchLibrary(library);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _switchLibrary(MusicLibrary library) async {
    try {
      final player = ref.read(playerProvider.notifier);
      await player.prepareForLibrarySwitch();
      final repository = ref.read(libraryRepositoryProvider);
      try {
        await repository.setActiveLibrary(library.id);
        ref.read(authStateProvider.notifier).switchLibrary(library);
        ref.invalidate(playerProvider);
        ref.invalidate(randomSongsProvider);
        ref.invalidate(recentAlbumsProvider);
        ref.invalidate(frequentAlbumsProvider);
        ref.invalidate(playlistsProvider);
        ref.invalidate(starredProvider);
        _showMessage('已切换到“${library.name}”', kind: EchoMessageKind.success);
      } catch (_) {
        await player.cancelLibrarySwitchPreparation();
        rethrow;
      }
    } catch (error) {
      _showMessage('切换音乐库失败: $error', kind: EchoMessageKind.error);
    }
  }

  Future<void> _showCrossfadeSheet(int currentValue) async {
    const values = <int>[0, 500, 1000, 1500, 2000, 2500, 3000];
    final selected = await showEchoBottomSheet<int>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => EchoBottomSheet(
        title: '切歌淡入淡出',
        subtitle: '选择相邻曲目同时播放的交叉衰减时长。',
        constrainToAvailableHeight: true,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final value in values)
                EchoChoiceRow(
                  title: _crossfadeLabel(value),
                  description: value == 0
                      ? '关闭交叉衰减'
                      : '用 ${_crossfadeLabel(value)} 平滑衔接相邻曲目',
                  selected: value == currentValue,
                  icon: AppIcons.timer,
                  onPressed: () => Navigator.of(sheetContext).pop(value),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected == null) return;
    ref.read(crossfadeDurationMsProvider.notifier).setDuration(selected);
  }

  Future<void> _showDesktopCloseBehaviorSheet() async {
    final exitOnClose = await showEchoBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      builder: (sheetContext) => EchoBottomSheet(
        title: '关闭窗口后',
        subtitle: '选择点击桌面窗口关闭按钮时的行为。',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            EchoChoiceRow(
              title: '隐藏到托盘并继续播放',
              description: '托盘不可用时将最小化到任务栏。',
              selected: !_exitOnDesktopClose,
              icon: AppIcons.music,
              onPressed: () => Navigator.of(sheetContext).pop(false),
            ),
            EchoChoiceRow(
              title: '关闭窗口时退出',
              description: '退出前可暂停尚未完成的本地下载。',
              selected: _exitOnDesktopClose,
              icon: AppIcons.close,
              onPressed: () => Navigator.of(sheetContext).pop(true),
            ),
          ],
        ),
      ),
    );
    if (exitOnClose == null || exitOnClose == _exitOnDesktopClose) return;

    try {
      await DesktopCloseSettings.setExitOnClose(exitOnClose);
      if (mounted) setState(() => _exitOnDesktopClose = exitOnClose);
    } catch (error) {
      _showMessage('保存桌面关闭行为失败: $error', kind: EchoMessageKind.error);
    }
  }

  String get _platformLabel {
    if (kIsWeb) return 'Web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'Android',
      TargetPlatform.iOS => 'iOS',
      TargetPlatform.linux => 'Linux',
      TargetPlatform.macOS => 'macOS',
      TargetPlatform.windows => 'Windows',
      TargetPlatform.fuchsia => 'Fuchsia',
    };
  }

  Future<void> _copyAboutInfo(String details) async {
    try {
      await Clipboard.setData(ClipboardData(text: details));
      _showMessage('版本信息已复制', kind: EchoMessageKind.success);
    } catch (error) {
      _showMessage('复制版本信息失败: $error', kind: EchoMessageKind.error);
    }
  }

  Future<void> _showAboutSheet() async {
    PackageInfo? packageInfo;
    try {
      packageInfo = await PackageInfo.fromPlatform();
    } catch (error) {
      Logger.warnWithTag('ABOUT', 'cannot load package information', error);
    }
    if (!mounted) return;

    final version = packageInfo?.version.isNotEmpty == true
        ? packageInfo!.version
        : '暂不可用';
    final buildNumber = packageInfo?.buildNumber.isNotEmpty == true
        ? packageInfo!.buildNumber
        : '暂不可用';
    final packageName = packageInfo?.packageName.trim() ?? '';
    final hasSeparatePackageName =
        packageName.isNotEmpty && packageName != echoApplicationId;
    final platform = _platformLabel;
    final installer = packageInfo?.installerStore;
    final details = <String>[
      '应用: $echoBrandName',
      '版本: $version',
      '构建号: $buildNumber',
      '应用 ID: $echoApplicationId',
      if (hasSeparatePackageName) '包名: $packageName',
      '运行平台: $platform',
      '构建来源: $_buildSource',
      if (_buildFlutterVersion.isNotEmpty) 'Flutter: $_buildFlutterVersion',
      if (_buildCommit.isNotEmpty) 'Git 提交: $_buildCommit',
      if (installer != null && installer.isNotEmpty) '安装来源: $installer',
    ].join('\n');

    await showEchoBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => EchoBottomSheet(
        title: '关于 $echoBrandName',
        constrainToAvailableHeight: true,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              EchoSurface(
                level: EchoSurfaceLevel.raised,
                borderColor: sheetContext.echoColors.controlBoundary,
                padding: EdgeInsets.all(sheetContext.echoSpacing.md),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox.square(
                      dimension:
                          sheetContext.echoInteraction.minimumTouchTarget,
                      child: Center(
                        child: Icon(
                          AppIcons.musicFilled,
                          size: 28,
                          color: sheetContext.echoColors.accent,
                        ),
                      ),
                    ),
                    SizedBox(width: sheetContext.echoSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            echoBrandName,
                            style: sheetContext.echoTypography.headline,
                          ),
                          SizedBox(height: sheetContext.echoSpacing.xxs),
                          Text(
                            '回响 · 基于 Subsonic API 的音乐客户端',
                            style: sheetContext.echoTypography.body.copyWith(
                              color: sheetContext.echoColors.muted,
                            ),
                          ),
                          SizedBox(height: sheetContext.echoSpacing.xxs),
                          Text(
                            '版本 $version · 构建 $buildNumber',
                            style: sheetContext.echoTypography.metadata
                                .copyWith(color: sheetContext.echoColors.muted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: sheetContext.echoSpacing.md),
              const EchoSectionHeader(title: '版本与构建'),
              SizedBox(height: sheetContext.echoSpacing.xs),
              EchoSurface(
                level: EchoSurfaceLevel.raised,
                borderColor: sheetContext.echoColors.controlBoundary,
                padding: EdgeInsets.all(sheetContext.echoSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _SettingsInfoLine(label: '版本号', value: version),
                    _SettingsInfoLine(label: '构建号', value: buildNumber),
                    const _SettingsInfoLine(
                      label: '应用 ID',
                      value: echoApplicationId,
                    ),
                    if (hasSeparatePackageName)
                      _SettingsInfoLine(label: '包名', value: packageName),
                    _SettingsInfoLine(label: '运行平台', value: platform),
                    _SettingsInfoLine(label: '构建来源', value: _buildSource),
                    if (_buildFlutterVersion.isNotEmpty)
                      _SettingsInfoLine(
                        label: 'Flutter 版本',
                        value: _buildFlutterVersion,
                      ),
                    if (_buildCommit.isNotEmpty)
                      _SettingsInfoLine(label: 'Git 提交', value: _buildCommit),
                    if (installer != null && installer.isNotEmpty)
                      _SettingsInfoLine(
                        label: '安装来源',
                        value: installer,
                        showBottomSpacing: false,
                      ),
                  ],
                ),
              ),
              SizedBox(height: sheetContext.echoSpacing.md),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: sheetContext.echoSpacing.xs,
                runSpacing: sheetContext.echoSpacing.xs,
                children: <Widget>[
                  EchoButton.ghost(
                    label: '项目主页',
                    onPressed: () => unawaited(
                      _openUrl('https://github.com/Ericwyn/echoes'),
                    ),
                  ),
                  EchoButton.secondary(
                    label: '复制版本信息',
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(_copyAboutInfo(details));
                    },
                  ),
                ],
              ),
              SizedBox(height: sheetContext.echoSpacing.md),
              Text(
                '© 2026 ${echoDisplayName()}',
                style: sheetContext.echoTypography.metadata.copyWith(
                  color: sheetContext.echoColors.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _themeModeText(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return '跟随系统';
      case ThemeMode.light:
        return '白色';
      case ThemeMode.dark:
        return '黑色';
    }
  }

  String _colorHex(Color color) {
    final value = color
        .toARGB32()
        .toRadixString(16)
        .padLeft(8, '0')
        .toUpperCase();
    return '#${value.substring(2)}';
  }
}

class _ServerSummary extends StatelessWidget {
  const _ServerSummary({required this.library, required this.activeAddress});

  final MusicLibrary? library;
  final ServerAddress? activeAddress;

  @override
  Widget build(BuildContext context) {
    return EchoSurface(
      level: EchoSurfaceLevel.raised,
      borderColor: context.echoColors.controlBoundary,
      padding: EdgeInsets.all(context.echoSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _SettingsInfoLine(label: '音乐库', value: library?.name ?? '未选择'),
          _SettingsInfoLine(
            label: '当前连接',
            value: activeAddress?.label ?? '未连接',
          ),
          _SettingsInfoLine(label: '服务器地址', value: activeAddress?.url ?? '未设置'),
          _SettingsInfoLine(label: '用户名', value: library?.username ?? '未设置'),
          _SettingsInfoLine(
            label: '认证方式',
            value: library?.authType == MusicLibraryAuthType.apiKey
                ? 'API Key'
                : '密码',
            showBottomSpacing: false,
          ),
        ],
      ),
    );
  }
}

class _SettingsInfoLine extends StatelessWidget {
  const _SettingsInfoLine({
    required this.label,
    required this.value,
    this.showBottomSpacing = true,
  });

  final String label;
  final String value;
  final bool showBottomSpacing;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '$label，$value',
      child: ExcludeSemantics(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: showBottomSpacing ? context.echoSpacing.sm : 0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                label,
                style: context.echoTypography.metadata.copyWith(
                  color: context.echoColors.muted,
                ),
              ),
              SizedBox(height: context.echoSpacing.xxs),
              SelectableText(value, style: context.echoTypography.body),
            ],
          ),
        ),
      ),
    );
  }
}

String _crossfadeLabel(int milliseconds) {
  if (milliseconds <= 0) return '关闭';
  return '${(milliseconds / 1000).toStringAsFixed(1)} 秒';
}
