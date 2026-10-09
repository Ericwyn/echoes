import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        defaultTargetPlatform,
        kIsWeb,
        visibleForTesting,
        listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import '../data/models/song.dart';
import '../data/models/audio_quality.dart';
import '../data/models/server_address.dart';
import '../data/sources/subsonic_api_client.dart';
import '../data/sources/local_storage.dart';
import '../data/repositories/music_repository.dart';

import '../core/network/connectivity_monitor.dart';
import '../core/platform/platform_file_bridge.dart';
import '../core/utils/logger.dart';
import '../core/utils/network_error_notifier.dart';
import '../core/services/audio_handler_service.dart';
import '../core/services/audio_media_item_mapper.dart';
import '../core/services/playback_wake_guard.dart';
import '../core/utils/playback_error_summary.dart';
import '../core/services/background_playback_advisor.dart';
import '../core/services/linux_mpris_service.dart';
import '../core/services/artwork_file_cache.dart';
import '../core/services/windows_smtc_service.dart';
import '../core/services/desktop_lifecycle_service.dart';
import '../core/utils/cover_ref_security.dart';

import 'music_provider.dart';
import 'api_provider.dart';
import 'audio_quality_provider.dart';
import 'download_provider.dart';
import 'audio_cache_provider.dart';
import 'crossfade_provider.dart';
import 'gd_music_provider.dart';
import '../providers/auth_provider.dart';

export 'player/player_state.dart';
export 'player/playback_contract.dart';
export 'player/favorite_scrobble_handler.dart';
export 'player/cache_manager_handler.dart';
import 'player/player_state.dart';
import 'player/playback_queue_state.dart';
import 'player/android_native_queue.dart';
import 'player/playback_contract.dart';
import 'player/playback_metadata.dart';
import 'player/favorite_scrobble_handler.dart';
import 'player/cache_manager_handler.dart';
import 'player/player_seek_policy.dart';
import 'player/transcoded_stream_seek.dart';

const _playerLogTag = 'PLAYER';
const _playDbgTag = 'PLAYDBG';

class _SeekSourceRestored implements Exception {}

bool get _isDesktopPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS);

bool get _isApplePlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// 将解析后的试听元数据写回原队列项，同时保留其它正式/试听歌曲。
@visibleForTesting
({List<Song> queue, int index}) resolvePreviewPlaybackQueue({
  required List<Song> queue,
  required int preferredIndex,
  required Song unresolvedSong,
  required Song resolvedSong,
}) {
  final nextQueue = List<Song>.of(queue);
  var nextIndex = preferredIndex;

  if (nextQueue.isEmpty) {
    return (queue: <Song>[resolvedSong], index: 0);
  }

  final preferredIndexMatches =
      nextIndex >= 0 &&
      nextIndex < nextQueue.length &&
      nextQueue[nextIndex].id == unresolvedSong.id;
  if (!preferredIndexMatches) {
    final matchedIndex = nextQueue.indexWhere(
      (item) => item.id == unresolvedSong.id,
    );
    if (matchedIndex >= 0) {
      nextIndex = matchedIndex;
    } else {
      nextIndex = nextIndex.clamp(0, nextQueue.length);
      nextQueue.insert(nextIndex, resolvedSong);
      return (queue: nextQueue, index: nextIndex);
    }
  }

  nextQueue[nextIndex] = resolvedSong;
  return (queue: nextQueue, index: nextIndex);
}

/// 播放器 Provider

// ...
final playerProvider = StateNotifierProvider<PlayerNotifier, PlayerState>((
  ref,
) {
  // 不固定 apiClient/musicRepository 引用，PlayerNotifier 内部通过 ref.read 动态获取
  // 这样既不建立 watch 依赖（不会被重建），又能始终拿到最新的实例
  return PlayerNotifier(ref);
});

/// Stable command surface shared by desktop, mobile and system adapters.
final playbackCommandsProvider = Provider<PlaybackCommands>(
  (ref) => ref.watch(playerProvider.notifier),
);

/// Platform-neutral playback view for selectors used by player surfaces.
final playbackSnapshotProvider = Provider<PlaybackSnapshot>((ref) {
  ref.watch(playerProvider);
  return ref.read(playerProvider.notifier).snapshot;
});

