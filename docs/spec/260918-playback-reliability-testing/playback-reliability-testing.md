# 播放可靠性验证

本次修复覆盖后台服务换源、运行时断流恢复、预缓存、拖动回滚、单曲循环复用、CPU 保活、后台设置引导和播放日志持久化。

## 自动回归

```sh
flutter test test/core/services/audio_handler_service_test.dart \
  test/providers/player_recovery_test.dart \
  test/core/services/audio_prefetch_service_test.dart \
  test/core/utils/playback_log_store_test.dart \
  test/core/services/playback_wake_guard_test.dart \
  test/core/services/background_playback_service_test.dart \
  test/features/settings/background_playback_page_test.dart
```

测试使用真实 PlayerNotifier 配合可控播放器事件，以及本地 HTTP 服务器验证预下载。
它们不能替代 Android 真机的系统服务、音频焦点和厂商后台限制测试。

## Android 真机验收

| 场景 | 操作 | 预期 |
| --- | --- | --- |
| 熄屏自动下一首 | 队列至少 3 首，熄屏完整播放两轮；分别测试原始音质和限码率音质 | 曲尾继续下一首，后台服务在换源期间保持 loading |
| 同一网络恢复 | 保持 Wi-Fi 连接，播放中使测试服务器暂时不可达再恢复 | 运行时错误或持续 buffering 后触发恢复，恢复到原进度 |
| 网络切换 | Wi-Fi 切移动网络，再切回 | 已经健康播放时不强制换源；失败恢复时重建当前线路 URL |
| 重试上限 | 故障持续存在 | 每轮最多 4 次恢复，等待间隔 2/4/8/16 秒，耗尽后暂停并提示；手动播放可重新尝试 |
| 暂停取消恢复 | 断流后、恢复前点击暂停 | 不再自动恢复出声；停止、切歌同样使旧恢复失效 |
| 曲尾竞争 | 接近曲尾时手动下一首，并人为延迟下一首加载 | 旧 completed 不跳过新歌曲 |
| 通知栏恢复音量 | 开启淡入淡出，在应用内暂停，再从锁屏点击播放 | 正常音量恢复 |
| 拖动失败 | 转码歌曲播放中断网并拖动进度 | 尝试恢复旧音源和旧位置；回滚失败进入有限重试，不伪造成功进度 |
| 歌词远跳转 | 刚起播、目标尚未缓冲时点击后面的歌词；分别测试原始音质和转码音质 | 进度保持歌词目标位置，大播放器和迷你播放器的播放按钮显示 loading 且不可点击；缓冲完成后按原播放意图继续 |
| 连续歌词跳转 | 加载期间连续选择多个歌词位置 | 最后一次选择生效，旧请求完成不覆盖新位置 |
| 跳转中的系统控制 | 转码换源时从通知栏暂停或播放 | 暂停后不自动出声；播放只更新意图，不另起整首加载或回到 00:00 |
| 跳转后断流 | 目标缓冲失败后恢复网络 | 恢复到用户选择的位置；重试耗尽后退出 loading，允许点击播放重试 |
| 单曲循环 | 转码歌曲拖到中间，开启单曲循环 | 下一轮从整首开头播放，而非只循环尾段 |
| 下一首预缓存 | 当前歌曲已有至少 30 秒缓冲，检查 PRECACHE 日志和服务器访问 | 出现实际下载；完成后下一首命中缓存；切歌取消未完成预缓存 |
| 隔夜日志 | 播放、退出进程、重新启动，然后导出日志 | 导出文件包含 Persistent playback history 与 Current session |

预缓存跳过 Web、试听歌曲、单曲队列和超过 20 分钟的下一首；随机模式按当前可见顺序预缓存下一首，在一轮末尾生成新随机顺序前不提前猜测下一轮。单次下载限制 64 MiB 和 2 分钟。

## 诊断日志

- `PLAYBACK`：启动、应用生命周期、播放/暂停/停止、音源加载、状态切换、歌曲完成。
- `AUDIO_SERVICE`：换源事务开始、结束及服务状态。
- `PLAYBACK_RECOVERY`：失败原因类型、重试次数、恢复位置、拖动回滚、重试耗尽。
- `PRECACHE`：实际下载开始、完成或取消/失败。

上述结构化日志保存到应用私有支持目录的 `playback_logs`，保留最近 7 个自然日。
每天当前文件达到约 1 MiB 后轮转，保留该日上一份文件；批量写入可能略超过阈值。
日志写入失败不阻塞播放。意外杀进程可能丢失最后约 250 毫秒尚未刷盘的记录。
持久化白名单不包含请求体、密码或带鉴权参数的流 URL；当前会话仍沿用原有内存日志导出。

## 本次本地验证记录

