import 'package:flutter/material.dart';

import '../../../core/design/echo_design.dart';
import '../../../core/services/background_playback_service.dart';
import '../widgets/echo_settings_components.dart';

class BackgroundPlaybackPage extends StatefulWidget {
  const BackgroundPlaybackPage({
    super.key,
    this.service = const BackgroundPlaybackService(),
  });

  final BackgroundPlaybackService service;

  @override
  State<BackgroundPlaybackPage> createState() => _BackgroundPlaybackPageState();
}

class _BackgroundPlaybackPageState extends State<BackgroundPlaybackPage>
    with WidgetsBindingObserver {
  BackgroundPlaybackStatus _status = const BackgroundPlaybackStatus();
  bool _loading = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    setState(() => _loading = true);
    final status = await widget.service.readStatus();
    if (!mounted || generation != _generation) return;
    setState(() {
      _status = status;
      _loading = false;
    });
  }

  Future<void> _open(BackgroundSettingsTarget target) async {
    final opened = await widget.service.openSettings(target);
    if (!opened && mounted) {
      showEchoMessage(context, '无法打开系统设置，请在手机设置中找到 Echoes，检查电池与后台活动限制。');
    }
  }

  String _value(bool? value, String yes, String no) =>
      _loading ? '检测中…' : (value == null ? '无法检测，请手动检查' : (value ? yes : no));

  @override
  Widget build(BuildContext context) {
    return EchoScaffold(
      topBar: EchoTopBar.back(context: context, title: '后台播放'),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            key: const PageStorageKey<String>(
              'echo-background-playback-settings-scroll',
            ),
            padding: EdgeInsets.fromLTRB(
              context.echoSpacing.md,
              context.echoSpacing.sm,
              context.echoSpacing.md,
              context.echoSpacing.xxl + context.echoShellBottomObstruction,
            ),
            children: [
              EchoSettingsSection(
                title: '熄屏播放检查',
                description: '如果熄屏后停顿、亮屏立即恢复，可检查以下设置。放开后台限制可能增加耗电；设置名称因手机而异。',
                children: [
                  EchoSettingRow(
                    icon: AppIcons.timer,
                    title: '系统电池优化',
                    value: _value(
                      _status.batteryExempt,
                      '已排除系统电池优化',
                      '未排除系统电池优化',
                    ),
                    description:
                        '点击后在系统弹窗中允许熄屏继续运行。已允许时会打开电池优化列表。此项不能代表所有厂商后台限制。',
                    onPressed: () => _open(BackgroundSettingsTarget.battery),
                  ),
                  EchoSettingRow(
                    icon: AppIcons.settings,
                    title: '省电模式',
                    value: _value(_status.powerSaveMode, '已开启', '未开启'),
                    description: '出现熄屏停顿时，可关闭省电模式后对比测试。',
                    onPressed: () => _open(BackgroundSettingsTarget.power),
                  ),
                  EchoSettingRow(
                    icon: AppIcons.settings,
                    title: '应用后台限制',
                    description: '进入 Echoes 应用信息，在电池设置中允许后台活动，或选择“不受限制”。',
                    onPressed: () => _open(BackgroundSettingsTarget.app),
                  ),
                ],
              ),
              SizedBox(height: context.echoSpacing.lg),
              EchoSettingsSection(
                title: _status.isSamsung ? '三星后台使用限制' : '厂商后台管理',
                description: _status.isSamsung
                    ? '休眠、深度休眠名单无法自动检测。请在“设置 → 电池（或设备维护 → 电池）→ 后台使用限制”中将 Echoes 移出休眠名单，并按需加入“从不休眠的应用”。'
                    : '部分手机另有休眠应用、自启动或后台运行设置，无法通过通用接口完整检测。即使已排除系统电池优化，也请检查这些限制。',
                children: [
                  if (_status.isSamsung)
                    EchoSettingRow(
                      icon: AppIcons.settings,
                      title: '打开从不休眠的应用',
                      description: '若当前系统不支持此入口，会打开应用信息，请按上方路径手动检查。',
                      onPressed: () => _open(BackgroundSettingsTarget.samsung),
                    ),
                  EchoButton.ghost(
                    label: _loading ? '检测中…' : '重新检测',
                    onPressed: _loading ? null : _refresh,
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