/// 播放器状态管理器
class PlayerNotifier extends StateNotifier<PlayerState>
    implements PlaybackCommands {
  final Ref _ref;
  final DateTime Function() _clock;
  AudioPlayer? _audioPlayer;
  EchoAudioHandler? _audioHandler;
  final PlaybackWakeGuard _wakeGuard;
  ConcatenatingAudioSource? _androidNativeQueue;
  AndroidNativeQueueTrack? _androidCurrentTrack;
  StreamSubscription<SequenceState?>? _androidNativeSequenceSubscription;
  bool _androidNativeQueueUpdating = false;
  bool _androidNativeQueueDirty = false;
  DateTime? _androidNativeQueueLastCheck;
  LoopMode _nativeLoopMode = LoopMode.off;
  Future<void> _playbackModeMutationTail = Future<void>.value();
  DateTime? _lastPollAt;
  bool _lastPollWasBackground = false;
  bool _lastPollRequestedPlayback = false;
  StreamSubscription? _downloadProgressSubscription;
  StreamSubscription<NetworkType>? _networkTypeSubscription;
  final Random _random = Random();
  Duration? _pendingSeekPosition;
  String? _pendingSeekSongId;
  bool _usingLockCachingSource = false;
  bool _playbackRequested = false;
  int? _replacingSourceGeneration;
  String? _currentStreamUrl;
  String? _currentStreamSongId;
  String? _currentStreamFormat;
  int? _currentStreamMaxBitRate;
  String? _loadedSourceSongId;
  String? _loadedSourceEntryId;
  String? _activePlaybackEntryId;
  String? _currentPlaybackLibraryId;
  int _sourceGeneration = 0;
  int _seekRequestGeneration = 0;
  int _positionSeekRevision = 0;
  int _transportRequestGeneration = 0;
  int? _activeSeekGeneration;
  String? _activeSeekSongId;
  bool _seekAwaitingReady = false;
  int _internalSeekPauseDepth = 0;
  bool _isApplyingPendingSeek = false;
  bool _seekByReloadStream = false;
  Duration _sourcePositionOffset = Duration.zero;
  ProcessingState? _lastProcessingStateForDebug;
  bool _isHandlingCompletion = false;
  String? _completionHandlingSongId;
  String? _completionHandlingEntryId;
  Timer? _positionPollTimer;
  Duration _lastPolledPlayerPosition = Duration.zero;
  int _stagnantPositionTicks = 0;
  int _lastStagnantLogTick = -1;
  int _lastIgnoredSyntheticPositionLogTick = -1;
  bool _syntheticPositionFallbackActive = false;
  int _playDebugSession = 0;
  int? _precacheStartedSession;
  String? _precacheTargetEntryId;
  bool _loggedDurationUnavailableForSong = false;
  Timer? _fadeTimer;
  Completer<void>? _fadeCompleter;
  Timer? _playbackVolumePersistTimer;
  double _fadeGain = 1;
  double _lastAudibleVolume = 1;
  static const Duration _playbackSessionPersistInterval = Duration(seconds: 15);
  Timer? _playbackSessionPersistTimer;
  Future<void>? _playbackSessionPersistFuture;
  bool _playbackSessionPersistDirty = false;
  bool _preservePlaybackSessionOnShutdown = false;
  bool _isRestoringPlaybackSession = false;
  bool _librarySwitchPreviousPlaybackRequested = false;
  Duration _librarySwitchResumePosition = Duration.zero;
  NetworkType _lastObservedNetworkType = NetworkType.none;
  bool _retryCurrentPlaybackOnReconnect = false;
  bool _retryingCurrentPlayback = false;
  String? _pendingRetrySongId;
  bool _pendingRetryIsPreview = false;
  bool _pendingRetryAutoPlay = true;
  Timer? _recoveryTimer;
  int _recoveryAttempts = 0;
  Duration? _retryPosition;
  DateTime? _bufferingSince;
  DateTime? _healthySince;
  final List<StreamSubscription<dynamic>> _playerSubscriptions = [];
  ProviderSubscription<ServerAddress?>? _routeSubscription;
  LinuxMprisService? _linuxMprisService;
  void Function()? _removeLinuxMprisStateListener;
  WindowsSmtcService? _windowsSmtcService;
  void Function()? _removeWindowsSmtcStateListener;
  late final ArtworkFileCache _artworkFileCache = ArtworkFileCache();
  int _mediaArtworkGeneration = 0;

  // ── Handlers ──────────────────────────────────────────────────────────────
  late final FavoriteScrobbleHandler _favoriteHandler;
  late final CacheManagerHandler _cacheHandler;

  /// 动态获取最新的 API client
  SubsonicApiClient get _apiClient => _ref.read(subsonicApiClientProvider);

  /// 动态获取最新的 MusicRepository
  MusicRepository get _musicRepository =>
      _ref.read(musicRepositoryProvider) ?? MusicRepository(_apiClient);

  late final Future<void> initialized;

  PlaybackSnapshot get snapshot => _snapshotFor(state);

  PlaybackSnapshot _snapshotFor(PlayerState snapshotState) =>
      PlaybackSnapshot.fromState(
        snapshotState,
        libraryId: _currentPlaybackLibraryId,
        sourceGeneration: _sourceGeneration,
        playbackRequested: _playbackRequested,
        positionSeekRevision: _positionSeekRevision,
      );

  String? _readActiveLibraryId() {
    final libraryId = _ref.read(authStateProvider).currentLibrary?.id.trim();
    return libraryId == null || libraryId.isEmpty ? null : libraryId;
  }

  void _bindAudioHandlerCommands() {
    _audioHandler?.bindCommands(
      owner: this,
      onSkipToNext: next,
      onSkipToPrevious: previous,
      onPlay: play,
      onPause: pause,
      onStop: stop,
      onSeek: seek,
    );
  }

  PlayerNotifier(
    this._ref, {
    AudioPlayer? player,
    bool restoreSession = true,
    DateTime Function()? clock,
    PlaybackWakeGuard? wakeGuard,
  }) : _wakeGuard = wakeGuard ?? PlaybackWakeGuard(),
       _clock = clock ?? DateTime.now,
       super(PlayerState()) {
    _favoriteHandler = FavoriteScrobbleHandler(_ref);
    _cacheHandler = CacheManagerHandler(_ref);
    _initConnectivityRetryHandling();
    initialized = _init(injectedPlayer: player, restoreSession: restoreSession);
  }

  @override
  set state(PlayerState value) {
    final previous = super.state;
    super.state = value;
    if (previous.queue.length != value.queue.length &&
        previous.currentSong?.id == value.currentSong?.id &&
        _replacingSourceGeneration == null) {
      unawaited(_syncNativeLoopMode());
    }
    _schedulePersistPlaybackSession(
      immediate:
          !identical(previous.queue, value.queue) ||
          previous.currentIndex != value.currentIndex ||
          previous.isPlaying != value.isPlaying,
    );
  }

  /// 初始化播放器
  Future<void> _init({
    AudioPlayer? injectedPlayer,
    required bool restoreSession,
  }) async {
    AudioPlayer player;

    if (injectedPlayer != null) {
      player = injectedPlayer;
    } else if (_isDesktopPlatform) {
      // AudioService's notification/background session is mobile-only. Desktop
      // integrations use Linux MPRIS or Windows SMTC below.
      Logger.infoWithTag(
        'PLAYBACK',
        'audio_service_skipped platform=${defaultTargetPlatform.name}',
      );
      player = _createAudioPlayer();
    } else {
      try {
        final audioHandler = await initAudioService();
        if (!mounted) return;
        _audioHandler = audioHandler;
        player = _audioHandler!.audioPlayer;
        Logger.info('AudioService initialized');

        _bindAudioHandlerCommands();
      } catch (e) {
        Logger.warn('AudioService not available: $e');
        Logger.warnWithTag(
          'PLAYBACK',
          'background_service_unavailable type=${e.runtimeType}',
        );
        player = _createAudioPlayer();
      }
    }
    if (!mounted) {
      if (_audioHandler == null) await player.dispose();
      return;
    }
    _audioPlayer = player;
    try {
      final volume = await LocalStorage.getPlaybackVolume();
      if (!mounted) {
        if (_audioHandler == null) await player.dispose();
        return;
      }
      if (volume > 0.0001) {
        _lastAudibleVolume = volume;
      }
      state = state.copyWith(userVolume: volume, isMuted: volume <= 0.0001);
      await player.setVolume(_effectivePlaybackVolume);
    } catch (error) {
      Logger.warnWithTag('PLAYBACK', 'failed to restore volume', error);
    }

    _playerSubscriptions.add(
      player.playbackEventStream.listen(
        (event) {
          if (event.processingState == ProcessingState.completed) {
            Logger.infoWithTag(
              'PLAYBACK',
              'native_completed song=${state.currentSong?.id} '
                  'eventAgeMs=${DateTime.now().difference(event.updateTime).inMilliseconds} '
                  'sourcePositionMs=${event.updatePosition.inMilliseconds}',
            );
          }
        },
        onError: (Object error, StackTrace stack) {
          if (_replacingSourceGeneration != null) {
            return; // handled by load catch
          }
          _handlePlaybackFailure('stream_error', error);
        },
      ),
    );

    // 监听播放状态
    _playerSubscriptions.add(
      player.playingStream.listen((isPlaying) {
        _playDbg(
          'playingStream playing=$isPlaying '
          'processing=${player.processingState.name} '
          'sourcePosition=${player.position} '
          'position=${_logicalPlayerPosition(player.position)} '
          'sourceBuffered=${player.bufferedPosition} '
          'buffered=${_logicalPlayerPosition(player.bufferedPosition)} '
          'song=${state.currentSong?.id}',
        );
        if (!mounted) return;
        if (_replacingSourceGeneration == null &&
            _internalSeekPauseDepth == 0 &&
            _loadedSourceSongId != null &&
            player.processingState == ProcessingState.ready) {
          if (!isPlaying && _playbackRequested) {
            _playbackRequested = false;
            _clearCurrentPlaybackRetry(reason: 'pause');
            unawaited(_wakeGuard.setActive(false, reason: 'external_pause'));
            _audioHandler?.updateTransportIntent(false);
            Logger.infoWithTag(
              'PLAYBACK',
              'external pause song=${state.currentSong?.id}',
            );
          } else if (isPlaying) {
            _playbackRequested = true;
            _audioHandler?.updateTransportIntent(true);
            unawaited(_wakeGuard.setActive(true, reason: 'external_resume'));
          }
        }
        state = state.copyWith(isPlaying: isPlaying);
      }),
    );

    // 监听播放进度
    _playerSubscriptions.add(
      player.positionStream.listen((position) {
        if (!mounted) return;

        // A queued seek is the user's latest intent. While the next source is
        // still loading, just_audio may continue to report the previous source
        // position; do not let that stale value make the scrubber jump back.
        if (_shouldPreserveSeekPosition()) {
          return;
        }

        final logicalPosition = _logicalPlayerPosition(position);

        // 合成进度模式下，lock cache 的 positionStream 可能回传 0 或过时位置，
        // 会把 UI 进度回退。此时统一忽略，交给轮询器维护并在恢复后切回真实位置。
        final ignorePositionWhileSynthetic =
            _syntheticPositionFallbackActive &&
            _usingLockCachingSource &&
            state.position > const Duration(milliseconds: 250);
        if (ignorePositionWhileSynthetic) {
          final isStuckZero = position <= const Duration(milliseconds: 50);
          final shouldLog =
              _stagnantPositionTicks != _lastIgnoredSyntheticPositionLogTick &&
              _stagnantPositionTicks % 6 == 0;
          if (shouldLog) {
            _lastIgnoredSyntheticPositionLogTick = _stagnantPositionTicks;
            _playDbg(
              isStuckZero
                  ? 'positionStream ignored_stuck_zero '
                        'sourcePos=$position logicalPos=$logicalPosition '
                        'statePos=${state.position} '
                        'song=${state.currentSong?.id}'
                  : 'positionStream ignored_while_synthetic '
                        'sourcePos=$position logicalPos=$logicalPosition '
                        'statePos=${state.position} '
                        'song=${state.currentSong?.id}',
            );
          }
          return;
        }

        state = state.copyWith(position: logicalPosition);
      }),
    );
    _startPositionPolling(player);

    // 监听缓冲进度（仅在在线流式播放且非 LockCachingAudioSource 模式下使用）
    _playerSubscriptions.add(
      player.bufferedPositionStream.listen((buffered) {
        if (mounted && _downloadProgressSubscription == null) {
          if (_shouldPreserveSeekPosition()) return;
          // 本地文件（下载/缓存）的 bufferedPositionStream 仅反映解码缓冲窗口，
          // 不代表文件可用进度，应跳过以保持 100%。
          final source = state.playbackSource;
          if (source == PlaybackSource.downloaded ||
              source == PlaybackSource.cached) {
            return;
          }
          // 当使用 LockCachingAudioSource 时,由 downloadProgressStream 更新 bufferedPosition
          // 避免播放器解码缓冲区（seek 后会重置）覆盖实际下载进度
          state = state.copyWith(
            bufferedPosition: _logicalPlayerPosition(buffered),
          );
        }
      }),
    );
    // 监听总时长
    _playerSubscriptions.add(
      player.durationStream.listen((duration) {
        if (mounted) {
          if (duration != null && duration > Duration.zero) {
            if (_shouldPreserveSeekPosition() && _seekByReloadStream) {
              _playDbg(
                'durationStream ignored during reload seek duration=$duration '
                'song=${state.currentSong?.id}',
              );
              return;
            }
            // A timeOffset stream may expose either the remaining duration or
            // the original X-Content-Duration. The song timeline is already
            // known, so do not replace it with a source-relative duration.
            if (_sourcePositionOffset > Duration.zero &&
                state.duration > Duration.zero) {
              _loggedDurationUnavailableForSong = false;
              _playDbg(
                'durationStream kept logical duration=${state.duration} '
                'sourceDuration=$duration offset=$_sourcePositionOffset '
                'song=${state.currentSong?.id}',
              );
              return;
            }
            // 如果流能提供时长，优先使用流的时长（更准确）
            state = state.copyWith(
              duration: _sourcePositionOffset > Duration.zero
                  ? duration + _sourcePositionOffset
                  : duration,
            );
            _loggedDurationUnavailableForSong = false;
            _playDbg(
              'durationStream duration=$duration song=${state.currentSong?.id}',
            );
          } else {
            if (!_loggedDurationUnavailableForSong &&
                state.currentSong != null) {
              _loggedDurationUnavailableForSong = true;
              _playDbg(
                'durationStream unavailable duration=$duration '
                'song=${state.currentSong?.id}',
              );
            }
          }
        }
        // 如果 duration 为 null 或 0，保持使用歌曲元数据的时长
      }),
    );

    // 监听播放完成
    _playerSubscriptions.add(
      player.playerStateStream.listen((playerState) {
        if (playerState.processingState == ProcessingState.completed &&
            _androidNativeQueue != null) {
          if (player.processingState != ProcessingState.completed) return;
          // The final state may arrive before the sequence subscription.
          // Complete the actual native cursor after a suspended Dart loop.
          final sequence = _androidNativeQueue!.sequence;
          final index = player.currentIndex;
          if (index != null && index >= 0 && index < sequence.length) {
            _onAndroidNativeSequence(
              SequenceState(
                sequence,
                index,
                List.generate(sequence.length, (i) => i),
                false,
                _nativeLoopMode,
              ),
            );
          }
        }
        if (mounted && state.processingState != playerState.processingState) {
          state = state.copyWith(processingState: playerState.processingState);
        }
        if (_lastProcessingStateForDebug != playerState.processingState) {
          Logger.infoWithTag(
            'PLAYBACK',
            'state=${playerState.processingState.name} '
                'playing=${playerState.playing} song=${state.currentSong?.id} '
                'loaded=$_loadedSourceSongId session=$_playDebugSession '
                'positionMs=${_logicalPlayerPosition(player.position).inMilliseconds}',
          );
          _lastProcessingStateForDebug = playerState.processingState;
          _seekDbg(
            'playerState=${playerState.processingState.name} '
            'playing=${playerState.playing} '
            'sourcePosition=${player.position} '
            'position=${_logicalPlayerPosition(player.position)} '
            'sourceBuffered=${player.bufferedPosition} '
            'buffered=${_logicalPlayerPosition(player.bufferedPosition)} '
            'duration=${player.duration} '
            'sourceOffset=$_sourcePositionOffset '
            'pending=$_pendingSeekPosition '
            'pendingSong=$_pendingSeekSongId '
            'currentSong=${state.currentSong?.id}',
          );
        }
        if (playerState.processingState == ProcessingState.ready ||
            playerState.processingState == ProcessingState.completed) {
          if (_seekAwaitingReady && _activeSeekGeneration != null) {
            _releaseSeekAnchor(_activeSeekGeneration!);
            if (_playbackRequested && !player.playing) {
              _startPlayback(fadeIn: false);
            }
          }
          unawaited(_applyPendingSeekIfNeeded());
        }

        if (playerState.processingState != ProcessingState.completed) {
          _isHandlingCompletion = false;
          _completionHandlingSongId = null;
          _completionHandlingEntryId = null;
        }

        if (mounted &&
            playerState.processingState == ProcessingState.completed &&
            _replacingSourceGeneration == null &&
            _loadedSourceSongId == state.currentSong?.id &&
            _loadedSourceEntryId == state.currentEntryId &&
            _loadedSourceSongId != null &&
            !_retryCurrentPlaybackOnReconnect &&
            _playbackRequested &&
            !_shouldPreserveSeekPosition()) {
          final completedSongId = state.currentSong?.id;
          final completedEntryId = state.currentEntryId;
          final shouldHandle =
              completedSongId != null &&
              completedEntryId != null &&
              (!_isHandlingCompletion ||
                  _completionHandlingSongId != completedSongId ||
                  _completionHandlingEntryId != completedEntryId);
          if (shouldHandle) {
            _isHandlingCompletion = true;
            _completionHandlingSongId = completedSongId;
            _completionHandlingEntryId = completedEntryId;
            _seekDbg(
              'completed detected song=$completedSongId '
              'loop=${state.loopMode.name} shuffle=${state.shuffleEnabled} '
              'index=${state.currentIndex}/${state.queue.length - 1} '
              'hasNext=${state.hasNext}',
            );
            unawaited(_onSongCompleted(completedSongId, completedEntryId));
          }
        }
      }),
    );

    _playerSubscriptions.add(
      player.positionDiscontinuityStream.listen((event) {
        if (event.reason != PositionDiscontinuityReason.autoAdvance ||
            _nativeLoopMode != LoopMode.one ||
            _replacingSourceGeneration != null ||
            _sourcePositionOffset != Duration.zero ||
            !_playbackRequested) {
          return;
        }
        final song = state.currentSong;
        if (song == null || _loadedSourceSongId != song.id) return;
        Logger.infoWithTag(
          'PLAYBACK',
          'repeat_native song=${song.id} source=${state.playbackSource?.name}',
        );
        if (!song.isPreview) {
          unawaited(_scrobble(song.id, submission: true));
          unawaited(_scrobble(song.id, submission: false));
        }
      }),
    );
    if (restoreSession) {
      await _restorePlaybackMode();
      await _restorePlaybackSession();
    }
    if (injectedPlayer == null &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.linux) {
      unawaited(_startLinuxMprisService());
    }
    if (injectedPlayer == null &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.windows) {
      unawaited(_startWindowsSmtcService());
    }
  }

  AudioPlayer _createAudioPlayer() => AudioPlayer(
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

  Future<void> _startWindowsSmtcService() async {
    if (!mounted || _windowsSmtcService != null) return;
    final initialSnapshot = _snapshotFor(state);
    final service = WindowsSmtcService(
      commands: this,
      artworkResolver: _resolveMediaArtwork,
    );
    _windowsSmtcService = service;
    _removeWindowsSmtcStateListener = addListener((next) {
      unawaited(
        service.updateSnapshot(_snapshotFor(next)).catchError((Object error) {
          Logger.warnWithTag('SMTC', 'failed to publish state', error);
        }),
      );
    });

    try {
      await service.start(initialSnapshot);
      if (!mounted) await service.dispose();
    } catch (error) {
      Logger.warnWithTag('SMTC', 'Windows media session unavailable', error);
      if (identical(_windowsSmtcService, service)) {
        _removeWindowsSmtcStateListener?.call();
        _removeWindowsSmtcStateListener = null;
        _windowsSmtcService = null;
      }
      await service.dispose();
    }
  }

  Future<void> _startLinuxMprisService() async {
    if (!mounted || _linuxMprisService != null) return;
    final initialSnapshot = _snapshotFor(state);
    final service = LinuxMprisService(
      commands: this,
      onRaise: DesktopLifecycleService.instance.showWindow,
      onQuit: DesktopLifecycleService.instance.requestExit,
      artworkResolver: _resolveMediaArtwork,
    );
    _linuxMprisService = service;
    _removeLinuxMprisStateListener = addListener((next) {
      unawaited(
        service.updateSnapshot(_snapshotFor(next)).catchError((Object error) {
          Logger.warnWithTag('MPRIS', 'failed to publish state', error);
        }),
      );
    });

    try {
      await service.updateSnapshot(initialSnapshot);
      await service.start();
      if (!mounted) await service.dispose();
    } catch (error) {
      Logger.warnWithTag('MPRIS', 'session bus adapter unavailable', error);
      if (identical(_linuxMprisService, service)) {
        _removeLinuxMprisStateListener?.call();
        _removeLinuxMprisStateListener = null;
        _linuxMprisService = null;
      }
      await service.dispose();
    }
  }

  Future<Uri?> _resolveMediaArtwork(PlaybackSnapshot snapshot) async {
    return _artworkFileCache.resolve(
      _remoteArtworkUrl(snapshot.artworkReference),
    );
  }

  String? _remoteArtworkUrl(String? artworkReference) {
    final reference = artworkReference?.trim() ?? '';
    if (reference.isEmpty) return null;

    final directUrl = extractTrustedCoverUrl(reference) ?? reference;
    final directUri = Uri.tryParse(directUrl);
    if (directUri != null &&
        directUri.host.isNotEmpty &&
        (directUri.scheme == 'http' || directUri.scheme == 'https')) {
      return directUrl;
    }

    final coverArtId = sanitizeServerCoverArtId(reference);
    if (coverArtId == null) return null;
    return _apiClient.getCoverArtUrl(coverArtId, size: 512);
  }

  void _initConnectivityRetryHandling() {
    _routeSubscription = _ref.listen<ServerAddress?>(activeAddressProvider, (
      previous,
      next,
    ) {
      if (next?.status == ServerAddressStatus.ok &&
          (previous?.id != next?.id ||
              previous?.status != ServerAddressStatus.ok)) {
        unawaited(
          _retryCurrentPlaybackIfNeeded(
            networkType: _lastObservedNetworkType,
            previousType: _lastObservedNetworkType,
          ),
        );
      }
    });
    final connectivityMonitor = _ref.read(connectivityMonitorProvider);
    _lastObservedNetworkType = connectivityMonitor.currentNetworkType;
    _networkTypeSubscription?.cancel();
    _networkTypeSubscription = connectivityMonitor.networkTypeStream.listen(
      (networkType) {
        final previousType = _lastObservedNetworkType;
        _lastObservedNetworkType = networkType;
        Logger.infoWithTag(
          'PLAYBACK_NETWORK',
          'connectivity ${previousType.name}->${networkType.name} '
              'song=${state.currentSong?.id} requested=$_playbackRequested '
              'pendingRetry=$_retryCurrentPlaybackOnReconnect retrying=$_retryingCurrentPlayback '
              'generation=$_sourceGeneration lifecycle=${WidgetsBinding.instance.lifecycleState?.name}',
        );
        if (networkType == NetworkType.none || previousType == networkType) {
          return;
        }
        unawaited(
          _retryCurrentPlaybackIfNeeded(
            networkType: networkType,
            previousType: previousType,
          ),
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        Logger.warnWithTag(
          _playerLogTag,
          'connectivity retry listener error',
          error,
        );
      },
    );
  }

  void _handlePlaybackFailure(String reason, Object error) {
    final song = state.currentSong;
    if (!mounted ||
        song == null ||
        _loadedSourceSongId != song.id ||
        !_playbackRequested ||
        _retryCurrentPlaybackOnReconnect ||
        _retryingCurrentPlayback) {
      return;
    }
    Logger.warnWithTag(
      'PLAYBACK_RECOVERY',
      '$reason song=${song.id} session=$_playDebugSession '
          'positionMs=${state.position.inMilliseconds} '
          'state=${_audioPlayer?.processingState.name} ${playbackErrorSummary(error)}',
    );
    _capturePlaybackDiagnostics(reason);
    _scheduleCurrentPlaybackRetry(
      song: song,
      isPreview: song.isPreview,
      autoPlay: true,
      position: _shouldPreserveSeekPosition()
          ? state.position
          : _logicalPlayerPosition(_audioPlayer?.position ?? Duration.zero),
    );
  }

  void _scheduleCurrentPlaybackRetry({
    required Song song,
    required bool isPreview,
    required bool autoPlay,
    Duration? position,
  }) {
    if (!mounted || state.currentSong?.id != song.id || !_playbackRequested) {
      return;
    }
    if (_retryCurrentPlaybackOnReconnect) return;
    _retryPosition = position ?? _retryPosition ?? state.position;
    if (_recoveryAttempts >= 4) {
      _playbackRequested = false;
      _invalidateSeekRequests();
      state = state.copyWith(hasPlaybackError: true, isPlaying: false);
      unawaited(_wakeGuard.setActive(false, reason: 'recovery_exhausted'));
      _audioHandler?.updateTransportIntent(false);
      _cancelFade();
      unawaited(_audioPlayer?.pause());
      Logger.warnWithTag(
        'PLAYBACK_RECOVERY',
        'exhausted song=${song.id} attempts=$_recoveryAttempts',
      );
      NetworkErrorNotifier.show('播放恢复失败，请点击播放重试');
      return;
    }
    _retryCurrentPlaybackOnReconnect = true;
    _pendingRetrySongId = song.id;
    _pendingRetryIsPreview = isPreview;
    _pendingRetryAutoPlay = autoPlay;
    final delay = Duration(seconds: 2 << _recoveryAttempts);
    Logger.infoWithTag(
      'PLAYBACK_RECOVERY',
      'scheduled song=${song.id} attempt=${_recoveryAttempts + 1} '
          'delayMs=${delay.inMilliseconds} positionMs=${_retryPosition?.inMilliseconds}',
    );
    _recoveryTimer?.cancel();
    final scheduledAt = _clock();
    _recoveryTimer = Timer(delay, () {
      final actualMs = _clock().difference(scheduledAt).inMilliseconds;
      Logger.infoWithTag(
        'PLAYBACK_RECOVERY',
        'timer_fired song=${song.id} attempt=${_recoveryAttempts + 1} '
            'expectedMs=${delay.inMilliseconds} actualMs=$actualMs '
            'lateMs=${actualMs - delay.inMilliseconds}',
      );
      _capturePlaybackDiagnostics('retry_timer');
      unawaited(
        _retryCurrentPlaybackIfNeeded(
          networkType: _lastObservedNetworkType,
          previousType: _lastObservedNetworkType,
        ),
      );
    });
  }

  void _clearCurrentPlaybackRetry({
    String? reason,
    bool preserveRetrying = false,
  }) {
    // A resume seek or immediate play error may have scheduled recovery after
    // prepare succeeded. Do not overwrite that failure with a stale ready path.
    if (reason?.startsWith('playback_ready') == true &&
        (_retryCurrentPlaybackOnReconnect ||
            _loadedSourceSongId != state.currentSong?.id)) {
      return;
    }
    final hadRetryState =
        _retryCurrentPlaybackOnReconnect ||
        _retryingCurrentPlayback ||
        _pendingRetrySongId != null;
    if (hadRetryState && reason != null) {
      _playDbg(
        'clear reconnect retry reason=$reason '
        'song=$_pendingRetrySongId retrying=$_retryingCurrentPlayback',
      );
    }
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _retryCurrentPlaybackOnReconnect = false;
    _pendingRetrySongId = null;
    _pendingRetryIsPreview = false;
    _pendingRetryAutoPlay = true;
    if (!preserveRetrying) {
      _retryingCurrentPlayback = false;
    }
    if (reason == 'stop' ||
        reason == 'pause' ||
        (!preserveRetrying &&
            (reason == 'play_song_started' ||
                reason == 'play_preview_started'))) {
      _recoveryAttempts = 0;
      _retryPosition = null;
    }
  }

  Future<void> _retryCurrentPlaybackIfNeeded({
    required NetworkType networkType,
    required NetworkType previousType,
  }) async {
    if (!mounted ||
        !_playbackRequested ||
        !_retryCurrentPlaybackOnReconnect ||
        _retryingCurrentPlayback) {
      return;
    }

    final song = state.currentSong;
    if (song == null) {
      _clearCurrentPlaybackRetry(reason: 'no_current_song');
      return;
    }

    if (_pendingRetrySongId != null && song.id != _pendingRetrySongId) {
      _clearCurrentPlaybackRetry(reason: 'current_song_changed');
      return;
    }

    _retryingCurrentPlayback = true;
    _recoveryTimer?.cancel();
    _recoveryAttempts += 1;
    final session = _playDebugSession;
    final transport = _transportRequestGeneration;
    final resumePosition = _retryPosition ?? state.position;
    Logger.infoWithTag(
      'PLAYBACK_RECOVERY',
      'attempt=$_recoveryAttempts song=${song.id} '
          'network=${networkType.name} positionMs=${resumePosition.inMilliseconds}',
    );
    final retryAutoPlay = _pendingRetryAutoPlay;
    final retryPreview = _pendingRetryIsPreview || song.isPreview;
    _playDbg(
      'retry current playback on connectivity change '
      '$previousType->$networkType song=${song.id} preview=$retryPreview',
    );

    try {
      final available =
          retryPreview || await _refreshRoutesAndCheckAvailability();
      if (!mounted ||
          _playDebugSession != session ||
          _transportRequestGeneration != transport ||
          !_playbackRequested) {
        return;
      }
      if (!available) {
        _retryCurrentPlaybackOnReconnect = false;
        _scheduleCurrentPlaybackRetry(
          song: song,
          isPreview: retryPreview,
          autoPlay: retryAutoPlay,
          position: resumePosition,
        );
        return;
      }
      final retryQueue = state.queue.isEmpty ? [song] : state.queue;
      var retryIndex = state.currentIndex;
      final currentIndexMatchesSong =
          retryIndex >= 0 &&
          retryIndex < retryQueue.length &&
          retryQueue[retryIndex].id == song.id;
      if (!currentIndexMatchesSong) {
        final matchedIndex = retryQueue.indexWhere(
          (item) => item.id == song.id,
        );
        retryIndex = matchedIndex >= 0 ? matchedIndex : 0;
      }

      await playSong(
        song,
        queue: retryQueue,
        index: retryIndex,
        autoPlay: retryAutoPlay,
        resumePosition: resumePosition,
      );
    } catch (e) {
      Logger.warnWithTag(
        _playerLogTag,
        'reconnect retry failed for current playback',
        e,
      );
    } finally {
      _retryingCurrentPlayback = false;
    }
  }

  /// 播放单曲
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    int? index,
    bool autoPlay = true,
    Duration resumePosition = Duration.zero,
  }) async {
    unawaited(_cacheHandler.cancelPrecache());
    if (!mounted) return;
    if (!_isRestoringPlaybackSession || _currentPlaybackLibraryId == null) {
      _currentPlaybackLibraryId = _readActiveLibraryId();
    }
    _playbackRequested = autoPlay;
    unawaited(_wakeGuard.setActive(autoPlay, reason: 'song_request'));
    Logger.infoWithTag(
      'PLAYBACK',
      'request song=${song.id} autoPlay=$autoPlay resumeMs=${resumePosition.inMilliseconds}',
    );
    _audioHandler?.updateTransportIntent(autoPlay);
    final requestedSongs = queue == null || queue.isEmpty
        ? <Song>[song]
        : queue;
    final reuseExistingQueue =
        queue != null && queue.isNotEmpty && identical(queue, state.queue);
    final requestedIndex = (index ?? 0).clamp(
      0,
      requestedSongs.isEmpty ? 0 : requestedSongs.length - 1,
    );
    var nextQueue = reuseExistingQueue
        ? state.playbackQueue.selectIndex(requestedIndex)
        : PlaybackQueueState.fromSongs(
            requestedSongs,
            currentIndex: requestedIndex,
          );
    if (!reuseExistingQueue && state.shuffleEnabled) {
      nextQueue = nextQueue.enableShuffle(_random);
    }
    final targetEntryId = nextQueue.currentEntryId;
    if (targetEntryId == null) return;
    _activePlaybackEntryId = targetEntryId;
    state = state.copyWith(playbackQueue: nextQueue);
    final playQueue = nextQueue.songs;
    final playIndex = nextQueue.currentIndex;

    if (song.isPreview) {
      await _playPreviewSongInternal(
        song,
        queue: playQueue,
        index: playIndex,
        entryId: targetEntryId,
        autoPlay: autoPlay,
        resumePosition: resumePosition,
      );
      return;
    }

    final debugSession = ++_playDebugSession;
    _invalidateLoadedSource(reason: 'song_transition');
    _transportRequestGeneration += 1;
    bool isCurrentSession() =>
        _isPlaybackContextCurrent(session: debugSession, songId: song.id);
    _clearCurrentPlaybackRetry(
      reason: 'play_song_started',
      preserveRetrying: _retryingCurrentPlayback,
    );
    try {
      _seekDbg(
        'playSong start song=${song.id} title="${song.title}" '
        'suffix=${song.suffix} duration=${song.duration}s '
        'queue=${playQueue.length} index=$playIndex autoPlay=$autoPlay',
      );
      _playDbg(
        'sid=$debugSession playSong enter song=${song.id} '
        'suffix=${song.suffix} durationSec=${song.duration} '
        'queue=${playQueue.length} index=$playIndex',
      );

      // 淡出当前歌曲（如果启用了淡入淡出）
      await _fadeOut(debugSession);
      if (_playDebugSession != debugSession) return;
      if (!autoPlay) {
        _cancelFade();
        await _audioPlayer?.pause();
        if (_playDebugSession != debugSession) return;
      }

      _downloadProgressSubscription?.cancel();
      _downloadProgressSubscription = null;
      _clearPendingSeek();
      if (resumePosition > Duration.zero) {
        _pendingSeekSongId = song.id;
        _pendingSeekPosition = resumePosition;
      }
      _usingLockCachingSource = false;
      _currentStreamUrl = null;
      _invalidateLoadedSource(reason: 'play_song_started');
      _invalidateSeekRequests();
      _clearStreamContext();
      _isHandlingCompletion = false;
      _completionHandlingSongId = null;
      _completionHandlingEntryId = null;
      _lastPolledPlayerPosition = Duration.zero;
      _stagnantPositionTicks = 0;
      _lastStagnantLogTick = -1;
      _lastIgnoredSyntheticPositionLogTick = -1;
      _syntheticPositionFallbackActive = false;
      _loggedDurationUnavailableForSong = false;

      // 如果歌曲有时长信息，先预设 duration（转码流可能无法获取时长）
      final initialDuration = song.duration != null
          ? Duration(seconds: song.duration!)
          : Duration.zero;

      final activeQueue = state.playbackQueue;
      if (!activeQueue.entries.containsKey(targetEntryId)) return;
      state = state.copyWith(
        playbackQueue: activeQueue
            .updateEntrySong(targetEntryId, song)
            .selectEntry(targetEntryId),
        position: resumePosition,
        duration: initialDuration, // 使用歌曲元数据的时长
        currentBitRateKbps: 0,
      );

      // 更新通知栏媒体信息
      _updateMediaItem(song);
      _scheduleSongRemoteRefresh(song, debugSession);

      // 获取当前音质设置
      final effectiveQuality = _ref.read(effectiveQualityProvider);
      final downloadService = _ref.read(downloadServiceProvider);
      final cacheService = _ref.read(audioCacheServiceProvider);

      // Use the library identity captured with this playback request.
      final libraryId = _currentPlaybackLibraryId ?? '';

      // ---- 三级优先音源 ----

      // 1. 检查是否已下载
      final downloadedPath = await downloadService.getDownloadedPath(
        song.id,
        libraryId,
      );
      if (downloadedPath != null && fileExistsSync(downloadedPath)) {
        Logger.info('Playing from download: ${song.title}');
        _playDbg(
          'sid=$debugSession source=download setFilePath path=$downloadedPath',
        );
        final sourceReady = await _replaceLoadedSource(
          songId: song.id,
          label: 'download',
          ownsSource: () =>
              _isPlaybackContextCurrent(session: debugSession, songId: song.id),
          setSource: (player) async {
            await _setLocalAudioSource(
              player,
              downloadedPath,
              AudioQualityLevel.original,
              PlaybackSource.downloaded,
            );
          },
        );
        if (!sourceReady) return;
        _replaceDownloadProgressSubscription(null);
        _usingLockCachingSource = false;
        _currentStreamUrl = null;
        _clearStreamContext();
        await _syncPlaybackAfterSourceReady(autoPlay: autoPlay);
        if (!isCurrentSession()) return;
        await _applyPendingSeekIfNeeded();
        if (!isCurrentSession()) return;
        _seekDbg('source=download path=$downloadedPath');
        state = state.copyWith(
          currentQuality: AudioQualityLevel.original,
          playbackSource: PlaybackSource.downloaded,
          currentBitRateKbps: _resolveCurrentBitRateKbps(
            song: song,
            quality: AudioQualityLevel.original,
            source: PlaybackSource.downloaded,
          ),
          bufferedPosition: initialDuration,
        );
        _clearCurrentPlaybackRetry(reason: 'playback_ready_downloaded');
        if (autoPlay) {
          await _scrobble(song.id, submission: false);
          if (!isCurrentSession()) return;
          _preCacheNextSong();
        }
        return;
      }

      // 2. 检查是否已缓存
      final cachedPath = await cacheService.getCachedPath(
        songId: song.id,
        libraryId: libraryId,
        quality: effectiveQuality,
      );
      if (cachedPath != null && fileExistsSync(cachedPath)) {
        Logger.info('Playing from cache: ${song.title}');
        _playDbg(
          'sid=$debugSession source=cache setFilePath path=$cachedPath '
          'quality=${effectiveQuality.name}',
        );
        final sourceReady = await _replaceLoadedSource(
          songId: song.id,
          label: 'cache',
          ownsSource: () =>
              _isPlaybackContextCurrent(session: debugSession, songId: song.id),
          setSource: (player) async {
            await _setLocalAudioSource(
              player,
              cachedPath,
              effectiveQuality,
              PlaybackSource.cached,
            );
          },
        );
        if (!sourceReady) return;
        _usingLockCachingSource = false;
        _currentStreamUrl = null;
        _clearStreamContext();
        await _syncPlaybackAfterSourceReady(autoPlay: autoPlay);
        if (!isCurrentSession()) return;
        await _applyPendingSeekIfNeeded();
        if (!isCurrentSession()) return;
        _seekDbg(
          'source=cache path=$cachedPath quality=${effectiveQuality.name}',
        );
        state = state.copyWith(
          currentQuality: effectiveQuality,
          playbackSource: PlaybackSource.cached,
          currentBitRateKbps: _resolveCurrentBitRateKbps(
            song: song,
            quality: effectiveQuality,
            source: PlaybackSource.cached,
            maxBitRate: effectiveQuality.maxBitRate,
          ),
          bufferedPosition: initialDuration,
        );
        _clearCurrentPlaybackRetry(reason: 'playback_ready_cached');
        if (autoPlay) {
          await _scrobble(song.id, submission: false);
          if (!isCurrentSession()) return;
          unawaited(
            _recordMobileCacheSavedBytesForHit(
              songId: song.id,
              cacheFilePath: cachedPath,
              libraryId: libraryId,
            ),
          );
          _preCacheNextSong();
        }
        return;
      }

      // 3. 流式播放（边播边缓存）
      final String? transcodeFormat = _needsTranscoding(song.suffix);
      final int? maxBitRate;
      if (transcodeFormat != null) {
        // 需要转码时：原始音质不限制码率，其它音质使用对应 maxBitRate。
        maxBitRate = effectiveQuality == AudioQualityLevel.original
            ? null
            : (effectiveQuality.maxBitRate ?? 320);
      } else if (effectiveQuality == AudioQualityLevel.original) {
        // 原始无损 — 不传 maxBitRate
        maxBitRate = null;
      } else {
        maxBitRate = effectiveQuality.maxBitRate;
      }
      final useServerTimeOffsetSeek = shouldUseServerTimeOffsetSeek(
        requestedFormat: transcodeFormat,
        requestedMaxBitRate: maxBitRate,
        sourceFormat: song.suffix,
        sourceBitRate: song.bitRate,
      );

      final activeAddress = await _ensureActiveAddressForPlayback(
        session: debugSession,
        reason: 'stream_playback',
      );
      if (_playDebugSession != debugSession) {
        _playDbg(
          'sid=$debugSession abandoned while waiting for active address '
          '(current=$_playDebugSession)',
        );
        return;
      }
      if (activeAddress == null) {
        _scheduleCurrentPlaybackRetry(
          song: song,
          isPreview: false,
          autoPlay: autoPlay,
        );
        NetworkErrorNotifier.show('网络异常，当前无可用线路');
        return;
      }

      final streamUrl = _buildStreamUrlOrThrow(
        song.id,
        session: debugSession,
        source: 'primary_stream',
        format: transcodeFormat,
        maxBitRate: maxBitRate,
      );
      final isAppleHttpStream =
          _isApplePlatform && streamUrl.startsWith('http://');
      _playDbg(
        'sid=$debugSession stream_resolved '
        'quality=${effectiveQuality.name} transcode=${transcodeFormat ?? 'none'} '
        'maxBitRate=${maxBitRate ?? 'none'} appleHttp=$isAppleHttpStream '
        'timeOffsetSeek=$useServerTimeOffsetSeek '
        'url=${_summarizeStreamUrl(streamUrl)}',
      );

      if (transcodeFormat != null) {
        Logger.info(
          'Transcoding ${song.suffix} to $transcodeFormat for: ${song.title}',
        );
      } else if (maxBitRate != null) {
        Logger.info(
          'Playing bitrate-limited stream (${song.suffix}) '
          'maxBitRate=$maxBitRate: ${song.title}',
        );
      } else {
        Logger.info(
          'Playing original format (${song.suffix}): ${song.title} '
          '[quality=${effectiveQuality.name}]',
        );
      }

      final isLongTrack = (song.duration ?? 0) > 1200; // >20 分钟
      final shouldUseLockCaching =
          !kIsWeb &&
          libraryId.isNotEmpty &&
          transcodeFormat == null &&
          maxBitRate == null &&
          !isLongTrack;

      if (!shouldUseLockCaching) {
        final reason = <String>[
          if (kIsWeb) 'web',
          if (libraryId.isEmpty) 'no-library',
          if (transcodeFormat != null) 'transcoding',
          if (maxBitRate != null) 'bitrate-limited',
          if (isLongTrack) 'long-track',
        ].join(',');
        _seekDbg('lock_cache_disabled reason=$reason');
      }

      // 使用 LockCachingAudioSource 边播边缓存（仅非转码且非超长音轨）
      if (shouldUseLockCaching) {
        try {
          final cacheFilePath = await cacheService.getCacheFilePath(
            songId: song.id,
            libraryId: libraryId,
            quality: effectiveQuality,
          );
          // ignore: experimental_member_use
          final audioSource = LockCachingAudioSource(
            Uri.parse(streamUrl),
            cacheFile: fileForPath(cacheFilePath),
          );
          _playDbg(
            'sid=$debugSession source=lock_cache setAudioSource '
            'cachePath=$cacheFilePath',
          );
          final sourceReady = await _replaceLoadedSource(
            songId: song.id,
            label: 'lock_cache',
            ownsSource: () => _isPlaybackContextCurrent(
              session: debugSession,
              songId: song.id,
            ),
            setSource: (player) async {
              await player.setAudioSource(audioSource);
            },
          );
          if (!sourceReady) return;
          _usingLockCachingSource = true;
          _currentStreamUrl = streamUrl;
          _setStreamContext(
            songId: song.id,
            format: transcodeFormat,
            maxBitRate: maxBitRate,
            seekByReloadStream: false,
          );
          await _syncPlaybackAfterSourceReady(autoPlay: autoPlay);
          if (!isCurrentSession()) return;
          _seekDbg(
            'source=lock_cache stream quality=${effectiveQuality.name} '
            'format=${transcodeFormat ?? song.suffix} '
            'processing=${_audioPlayer?.processingState.name}',
          );
          await _applyPendingSeekIfNeeded();
          if (!isCurrentSession()) return;

          state = state.copyWith(
            currentQuality: effectiveQuality,
            playbackSource: PlaybackSource.stream,
            currentBitRateKbps: _resolveCurrentBitRateKbps(
              song: song,
              quality: effectiveQuality,
              source: PlaybackSource.stream,
              maxBitRate: maxBitRate,
            ),
          );

          // 监听下载进度：更新缓冲进度条 + 下载完成时注册缓存
          _downloadProgressSubscription?.cancel();
          final capSongId = song.id;
          final capLibraryId = libraryId;
          final capQuality = effectiveQuality;
          final capCacheFilePath = cacheFilePath;
          // ignore: experimental_member_use
          _downloadProgressSubscription = audioSource.downloadProgressStream
              .listen((progress) {
                if (mounted && state.duration > Duration.zero) {
                  final buffered = Duration(
                    milliseconds: (state.duration.inMilliseconds * progress)
                        .round(),
                  );
                  state = state.copyWith(bufferedPosition: buffered);
                }
                // 下载完成 → 注册缓存
                if (progress >= 1.0) {
                  _registerCacheFromFile(
                    capCacheFilePath,
                    capSongId,
                    capLibraryId,
                    capQuality,
                  );
                }
              });
        } catch (e) {
          // Fallback: 直接流式播放不缓存
          _playDbg(
            'sid=$debugSession source=lock_cache setAudioSource failed '
            'err=$e, fallback=setUrl',
          );
          Logger.warn('LockCachingAudioSource failed, falling back to URL', e);
          _playDbg(
            'sid=$debugSession source=direct_stream_from_lock_fallback '
            'setUrl=${_summarizeStreamUrl(streamUrl)}',
          );
          final sourceReady = await _replaceLoadedSource(
            songId: song.id,
            label: 'direct_stream_from_lock_fallback',
            ownsSource: () => _isPlaybackContextCurrent(
              session: debugSession,
              songId: song.id,
            ),
            setSource: (player) async {
              await player.setUrl(streamUrl);
            },
          );
          if (!sourceReady) return;
          _usingLockCachingSource = false;
          _currentStreamUrl = streamUrl;
          _setStreamContext(
            songId: song.id,
            format: transcodeFormat,
            maxBitRate: maxBitRate,
            seekByReloadStream: useServerTimeOffsetSeek,
          );
          await _syncPlaybackAfterSourceReady(autoPlay: autoPlay);
          if (!isCurrentSession()) return;
          _seekDbg(
            'source=direct_stream_from_lock_fallback quality=${effectiveQuality.name} '
            'format=${transcodeFormat ?? song.suffix}',
          );
          await _applyPendingSeekIfNeeded();
          if (!isCurrentSession()) return;
          state = state.copyWith(
            currentQuality: effectiveQuality,
            playbackSource: PlaybackSource.stream,
            currentBitRateKbps: _resolveCurrentBitRateKbps(
              song: song,
              quality: effectiveQuality,
              source: PlaybackSource.stream,
              maxBitRate: maxBitRate,
            ),
          );
        }
      } else {
        // 直接流式播放（Web / 无音乐库 / 转码流 / 超长音轨）
        try {
          _playDbg(
            'sid=$debugSession source=direct_stream setUrl='
            '${_summarizeStreamUrl(streamUrl)}',
          );
          final sourceReady = await _replaceLoadedSource(
            songId: song.id,
            label: 'direct_stream',
            ownsSource: () => _isPlaybackContextCurrent(
              session: debugSession,
              songId: song.id,
            ),
            setSource: (player) async {
              await player.setUrl(streamUrl);
            },
          );
          if (!sourceReady) return;
          _usingLockCachingSource = false;
          _currentStreamUrl = streamUrl;
          _setStreamContext(
            songId: song.id,
            format: transcodeFormat,
            maxBitRate: maxBitRate,
            seekByReloadStream: useServerTimeOffsetSeek,
          );
          await _syncPlaybackAfterSourceReady(autoPlay: autoPlay);
          if (!isCurrentSession()) return;
          _seekDbg(
            'source=direct_stream quality=${effectiveQuality.name} '
            'format=${transcodeFormat ?? song.suffix}',
          );
        } catch (e) {
          final canFallbackToLockCache =
              isAppleHttpStream && libraryId.isNotEmpty;
          _playDbg(
            'sid=$debugSession source=direct_stream setUrl failed err=$e '
            'canFallbackToLockCache=$canFallbackToLockCache',
          );
          if (!canFallbackToLockCache) rethrow;

          Logger.warn(
            'Direct stream failed on Apple HTTP, falling back to lock cache',
            e,
          );
          final cacheFilePath = await cacheService.getCacheFilePath(
            songId: song.id,
            libraryId: libraryId,
            quality: effectiveQuality,
          );
          // ignore: experimental_member_use
          final audioSource = LockCachingAudioSource(
            Uri.parse(streamUrl),
            cacheFile: fileForPath(cacheFilePath),
          );
          _playDbg(
            'sid=$debugSession source=lock_cache_from_direct_fallback '
            'setAudioSource cachePath=$cacheFilePath',
          );
          final sourceReady = await _replaceLoadedSource(
            songId: song.id,
            label: 'lock_cache_from_direct_fallback',
            ownsSource: () => _isPlaybackContextCurrent(
              session: debugSession,
              songId: song.id,
            ),
            setSource: (player) async {
              await player.setAudioSource(audioSource);
            },
          );
          if (!sourceReady) return;
          _usingLockCachingSource = true;
          _currentStreamUrl = streamUrl;
          _setStreamContext(
            songId: song.id,
            format: transcodeFormat,
            maxBitRate: maxBitRate,
            seekByReloadStream: useServerTimeOffsetSeek,
          );
          await _syncPlaybackAfterSourceReady(autoPlay: autoPlay);
          if (!isCurrentSession()) return;
          _seekDbg(
            'source=lock_cache_from_direct_fallback '
            'quality=${effectiveQuality.name} '
            'format=${transcodeFormat ?? song.suffix}',
          );
        }

        await _applyPendingSeekIfNeeded();
        if (!isCurrentSession()) return;
        state = state.copyWith(
          currentQuality: effectiveQuality,
          playbackSource: PlaybackSource.stream,
          currentBitRateKbps: _resolveCurrentBitRateKbps(
            song: song,
            quality: effectiveQuality,
            source: PlaybackSource.stream,
            maxBitRate: maxBitRate,
          ),
        );
      }

      if (!isCurrentSession()) return;
      _clearCurrentPlaybackRetry(reason: 'playback_ready_stream');

      // 上报"正在播放"
      if (autoPlay) {
        await _scrobble(song.id, submission: false);
        if (!isCurrentSession()) return;
      }

      Logger.info('Playing: ${song.title}');
      _seekDbg(
        'playSong ready song=${song.id} currentPos=${_audioPlayer?.position} '
        'duration=${state.duration}',
      );
      _playDbg(
        'sid=$debugSession playSong ready '
        'playerPos=${_audioPlayer?.position} '
        'buffered=${_audioPlayer?.bufferedPosition} '
        'duration=${_audioPlayer?.duration} '
        'usingLock=$_usingLockCachingSource '
        'stream=${_summarizeStreamUrl(_currentStreamUrl)}',
      );

      // 预缓存下一首
      if (autoPlay) {
        _preCacheNextSong();
      }
    } catch (e) {
      Logger.error('Failed to play song', e);
      _seekDbg('playSong failed song=${song.id} err=$e');

      // 如果在重试前用户已切歌（新的 playSong 被调用），放弃本次重试
      if (_playDebugSession != debugSession) {
        _playDbg(
          'sid=$debugSession abandoned (current=$_playDebugSession), '
          'skip transcoding retry',
        );
        return;
      }

      final hasAvailableRoute = await _refreshRoutesAndCheckAvailability();
      if (!isCurrentSession()) return;
      if (!hasAvailableRoute) {
        _scheduleCurrentPlaybackRetry(
          song: song,
          isPreview: false,
          autoPlay: autoPlay,
        );
        NetworkErrorNotifier.show('网络异常，当前无可用线路');
        return;
      }

      // 路由刷新后再次检查会话
      if (_playDebugSession != debugSession) {
        _playDbg(
          'sid=$debugSession abandoned after route refresh '
          '(current=$_playDebugSession)',
        );
        return;
      }

      // 如果播放失败且没有转码过，尝试转码播放
      if (_needsTranscoding(song.suffix) == null) {
        Logger.info('Original format failed, retrying with MP3 transcoding');
        await _playWithTranscoding(
          song,
          queue: queue,
          index: index,
          debugSession: debugSession,
          autoPlay: autoPlay,
        );
      } else {
        _scheduleCurrentPlaybackRetry(
          song: song,
          isPreview: false,
          autoPlay: autoPlay,
        );
      }
    }
  }

  /// 使用转码方式播放（降级方案）
  Future<void> _playWithTranscoding(
    Song song, {
    List<Song>? queue,
    int? index,
    int? debugSession,
    bool autoPlay = true,
  }) async {
    // 会话已被更新的 playSong 取代，放弃本次转码重试
    final sid = debugSession ?? _playDebugSession;
    bool isCurrentSession() =>
        _isPlaybackContextCurrent(session: sid, songId: song.id);
    if (debugSession != null && _playDebugSession != debugSession) {
      _playDbg(
        'sid=$sid transcoding retry abandoned '
        '(current=$_playDebugSession)',
      );
      return;
    }

    try {
      final authState = _ref.read(authStateProvider);
      final libraryId = authState.currentLibrary?.id ?? '';
      final cacheService = _ref.read(audioCacheServiceProvider);
      final streamUrl = _buildStreamUrlOrThrow(
        song.id,
        session: sid,
        source: 'transcoding_retry',
        format: 'mp3', // 转码为 MP3
        maxBitRate: 320,
      );
      final useServerTimeOffsetSeek = shouldUseServerTimeOffsetSeek(
        requestedFormat: 'mp3',
        requestedMaxBitRate: 320,
        sourceFormat: song.suffix,
        sourceBitRate: song.bitRate,
      );
      final isAppleHttpStream =
          _isApplePlatform && streamUrl.startsWith('http://');

      Logger.info('Retrying with MP3 transcoding: ${song.title}');
      _playDbg(
        'sid=${debugSession ?? _playDebugSession} transcoding retry '
        'song=${song.id} appleHttp=$isAppleHttpStream '
        'url=${_summarizeStreamUrl(streamUrl)}',
      );

      try {
        _playDbg(
          'sid=${debugSession ?? _playDebugSession} '
          'source=direct_stream_transcoding setUrl='
          '${_summarizeStreamUrl(streamUrl)}',
        );
        // 在实际设置音源前再次检查会话
        if (debugSession != null && _playDebugSession != debugSession) {
          _playDbg(
            'sid=$sid transcoding setUrl abandoned '
            '(current=$_playDebugSession)',
          );
          return;
        }
        final sourceReady = await _replaceLoadedSource(
          songId: song.id,
          label: 'direct_stream_transcoding',
          ownsSource: () =>
              _isPlaybackContextCurrent(session: sid, songId: song.id),
          setSource: (player) async {
            await player.setUrl(streamUrl);
          },
        );
        if (!sourceReady) return;
        _usingLockCachingSource = false;
        _currentStreamUrl = streamUrl;
        _setStreamContext(
          songId: song.id,
          format: 'mp3',
          maxBitRate: 320,
          seekByReloadStream: useServerTimeOffsetSeek,
        );
        await _syncPlaybackAfterSourceReady(autoPlay: autoPlay);
        if (!isCurrentSession()) return;
        _seekDbg('source=direct_stream_transcoding mp3 song=${song.id}');
      } catch (e) {
        final canFallbackToLockCache =
            isAppleHttpStream && libraryId.isNotEmpty;
        _playDbg(
          'sid=${debugSession ?? _playDebugSession} '
          'source=direct_stream_transcoding setUrl failed err=$e '
          'canFallbackToLockCache=$canFallbackToLockCache',
        );
        if (!canFallbackToLockCache) rethrow;

        Logger.warn(
          'Direct transcoding stream failed on Apple HTTP, retrying lock cache',
          e,
        );
        final cacheFilePath = await cacheService.getCacheFilePath(
          songId: song.id,
          libraryId: libraryId,
          quality: AudioQualityLevel.high,
        );
        // ignore: experimental_member_use
        final audioSource = LockCachingAudioSource(
          Uri.parse(streamUrl),
          cacheFile: fileForPath(cacheFilePath),
        );
        _playDbg(
          'sid=${debugSession ?? _playDebugSession} '
          'source=lock_cache_transcoding setAudioSource '
          'cachePath=$cacheFilePath',
        );
        final sourceReady = await _replaceLoadedSource(
          songId: song.id,
          label: 'lock_cache_transcoding',
          ownsSource: () =>
              _isPlaybackContextCurrent(session: sid, songId: song.id),
          setSource: (player) async {
            await player.setAudioSource(audioSource);
          },
        );
        if (!sourceReady) return;
        _usingLockCachingSource = true;
        _currentStreamUrl = streamUrl;
        _setStreamContext(
          songId: song.id,
          format: 'mp3',
          maxBitRate: 320,
          seekByReloadStream: useServerTimeOffsetSeek,
        );
        await _syncPlaybackAfterSourceReady(autoPlay: autoPlay);
        if (!isCurrentSession()) return;
        _seekDbg('source=lock_cache_transcoding mp3 song=${song.id}');
      }

      // 转码设置音源完成后再次检查会话
      if (debugSession != null && _playDebugSession != debugSession) {
        _playDbg(
          'sid=$sid transcoding post-setup abandoned '
          '(current=$_playDebugSession)',
        );
        return;
      }
      await _applyPendingSeekIfNeeded();
      if (!isCurrentSession()) return;
      final effectiveQuality = _ref.read(effectiveQualityProvider);
      state = state.copyWith(
        currentQuality: effectiveQuality,
        playbackSource: PlaybackSource.stream,
        currentBitRateKbps: _resolveCurrentBitRateKbps(
          song: song,
          quality: effectiveQuality,
          source: PlaybackSource.stream,
          maxBitRate: 320,
        ),
      );
      _clearCurrentPlaybackRetry(reason: 'playback_ready_transcoding');

      // 上报"正在播放"
      if (autoPlay) {
        await _scrobble(song.id, submission: false);
        if (!isCurrentSession()) return;
      }
    } catch (e) {
      Logger.error('Failed to play song even with transcoding', e);
      final hasAvailableRoute = await _refreshRoutesAndCheckAvailability();
      if (debugSession != null && _playDebugSession != debugSession) {
        _playDbg(
          'sid=$sid transcoding retry abandoned after route refresh '
          '(current=$_playDebugSession)',
        );
        return;
      }
      _scheduleCurrentPlaybackRetry(
        song: song,
        isPreview: false,
        autoPlay: autoPlay,
      );
      if (!hasAvailableRoute) NetworkErrorNotifier.show('网络异常，当前无可用线路');
    }
  }

  /// 判断格式是否需要强制转码
  /// 返回 null 表示直接使用原始格式，返回格式字符串表示需要转码
  String? _needsTranscoding(String? suffix) {
    if (suffix == null) return null;

    final lowerSuffix = suffix.toLowerCase();

    // macOS/iOS 原生支持 m4a/alac（AVFoundation/CoreAudio），无需转码
    // 所有平台都不支持的格式
    const universallyUnsupported = [
      'ape', // Monkey's Audio
      'wv', // WavPack
      'tta', // True Audio
      'dff', // DSD
      'dsf', // DSD
      'tak', // TAK
    ];

    if (universallyUnsupported.contains(lowerSuffix)) {
      return 'mp3';
    }

    // Android 上 m4a/alac 支持不完整，需要转码
    if (!_isApplePlatform) {
      const androidUnsupported = [
        'm4a', // 可能包含 ALAC 编码，Android 支持不完整
        'alac', // Apple Lossless
      ];
      if (androidUnsupported.contains(lowerSuffix)) {
        return 'mp3';
      }
    }

    // 其他格式优先尝试原始格式播放
    // 支持的格式包括：mp3, aac, flac, ogg, opus, wav 等
    return null;
  }

  int _normalizeBitRateKbps(int? bitRate) {
    if (bitRate == null || bitRate <= 0) return 0;
    // 兼容个别场景可能传入 bps（例如 320000）。
    if (bitRate >= 10000) return bitRate ~/ 1000;
    return bitRate;
  }

  int _parseBitRateFromText(String? text) {
    if (text == null) return 0;
    final match = RegExp(
      r'(\d{2,4})\s*kbps',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return 0;
    return int.tryParse(match.group(1) ?? '') ?? 0;
  }

  int _resolveCurrentBitRateKbps({
    required Song song,
    required AudioQualityLevel quality,
    required PlaybackSource source,
    int? maxBitRate,
  }) {
    final songBitRate = _normalizeBitRateKbps(song.bitRate);
    if (song.isPreview) {
      if (songBitRate > 0) return songBitRate;
      return _parseBitRateFromText(song.previewQualityLabel);
    }

    switch (source) {
      case PlaybackSource.downloaded:
        return songBitRate;
      case PlaybackSource.cached:
        if (quality != AudioQualityLevel.original &&
            quality.maxBitRate != null) {
          return quality.maxBitRate!;
        }
        return songBitRate;
      case PlaybackSource.stream:
        if (maxBitRate != null && maxBitRate > 0) return maxBitRate;
        if (quality != AudioQualityLevel.original &&
            quality.maxBitRate != null) {
          return quality.maxBitRate!;
        }
        return songBitRate;
    }
  }

  void _scheduleSongRemoteRefresh(Song song, int session) {
    unawaited(() async {
      final activeAddress = await _ensureActiveAddressForPlayback(
        session: session,
        reason: 'song_remote_refresh',
        logFailure: false,
      );
      if (activeAddress == null ||
          !mounted ||
          _playDebugSession != session ||
          state.currentSong?.id != song.id) {
        return;
      }
      _updateMediaItem(song);
      await _enrichSongMetadata(song.id, session);
    }());
  }

  ServerAddress? _syncImmediateActiveAddress({
    required int session,
    required String reason,
  }) {
    final pool = _ref.read(addressPoolProvider);
    final active = pool.activeAddress ?? _ref.read(activeAddressProvider);
    if (active == null) return null;

    final dio = _apiClient.dio;
    if (dio.options.baseUrl != active.url) {
      dio.options.baseUrl = active.url;
      Logger.infoWithTag('API', 'switched base URL to: ${active.url}');
    }
    _playDbg(
      'sid=$session active_address_ready '
      'reason=$reason label=${active.label} url=${active.url}',
    );
    return active;
  }

  Future<ServerAddress?> _ensureActiveAddressForPlayback({
    required int session,
    required String reason,
    bool logFailure = true,
  }) async {
    final immediate = _syncImmediateActiveAddress(
      session: session,
      reason: reason,
    );
    if (immediate != null) return immediate;

    _playDbg('sid=$session active_address_wait start reason=$reason');
    try {
      final ensured = await _ref.read(ensureActiveAddressProvider.future);
      final dio = _apiClient.dio;
      if (dio.options.baseUrl != ensured.url) {
        dio.options.baseUrl = ensured.url;
        Logger.infoWithTag('API', 'switched base URL to: ${ensured.url}');
      }
      _playDbg(
        'sid=$session active_address_ready '
        'reason=$reason label=${ensured.label} url=${ensured.url}',
      );
      return ensured;
    } catch (e) {
      if (logFailure) {
        Logger.warnWithTag(
          _playerLogTag,
          'failed to ensure active address for $reason',
          e,
        );
      }
      _playDbg(
        'sid=$session active_address_wait failed '
        'reason=$reason err=$e',
      );
      return null;
    }
  }

  String _buildStreamUrlOrThrow(
    String songId, {
    required int session,
    required String source,
    int? maxBitRate,
    String? format,
    int? timeOffset,
  }) {
    final streamUrl = _apiClient.getStreamUrl(
      songId,
      maxBitRate: maxBitRate,
      format: format,
      timeOffset: timeOffset,
    );
    if (streamUrl.isEmpty) {
      final baseUrl = _apiClient.dio.options.baseUrl;
      _playDbg(
        'sid=$session $source stream_url_empty '
        'baseUrl=${baseUrl.isEmpty ? 'none' : baseUrl}',
      );
      throw StateError('No active server address available for stream URL');
    }
    return streamUrl;
  }

  /// 更新通知栏媒体信息
  void _updateMediaItem(Song song) {
    final handler = _audioHandler;
    if (handler == null) return;

    final artworkReference = song.artworkReference;
    final artworkUrl = _remoteArtworkUrl(artworkReference);
    final generation = ++_mediaArtworkGeneration;
    final session = _playDebugSession;
    final entryId = state.currentEntryId;
    final durationOverride = state.currentSong?.id == song.id
        ? state.duration
        : null;

    // Publish track identity immediately. The OS then clears the previous
    // song's thumbnail while the shared cache resolves the new local file.
    unawaited(
      handler.updateMediaItem(
        buildAudioMediaItem(
          PlaybackMetadata.fromSong(song, durationOverride: durationOverride),
        ),
      ),
    );
    if (artworkUrl == null) return;

    unawaited(
      _publishCachedMediaArtwork(
        song: song,
        artworkReference: artworkReference,
        artworkUrl: artworkUrl,
        generation: generation,
        session: session,
        entryId: entryId,
      ),
    );
  }

  Future<void> _publishCachedMediaArtwork({
    required Song song,
    required String? artworkReference,
    required String artworkUrl,
    required int generation,
    required int session,
    required String? entryId,
  }) async {
    final artworkUri = await _artworkFileCache.resolve(artworkUrl);
    if (artworkUri == null ||
        !mounted ||
        generation != _mediaArtworkGeneration ||
        session != _playDebugSession ||
        state.currentSong?.id != song.id ||
        state.currentEntryId != entryId ||
        state.currentSong?.artworkReference != artworkReference) {
      return;
    }

    final handler = _audioHandler;
    if (handler == null) return;
    final durationOverride = state.currentSong?.id == song.id
        ? state.duration
        : null;
    await handler.updateMediaItem(
      buildAudioMediaItem(
        PlaybackMetadata.fromSong(song, durationOverride: durationOverride),
        artworkUri: artworkUri,
      ),
    );
  }

  /// 异步补充歌曲元数据（格式/码率/位深/采样率/声道数），不阻塞播放流程。
  Future<void> _enrichSongMetadata(String songId, int session) async {
    try {
      final fullSong = await _musicRepository.getSong(songId);
      if (fullSong == null) return;
      // 会话已切换 → 丢弃
      if (!mounted || _playDebugSession != session) return;
      final current = state.currentSong;
      if (current == null || current.id != songId) return;
      // 仅在缺失时补充
      final needsUpdate =
          current.suffix == null ||
          current.bitRate == null ||
          current.bitDepth == null ||
          current.samplingRate == null ||
          current.channelCount == null;
      if (!needsUpdate) return;
      final enriched = current.copyWith(
        suffix: current.suffix ?? fullSong.suffix,
        bitRate: current.bitRate ?? fullSong.bitRate,
        bitDepth: current.bitDepth ?? fullSong.bitDepth,
        samplingRate: current.samplingRate ?? fullSong.samplingRate,
        channelCount: current.channelCount ?? fullSong.channelCount,
      );
      if (mounted && state.currentSong?.id == songId) {
        state = state.copyWith(currentSong: enriched);
        // 同步更新队列中的歌曲对象
        final idx = state.currentIndex;
        if (idx >= 0 &&
            idx < state.queue.length &&
            state.queue[idx].id == songId) {
          final updatedQueue = List<Song>.from(state.queue);
          updatedQueue[idx] = enriched;
          state = state.copyWith(queue: updatedQueue);
        }
        if (_currentStreamSongId == songId &&
            _sourcePositionOffset == Duration.zero) {
          final useServerTimeOffsetSeek = shouldUseServerTimeOffsetSeek(
            requestedFormat: _currentStreamFormat,
            requestedMaxBitRate: _currentStreamMaxBitRate,
            sourceFormat: enriched.suffix,
            sourceBitRate: enriched.bitRate,
          );
          if (useServerTimeOffsetSeek != _seekByReloadStream) {
            _seekByReloadStream = useServerTimeOffsetSeek;
            _seekDbg(
              'updated timeOffset seek after metadata refresh '
              'song=$songId bitRate=${enriched.bitRate} '
              'maxBitRate=$_currentStreamMaxBitRate '
              'enabled=$useServerTimeOffsetSeek',
            );
          }
        }
      }
    } catch (e) {
      Logger.debug('Failed to enrich song metadata for $songId: $e');
    }
  }

  /// 启动播放但不阻塞当前流程。
  /// just_audio 的 play() Future 会在暂停/结束时才完成，不能在切歌流程里 await。
  void _startPlayback({bool fadeIn = true}) {
    final player = _audioPlayer;
    if (player == null || !_playbackRequested) return;
    final session = _playDebugSession;
    unawaited(_wakeGuard.setActive(true, reason: 'play'));
    unawaited(
      player.play().catchError((Object error) {
        if (mounted && session == _playDebugSession) {
          _handlePlaybackFailure('play_error', error);
        }
      }),
    );
    if (fadeIn) {
      _fadeIn();
    }
  }

  Future<void> _syncPlaybackAfterSourceReady({required bool autoPlay}) async {
    final session = _playDebugSession;
    await _applyPendingSeekIfNeeded();
    await _syncNativeLoopMode();
    if (!mounted ||
        session != _playDebugSession ||
        _retryCurrentPlaybackOnReconnect ||
        _loadedSourceSongId != state.currentSong?.id) {
      return;
    }
    if (_playbackRequested) {
      _startPlayback();
      return;
    }

    _cancelFade();
    await _audioPlayer?.pause();
    if (mounted && state.isPlaying) {
      state = state.copyWith(isPlaying: false);
    }
  }

  // ---------------------------------------------------------------------------
  // 淡入淡出
  // ---------------------------------------------------------------------------

  double get _effectivePlaybackVolume =>
      state.isMuted ? 0 : state.userVolume * _fadeGain;

  void _applyEffectivePlaybackVolume() {
    final player = _audioPlayer;
    if (player == null) return;
    unawaited(
      player.setVolume(_effectivePlaybackVolume).catchError((Object error) {
        Logger.warnWithTag('PLAYBACK', 'failed to apply volume', error);
      }),
    );
  }

  /// Sets the persistent user volume independently from crossfade gain.
  @override
  Future<void> setUserVolume(double value) async {
    final volume = value.clamp(0.0, 1.0).toDouble();
    final muted = volume <= 0.0001;
    if ((state.userVolume - volume).abs() < 0.0001 && state.isMuted == muted) {
      return;
    }
    if (!muted) {
      _lastAudibleVolume = volume;
    }
    state = state.copyWith(userVolume: volume, isMuted: muted);
    _applyEffectivePlaybackVolume();
    _playbackVolumePersistTimer?.cancel();
    _playbackVolumePersistTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(LocalStorage.setPlaybackVolume(volume));
    });
  }

  @override
  Future<void> setMuted(bool muted) async {
    if (!muted && state.userVolume <= 0.0001) {
      await setUserVolume(_lastAudibleVolume);
      return;
    }
    if (state.isMuted == muted) return;
    state = state.copyWith(isMuted: muted);
    _applyEffectivePlaybackVolume();
  }

  Future<void> toggleMuted() => setMuted(!state.isMuted);

  /// 取消正在进行的淡入淡出动画并恢复用户设定音量。
  void _cancelFade() {
    _fadeTimer?.cancel();
    _fadeTimer = null;
    final completer = _fadeCompleter;
    _fadeCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
    _fadeGain = 1;
    _applyEffectivePlaybackVolume();
  }

  /// 淡出当前正在播放的歌曲。
  /// 如果用户未启用淡入淡出或当前未在播放，则立即返回。
  Future<void> _fadeOut(int session) async {
    _cancelFade();
    final durationMs = _ref.read(crossfadeDurationMsProvider);
    if (durationMs <= 0) return;
    final player = _audioPlayer;
    if (player == null ||
        !player.playing ||
        player.processingState == ProcessingState.completed) {
      return;
    }

    // 淡出只使用一半时长，另一半留给淡入
    final fadeMs = durationMs ~/ 2;
    const stepMs = 20;
    final steps = (fadeMs / stepMs).ceil().clamp(1, 500);
    final volumeStep = 1.0 / steps;
    var currentGain = 1.0;
    _fadeGain = currentGain;

    _playDbg('sid=$session fadeOut start durationMs=$fadeMs steps=$steps');

    final completer = Completer<void>();
    _fadeCompleter = completer;
    _fadeTimer = Timer.periodic(const Duration(milliseconds: stepMs), (timer) {
      // 会话已变（用户快速切歌）→ 立即中止
      if (_playDebugSession != session) {
        timer.cancel();
        if (identical(_fadeTimer, timer)) _fadeTimer = null;
        if (identical(_fadeCompleter, completer)) {
          _fadeCompleter = null;
        }
        if (!completer.isCompleted) completer.complete();
        return;
      }
      currentGain = (currentGain - volumeStep).clamp(0.0, 1.0);
      _fadeGain = currentGain;
      _applyEffectivePlaybackVolume();
      if (currentGain <= 0.0) {
        timer.cancel();
        _fadeTimer = null;
        if (identical(_fadeCompleter, completer)) {
          _fadeCompleter = null;
        }
        _playDbg('sid=$session fadeOut complete');
        if (!completer.isCompleted) completer.complete();
      }
    });

    return completer.future;
  }

  /// 淡入新歌曲：仅调整 fade gain，不覆盖用户音量。
  void _fadeIn() {
    _cancelFade();
    final durationMs = _ref.read(crossfadeDurationMsProvider);
    if (durationMs <= 0) {
      _fadeGain = 1;
      _applyEffectivePlaybackVolume();
      return;
    }
    final player = _audioPlayer;
    if (player == null) return;

    // 淡入使用另一半时长
    final fadeMs = durationMs ~/ 2;
    const stepMs = 20;
    final steps = (fadeMs / stepMs).ceil().clamp(1, 500);
    final volumeStep = 1.0 / steps;
    var currentGain = 0.0;
    _fadeGain = currentGain;
    _applyEffectivePlaybackVolume();

    final session = _playDebugSession;
    _playDbg('sid=$session fadeIn start durationMs=$fadeMs steps=$steps');

    _fadeTimer = Timer.periodic(const Duration(milliseconds: stepMs), (timer) {
      if (_playDebugSession != session) {
        timer.cancel();
        if (identical(_fadeTimer, timer)) _fadeTimer = null;
        return;
      }
      currentGain = (currentGain + volumeStep).clamp(0.0, 1.0);
      _fadeGain = currentGain;
      _applyEffectivePlaybackVolume();
      if (currentGain >= 1.0) {
        timer.cancel();
        _fadeTimer = null;
        _playDbg('sid=$session fadeIn complete');
      }
    });
  }

  /// 播放队列
  @override
  Future<void> playQueue(List<Song> songs, {int startIndex = 0}) async {
    if (songs.isEmpty) return;
    final safeStartIndex = startIndex.clamp(0, songs.length - 1).toInt();
    await playSong(songs[safeStartIndex], queue: songs, index: safeStartIndex);
  }

  /// 播放试听歌曲。
  @override
  Future<void> playPreviewSong(Song song) async {
    await playSong(song);
  }

  Future<void> _playPreviewSongInternal(
    Song song, {
    required List<Song> queue,
    required int index,
    required String entryId,
    bool autoPlay = true,
    Duration resumePosition = Duration.zero,
  }) async {
    final debugSession = ++_playDebugSession;
    _invalidateLoadedSource(reason: 'song_transition');
    _transportRequestGeneration += 1;
    bool isCurrentSession() =>
        _isPlaybackContextCurrent(session: debugSession, songId: song.id);
    _clearCurrentPlaybackRetry(
      reason: 'play_preview_started',
      preserveRetrying: _retryingCurrentPlayback,
    );

    late final Song resolvedSong;
    try {
      resolvedSong = await _resolvePreviewSongForPlayback(song);
    } catch (e) {
      Logger.error('Failed to resolve preview song', e);
      if (_playDebugSession == debugSession) {
        await pause();
        NetworkErrorNotifier.show('试听链接解析失败');
      }
      return;
    }
    if (_playDebugSession != debugSession) return;

    final streamUrl = resolvedSong.previewStreamUrl?.trim() ?? '';
    final previewHeaders = resolvedSong.previewRequestHeaders;
    if (!state.playbackQueue.entries.containsKey(entryId)) return;

    if (!autoPlay) {
      _cancelFade();
      await _audioPlayer?.pause();
      if (_playDebugSession != debugSession) return;
    }

    _downloadProgressSubscription?.cancel();
    _downloadProgressSubscription = null;
    _clearPendingSeek();
    if (resumePosition > Duration.zero) {
      _pendingSeekSongId = song.id;
      _pendingSeekPosition = resumePosition;
    }
    _usingLockCachingSource = false;
    _currentStreamUrl = null;
    _invalidateLoadedSource(reason: 'play_preview_started');
    _invalidateSeekRequests();
    _clearStreamContext();
    _isHandlingCompletion = false;
    _completionHandlingSongId = null;
    _completionHandlingEntryId = null;
    _lastPolledPlayerPosition = Duration.zero;
    _stagnantPositionTicks = 0;
    _lastStagnantLogTick = -1;
    _lastIgnoredSyntheticPositionLogTick = -1;
    _syntheticPositionFallbackActive = false;
    _loggedDurationUnavailableForSong = false;

    final initialDuration = resolvedSong.duration != null
        ? Duration(seconds: resolvedSong.duration!)
        : Duration.zero;

    final latestQueue = state.playbackQueue;
    if (!latestQueue.entries.containsKey(entryId)) return;
    state = state.copyWith(
      playbackQueue: latestQueue
          .updateEntrySong(entryId, resolvedSong)
          .selectEntry(entryId),
      position: resumePosition,
      duration: initialDuration,
      currentBitRateKbps: 0,
    );

    _updateMediaItem(resolvedSong);

    try {
      _playDbg(
        'sid=$debugSession preview setUrl song=${resolvedSong.id} '
        'queue=${state.queue.length} index=${state.currentIndex} '
        'url=${_summarizeStreamUrl(streamUrl)} '
        'headers=${previewHeaders.keys.join(",")}',
      );
      final sourceReady = await _replaceLoadedSource(
        songId: resolvedSong.id,
        label: 'preview',
        ownsSource: () => _isPlaybackContextCurrent(
          session: debugSession,
          songId: resolvedSong.id,
        ),
        setSource: (player) async {
          await player.setUrl(streamUrl, headers: previewHeaders);
        },
      );
      if (!sourceReady) return;
      _usingLockCachingSource = false;
      _currentStreamUrl = streamUrl;
      _setStreamContext(
        songId: resolvedSong.id,
        format: null,
        maxBitRate: null,
        seekByReloadStream: false,
      );
      await _syncPlaybackAfterSourceReady(autoPlay: autoPlay);
      if (!isCurrentSession()) return;
      await _applyPendingSeekIfNeeded();
      if (!isCurrentSession()) return;
      state = state.copyWith(
        currentQuality: AudioQualityLevel.original,
        playbackSource: PlaybackSource.stream,
        currentBitRateKbps: _resolveCurrentBitRateKbps(
          song: resolvedSong,
          quality: AudioQualityLevel.original,
          source: PlaybackSource.stream,
          maxBitRate: _normalizeBitRateKbps(resolvedSong.bitRate),
        ),
      );
      _clearCurrentPlaybackRetry(reason: 'playback_ready_preview');
    } catch (e) {
      Logger.error('Failed to play preview song', e);
      if (_playDebugSession != debugSession) {
        _playDbg(
          'sid=$debugSession preview abandoned after failure '
          '(current=$_playDebugSession)',
        );
        return;
      }
      final hasAvailableRoute = await _refreshRoutesAndCheckAvailability();
      if (_playDebugSession != debugSession) {
        _playDbg(
          'sid=$debugSession preview abandoned after route refresh '
          '(current=$_playDebugSession)',
        );
        return;
      }
      if (!hasAvailableRoute) {
        _scheduleCurrentPlaybackRetry(
          song: resolvedSong,
          isPreview: true,
          autoPlay: autoPlay,
        );
        NetworkErrorNotifier.show('试听播放失败，当前无可用线路');
        return;
      }
      _scheduleCurrentPlaybackRetry(
        song: resolvedSong,
        isPreview: true,
        autoPlay: autoPlay,
      );
      NetworkErrorNotifier.show('试听播放失败');
    }
  }

  /// 试听歌曲可以先作为普通队列项加入；真正轮到播放时再补齐临时 URL。
  Future<Song> _resolvePreviewSongForPlayback(Song song) async {
    final existingUrl = song.previewStreamUrl?.trim() ?? '';
    if (existingUrl.isNotEmpty) return song;

    final source = song.previewSource?.trim() ?? '';
    final trackId = song.previewTrackId?.trim() ?? '';
    if (source.isEmpty || trackId.isEmpty) {
      throw StateError('试听歌曲缺少 source/trackId');
    }

    final client = _ref.read(gdMusicApiClientProvider);
    final resolved = await client.resolveSongUrl(
      source: source,
      trackId: trackId,
    );

    var coverUrl = song.previewCoverUrl?.trim();
    final picId = song.previewPicId?.trim() ?? '';
    if ((coverUrl == null || coverUrl.isEmpty) && picId.isNotEmpty) {
      coverUrl = await client.resolveCoverUrl(source: source, picId: picId);
    }

    return song.copyWith(
      previewStreamUrl: resolved.url,
      previewCoverUrl: coverUrl,
      previewQualityLabel: resolved.qualityLabel,
      previewRequestHeaders: resolved.requiredHeaders,
      bitRate: resolved.bitRateKbps,
      suffix: resolved.suffix ?? song.suffix,
    );
  }

  /// 播放/暂停
  @override
  Future<void> togglePlayPause() async {
    if (state.isLoading) return;
    if (state.isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  /// 暂停（带淡出）
  @override
  Future<void> pause() async {
    Logger.infoWithTag('PLAYBACK', 'pause song=${state.currentSong?.id}');
    _playbackRequested = false;
    _clearCurrentPlaybackRetry(reason: 'pause');
    unawaited(_cacheHandler.cancelPrecache());
    _audioHandler?.updateTransportIntent(false);
    final playbackSession = _playDebugSession;
    final transportRequest = ++_transportRequestGeneration;
    final durationMs = _ref.read(crossfadeDurationMsProvider);
    if (durationMs > 0 && state.isPlaying) {
      await _fadeOutForPause();
      if (_playDebugSession != playbackSession ||
          _transportRequestGeneration != transportRequest) {
        return;
      }
    }
    await _audioPlayer?.pause();
    if (_playDebugSession == playbackSession &&
        _transportRequestGeneration == transportRequest) {
      await _wakeGuard.setActive(false, reason: 'pause');
    }
    if (_playDebugSession != playbackSession ||
        _transportRequestGeneration != transportRequest) {
      return;
    }
  }

  /// 播放（从暂停恢复，不使用淡入——淡入淡出仅用于切歌）
  @override
  Future<void> play() {
    Logger.infoWithTag('PLAYBACK', 'resume song=${state.currentSong?.id}');
    _playbackRequested = true;
    _audioHandler?.updateTransportIntent(true);
    _transportRequestGeneration += 1;
    _cancelFade(); // 取消任何进行中的淡入淡出，恢复音量到 1.0
    // A transport resume during a seek/source replacement updates intent only.
    // Starting playSong here would invalidate the seek and reload from a stale
    // (often zero) position before the replacement's timeOffset is installed.
    if (_replacingSourceGeneration != null || state.isSeeking) {
      return Future<void>.value();
    }
    state = state.copyWith(hasPlaybackError: false);
    final song = state.currentSong;
    if (song != null && state.processingState == ProcessingState.completed) {
      return playSong(
        song,
        queue: state.queue,
        index: state.currentIndex,
        resumePosition: Duration.zero,
      );
    }
    if (song != null &&
        (_loadedSourceSongId != song.id || _recoveryAttempts >= 4)) {
      final resumePosition = _retryPosition ?? state.position;
      _recoveryAttempts = 0;
      return playSong(
        song,
        queue: state.queue,
        index: state.currentIndex,
        resumePosition: resumePosition,
      );
    }
    _startPlayback(fadeIn: false);
    return Future<void>.value();
  }

  @override
  Future<void> stop() async {
    Logger.infoWithTag('PLAYBACK', 'stop song=${state.currentSong?.id}');
    _playbackRequested = false;
    _audioHandler?.updateTransportIntent(false);
    _playDebugSession += 1;
    _transportRequestGeneration += 1;
    _clearCurrentPlaybackRetry(reason: 'stop');
    unawaited(_cacheHandler.cancelPrecache());
    _invalidateLoadedSource(reason: 'stop');
    _invalidateSeekRequests();
    _cancelFade();
    // Release for this stop request before awaiting native work: a later play
    // must not have its newly acquired lease released by a stale stop.
    unawaited(_wakeGuard.setActive(false, reason: 'stop'));
    await _audioPlayer?.stop();
  }

  /// Captures the last logical queue and position before desktop teardown stops
  /// the native player. A native stop can reset its reported position to zero.
  Future<void> stopForDesktopExit() async {
    await initialized;

    _playbackSessionPersistTimer?.cancel();
    _playbackSessionPersistTimer = null;
    await _persistPlaybackSession();
    _playbackSessionPersistTimer?.cancel();
    _playbackSessionPersistTimer = null;

    // `_persistPlaybackSession` has already flushed the latest logical queue
    // and position. Preserve that snapshot before native stop resets position;
    // writing it a second time only makes desktop shutdown wait on duplicate IO.
    _preservePlaybackSessionOnShutdown = true;
    await stop();
  }

  /// Persists the outgoing library queue, stops its audio, and detaches its
  /// media item before a new library gets a fresh PlayerNotifier.
  Future<void> prepareForLibrarySwitch() async {
    await initialized;
    if (!mounted || _preservePlaybackSessionOnShutdown) return;

    _playbackSessionPersistTimer?.cancel();
    _playbackSessionPersistTimer = null;
    await _persistPlaybackSession();
    _playbackSessionPersistTimer?.cancel();
    _playbackSessionPersistTimer = null;

    _librarySwitchPreviousPlaybackRequested = _playbackRequested;
    _librarySwitchResumePosition = state.position;
    _preservePlaybackSessionOnShutdown = true;
    _audioHandler?.updateTransportIntent(false);
    try {
      await stop();
    } catch (error) {
      Logger.warnWithTag(
        'PLAYBACK',
        'could not stop audio during library switch',
        error,
      );
      try {
        await _audioPlayer?.pause();
      } catch (pauseError) {
        Logger.warnWithTag(
          'PLAYBACK',
          'could not pause audio during library switch',
          pauseError,
        );
      }
    }
    if (mounted && state.position != _librarySwitchResumePosition) {
      state = state.copyWith(
        position: _librarySwitchResumePosition,
        isPlaying: false,
      );
    }
    await _audioHandler?.clearMediaItem();
    _audioHandler?.unbindCommands(this);
    unawaited(_wakeGuard.setActive(false, reason: 'library_switch'));
  }

  Future<void> cancelLibrarySwitchPreparation() async {
    if (!_preservePlaybackSessionOnShutdown || !mounted) return;
    _preservePlaybackSessionOnShutdown = false;
    _bindAudioHandlerCommands();
    final song = state.currentSong;
    if (song != null) {
      _activePlaybackEntryId = state.currentEntryId;
      _updateMediaItem(song);
      if (_librarySwitchPreviousPlaybackRequested) {
        await play();
      }
    }
    _librarySwitchPreviousPlaybackRequested = false;
    _librarySwitchResumePosition = Duration.zero;
  }

  /// 暂停前的淡出：音量降到 0 后返回，由 pause() 执行实际暂停。
  Future<void> _fadeOutForPause() async {
    _cancelFade();
    final durationMs = _ref.read(crossfadeDurationMsProvider);
    if (durationMs <= 0) return;
    final player = _audioPlayer;
    if (player == null ||
        !player.playing ||
        player.processingState == ProcessingState.completed) {
      return;
    }

    final fadeMs = durationMs ~/ 2;
    const stepMs = 20;
    final steps = (fadeMs / stepMs).ceil().clamp(1, 500);
    final volumeStep = 1.0 / steps;
    var currentGain = 1.0;
    final session = _playDebugSession;
    final transportRequest = _transportRequestGeneration;
    _fadeGain = currentGain;

    final completer = Completer<void>();
    _fadeCompleter = completer;
    _fadeTimer = Timer.periodic(const Duration(milliseconds: stepMs), (timer) {
      if (_playDebugSession != session ||
          _transportRequestGeneration != transportRequest) {
        timer.cancel();
        if (identical(_fadeTimer, timer)) _fadeTimer = null;
        if (identical(_fadeCompleter, completer)) _fadeCompleter = null;
        if (!completer.isCompleted) completer.complete();
        return;
      }
      currentGain = (currentGain - volumeStep).clamp(0.0, 1.0);
      _fadeGain = currentGain;
      _applyEffectivePlaybackVolume();
      if (currentGain <= 0.0) {
        timer.cancel();
        _fadeTimer = null;
        if (identical(_fadeCompleter, completer)) {
          _fadeCompleter = null;
        }
        if (!completer.isCompleted) completer.complete();
      }
    });

    return completer.future;
  }

  /// 上一首
  @override
  Future<void> previous() async {
    if (!state.hasPrevious) return;

    final previousIndex = _getQueuePreviousIndex();
    if (previousIndex == null) return;
    final previousSong = state.queue[previousIndex];
    await playSong(previousSong, queue: state.queue, index: previousIndex);
  }

  /// 下一首
  @override
  Future<void> next() async {
    if (!state.hasNext) return;

    final nextIndex = state.currentIndex + 1;
    if (nextIndex < state.queue.length) {
      final nextSong = state.queue[nextIndex];
      await playSong(nextSong, queue: state.queue, index: nextIndex);
      return;
    }

    if (state.shuffleEnabled &&
        state.loopMode != LoopMode.off &&
        state.queue.isNotEmpty) {
      final nextRound = state.playbackQueue.nextShuffleRound(_random);
      state = state.copyWith(playbackQueue: nextRound);
      await playSong(nextRound.currentSong!, queue: state.queue, index: 0);
      return;
    }

    // 回绕到首曲（单曲队列时等同于重播当前曲目）。
    if (state.loopMode != LoopMode.off && state.queue.isNotEmpty) {
      await skipToQueueItem(0);
    }
  }

  /// 跳转到指定位置
  @override
  Future<void> seek(Duration position) async {
    final player = _audioPlayer;
    final currentSongId = state.currentSong?.id;
    if (player == null || currentSongId == null) return;

    final seekGeneration = ++_seekRequestGeneration;
    final playbackSession = _playDebugSession;
    bool isCurrentSeek() => _isSeekRequestCurrent(
      seekGeneration: seekGeneration,
      playbackSession: playbackSession,
      songId: currentSongId,
    );
    bool ownsSource() => _isPlaybackContextCurrent(
      session: playbackSession,
      songId: currentSongId,
    );
    final target = _normalizeSeekPosition(position);
    state = state.copyWith(isSeeking: true, hasPlaybackError: false);
    _seekAwaitingReady = false;
    final canSeekNow = canSeekLoadedPlayerSource(
      processingState: player.processingState,
      loadedSourceSongId: _loadedSourceSongId,
      currentSongId: currentSongId,
    );
    _seekDbg(
      'seek request song=$currentSongId target=$target '
      'playerPos=${player.position} state=${player.processingState.name} '
      'canSeekNow=$canSeekNow loadedSource=$_loadedSourceSongId '
      'lockCache=$_usingLockCachingSource',
    );

    if (!canSeekNow) {
      _pendingSeekSongId = currentSongId;
      _pendingSeekPosition = target;
      _seekDbg('seek queued pendingSong=$_pendingSeekSongId pending=$target');
      if (mounted) {
        state = state.copyWith(position: target);
      }
      return;
    }

    _activeSeekGeneration = seekGeneration;
    _activeSeekSongId = currentSongId;

    // 可立即 seek 时，先把 UI 锚定到目标位置，避免等待底层回调期间回退到旧进度。
    if (mounted) {
      state = state.copyWith(position: target);
    }
    if (_usingLockCachingSource) {
      _syntheticPositionFallbackActive = true;
      _seekDbg('seek anchor synthetic position target=$target');
    }

    _clearPendingSeek();
    try {
      await _seekWithFallback(
        target,
        songId: currentSongId,
        isCurrentSeek: isCurrentSeek,
        ownsSource: ownsSource,
      );
      if (isCurrentSeek() && mounted) {
        _positionSeekRevision += 1;
        state = state.copyWith(position: target);
        if (_playbackRequested && !player.playing) {
          _startPlayback(fadeIn: false);
        }
      }
    } on _SeekSourceRestored {
      if (isCurrentSeek()) {
        NetworkErrorNotifier.show('拖动失败，已恢复原播放位置');
      }
    } catch (error) {
      if (isCurrentSeek()) {
        final song = state.currentSong;
        if (song != null) {
          _scheduleCurrentPlaybackRetry(
            song: song,
            isPreview: song.isPreview,
            autoPlay: _playbackRequested,
            position: target,
          );
        }
      }
    } finally {
      _releaseSeekAnchor(seekGeneration);
      _schedulePendingSeekIfReady();
    }
  }

  /// 跳转到队列中的指定歌曲
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= state.queue.length) return;

    final song = state.queue[index];
    await playSong(song, queue: state.queue, index: index);
  }

  @override
  Future<void> skipToQueueEntry(String entryId) async {
    final index = state.playbackQueue.indexOfEntry(entryId);
    if (index < 0) return;
    await skipToQueueItem(index);
  }

  Future<void> _syncNativeLoopMode() async {
    final player = _audioPlayer;
    if (player == null) return;
    final repeat =
        !state.shuffleEnabled &&
        (state.loopMode == LoopMode.one ||
            (state.loopMode == LoopMode.all && state.queue.length == 1)) &&
        _sourcePositionOffset == Duration.zero &&
        _loadedSourceSongId != null &&
        _loadedSourceSongId == state.currentSong?.id;
    final mode = repeat ? LoopMode.one : LoopMode.off;
    if (_nativeLoopMode == mode) return;
    _nativeLoopMode = mode;
    try {
      await player.setLoopMode(mode);
      Logger.infoWithTag(
        'PLAYBACK',
        'native_loop=${mode.name} song=${state.currentSong?.id} offsetMs=${_sourcePositionOffset.inMilliseconds}',
      );
    } catch (error) {
      _nativeLoopMode = LoopMode.off;
      Logger.warnWithTag(
        'PLAYBACK',
        'native_loop failed type=${error.runtimeType}',
      );
      // Completion handling can still repeat via seek when native looping fails.
    }
  }

  /// 设置循环模式
  @override
  Future<void> setLoopMode(LoopMode mode) => _enqueuePlaybackModeMutation(
    () => _applyPlaybackModes(
      loopMode: mode,
      shuffleEnabled: state.shuffleEnabled,
    ),
  );

  /// 切换循环模式
  Future<void> toggleLoopMode() => _enqueuePlaybackModeMutation(() async {
    final nextMode = switch (state.loopMode) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    await _applyPlaybackModes(
      loopMode: nextMode,
      shuffleEnabled: state.shuffleEnabled,
    );
  });

  /// 设置随机播放
  @override
  Future<void> setShuffleEnabled(bool enabled) => _enqueuePlaybackModeMutation(
    () =>
        _applyPlaybackModes(loopMode: state.loopMode, shuffleEnabled: enabled),
  );

  /// 切换随机播放
  Future<void> toggleShuffle() => _enqueuePlaybackModeMutation(() async {
    await _applyPlaybackModes(
      loopMode: state.loopMode,
      shuffleEnabled: !state.shuffleEnabled,
    );
  });

  /// 播放失败后刷新全部线路，确认是否存在可用线路
  Future<bool> _refreshRoutesAndCheckAvailability() async {
    try {
      final pool = _ref.read(addressPoolProvider);
      final active = await pool.probeAll();
      if (active?.status == ServerAddressStatus.ok) return true;
      return pool.addresses.any((a) => a.status == ServerAddressStatus.ok);
    } catch (e) {
      Logger.warn('Failed to refresh routes after playback error', e);
      return false;
    }
  }

  /// 当前播放模式
  PlaybackMode get playbackMode {
    if (state.shuffleEnabled) return PlaybackMode.shuffle;
    if (state.loopMode == LoopMode.one) return PlaybackMode.repeatOne;
    if (state.loopMode == LoopMode.all) return PlaybackMode.repeatAll;
    return PlaybackMode.sequential;
  }

  /// 设置播放模式
  @override
  Future<void> setPlaybackMode(PlaybackMode mode, {bool persist = true}) =>
      _enqueuePlaybackModeMutation(
        () => _setPlaybackModeNow(mode, persist: persist),
      );

  Future<void> _setPlaybackModeNow(
    PlaybackMode mode, {
    bool persist = true,
  }) async {
    final modes = switch (mode) {
      PlaybackMode.sequential => (
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      ),
      // Preserve the old combined-mode behavior: cycling to Shuffle also
      // repeats the shuffled playlist. Direct shuffle/loop commands remain
      // independent.
      PlaybackMode.shuffle => (loopMode: LoopMode.all, shuffleEnabled: true),
      PlaybackMode.repeatAll => (loopMode: LoopMode.all, shuffleEnabled: false),
      PlaybackMode.repeatOne => (loopMode: LoopMode.one, shuffleEnabled: false),
    };
    await _applyPlaybackModes(
      loopMode: modes.loopMode,
      shuffleEnabled: modes.shuffleEnabled,
      persist: persist,
    );
  }

  Future<void> _enqueuePlaybackModeMutation(Future<void> Function() mutation) {
    final operation = _playbackModeMutationTail.then((_) => mutation());
    // Keep later commands runnable even if one native or persistence operation
    // fails. The caller still receives the original error from `operation`.
    _playbackModeMutationTail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return operation;
  }

  Future<void> _applyPlaybackModes({
    required LoopMode loopMode,
    required bool shuffleEnabled,
    PlaybackQueueState? queue,
    bool persist = true,
  }) async {
    final previous = state;
    final baseQueue = queue ?? previous.playbackQueue;
    final shuffleChanged = previous.shuffleEnabled != shuffleEnabled;
    final modesChanged = shuffleChanged || previous.loopMode != loopMode;
    final queueChanged = !identical(baseQueue, previous.playbackQueue);
    final nextQueue = queue != null || !shuffleChanged
        ? baseQueue
        : shuffleEnabled
        ? baseQueue.enableShuffle(_random)
        : baseQueue.restoreBaseOrder();

    // Ordering/repeat belong to the notifier, including the Android native
    // lookahead window. Native shuffle must never invent another order.
    await _audioPlayer?.setShuffleModeEnabled(false);
    if (mounted) {
      state = state.copyWith(
        playbackQueue: nextQueue,
        loopMode: loopMode,
        shuffleEnabled: shuffleEnabled,
      );
    }
    if (modesChanged || queueChanged) _onQueueOrderChanged();
    await _syncNativeLoopMode();
    if (persist) await _persistPlaybackModes();
  }

  /// 顺序播放 -> 列表循环 -> 单曲循环 -> 随机播放 -> 顺序播放
  @override
  Future<void> cyclePlaybackMode() => _enqueuePlaybackModeMutation(() async {
    final nextMode = switch (playbackMode) {
      PlaybackMode.sequential => PlaybackMode.repeatAll,
      PlaybackMode.repeatAll => PlaybackMode.repeatOne,
      PlaybackMode.repeatOne => PlaybackMode.shuffle,
      PlaybackMode.shuffle => PlaybackMode.sequential,
    };
    await _setPlaybackModeNow(nextMode);
  });

  /// Cycles only repeat mode, preserving the independent shuffle setting.
  @override
  Future<void> cycleLoopMode() => _enqueuePlaybackModeMutation(() async {
    final nextMode = switch (state.loopMode) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    await _applyPlaybackModes(
      loopMode: nextMode,
      shuffleEnabled: state.shuffleEnabled,
    );
  });

  Future<void> _restorePlaybackMode() async {
    try {
      final storedModes = await LocalStorage.getPlaybackModes();
      if (storedModes != null) {
        final loopMode = LoopMode.values.firstWhere(
          (mode) => mode.name == storedModes.loopMode,
          orElse: () => LoopMode.all,
        );
        await _enqueuePlaybackModeMutation(
          () => _applyPlaybackModes(
            loopMode: loopMode,
            shuffleEnabled: storedModes.shuffleEnabled,
            persist: false,
          ),
        );
        Logger.infoWithTag(
          _playerLogTag,
          'playback modes restored: loop=${loopMode.name} '
          'shuffle=${storedModes.shuffleEnabled}',
        );
        return;
      }

      final storedMode = await LocalStorage.getPlaybackMode();
      final mode = PlaybackMode.values.firstWhere(
        (item) => item.name == storedMode,
        orElse: () => PlaybackMode.repeatAll,
      );
      await setPlaybackMode(mode, persist: false);
      await _persistPlaybackModes();
      Logger.infoWithTag(_playerLogTag, 'playback mode restored: ${mode.name}');
    } catch (e) {
      Logger.warnWithTag(_playerLogTag, 'failed to restore playback mode', e);
    }
  }

  Future<void> _persistPlaybackModes() async {
    try {
      await LocalStorage.setPlaybackModes(
        loopMode: state.loopMode.name,
        shuffleEnabled: state.shuffleEnabled,
      );
    } catch (e) {
      Logger.warnWithTag(
        _playerLogTag,
        'failed to persist playback modes: loop=${state.loopMode.name} '
        'shuffle=${state.shuffleEnabled}',
        e,
      );
    }
  }

  void _schedulePersistPlaybackSession({bool immediate = false}) {
    if (!mounted ||
        _isRestoringPlaybackSession ||
        _preservePlaybackSessionOnShutdown) {
      return;
    }

    if (immediate) {
      _playbackSessionPersistTimer?.cancel();
      _playbackSessionPersistTimer = null;
      unawaited(_persistPlaybackSession());
      return;
    }

    if (_playbackSessionPersistTimer != null) return;
    _playbackSessionPersistTimer = Timer(_playbackSessionPersistInterval, () {
      _playbackSessionPersistTimer = null;
      unawaited(_persistPlaybackSession());
    });
  }

  Map<String, dynamic>? _buildPlaybackSessionPayload() {
    if (state.queue.isEmpty) return null;

    final normalizedPosition = _normalizeSeekPosition(state.position);
    return {
      'version': 2,
      'mode': playbackMode.name,
      'loopMode': state.loopMode.name,
      'shuffleEnabled': state.shuffleEnabled,
      'libraryId': _currentPlaybackLibraryId,
      ...state.playbackQueue.toJson(),
      'positionMs': normalizedPosition.inMilliseconds,
      'isPlaying': state.isPlaying,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
  }

  Future<void> _persistPlaybackSession() async {
    if (!mounted ||
        _isRestoringPlaybackSession ||
        _preservePlaybackSessionOnShutdown) {
      return;
    }
    _playbackSessionPersistDirty = true;
    var activePersist = _playbackSessionPersistFuture;
    while (activePersist != null) {
      await activePersist;
      if (!_playbackSessionPersistDirty || !mounted) return;
      activePersist = _playbackSessionPersistFuture;
    }

    final completion = Completer<void>();
    _playbackSessionPersistFuture = completion.future;
    final watch = Stopwatch()..start();
    try {
      while (_playbackSessionPersistDirty && mounted) {
        _playbackSessionPersistDirty = false;
        final payload = _buildPlaybackSessionPayload();
        final libraryId = _currentPlaybackLibraryId;
        if (payload == null) {
          await LocalStorage.clearPlaybackSession(libraryId: libraryId);
        } else {
          await LocalStorage.savePlaybackSession(payload, libraryId: libraryId);
        }
      }
      if (watch.elapsedMilliseconds > 200) {
        Logger.infoWithTag(
          'PLAYBACK',
          'session_save_slow elapsedMs=${watch.elapsedMilliseconds} queue=${state.queue.length}',
        );
      }
    } catch (e) {
      _playbackSessionPersistDirty = true;
      Logger.warnWithTag(
        _playerLogTag,
        'failed to persist playback session',
        e,
      );
    } finally {
      if (identical(_playbackSessionPersistFuture, completion.future)) {
        _playbackSessionPersistFuture = null;
      }
      completion.complete();
    }
  }

  Future<void> _restorePlaybackSession() async {
    if (!mounted) return;
    var restored = false;
    _isRestoringPlaybackSession = true;

    try {
      await _ref.read(authStateProvider.notifier).initialized;
      final activeLibraryId = _readActiveLibraryId();
      var session = await LocalStorage.getPlaybackSession(
        libraryId: activeLibraryId,
      );
      if (session == null) return;
      _currentPlaybackLibraryId = _storedPlaybackLibraryId(session);

      final version = _parseStoredInt(session['version']) ?? 1;
      if (version >= 2) {
        final restoredQueue = PlaybackQueueState.fromJson(session);
        if (restoredQueue == null) {
          final legacySession = await LocalStorage.getLegacyPlaybackSession(
            libraryId: _currentPlaybackLibraryId,
          );
          if (legacySession == null) {
            await LocalStorage.clearPlaybackSession(
              libraryId: _currentPlaybackLibraryId,
            );
            return;
          }
          session = legacySession;
          _currentPlaybackLibraryId =
              _storedPlaybackLibraryId(session) ?? _readActiveLibraryId();
        } else {
          final sessionPayload = session!;
          final restoredMode = PlaybackMode.values.firstWhere(
            (mode) => mode.name == sessionPayload['mode']?.toString(),
            orElse: () => PlaybackMode.repeatAll,
          );
          final storedLoopMode = LoopMode.values.firstWhere(
            (mode) => mode.name == sessionPayload['loopMode']?.toString(),
            orElse: () => switch (restoredMode) {
              PlaybackMode.repeatOne => LoopMode.one,
              PlaybackMode.repeatAll || PlaybackMode.shuffle => LoopMode.all,
              _ => LoopMode.off,
            },
          );
          final storedShuffleEnabled = sessionPayload['shuffleEnabled'] is bool
              ? sessionPayload['shuffleEnabled']! as bool
              : restoredMode == PlaybackMode.shuffle;
          await _enqueuePlaybackModeMutation(
            () => _applyPlaybackModes(
              loopMode: storedLoopMode,
              shuffleEnabled: storedShuffleEnabled,
              queue: restoredQueue,
              persist: false,
            ),
          );
          if (restoredQueue.currentSong == null) {
            Logger.infoWithTag(
              _playerLogTag,
              'playback session v2 restored without current entry '
              'queue=${restoredQueue.length} mode=${restoredMode.name}',
            );
            restored = true;
            return;
          }
          final storedPositionMs =
              _parseStoredInt(sessionPayload['positionMs']) ?? 0;
          final restoredPosition = Duration(
            milliseconds: max(0, storedPositionMs),
          );
          await playSong(
            restoredQueue.currentSong!,
            queue: state.queue,
            index: restoredQueue.currentIndex,
            autoPlay: false,
          );
          if (restoredPosition > Duration.zero) {
            await seek(restoredPosition);
          }
          await pause();
          Logger.infoWithTag(
            _playerLogTag,
            'playback session v2 restored queue=${state.queue.length} '
            'index=${state.currentIndex} mode=${restoredMode.name}',
          );
          restored = true;
          return;
        }
      }

      final queue = _parsePlaybackSessionQueue(session['queue']);
      if (queue.isEmpty) {
        await LocalStorage.clearPlaybackSession(
          libraryId: _currentPlaybackLibraryId,
        );
        return;
      }

      final preferredIndex = _parseStoredInt(session['currentIndex']) ?? 0;
      final currentSongId = session['currentSongId']?.toString();
      final restoredIndex = _resolveRestoredQueueIndex(
        queue: queue,
        preferredIndex: preferredIndex,
        currentSongId: currentSongId,
      );
      final storedPositionMs = _parseStoredInt(session['positionMs']) ?? 0;
      final restoredPosition = Duration(milliseconds: max(0, storedPositionMs));
      final wasPlaying = session['isPlaying'] == true;
      Logger.infoWithTag(
        _playerLogTag,
        'restoring playback session queue=${queue.length} '
        'index=$restoredIndex posMs=${restoredPosition.inMilliseconds} '
        'wasPlaying=$wasPlaying',
      );
      await playSong(
        queue[restoredIndex],
        queue: queue,
        index: restoredIndex,
        autoPlay: false,
      );
      if (restoredPosition > Duration.zero) {
        await seek(restoredPosition);
      }
      // 安全策略：恢复会话后始终暂停，避免未确认自动播放出声。
      await pause();

      Logger.infoWithTag(_playerLogTag, 'playback session restored');
      restored = true;
    } catch (e) {
      Logger.warnWithTag(
        _playerLogTag,
        'failed to restore playback session',
        e,
      );
    } finally {
      _isRestoringPlaybackSession = false;
    }

    if (restored) {
      _schedulePersistPlaybackSession(immediate: true);
    }
  }

  List<Song> _parsePlaybackSessionQueue(Object? rawQueue) {
    if (rawQueue is! List) return const [];

    final queue = <Song>[];
    for (final item in rawQueue) {
      try {
        if (item is Map<String, dynamic>) {
          queue.add(Song.fromJson(item));
          continue;
        }
        if (item is Map) {
          final mapped = item.map(
            (key, value) => MapEntry(key.toString(), value),
          );
          queue.add(Song.fromJson(mapped));
        }
      } catch (e) {
        Logger.warnWithTag(
          _playerLogTag,
          'skip invalid song in playback session',
          e,
        );
      }
    }
    return queue;
  }

  int? _parseStoredInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  String? _storedPlaybackLibraryId(Map<String, dynamic> session) {
    final stored = session['libraryId']?.toString().trim();
    if (stored != null && stored.isNotEmpty) return stored;
    return _readActiveLibraryId();
  }

  int _resolveRestoredQueueIndex({
    required List<Song> queue,
    required int preferredIndex,
    required String? currentSongId,
  }) {
    if (queue.isEmpty) return 0;

    if (currentSongId != null && currentSongId.isNotEmpty) {
      if (preferredIndex >= 0 &&
          preferredIndex < queue.length &&
          queue[preferredIndex].id == currentSongId) {
        return preferredIndex;
      }

      final matched = queue.indexWhere((song) => song.id == currentSongId);
      if (matched >= 0) return matched;
    }

    if (preferredIndex < 0) return 0;
    if (preferredIndex >= queue.length) return queue.length - 1;
    return preferredIndex;
  }

  int? _getQueuePreviousIndex() {
    final queue = state.queue;
    if (queue.isEmpty) return null;
    if (queue.length == 1) return 0;

    final currentIndex = state.currentIndex;
    if (currentIndex <= 0) return queue.length - 1;
    if (currentIndex >= queue.length) return queue.length - 1;
    return currentIndex - 1;
  }

  /// 添加到队列末尾
  @override
  void addToQueue(Song song) {
    state = state.copyWith(
      playbackQueue: state.playbackQueue.append(<Song>[song]),
    );
    _onQueueOrderChanged();
  }

  /// 添加多首到队列
  @override
  void addAllToQueue(List<Song> songs) {
    state = state.copyWith(playbackQueue: state.playbackQueue.append(songs));
    _onQueueOrderChanged();
  }

  /// 添加到下一曲位置
  @override
  Future<void> playNext(Song song) async {
    if (state.queue.isEmpty || state.currentSong == null) {
      await playSong(song, queue: [song], index: 0);
      return;
    }

    state = state.copyWith(playbackQueue: state.playbackQueue.insertNext(song));
    _onQueueOrderChanged();
  }

  /// 清空队列
  @override
  Future<void> clearQueue() async {
    final currentSong = state.currentSong;
    if (currentSong != null) {
      state = state.copyWith(
        playbackQueue: state.playbackQueue.clearUpcoming(),
      );
      _onQueueOrderChanged();
      return;
    }

    _playbackRequested = false;
    _audioHandler?.updateTransportIntent(false);
    unawaited(_cacheHandler.cancelPrecache());
    await _audioPlayer?.stop();
    await _audioHandler?.stop();
    unawaited(_wakeGuard.setActive(false, reason: 'queue_cleared'));
    _activePlaybackEntryId = null;
    _invalidateLoadedSource(reason: 'queue_cleared');
    _invalidateSeekRequests();
    state = state.copyWith(
      playbackQueue: PlaybackQueueState.empty(),
      isPlaying: false,
      processingState: ProcessingState.idle,
      position: Duration.zero,
      duration: Duration.zero,
      currentQuality: null,
      playbackSource: null,
      currentBitRateKbps: 0,
    );
  }

  /// 从队列移除
  void removeFromQueue(int index) {
    if (index < 0 || index >= state.queue.length) return;

    final nextQueue = state.playbackQueue.removeAt(index);

    // 如果移除的是当前播放的歌曲
    if (index == state.currentIndex) {
      // 停止播放
      _playbackRequested = false;
      _audioHandler?.updateTransportIntent(false);
      unawaited(_wakeGuard.setActive(false, reason: 'queue_current_removed'));
      _audioPlayer?.stop();
      _audioHandler?.stop();
      _activePlaybackEntryId = null;
      _invalidateLoadedSource(reason: 'current_queue_item_removed');
      _invalidateSeekRequests();
      state = state.copyWith(
        playbackQueue: nextQueue,
        isPlaying: false,
        processingState: ProcessingState.idle,
        position: Duration.zero,
        duration: Duration.zero,
        currentQuality: null,
        playbackSource: null,
        currentBitRateKbps: 0,
      );
      _onQueueOrderChanged();
    } else {
      state = state.copyWith(playbackQueue: nextQueue);
      _onQueueOrderChanged();
    }
  }

  @override
  void removeQueueEntry(String entryId) {
    final index = state.playbackQueue.indexOfEntry(entryId);
    if (index < 0) return;
    removeFromQueue(index);
  }

  /// Reorders the visible queue without reloading the current audio source.
  @override
  void reorderQueue(int oldIndex, int newIndex) {
    final nextQueue = state.playbackQueue.move(
      oldIndex,
      newIndex,
      shuffleEnabled: state.shuffleEnabled,
    );
    if (identical(nextQueue, state.playbackQueue)) return;
    state = state.copyWith(playbackQueue: nextQueue);
    _onQueueOrderChanged();
  }

  void _onQueueOrderChanged() {
    _androidNativeQueueLastCheck = null;
    _androidNativeQueueDirty = true;
    unawaited(_refreshAndroidNativeQueue());
    _precacheStartedSession = null;
    _precacheTargetEntryId = null;
    unawaited(_cacheHandler.cancelPrecache());
    _preCacheNextSong();
  }

  /// 歌曲播放完成
  Future<void> _onSongCompleted(
    String completedSongId,
    String completedEntryId,
  ) async {
    if (state.currentSong?.id != completedSongId ||
        state.currentEntryId != completedEntryId) {
      return;
    }
    Logger.infoWithTag(
      'PLAYBACK',
      'completed song=$completedSongId index=${state.currentIndex} queue=${state.queue.length} mode=${playbackMode.name}',
    );
    _capturePlaybackDiagnostics('completed');

    // 不阻塞切歌流程，避免完成态停留过久导致竞态。
    if (state.currentSong?.isPreview != true) {
      unawaited(_scrobble(completedSongId, submission: true));
    }

    // Repeat-one is independent from shuffle and repeats the current entry.
    if (state.loopMode == LoopMode.one ||
        (state.loopMode == LoopMode.all && state.queue.length == 1)) {
      // 单曲循环
      _seekDbg('completed -> repeat one song=$completedSongId');
      if (_sourcePositionOffset == Duration.zero &&
          _loadedSourceSongId == completedSongId) {
        final session = _playDebugSession;
        final transport = _transportRequestGeneration;
        Logger.infoWithTag('PLAYBACK', 'repeat_reuse song=$completedSongId');
        try {
          // Deliberately bypass timeOffset seek: this source starts at zero.
          await _audioPlayer!
              .seek(Duration.zero)
              .timeout(const Duration(seconds: 5));
          if (!mounted ||
              session != _playDebugSession ||
              transport != _transportRequestGeneration ||
              !_playbackRequested) {
            return;
          }
          _isHandlingCompletion = false;
          _completionHandlingSongId = null;
          _completionHandlingEntryId = null;
          state = state.copyWith(position: Duration.zero);
          _startPlayback(fadeIn: false);
          if (!state.currentSong!.isPreview) {
            unawaited(_scrobble(completedSongId, submission: false));
          }
        } catch (error) {
          if (mounted &&
              session == _playDebugSession &&
              transport == _transportRequestGeneration) {
            _handlePlaybackFailure('repeat_seek_failed', error);
          }
        }
      } else {
        Logger.infoWithTag(
          'PLAYBACK',
          'repeat_reload_tail song=$completedSongId offsetMs=${_sourcePositionOffset.inMilliseconds}',
        );
        await playSong(
          state.currentSong!,
          queue: state.queue,
          index: state.currentIndex,
        );
      }
    } else if (state.hasNext) {
      // Follow the visible shuffle order when enabled; next() starts another
      // randomized round only when repeat is enabled.
      _seekDbg('completed -> next song=$completedSongId');
      await next();
    } else {
      _seekDbg('completed -> queue end song=$completedSongId');
      await pause();
    }
  }

  /// 上报播放记录（Scrobble）
  Future<void> _scrobble(String songId, {required bool submission}) =>
      _favoriteHandler.scrobble(songId, submission: submission);

  Future<void> _recordMobileCacheSavedBytesForHit({
    required String songId,
    required String cacheFilePath,
    required String libraryId,
  }) => _favoriteHandler.recordMobileCacheSavedBytesForHit(
    songId: songId,
    cacheFilePath: cacheFilePath,
    libraryId: libraryId,
  );

  /// 切换当前歌曲的收藏状态
  Future<void> toggleFavorite() async {
    final currentSong = state.currentSong;
    if (currentSong == null) return;
    await toggleSongFavorite(currentSong);
  }

  /// 切换指定歌曲的收藏状态
  Future<bool?> toggleSongFavorite(Song song) async {
    final newStarred = await _favoriteHandler.toggleSongFavorite(
      song: song,
      currentSong: state.currentSong,
      queue: state.queue,
    );
    if (newStarred == null) return null;

    final updatedQueue = _favoriteHandler.updateQueueStarred(
      state.queue,
      song.id,
      newStarred,
    );
    final currentSong = state.currentSong;
    final updatedCurrentSong = currentSong != null && currentSong.id == song.id
        ? currentSong.copyWith(starred: newStarred)
        : currentSong;

    state = state.copyWith(
      currentSong: updatedCurrentSong,
      queue: updatedQueue,
    );
    _favoriteHandler.invalidateFavoriteProviders(albumId: song.albumId);
    return newStarred;
  }

  Future<void> refreshSongMetadata(String songId) async {
    if (songId.trim().isEmpty) return;

    try {
      final fullSong = await _musicRepository.getSong(songId);
      if (fullSong == null) return;

      final currentSong = state.currentSong;
      final updatedQueue = List<Song>.from(state.queue);
      var queueChanged = false;
      for (var i = 0; i < updatedQueue.length; i++) {
        if (updatedQueue[i].id != songId) continue;
        updatedQueue[i] = fullSong;
        queueChanged = true;
      }

      if (currentSong != null && currentSong.id == songId) {
        state = state.copyWith(
          currentSong: fullSong,
          queue: queueChanged ? updatedQueue : state.queue,
        );
        _updateMediaItem(fullSong);
        return;
      }

      if (queueChanged) {
        state = state.copyWith(queue: updatedQueue);
      }
    } catch (e) {
      Logger.warnWithTag(_playerLogTag, 'failed to refresh song metadata', e);
    }
  }

  Duration _normalizeSeekPosition(Duration position) {
    if (position < Duration.zero) return Duration.zero;
    final duration = state.duration;
    if (duration > Duration.zero && position > duration) {
      return duration;
    }
    return position;
  }

  Future<void> _applyPendingSeekIfNeeded() async {
    if (_isApplyingPendingSeek) return;

    final player = _audioPlayer;
    final pending = _pendingSeekPosition;
    final pendingSongId = _pendingSeekSongId;
    final currentSongId = state.currentSong?.id;
    if (player == null ||
        pending == null ||
        pendingSongId == null ||
        currentSongId == null) {
      return;
    }
    if (pendingSongId != currentSongId) return;

    final canSeekNow = canSeekLoadedPlayerSource(
      processingState: player.processingState,
      loadedSourceSongId: _loadedSourceSongId,
      currentSongId: currentSongId,
    );
    if (!canSeekNow) return;

    _isApplyingPendingSeek = true;
    final seekGeneration = ++_seekRequestGeneration;
    final playbackSession = _playDebugSession;
    bool isCurrentSeek() => _isSeekRequestCurrent(
      seekGeneration: seekGeneration,
      playbackSession: playbackSession,
      songId: currentSongId,
    );
    bool ownsSource() => _isPlaybackContextCurrent(
      session: playbackSession,
      songId: currentSongId,
    );
    final target = _normalizeSeekPosition(pending);
    _activeSeekGeneration = seekGeneration;
    _activeSeekSongId = currentSongId;
    _seekAwaitingReady = false;
    state = state.copyWith(isSeeking: true);
    _seekDbg(
      'applyPendingSeek song=$currentSongId target=$target '
      'playerPos=${player.position} state=${player.processingState.name}',
    );
    _clearPendingSeek();
    try {
      await _seekWithFallback(
        target,
        songId: currentSongId,
        isCurrentSeek: isCurrentSeek,
        ownsSource: ownsSource,
      );
      if (isCurrentSeek() && mounted) {
        _positionSeekRevision += 1;
        state = state.copyWith(position: target);
        if (_playbackRequested && !player.playing) {
          _startPlayback(fadeIn: false);
        }
      }
    } on _SeekSourceRestored {
      if (isCurrentSeek()) {
        NetworkErrorNotifier.show('拖动失败，已恢复原播放位置');
      }
    } catch (error) {
      if (isCurrentSeek()) {
        final song = state.currentSong;
        if (song != null) {
          _scheduleCurrentPlaybackRetry(
            song: song,
            isPreview: song.isPreview,
            autoPlay: _playbackRequested,
            position: target,
          );
        }
      }
    } finally {
      _releaseSeekAnchor(seekGeneration);
      _isApplyingPendingSeek = false;
      _schedulePendingSeekIfReady();
    }
  }

  Future<void> _seekWithFallback(
    Duration target, {
    required String songId,
    required bool Function() isCurrentSeek,
    required bool Function() ownsSource,
  }) async {
    final player = _audioPlayer;
    if (player == null || !isCurrentSeek()) return;

    if (_seekByReloadStream &&
        _currentStreamSongId == songId &&
        _currentStreamUrl != null) {
      final shouldResume = _playbackRequested;
      final seekTarget = TranscodedStreamSeekTarget.fromLogical(target);
      final streamFormat = _currentStreamFormat;
      final streamMaxBitRate = _currentStreamMaxBitRate;
      final wasUsingLockCachingSource = _usingLockCachingSource;
      final reloadUrl = _apiClient.getStreamUrl(
        songId,
        maxBitRate: streamMaxBitRate,
        format: streamFormat,
        timeOffset: seekTarget.serverOffset.inSeconds,
      );
      _seekDbg(
        'seek reload-stream song=$songId '
        'target=$target serverOffset=${seekTarget.serverOffset} '
        'sourcePosition=${seekTarget.sourcePosition} format=$streamFormat '
        'maxBitRate=$streamMaxBitRate wasPlaying=$shouldResume '
        'lockCache=$wasUsingLockCachingSource',
      );
      try {
        var reloadedWithLockCaching = false;
        final sourceReady = await _replaceLoadedSource(
          songId: songId,
          label: 'seek_reload_stream',
          ownsSource: ownsSource,
          setSource: (sourcePlayer) async {
            if (wasUsingLockCachingSource && _isAppleHttpUrl(reloadUrl)) {
              // Apple HTTP streams may require just_audio's local proxy. Do
              // not reuse the full-song cache file: this URL contains only a
              // timeOffset tail segment.
              // ignore: experimental_member_use
              final audioSource = LockCachingAudioSource(Uri.parse(reloadUrl));
              await sourcePlayer.setAudioSource(
                audioSource,
                initialPosition: seekTarget.sourcePosition,
              );
              reloadedWithLockCaching = true;
              return;
            }
            await sourcePlayer.setUrl(
              reloadUrl,
              initialPosition: seekTarget.sourcePosition,
            );
          },
        );
        if (!sourceReady) return;
        if (reloadedWithLockCaching) {
          // A tail segment must not be registered as a complete song cache.
          _replaceDownloadProgressSubscription(null);
        }
        _usingLockCachingSource = reloadedWithLockCaching;
        _currentStreamUrl = reloadUrl;
        _setStreamContext(
          songId: songId,
          format: streamFormat,
          maxBitRate: streamMaxBitRate,
          seekByReloadStream: true,
          sourcePositionOffset: seekTarget.serverOffset,
        );
        await _syncNativeLoopMode();
        if (!isCurrentSeek()) {
          _schedulePendingSeekIfReady();
          return;
        }
        if (mounted) {
          state = state.copyWith(position: target, bufferedPosition: target);
        }
        if (shouldResume) {
          _startPlayback(fadeIn: false);
        }
        await Future<void>.delayed(const Duration(milliseconds: 220));
        if (!isCurrentSeek()) return;
        final actualReload = _logicalPlayerPosition(player.position);
        final reloadDrift = (actualReload - target).inMilliseconds.abs();
        _seekDbg(
          'seek reload-stream verify target=$target '
          'sourceActual=${player.position} actual=$actualReload '
          'sourceOffset=$_sourcePositionOffset driftMs=$reloadDrift',
        );
        if (reloadDrift <= 2000) return;
        Logger.warn(
          'Reload-stream seek drift still high '
          '(target=$target, actual=$actualReload), retrying plain seek',
        );
        if (!isCurrentSeek()) return;
        await player.seek(seekTarget.sourcePosition);
        return;
      } catch (e) {
        if (!isCurrentSeek()) return;
        rethrow;
      }
    }

    final sourceTarget = _sourceSeekPosition(target);
    _seekDbg(
      'seek execute target=$target sourceTarget=$sourceTarget '
      'sourceFrom=${player.position} '
      'from=${_logicalPlayerPosition(player.position)} '
      'sourceOffset=$_sourcePositionOffset '
      'state=${player.processingState.name} lockCache=$_usingLockCachingSource',
    );
    await player.seek(sourceTarget);
    if (!isCurrentSeek()) return;

    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (!isCurrentSeek()) return;
    // A slow range request is not evidence of seek drift. Keep the target
    // anchored until the engine reports ready instead of pausing/reloading it.
    if (player.processingState == ProcessingState.buffering ||
        player.processingState == ProcessingState.loading) {
      return;
    }
    final actual = _logicalPlayerPosition(player.position);
    final drift = (actual - target).inMilliseconds.abs();
    _seekDbg(
      'seek verify target=$target sourceActual=${player.position} '
      'actual=$actual driftMs=$drift',
    );
    if (drift <= 2000) return;

    // LockCachingAudioSource 在刚开始下载时，远跳转可能出现“位置变化但音频仍从头播放”。
    // 检测到明显偏差时切换到直连流并携带 initialPosition，保证实际音频位置正确。
    if (_usingLockCachingSource && _currentStreamUrl != null) {
      final shouldResume = _playbackRequested;
      final isAppleHttpStream = _isAppleHttpUrl(_currentStreamUrl);
      if (isAppleHttpStream) {
        Logger.warn(
          'Lock cache seek drift detected on Apple HTTP '
          '(target=$target, actual=$actual), trying lock-cache reload',
        );
        try {
          final reloaded = await _trySeekByReloadingLockCache(
            player: player,
            target: target,
            shouldResume: shouldResume,
            songId: songId,
            isCurrentSeek: isCurrentSeek,
            ownsSource: ownsSource,
          );
          if (!isCurrentSeek()) return;
          if (reloaded) return;
        } catch (e) {
          if (!isCurrentSeek()) return;
          rethrow;
        }
        _seekDbg(
          'seek fallback lock-cache reload unavailable, '
          'keep synthetic position target=$target',
        );
        _syntheticPositionFallbackActive = true;
        if (isCurrentSeek() && mounted) {
          state = state.copyWith(position: target);
        }
        return;
      }

      Logger.warn(
        'Lock cache seek drift detected (target=$target, actual=$actual), '
        'switching to direct stream source',
      );
      _seekDbg(
        'seek fallback -> direct stream initialPosition=$target '
        'wasPlaying=$shouldResume',
      );
      try {
        final streamUrl = _currentStreamUrl!;
        final streamFormat = _currentStreamFormat;
        final streamMaxBitRate = _currentStreamMaxBitRate;
        final reloadStreamSeek = _seekByReloadStream;
        final sourceReady = await _replaceLoadedSource(
          songId: songId,
          label: 'seek_direct_stream_fallback',
          ownsSource: ownsSource,
          setSource: (sourcePlayer) async {
            await sourcePlayer.setUrl(streamUrl, initialPosition: target);
          },
        );
        if (!sourceReady) return;
        _replaceDownloadProgressSubscription(null);
        _usingLockCachingSource = false;
        _currentStreamUrl = streamUrl;
        _setStreamContext(
          songId: songId,
          format: streamFormat,
          maxBitRate: streamMaxBitRate,
          seekByReloadStream: reloadStreamSeek,
        );
        if (!isCurrentSeek()) {
          _schedulePendingSeekIfReady();
          return;
        }
        if (shouldResume) {
          _startPlayback(fadeIn: false);
        }
        _seekDbg('seek fallback completed now=${player.position}');
        return;
      } catch (e) {
        if (!isCurrentSeek()) return;
        rethrow;
      }
    }

    // 直连流/本地文件也做一次强制重试，规避解码器刚起播时的 seek 抖动。
    final shouldResume = _playbackRequested;
    Logger.warn(
      'Seek drift detected on non-lock source (target=$target, actual=$actual), '
      'retrying seek',
    );
    if (shouldResume) {
      // Only this pause belongs to seek recovery. Genuine transport/audio
      // focus pauses during a seek must still cancel the playback intent.
      _internalSeekPauseDepth += 1;
      try {
        await player.pause();
      } finally {
        _internalSeekPauseDepth -= 1;
      }
      if (!isCurrentSeek()) return;
    }
    await player.seek(sourceTarget);
    if (!isCurrentSeek()) return;
    if (shouldResume) {
      _startPlayback(fadeIn: false);
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!isCurrentSeek()) return;
    _seekDbg('seek retry completed now=${player.position}');
  }

  Future<bool> _trySeekByReloadingLockCache({
    required AudioPlayer player,
    required Duration target,
    required bool shouldResume,
    required String songId,
    required bool Function() isCurrentSeek,
    required bool Function() ownsSource,
  }) async {
    if (!isCurrentSeek()) return false;

    final currentStreamUrl = _currentStreamUrl;
    if (currentStreamUrl == null) return false;
    final reloadUrl = _withoutTimeOffset(currentStreamUrl);
    final streamFormat = _currentStreamFormat;
    final streamMaxBitRate = _currentStreamMaxBitRate;
    final reloadStreamSeek = _seekByReloadStream;

    _seekDbg(
      'seek fallback -> lock-cache reload target=$target '
      'format=$streamFormat maxBitRate=$streamMaxBitRate cache=temporary',
    );
    _playDbg(
      'seek_lock_cache_reload '
      'url=${_summarizeStreamUrl(reloadUrl)} cache=temporary',
    );

    // ignore: experimental_member_use
    final audioSource = LockCachingAudioSource(Uri.parse(reloadUrl));
    final sourceReady = await _replaceLoadedSource(
      songId: songId,
      label: 'seek_lock_cache_reload',
      ownsSource: ownsSource,
      setSource: (sourcePlayer) async {
        await sourcePlayer.setAudioSource(audioSource, initialPosition: target);
      },
    );
    if (!sourceReady) return false;
    // This is a temporary retry source. Do not let it replace or register the
    // normal full-song cache entry; bufferedPositionStream is sufficient.
    _replaceDownloadProgressSubscription(null);
    _usingLockCachingSource = true;
    _currentStreamUrl = reloadUrl;
    _setStreamContext(
      songId: songId,
      format: streamFormat,
      maxBitRate: streamMaxBitRate,
      seekByReloadStream: reloadStreamSeek,
    );
    if (!isCurrentSeek()) {
      _schedulePendingSeekIfReady();
      return true;
    }
    if (shouldResume) {
      _startPlayback();
    }

    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (!isCurrentSeek()) return true;
    final actual = _logicalPlayerPosition(player.position);
    final drift = (actual - target).inMilliseconds.abs();
    _seekDbg(
      'seek fallback lock-cache reload verify target=$target '
      'sourceActual=${player.position} actual=$actual driftMs=$drift',
    );

    if (actual <= const Duration(milliseconds: 50)) {
      // 底层 position 仍可能卡 0，保持 UI 在用户拖动位置，后续由合成进度推进。
      _syntheticPositionFallbackActive = true;
      if (isCurrentSeek() && mounted) {
        state = state.copyWith(position: target);
      }
      _seekDbg(
        'seek fallback lock-cache reload position still zero, '
        'keep synthetic position target=$target',
      );
    }
    return true;
  }

  bool _isAppleHttpUrl(String? url) {
    if (url == null || url.isEmpty || kIsWeb) return false;
    return _isApplePlatform && url.startsWith('http://');
  }

  void _clearPendingSeek() {
    if (_pendingSeekPosition != null || _pendingSeekSongId != null) {
      _seekDbg(
        'clearPendingSeek pending=$_pendingSeekPosition pendingSong=$_pendingSeekSongId',
      );
    }
    _pendingSeekPosition = null;
    _pendingSeekSongId = null;
  }

  void _setStreamContext({
    required String songId,
    required String? format,
    required int? maxBitRate,
    required bool seekByReloadStream,
    Duration sourcePositionOffset = Duration.zero,
  }) {
    _currentStreamSongId = songId;
    _currentStreamFormat = format;
    _currentStreamMaxBitRate = maxBitRate;
    _seekByReloadStream = seekByReloadStream;
    _setSourcePositionOffset(sourcePositionOffset);
  }

  void _clearStreamContext() {
    _currentStreamSongId = null;
    _currentStreamFormat = null;
    _currentStreamMaxBitRate = null;
    _seekByReloadStream = false;
    _setSourcePositionOffset(Duration.zero);
  }

  void _setSourcePositionOffset(Duration offset) {
    final normalized = offset < Duration.zero ? Duration.zero : offset;
    if (_sourcePositionOffset == normalized) return;
    _sourcePositionOffset = normalized;
    _audioHandler?.setPositionOffset(normalized);
    _seekDbg('source timeline offset updated: $normalized');
  }

  Duration _logicalPlayerPosition(Duration sourcePosition) {
    return addPlaybackPositionOffset(
      sourcePosition,
      _sourcePositionOffset,
      maximum: state.duration > Duration.zero ? state.duration : null,
    );
  }

  Duration _sourceSeekPosition(Duration logicalPosition) {
    final sourcePosition = logicalPosition - _sourcePositionOffset;
    return sourcePosition < Duration.zero ? Duration.zero : sourcePosition;
  }

  String _withoutTimeOffset(String url) {
    final uri = Uri.parse(url);
    final query = Map<String, String>.from(uri.queryParameters)
      ..remove('timeOffset');
    return uri.replace(queryParameters: query).toString();
  }

  bool _isPlaybackContextCurrent({
    required int session,
    required String songId,
  }) {
    return mounted &&
        _playDebugSession == session &&
        _activePlaybackEntryId == state.currentEntryId &&
        state.currentSong?.id == songId;
  }

  void _invalidateLoadedSource({required String reason}) {
    _androidNativeQueue = null;
    _androidCurrentTrack = null;
    _androidNativeQueueLastCheck = null;
    _sourceGeneration += 1;
    _loadedSourceSongId = null;
    _loadedSourceEntryId = null;
    _healthySince = null;
    _bufferingSince = null;
    _playDbg('source invalidated generation=$_sourceGeneration reason=$reason');
  }

  Future<void> _setLocalAudioSource(
    AudioPlayer player,
    String path,
    AudioQualityLevel quality,
    PlaybackSource source,
  ) async {
    final entryId = state.currentEntryId;
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        entryId == null) {
      await player.setFilePath(path);
      return;
    }
    // Prepare the current file in an extensible native playlist. Upcoming
    // files are attached while this track is audible, before completion.
    final currentTrack = AndroidNativeQueueTrack(
      entryId: entryId,
      quality: quality,
      source: source,
    );
    final playlist = ConcatenatingAudioSource(
      children: [AudioSource.file(path, tag: currentTrack)],
    );
    _androidNativeQueue = playlist;
    _androidCurrentTrack = currentTrack;
    _androidNativeQueueLastCheck = null;
    _androidNativeSequenceSubscription ??= player.sequenceStateStream.listen(
      _onAndroidNativeSequence,
    );
    await player.setAudioSource(playlist);
  }

  void _onAndroidNativeSequence(SequenceState? sequence) {
    final playlist = _androidNativeQueue;
    final player = _audioPlayer;
    final track = sequence?.currentSource?.tag;
    if (!mounted ||
        playlist == null ||
        player == null ||
        _androidCurrentTrack == null ||
        _loadedSourceEntryId != state.currentEntryId ||
        !identical(player.audioSource, playlist) ||
        _replacingSourceGeneration != null ||
        track is! AndroidNativeQueueTrack ||
        identical(track, _androidCurrentTrack)) {
      return;
    }
    final tracks = playlist.children
        .cast<IndexedAudioSource>()
        .map((source) => source.tag as AndroidNativeQueueTrack)
        .toList();
    final fromIndex = tracks.indexOf(_androidCurrentTrack!);
    final toIndex = tracks.indexOf(track);
    if (fromIndex < 0 || toIndex <= fromIndex) return;
    final advanced = tracks.sublist(fromIndex + 1, toIndex + 1);
    final expected = androidNativeUpcomingEntries(
      state.playbackQueue,
      loopMode: state.loopMode,
      shuffleEnabled: state.shuffleEnabled,
      count: advanced.length,
    );
    // A queued platform event can arrive after the user edits the queue.
    // Never adopt a removed/reordered occurrence as the intended next track.
    if (!listEquals(
      expected.map((e) => e.entryId).toList(),
      advanced.map((t) => t.entryId).toList(),
    )) {
      Logger.warnWithTag(
        'PLAYBACK',
        'native_queue_stale entry=${track.entryId}',
      );
      final intendedId = state.loopMode == LoopMode.one
          ? state.currentEntryId
          : _peekNextEntryId();
      final intendedIndex = intendedId == null
          ? -1
          : state.playbackQueue.indexOfEntry(intendedId);
      if (intendedIndex < 0) {
        unawaited(stop());
      } else {
        unawaited(
          playSong(
            state.queue[intendedIndex],
            queue: state.queue,
            index: intendedIndex,
            autoPlay: _playbackRequested,
          ),
        );
      }
      return;
    }
    final previousSong = state.currentSong;
    final song = state.playbackQueue.entries[track.entryId]!.song;
    _androidCurrentTrack = track;
    _playDebugSession += 1;
    _sourceGeneration += 1;
    _activePlaybackEntryId = track.entryId;
    _loadedSourceEntryId = track.entryId;
    _loadedSourceSongId = song.id;
    _healthySince = null;
    _bufferingSince = null;
    _lastPolledPlayerPosition = Duration.zero;
    _stagnantPositionTicks = 0;
    _syntheticPositionFallbackActive = false;
    _currentStreamUrl = null;
    _invalidateSeekRequests();
    _clearPendingSeek();
    _clearStreamContext();
    _usingLockCachingSource = false;
    _isHandlingCompletion = false;
    _completionHandlingSongId = null;
    _completionHandlingEntryId = null;
    _clearCurrentPlaybackRetry(reason: 'play_song_started');
    _precacheStartedSession = null;
    _precacheTargetEntryId = null;
    _androidNativeQueueLastCheck = null;
    final duration = player.duration ?? Duration(seconds: song.duration ?? 0);
    state = state.copyWith(
      playbackQueue: state.playbackQueue.selectEntry(track.entryId),
      position: player.position,
      duration: duration,
      bufferedPosition: duration,
      isPlaying: player.playing,
      processingState: player.processingState,
      currentQuality: track.quality,
      playbackSource: track.source,
      currentBitRateKbps: _resolveCurrentBitRateKbps(
        song: song,
        quality: track.quality,
        source: track.source,
        maxBitRate: track.quality.maxBitRate,
      ),
    );
    _updateMediaItem(song);
    _scheduleSongRemoteRefresh(song, _playDebugSession);
    Logger.infoWithTag(
      'PLAYBACK',
      'native_auto_advance from=${previousSong?.id} song=${song.id} '
          'entry=${track.entryId} session=$_playDebugSession generation=$_sourceGeneration '
          'index=${state.currentIndex} source=${track.source.name}',
    );
    if (previousSong != null && !previousSong.isPreview) {
      unawaited(_scrobble(previousSong.id, submission: true));
    }
    // Dart may receive the latest cursor after more than one native handoff.
    // Acknowledge intermediate completions instead of replaying those tracks.
    for (final completed in advanced.take(advanced.length - 1)) {
      final completedSong =
          state.playbackQueue.entries[completed.entryId]!.song;
      if (!completedSong.isPreview) {
        unawaited(_scrobble(completedSong.id, submission: true));
      }
    }
    if (_playbackRequested && !song.isPreview) {
      unawaited(_scrobble(song.id, submission: false));
    }
    if (!_playbackRequested && player.playing) {
      unawaited(player.pause());
    }
    _preCacheNextSong();
  }

  Future<void> _refreshAndroidNativeQueue() async {
    final playlist = _androidNativeQueue;
    final player = _audioPlayer;
    final entryId = state.currentEntryId;
    if (!mounted ||
        playlist == null ||
        player == null ||
        entryId == null ||
        !identical(player.audioSource, playlist) ||
        _loadedSourceEntryId != entryId ||
        _replacingSourceGeneration != null) {
      return;
    }
    if (_androidNativeQueueUpdating) {
      return;
    }
    if (!_androidNativeQueueDirty &&
        _androidNativeQueueLastCheck != null &&
        _clock().difference(_androidNativeQueueLastCheck!) <
            const Duration(seconds: 5)) {
      return;
    }
    _androidNativeQueueUpdating = true;
    _androidNativeQueueDirty = false;
    _androidNativeQueueLastCheck = _clock();
    final generation = _sourceGeneration;
    final queue = state.playbackQueue;
    final loopMode = state.loopMode;
    final shuffleEnabled = state.shuffleEnabled;
    bool ownsQueue() =>
        mounted &&
        identical(_androidNativeQueue, playlist) &&
        identical(player.audioSource, playlist) &&
        _sourceGeneration == generation &&
        state.currentEntryId == entryId &&
        state.playbackQueue.revision == queue.revision &&
        state.loopMode == loopMode &&
        state.shuffleEnabled == shuffleEnabled;
    try {
      final quality = _ref.read(effectiveQualityProvider);
      final libraryId = _currentPlaybackLibraryId ?? '';
      final downloads = _ref.read(downloadServiceProvider);
      final cache = _ref.read(audioCacheServiceProvider);
      final upcoming = <IndexedAudioSource>[];
      for (final entry in androidNativeUpcomingEntries(
        queue,
        loopMode: loopMode,
        shuffleEnabled: shuffleEnabled,
      )) {
        if (entry.song.isPreview) break;
        var path = await downloads.getDownloadedPath(entry.song.id, libraryId);
        var source = PlaybackSource.downloaded;
        var nextQuality = AudioQualityLevel.original;
        if (path == null || !fileExistsSync(path)) {
          path = await cache.getCachedPath(
            songId: entry.song.id,
            libraryId: libraryId,
            quality: quality,
          );
          source = PlaybackSource.cached;
          nextQuality = quality;
        }
        if (!ownsQueue()) return;
        // Do not skip an unavailable next track or put a Dart HTTP proxy into
        // the native handoff. Prefetch can make it available on a later check.
        if (path == null || !fileExistsSync(path)) break;
        upcoming.add(
          AudioSource.file(
            path,
            tag: AndroidNativeQueueTrack(
              entryId: entry.entryId,
              quality: nextQuality,
              source: source,
            ),
          ),
        );
      }
      if (!ownsQueue()) return;
      var index = player.currentIndex ?? 0;
      if (index < 0 || index >= playlist.children.length) return;
      var common = 0;
      while (index + 1 + common < playlist.children.length &&
          common < upcoming.length) {
        final existing =
            (playlist.children[index + 1 + common] as IndexedAudioSource).tag;
        final desired = upcoming[common].tag as AndroidNativeQueueTrack;
        if (existing is! AndroidNativeQueueTrack ||
            existing.entryId != desired.entryId ||
            existing.quality != desired.quality ||
            existing.source != desired.source) {
          break;
        }
        common += 1;
      }
      final removeFrom = index + 1 + common;
      if (removeFrom < playlist.children.length) {
        await playlist.removeRange(removeFrom, playlist.children.length);
      }
      if (!ownsQueue()) return;
      if (common < upcoming.length) {
        await playlist.addAll(upcoming.skip(common).toList());
      }
      if (!ownsQueue()) return;
      // Keep one previous track and two upcoming tracks; a 1654-song app queue
      // must not create 1654 native decoders/media sources.
      index = player.currentIndex ?? 0;
      if (index > 1) await playlist.removeRange(0, index - 1);
      if (!ownsQueue()) return;
      Logger.infoWithTag(
        'PLAYBACK',
        'native_queue_prepared entry=$entryId '
            'upcoming=${upcoming.map((s) => (s.tag as AndroidNativeQueueTrack).entryId).join(',')} '
            'sources=${playlist.children.length} generation=$generation',
      );
    } catch (error) {
      Logger.warnWithTag(
        'PLAYBACK',
        'native_queue_prepare_failed ${playbackErrorSummary(error)}',
      );
    } finally {
      _androidNativeQueueUpdating = false;
      if (mounted &&
          (_androidNativeQueueDirty ||
              !identical(_androidNativeQueue, playlist))) {
        unawaited(_refreshAndroidNativeQueue());
      }
    }
  }

  void _capturePlaybackDiagnostics(String reason) {
    unawaited(
      _wakeGuard.capture(
        reason: reason,
        context:
            'song=${state.currentSong?.id} entry=${state.currentEntryId} '
            'session=$_playDebugSession generation=$_sourceGeneration '
            'state=${_audioPlayer?.processingState.name} nativePlaying=${_audioPlayer?.playing} '
            'intent=$_playbackRequested replacing=$_replacingSourceGeneration '
            'pendingRetry=$_retryCurrentPlaybackOnReconnect retrying=$_retryingCurrentPlayback '
            'network=${_lastObservedNetworkType.name} '
            'lifecycle=${WidgetsBinding.instance.lifecycleState?.name}',
      ),
    );
  }

  Future<bool> _replaceLoadedSource({
    required String songId,
    required String label,
    required bool Function() ownsSource,
    required Future<void> Function(AudioPlayer player) setSource,
  }) async {
    final player = _audioPlayer;
    if (player == null || !ownsSource()) {
      _playDbg('source=$label setup abandoned before load song=$songId');
      return false;
    }

    final previousSource = player.audioSource;
    final previousSongId = _loadedSourceSongId;
    final previousEntryId = _loadedSourceEntryId;
    final previousPosition = player.position;
    final previousLogicalPosition = _logicalPlayerPosition(previousPosition);
    final generation = ++_sourceGeneration;
    _loadedSourceSongId = null;
    _loadedSourceEntryId = null;
    _replacingSourceGeneration = generation;
    state = state.copyWith(isChangingSource: true, hasPlaybackError: false);
    _audioHandler?.beginSourceTransition(
      generation,
      playing: _playbackRequested,
    );
    final loadElapsed = Stopwatch()..start();
    final loadStartedAt = _clock();
    // Android monotonic timers can exclude suspend; wall time exposes that gap.
    int wallElapsedMs() => _clock().difference(loadStartedAt).inMilliseconds;
    String loadPhase = 'pause';
    final loadWatchdog = Timer(const Duration(seconds: 10), () {
      if (_sourceGeneration != generation || !ownsSource()) return;
      Logger.warnWithTag(
        'PLAYBACK',
        'load_waiting source=$label song=$songId generation=$generation '
            'phase=$loadPhase elapsedMs=${wallElapsedMs()} monotonicMs=${loadElapsed.elapsedMilliseconds} '
            'timeoutMs=30000',
      );
      _capturePlaybackDiagnostics('load_waiting');
    });
    _capturePlaybackDiagnostics('load_begin');
    _playDbg('source=$label load begin song=$songId generation=$generation');
    Logger.infoWithTag(
      'PLAYBACK',
      'load begin source=$label song=$songId generation=$generation',
    );

    try {
      // Keep playWhenReady off until the new source's logical seek is applied.
      // The service remains playing/loading through the transition above.
      await player.pause();
      loadPhase = 'loop_mode';
      await player.setLoopMode(LoopMode.off);
      _nativeLoopMode = LoopMode.off;
      if (_sourceGeneration != generation || !ownsSource()) return false;
      loadPhase = 'set_source';
      await setSource(player).timeout(const Duration(seconds: 30));
    } catch (error) {
      Logger.warnWithTag(
        'PLAYBACK',
        'load failed source=$label song=$songId generation=$generation '
            'phase=$loadPhase elapsedMs=${wallElapsedMs()} monotonicMs=${loadElapsed.elapsedMilliseconds} '
            '${playbackErrorSummary(error)}',
      );
      _capturePlaybackDiagnostics('load_failed');
      if (_sourceGeneration != generation || !ownsSource()) return false;
      _loadedSourceSongId = null;
      _loadedSourceEntryId = null;
      if (error is TimeoutException) {
        await player.stop(); // cancel the native load as well as the Dart wait
      }
      if (_sourceGeneration != generation || !ownsSource()) return false;
      if (label.startsWith('seek_') &&
          previousSource != null &&
          previousSongId == songId) {
        var restored = false;
        try {
          await player
              .setAudioSource(previousSource, initialPosition: previousPosition)
              .timeout(const Duration(seconds: 30));
          if (_sourceGeneration != generation || !ownsSource()) return false;
          _loadedSourceSongId = songId;
          _loadedSourceEntryId = previousEntryId;
          _syntheticPositionFallbackActive = false;
          state = state.copyWith(position: previousLogicalPosition);
          if (_playbackRequested) _startPlayback(fadeIn: false);
          restored = true;
          Logger.infoWithTag(
            'PLAYBACK_RECOVERY',
            'seek rollback restored song=$songId positionMs=${previousLogicalPosition.inMilliseconds}',
          );
        } catch (rollbackError) {
          if (_sourceGeneration != generation || !ownsSource()) return false;
          if (rollbackError is TimeoutException) await player.stop();
          Logger.warnWithTag(
            'PLAYBACK_RECOVERY',
            'seek rollback failed song=$songId type=${rollbackError.runtimeType}',
          );
          _scheduleCurrentPlaybackRetry(
            song: state.currentSong!,
            isPreview: state.currentSong!.isPreview,
            autoPlay: _playbackRequested,
            position: previousLogicalPosition,
          );
        }
        if (restored) throw _SeekSourceRestored();
      }
      rethrow;
    } finally {
      loadWatchdog.cancel();
      if (_replacingSourceGeneration == generation) {
        _replacingSourceGeneration = null;
        if (mounted) state = state.copyWith(isChangingSource: false);
      }
      _audioHandler?.endSourceTransition(generation);
      Logger.infoWithTag(
        'PLAYBACK',
        'load_end source=$label song=$songId generation=$generation '
            'elapsedMs=${wallElapsedMs()} monotonicMs=${loadElapsed.elapsedMilliseconds} '
            'currentGeneration=$_sourceGeneration state=${player.processingState.name}',
      );
      _capturePlaybackDiagnostics('load_end');
    }

    if (_sourceGeneration != generation ||
        !ownsSource() ||
        player.audioSource == null) {
      _playDbg(
        'source=$label load abandoned song=$songId generation=$generation '
        'currentGeneration=$_sourceGeneration',
      );
      return false;
    }

    _loadedSourceSongId = songId;
    _loadedSourceEntryId = _activePlaybackEntryId;
    _playDbg('source=$label load ready song=$songId generation=$generation');
    Logger.infoWithTag(
      'PLAYBACK',
      'load ready source=$label song=$songId generation=$generation',
    );
    return true;
  }

  void _replaceDownloadProgressSubscription(StreamSubscription? next) {
    final previous = _downloadProgressSubscription;
    _downloadProgressSubscription = next;
    if (previous != null && !identical(previous, next)) {
      unawaited(previous.cancel());
    }
  }

  void _invalidateSeekRequests() {
    _seekRequestGeneration += 1;
    _activeSeekGeneration = null;
    _activeSeekSongId = null;
    _seekAwaitingReady = false;
    if (mounted) state = state.copyWith(isSeeking: false);
  }

  bool _isSeekRequestCurrent({
    required int seekGeneration,
    required int playbackSession,
    required String songId,
  }) {
    return _seekRequestGeneration == seekGeneration &&
        _isPlaybackContextCurrent(session: playbackSession, songId: songId);
  }

  void _releaseSeekAnchor(int seekGeneration) {
    if (_activeSeekGeneration != seekGeneration) return;
    if (mounted &&
        seekGeneration == _seekRequestGeneration &&
        _activeSeekSongId == state.currentSong?.id &&
        (_audioPlayer?.processingState == ProcessingState.buffering ||
            _audioPlayer?.processingState == ProcessingState.loading)) {
      _seekAwaitingReady = true;
      return;
    }
    _activeSeekGeneration = null;
    _activeSeekSongId = null;
    _seekAwaitingReady = false;
    if (mounted) {
      state = state.copyWith(isSeeking: _shouldPreserveSeekPosition());
    }
  }

  void _schedulePendingSeekIfReady() {
    if (!mounted || _isApplyingPendingSeek) return;
    final player = _audioPlayer;
    final currentSongId = state.currentSong?.id;
    if (player == null || currentSongId == null) return;
    if (!shouldPreservePendingSeekPosition(
      pendingPosition: _pendingSeekPosition,
      pendingSongId: _pendingSeekSongId,
      currentSongId: currentSongId,
    )) {
      return;
    }
    if (!canSeekLoadedPlayerSource(
      processingState: player.processingState,
      loadedSourceSongId: _loadedSourceSongId,
      currentSongId: currentSongId,
    )) {
      return;
    }
    unawaited(_applyPendingSeekIfNeeded());
  }

  bool _shouldPreserveSeekPosition() {
    final currentSongId = state.currentSong?.id;
    return shouldPreservePendingSeekPosition(
          pendingPosition: _pendingSeekPosition,
          pendingSongId: _pendingSeekSongId,
          currentSongId: currentSongId,
        ) ||
        (_activeSeekGeneration == _seekRequestGeneration &&
            _activeSeekSongId != null &&
            _activeSeekSongId == currentSongId);
  }

  void _startPositionPolling(AudioPlayer player) {
    _positionPollTimer?.cancel();
    _positionPollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      if (state.currentSong == null) return;
      _preCacheNextSong();
      final now = _clock();
      final previousPoll = _lastPollAt;
      final wasBackground = _lastPollWasBackground;
      final wasRequested = _lastPollRequestedPlayback;
      _lastPollAt = now;
      _lastPollRequestedPlayback = _playbackRequested;
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      _lastPollWasBackground =
          lifecycle == AppLifecycleState.paused ||
          lifecycle == AppLifecycleState.hidden;
      if (_playbackRequested &&
          wasRequested &&
          previousPoll != null &&
          now.difference(previousPoll) > const Duration(seconds: 3)) {
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
          BackgroundPlaybackAdvisor.instance.recordGap(
            gap: now.difference(previousPoll),
            wasBackground: wasBackground,
          );
        }
        Logger.warnWithTag(
          'PLAYBACK',
          'event_loop_gap ms=${now.difference(previousPoll).inMilliseconds} song=${state.currentSong?.id} state=${player.processingState.name}',
        );
      }
      if (_playbackRequested &&
          player.processingState == ProcessingState.buffering &&
          _replacingSourceGeneration == null) {
        _healthySince = null;
        _bufferingSince ??= now;
        if (now.difference(_bufferingSince!) >= const Duration(seconds: 30)) {
          _handlePlaybackFailure(
            'buffering_timeout',
            TimeoutException('buffering'),
          );
          _bufferingSince = now;
        }
      } else {
        _bufferingSince = null;
        if (_playbackRequested &&
            player.playing &&
            player.processingState == ProcessingState.ready &&
            !_retryCurrentPlaybackOnReconnect &&
            !_retryingCurrentPlayback) {
          _healthySince ??= now;
          if (now.difference(_healthySince!) >= const Duration(seconds: 30)) {
            _recoveryAttempts = 0;
            _retryPosition = null;
          }
        } else {
          _healthySince = null;
        }
      }
      if (_shouldPreserveSeekPosition()) {
        return;
      }

      final sourcePlayerPos = player.position;
      final playerPos = _logicalPlayerPosition(sourcePlayerPos);
      final processing = player.processingState;
      final isReadyPlaying =
          player.playing && processing == ProcessingState.ready;

      final deltaFromLast = (sourcePlayerPos - _lastPolledPlayerPosition)
          .inMilliseconds
          .abs();
      if (deltaFromLast <= 150) {
        _stagnantPositionTicks += 1;
      } else {
        _stagnantPositionTicks = 0;
      }
      _lastPolledPlayerPosition = sourcePlayerPos;

      // 正常情况下用底层播放器位置对齐 UI 进度。
      final drift = (playerPos - state.position).inMilliseconds.abs();
      final keepSyntheticProgress =
          _syntheticPositionFallbackActive &&
          _usingLockCachingSource &&
          isReadyPlaying &&
          sourcePlayerPos <= const Duration(milliseconds: 50);
      final preserveSyntheticPosition =
          _syntheticPositionFallbackActive &&
          _usingLockCachingSource &&
          state.position > const Duration(milliseconds: 250) &&
          (!isReadyPlaying ||
              playerPos + const Duration(seconds: 5) < state.position);

      if (drift >= 250 &&
          !keepSyntheticProgress &&
          !preserveSyntheticPosition) {
        final canDeactivateSynthetic =
            _syntheticPositionFallbackActive &&
            isReadyPlaying &&
            sourcePlayerPos > Duration.zero &&
            drift <= 3000;
        if (canDeactivateSynthetic) {
          _syntheticPositionFallbackActive = false;
          _seekDbg('position fallback deactivated, player position recovered');
        }
        state = state.copyWith(position: playerPos);
        return;
      }
      if (drift >= 250 &&
          preserveSyntheticPosition &&
          _stagnantPositionTicks != _lastStagnantLogTick &&
          _stagnantPositionTicks % 6 == 0) {
        _playDbg(
          'position sync skipped to preserve synthetic '
          'sourcePlayerPos=$sourcePlayerPos playerPos=$playerPos '
          'statePos=${state.position} '
          'driftMs=$drift playing=${player.playing} '
          'processing=${processing.name} song=${state.currentSong?.id}',
        );
      }
      if (drift >= 250 &&
          keepSyntheticProgress &&
          _stagnantPositionTicks != _lastStagnantLogTick &&
          _stagnantPositionTicks % 6 == 0) {
        _playDbg(
          'position drift sync skipped while synthetic active '
          'sourcePlayerPos=$sourcePlayerPos playerPos=$playerPos '
          'statePos=${state.position} '
          'driftMs=$drift song=${state.currentSong?.id}',
        );
      }

      // iOS + LockCachingAudioSource 某些流上 position 可能卡在 0。
      // 当确认持续卡住时，按时间片推进 UI 进度，避免进度条一直 0:00。
      final shouldUseSyntheticPosition =
          _usingLockCachingSource &&
          isReadyPlaying &&
          sourcePlayerPos <= const Duration(milliseconds: 50) &&
          state.duration > Duration.zero &&
          _stagnantPositionTicks >= 6;
      if (shouldUseSyntheticPosition &&
          _stagnantPositionTicks != _lastStagnantLogTick &&
          _stagnantPositionTicks % 6 == 0) {
        _lastStagnantLogTick = _stagnantPositionTicks;
        _playDbg(
          'position_stagnant ticks=$_stagnantPositionTicks '
          'sourcePlayerPos=$sourcePlayerPos playerPos=$playerPos '
          'statePos=${state.position} '
          'buffered=${player.bufferedPosition} duration=${state.duration} '
          'processing=${processing.name} playing=${player.playing} '
          'song=${state.currentSong?.id} '
          'format=$_currentStreamFormat maxBitRate=$_currentStreamMaxBitRate '
          'stream=${_summarizeStreamUrl(_currentStreamUrl)}',
        );
      }
      if (!shouldUseSyntheticPosition) return;

      final next = _normalizeSeekPosition(
        state.position + const Duration(milliseconds: 500),
      );
      if (next <= state.position) return;

      if (!_syntheticPositionFallbackActive) {
        _syntheticPositionFallbackActive = true;
        _seekDbg(
          'position fallback activated for lock_cache source '
          'song=${state.currentSong?.id}',
        );
      }
      state = state.copyWith(position: next);
    });
  }

  void _seekDbg(String message) {
    Logger.info('[SEEKDBG] $message');
  }

  void _playDbg(String message) {
    Logger.infoWithTag(_playDbgTag, message);
  }

  String _summarizeStreamUrl(String? url) {
    if (url == null || url.isEmpty) return 'none';
    try {
      final uri = Uri.parse(url);
      final host = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
      final q = uri.queryParameters;
      final id = q['id'] ?? '-';
      final format = q['format'] ?? '-';
      final maxBitRate = q['maxBitRate'] ?? '-';
      final timeOffset = q['timeOffset'] ?? '-';
      return '${uri.scheme}://$host${uri.path} '
          'id=$id format=$format maxBitRate=$maxBitRate timeOffset=$timeOffset';
    } catch (_) {
      return 'invalid_url';
    }
  }

  /// 从缓存文件注册缓存元数据（downloadProgressStream 到 1.0 时调用）
  Future<void> _registerCacheFromFile(
    String cacheFilePath,
    String songId,
    String libraryId,
    AudioQualityLevel quality,
  ) => _cacheHandler.registerCacheFromFile(
    cacheFilePath,
    songId,
    libraryId,
    quality,
  );

  /// Only prefetch once the current song has a useful buffer. Downloads use a
  /// separate cancellable file, so a next/seek cannot race the playing cache.
  void _preCacheNextSong() {
    unawaited(_refreshAndroidNativeQueue());
    final nextEntryId = _peekNextEntryId();
    if (!_playbackRequested ||
        _loadedSourceSongId != state.currentSong?.id ||
        nextEntryId == null ||
        (_precacheStartedSession == _playDebugSession &&
            _precacheTargetEntryId == nextEntryId) ||
        _retryCurrentPlaybackOnReconnect ||
        _retryingCurrentPlayback ||
        state.currentSong?.isPreview == true) {
      return;
    }
    final enoughBuffered =
        state.playbackSource == PlaybackSource.cached ||
        state.playbackSource == PlaybackSource.downloaded ||
        (state.duration > Duration.zero &&
            state.bufferedPosition >= state.duration) ||
        state.bufferedPosition - state.position >= const Duration(seconds: 30);
    if (!enoughBuffered) return;
    _precacheStartedSession = _playDebugSession;
    _precacheTargetEntryId = nextEntryId;
    unawaited(
      _cacheHandler.preCacheNextSong(
        state: state,
        needsTranscoding: _needsTranscoding,
        seekDbg: _seekDbg,
      ),
    );
  }

  String? _peekNextEntryId() {
    if (state.loopMode == LoopMode.one || state.currentIndex < 0) return null;
    final nextIndex = state.currentIndex + 1;
    if (nextIndex < state.queueEntryIds.length) {
      return state.queueEntryIds[nextIndex];
    }
    if (state.shuffleEnabled ||
        state.loopMode == LoopMode.off ||
        state.queueEntryIds.isEmpty) {
      return null;
    }
    return state.queueEntryIds.first;
  }

  @override
  void dispose() {
    _androidNativeQueue = null;
    _androidCurrentTrack = null;
    _androidNativeSequenceSubscription?.cancel();
    _playbackSessionPersistTimer?.cancel();
    _playbackVolumePersistTimer?.cancel();
    unawaited(LocalStorage.setPlaybackVolume(state.userVolume));
    if (!_preservePlaybackSessionOnShutdown) {
      unawaited(_persistPlaybackSession());
    }
    _positionPollTimer?.cancel();
    _removeLinuxMprisStateListener?.call();
    _removeLinuxMprisStateListener = null;
    final mprisService = _linuxMprisService;
    _linuxMprisService = null;
    if (mprisService != null) unawaited(mprisService.dispose());
    _removeWindowsSmtcStateListener?.call();
    _removeWindowsSmtcStateListener = null;
    final windowsSmtcService = _windowsSmtcService;
    _windowsSmtcService = null;
    if (windowsSmtcService != null) {
      unawaited(windowsSmtcService.dispose());
    }
    unawaited(_wakeGuard.dispose());
    _cancelFade();
    _downloadProgressSubscription?.cancel();
    _networkTypeSubscription?.cancel();
    _routeSubscription?.close();
    _recoveryTimer?.cancel();
    unawaited(_cacheHandler.cancelPrecache());
    for (final subscription in _playerSubscriptions) {
      subscription.cancel();
    }
    // Check if initialized/assigned before disposing
    // Since it was 'late', we can't check.
    // Converting to nullable field:
    if (_audioHandler != null) {
      _audioHandler!.unbindCommands(this);
    } else {
      _audioPlayer?.dispose();
    }
    super.dispose();
  }
}