2026-09-18 使用本机 Flutter 3.41.7 / Dart 3.11.5 执行全项目静态分析，无问题；本轮全量 374 个测试通过，并另补停播与重新播放竞争的定向回归。
仓库 CI 使用 Flutter 3.38.9，本次没有更改依赖锁文件。Android 新增 Kotlin 插件尚未在本机编译，需由 Actions 编译验证；上述 Android 真机用例尚未执行。

## 熄屏与重复播放补充验证

- 完整音源开启单曲循环，连续听两轮：应出现 `repeat_native`，不再每轮出现 `load begin`。原生循环不可用时走 `repeat_reuse`；远程流的 seek 仍可能产生网络缓冲。
- 对服务器 timeOffset 转码流拖到中间：本轮结束出现一次 `repeat_reload_tail`，下一轮必须从 0 开始，之后使用原生循环。
- 单首队列增加第二首：应退出原生单曲循环，正常自动下一首；删除第二首后恢复单首循环。
- 打开“设置 → 后台播放”，对照手机的电池优化与省电模式；修改后返回应用应自动刷新。检测失败显示未知，不应显示已放开。
- 三星手机检查“从不休眠的应用”入口；不支持时退回应用信息页。休眠名单不能自动检测，需要手动核对。参考 [三星官方说明](https://developer.samsung.com/mobile/app-management.html)。
- 熄屏至少 15 分钟，跨越两次曲尾，分别验证本地缓存、网络流和单曲循环；尽量不要在曲尾前唤醒屏幕。若仍停顿，记录实际静音和亮屏时间并导出日志。
- 对照 `cpu_guard` 的 `held / foreground / interactive / idle / batteryExempt / powerSave / gapMs / sleptMs`；暂停/停止应出现释放记录且不再续期。`sleptMs` 是设备睡眠时间差，不等于断流时长。
- 偶发熄屏切歌失败：恢复后立即导出日志（包含持久化历史）。关联 `song / session / generation`，依次检查 `completed`、`load begin`、`load_waiting`、`load failed`、`load_end` 和 `PLAYBACK_RECOVERY timer_fired`。`phase` 区分 pause、loop_mode、set_source；`elapsedMs / actualMs / lateMs` 用于识别超时和恢复定时器是否因设备休眠延迟。诊断只增加观测，不修改原有重试或保活策略。
- `PLAYBACK_NATIVE` 中的 `timeMs / elapsedMs / uptimeMs` 是原生采样时间，日志行时间是 Dart 接收时间，亮屏后补发事件时两者可能差很多。`servicePresent=false` 表示未发现服务；`serviceForeground=null` 或 `serviceInspectionError` 不应当作服务退出前台。对照 `mediaNotificationCount / notificationsEnabled / mediaPlaybackState` 判断通知是否存在、媒体会话状态是否与 Dart 发布状态一致（Android PlaybackState 数值：0 NONE、1 STOPPED、2 PAUSED、3 PLAYING、6 BUFFERING、7 ERROR、8 CONNECTING）。
- 原生层暂存最近 40 次采样及 SCREEN_ON / SCREEN_OFF / DEVICE_IDLE_MODE_CHANGED / POWER_SAVE_MODE_CHANGED 事件，没有额外周期轮询。读取快照不续期唤醒锁。`history_gap` 表示暂存历史有缺口；事件不能替代系统服务的完整生命周期日志。`networkPresent / networkInternet / networkValidated / networkTransport / restrictBackground` 描述系统网络状态，不保证音乐服务器可达。
- `PLAYBACK_NETWORK` 的 `cause=dns / timeout / network_unreachable / tls` 在 release 也保留，异常原文、认证参数和完整 URL 不写入这些诊断。`AUDIO_SERVICE platform_async_error` 捕获插件异步状态同步失败；仅看到 `publish` 不代表 Android 已接受状态。先比较正常与故障两次导出，再判断网络异常是触发条件还是省电限制的结果。
- `event_loop_gap` 表示 Dart 回调间隔异常，`native_completed eventAgeMs` 帮助区分事件投递延迟；这些信号不能单独证明是厂商杀后台或网络故障。检测到后台延迟后，回到前台只提示一次设置检查。

Android CPU 锁在请求播放期间持续持有，暂停、停止、恢复耗尽或引擎销毁时释放，不保持屏幕常亮。Dart 每 20 秒发送心跳，原生侧若 5 分钟未收到心跳会释放锁，防止播放线程失联后无限耗电。锁覆盖原生歌曲结束到 Dart 切换下一首的间隙；它仍不能绕过所有厂商后台限制。系统电池优化状态和设置跳转使用 [Android 官方接口](https://developer.android.com/reference/android/os/PowerManager#isIgnoringBatteryOptimizations(java.lang.String))，不自动修改用户设置。

验证曲尾卡顿时，同时抓取 `adb logcat -b main,system,events,crash -v year,threadtime` 和 `adb shell dumpsys batterystats --history`。原生日志标签 `EchoWakeGuard` 会记录获取、释放以及心跳超时；正常跨曲应保持同一次锁，暂停或停止应出现明确的释放原因。
