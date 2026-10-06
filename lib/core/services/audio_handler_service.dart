import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../constants/app_identity.dart';
import '../utils/logger.dart';
import '../utils/playback_error_summary.dart';
import '../theme/color_scheme.dart';

const echoPlaybackSystemActions = <MediaAction>{MediaAction.seek};

/// 音频处理器 - 处理后台播放和通知栏控制
class EchoAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer _audioPlayer;

  // 暴露 AudioPlayer 给外部使用
  AudioPlayer get audioPlayer => _audioPlayer;

  // 用于通知外部的回调
  Future<void> Function()? onSkipToNext;
  Future<void> Function()? onSkipToPrevious;
  Future<void> Function()? onPlay;
  Future<void> Function()? onPause;
  Future<void> Function()? onStop;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Object? _commandOwner;
  bool _commandsHaveBeenBound = false;
  int? _sourceTransition;
  bool _transitionPlaying = false;
  Future<void> Function(Duration position)? onSeek;
  Duration _positionOffset = Duration.zero;
  (AudioProcessingState, bool)? _lastLoggedState;

  EchoAudioHandler(this._audioPlayer) {
    _init();
  }

  void bindCommands({
    required Object owner,
    required Future<void> Function() onPlay,
    required Future<void> Function() onPause,
    required Future<void> Function() onStop,
    required Future<void> Function(Duration position) onSeek,
    required Future<void> Function() onSkipToNext,
    required Future<void> Function() onSkipToPrevious,
  }) {
    _commandOwner = owner;
    _commandsHaveBeenBound = true;
    this.onPlay = onPlay;
    this.onPause = onPause;
    this.onStop = onStop;
    this.onSeek = onSeek;
    this.onSkipToNext = onSkipToNext;
    this.onSkipToPrevious = onSkipToPrevious;
  }

  void unbindCommands(Object owner) {
    if (!identical(_commandOwner, owner)) return;
    _commandOwner = null;
    onPlay = null;
    onPause = null;
    onStop = null;
    onSeek = null;
    onSkipToNext = null;
    onSkipToPrevious = null;
  }

  Future<void> clearMediaItem() async {
    Logger.infoWithTag(
      'AUDIO_SERVICE',
      'media_item cleared id=${mediaItem.value?.id}',
    );
    mediaItem.add(null);
    _broadcastState();
  }

  /// 初始化监听器
  void _init() {
    // 监听播放状态变化，同步到通知栏
    _subscriptions.add(
      _audioPlayer.playingStream.listen((playing) {
        _broadcastState();
      }),
    );

    // Android's media session extrapolates position while playing. Publishing
    // UI position ticks (5-60/sec) needlessly queues platform calls in background.
    _subscriptions.add(
      _audioPlayer.playbackEventStream.listen(
        (event) {
          _broadcastState(processingState: event.processingState);
        },
        onError: (Object error, StackTrace stack) {
          // PlayerNotifier owns runtime error recovery.
        },
      ),
    );
  }

  /// 广播当前状态到通知栏
  void _broadcastState({ProcessingState? processingState}) {
    final report = (_getProcessingState(processingState), _reportedPlaying);
    if (_lastLoggedState != report) {
      _lastLoggedState = report;
      Logger.infoWithTag(
        'AUDIO_SERVICE',
        'publish state=${report.$1.name} playing=${report.$2} transition=$_sourceTransition '
            'nativeState=${_audioPlayer.processingState.name} nativePlaying=${_audioPlayer.playing} '
            'intent=$_transitionPlaying mediaId=${mediaItem.value?.id}',
      );
    }
    playbackState.add(
      playbackState.value.copyWith(
        controls: _getControls(),
        androidCompactActionIndices: const [0, 1, 2],
        // Explicitly advertise seeking so OEM MediaStyle implementations do
        // not render the notification progress control as disabled.
        systemActions: echoPlaybackSystemActions,
        processingState: _getProcessingState(processingState),
        playing: _reportedPlaying,
        updatePosition: _logicalPosition(_audioPlayer.position),
        bufferedPosition: _logicalPosition(_audioPlayer.bufferedPosition),
        speed: _audioPlayer.speed,
      ),
    );
  }

  bool get _reportedPlaying =>
      _sourceTransition != null ||
          _audioPlayer.processingState == ProcessingState.idle
      ? _transitionPlaying
      : _audioPlayer.playing;

  /// 获取控制按钮
  List<MediaControl> _getControls() {
    return [
      MediaControl.skipToPrevious,
      if (_reportedPlaying) MediaControl.pause else MediaControl.play,
      MediaControl.skipToNext,
    ];
  }

  /// 获取处理状态
  AudioProcessingState _getProcessingState(ProcessingState? eventState) {
    if (_sourceTransition != null) return AudioProcessingState.loading;
    switch (eventState ?? _audioPlayer.processingState) {
      case ProcessingState.idle:
        // A failed prepare may leave the decoder idle while bounded recovery
        // is pending. Only an explicit pause/stop should tear down the service.
        return _transitionPlaying && mediaItem.value != null
            ? AudioProcessingState.buffering
            : AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  /// 更新媒体信息（歌曲切换时调用）
  @override
  Future<void> updateMediaItem(MediaItem item) async {
    Logger.infoWithTag(
      'AUDIO_SERVICE',
      'media_item update id=${item.id} hasArtwork=${item.artUri != null}',
    );
    mediaItem.add(item);

    // Metadata updates must not change the user's transport intent.
    _broadcastState();
  }

  void beginSourceTransition(int generation, {required bool playing}) {
    _sourceTransition = generation;
    _transitionPlaying = playing;
    Logger.infoWithTag(
      'AUDIO_SERVICE',
      'source transition begin generation=$generation playing=$playing',
    );
    _broadcastState();
  }

  void endSourceTransition(int generation) {
    if (_sourceTransition != generation) return;
    _sourceTransition = null;
    Logger.infoWithTag(
      'AUDIO_SERVICE',
      'source transition end generation=$generation state=${_audioPlayer.processingState.name}',
    );
    _broadcastState();
  }

  void updateTransportIntent(bool playing) {
    _transitionPlaying = playing;
    _broadcastState();
  }

  // ===== 播放控制 =====

  @override
  Future<void> play() async {
    Logger.info('AudioHandler: play');
    if (onPlay != null) return onPlay!();
    if (_commandsHaveBeenBound) return;
    unawaited(_audioPlayer.play());
  }

  @override
  Future<void> pause() async {
    Logger.info('AudioHandler: pause');
    if (onPause != null) return onPause!();
    if (_commandsHaveBeenBound) return;
    await _audioPlayer.pause();
  }

  @override
  Future<void> stop() async {
    Logger.info('AudioHandler: stop');
    _sourceTransition = null;
    _transitionPlaying = false;
    if (onStop != null) {
      await onStop!();
    } else {
      await _audioPlayer.stop();
    }
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    Logger.info('AudioHandler: seek to $position');
    final callback = onSeek;
    if (callback != null) {
      await callback(position);
      return;
    }
    if (_commandsHaveBeenBound) return;
    await _audioPlayer.seek(position);
  }

  /// Sets the logical song offset of the currently loaded source.
  ///
  /// A Subsonic `timeOffset` stream starts its decoder timeline at zero even
  /// though it contains audio from the middle of the song. Media-session
  /// progress must add this offset, and seek actions must be delegated back to
  /// PlayerNotifier so it can rebuild the stream URL.
  void setPositionOffset(Duration offset) {
    _positionOffset = offset < Duration.zero ? Duration.zero : offset;
    _broadcastState();
  }

  Duration _logicalPosition(Duration sourcePosition) {
    return sourcePosition + _positionOffset;
  }

  @override
  Future<void> skipToNext() async {
    Logger.info('AudioHandler: skipToNext');
    await onSkipToNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    Logger.info('AudioHandler: skipToPrevious');
    await onSkipToPrevious?.call();
  }

  @override
  Future<void> setSpeed(double speed) async {
    await _audioPlayer.setSpeed(speed);
  }

  /// 清理资源
  Future<void> dispose() async {
    onPlay = null;
    onPause = null;
    onStop = null;
    onSeek = null;
    onSkipToNext = null;
    onSkipToPrevious = null;
    await stop();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _audioPlayer.dispose();
  }
}

Future<EchoAudioHandler>? _audioServiceFuture;

/// Initialize the process-wide AudioService handler once. A PlayerNotifier can
/// be recreated when the active library changes, but AudioService itself is a
/// process singleton and its engine must survive that rebind.
Future<EchoAudioHandler> initAudioService() async {
  final future = _audioServiceFuture ??= _initializeAudioService();
  try {
    return await future;
  } catch (_) {
    if (identical(_audioServiceFuture, future)) _audioServiceFuture = null;
    rethrow;
  }
}

Future<EchoAudioHandler> _initializeAudioService() async {
  final appName = echoDisplayName();
  final isChinese = appName == '回响';
  final audioPlayer = AudioPlayer(
    audioLoadConfiguration: const AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        minBufferDuration: Duration(minutes: 10),
        maxBufferDuration: Duration(minutes: 15),
        bufferForPlaybackDuration: Duration(seconds: 5),
        bufferForPlaybackAfterRebufferDuration: Duration(seconds: 10),
      ),
      darwinLoadControl: DarwinLoadControl(
        preferredForwardBufferDuration: Duration(minutes: 10),
      ),
    ),
  );

  EchoAudioHandler? createdHandler;
  StreamSubscription<Object>? platformErrors;
  try {
    // Install before init: platform failures are otherwise absent from exports.
    platformErrors = AudioService.asyncError.listen((error) {
      Logger.warnWithTag(
        'AUDIO_SERVICE',
        'platform_async_error ${playbackErrorSummary(error)} '
            'publishedState=${createdHandler?.playbackState.value.processingState.name} '
            'publishedPlaying=${createdHandler?.playbackState.value.playing} '
            'mediaId=${createdHandler?.mediaItem.value?.id}',
      );
    });
    return await AudioService.init<EchoAudioHandler>(
      builder: () {
        createdHandler = EchoAudioHandler(audioPlayer);
        createdHandler!._subscriptions.add(platformErrors!);
        return createdHandler!;
      },
      config: AudioServiceConfig(
        androidNotificationChannelId: '$echoApplicationId.audio',
        androidNotificationChannelName: isChinese
            ? '$appName 音乐播放'
            : '$appName Music Playback',
        androidNotificationChannelDescription: isChinese
            ? '$appName 播放控制'
            : '$appName music controls',
        // Android 通知进度条/强调元素使用的底色，避免浅色主题下不可见。
        notificationColor: AppColorScheme.defaultSeedColor,
        androidNotificationOngoing: false, // 允许用户手动关闭通知
        androidNotificationIcon: 'drawable/ic_notification',
        androidShowNotificationBadge: true,
        androidStopForegroundOnPause: false, // 暂停时保持通知栏
        fastForwardInterval: Duration(seconds: 10),
        rewindInterval: Duration(seconds: 10),
      ),
    );
  } catch (_) {
    await platformErrors?.cancel();
    if (createdHandler != null) {
      await createdHandler!.dispose();
    } else {
      await audioPlayer.dispose();
    }
    rethrow;
  }
}
