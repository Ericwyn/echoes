import 'dart:async';
import 'dart:convert';
import 'package:echoes/core/services/playback_wake_guard.dart';
import 'package:echoes/core/utils/logger.dart';

import 'package:dio/dio.dart';
import 'package:echoes/core/network/address_pool.dart';
import 'package:echoes/core/services/audio_cache_service.dart';
import 'package:echoes/core/services/download_service.dart';
import 'package:echoes/data/models/audio_quality.dart';
import 'package:echoes/data/models/server_address.dart';
import 'package:echoes/data/repositories/music_repository.dart';
import 'package:echoes/data/sources/subsonic_api_client.dart';
import 'package:echoes/data/sources/local_storage.dart';
import 'package:echoes/providers/audio_cache_provider.dart';
import 'package:echoes/providers/audio_quality_provider.dart';
import 'package:echoes/providers/auth_provider.dart';
import 'package:echoes/providers/download_provider.dart';
import 'package:echoes/providers/music_provider.dart';
import 'package:echoes/core/network/connectivity_monitor.dart';
import 'package:echoes/data/models/song.dart';
import 'package:echoes/providers/api_provider.dart';
import 'package:echoes/providers/crossfade_provider.dart';
import 'package:echoes/providers/player_provider.dart';
import 'package:echoes/providers/player/playback_queue_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as audio;
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockPlayer extends Mock implements audio.AudioPlayer {}

class RecordingWakeGuard extends PlaybackWakeGuard {
  RecordingWakeGuard() : super(enabled: false);
  final calls = <bool>[];
  final snapshots = <String>[];

  @override
  Future<void> capture({required String reason, String context = ''}) async {
    snapshots.add(reason);
  }

  @override
  Future<void> setActive(bool active, {required String reason}) async {
    calls.add(active);
  }
}

class MockConnectivity extends Mock implements ConnectivityMonitor {}

class MockCache extends Mock implements AudioCacheService {}

class MockDownloads extends Mock implements DownloadService {}

class MockApi extends Mock implements SubsonicApiClient {}

class MockPool extends Mock implements AddressPool {}

class MockMusic extends Mock implements MusicRepository {}

class TestAuth extends StateNotifier<AuthState> implements AuthNotifier {
  TestAuth() : super(AuthState(isInitializing: false));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late MockPlayer engine;
  late ProviderContainer container;
  late PlayerNotifier notifier;
  late StreamController<audio.PlaybackEvent> errors;
  late StreamController<audio.PlayerState> states;
  late StreamController<bool> playingEvents;
  late bool playing;
  late audio.ProcessingState processing;
  late Duration position;
  late audio.AudioSource? source;
  late int loads;
  late int plays;
  late List<double> volumeWrites;
  Completer<Duration?>? pendingLoad;
  final song = Song(
    id: 'preview',
    title: 'Preview',
    duration: 120,
    isPreview: true,
    previewStreamUrl: 'https://example.invalid/audio.mp3',
  );

  setUpAll(() {
    registerFallbackValue(Duration.zero);
    registerFallbackValue(AudioQualityLevel.standard);
    registerFallbackValue(audio.LoopMode.off);
    registerFallbackValue(
      audio.AudioSource.uri(Uri.parse('https://example.invalid')),
    );
  });

  void createFixture({
    DateTime Function()? clock,
    PlaybackWakeGuard? wakeGuard,
    bool restoreSession = false,
    Map<String, Object> initialPreferences = const <String, Object>{},
  }) {
    SharedPreferences.setMockInitialValues(initialPreferences);
    engine = MockPlayer();
    final network = MockConnectivity();
    when(() => network.currentNetworkType).thenReturn(NetworkType.wifi);
    when(
      () => network.networkTypeStream,
    ).thenAnswer((_) => const Stream.empty());
    errors = StreamController<audio.PlaybackEvent>.broadcast(sync: true);
    states = StreamController<audio.PlayerState>.broadcast(sync: true);
    playingEvents = StreamController<bool>.broadcast(sync: true);
    playing = false;
    processing = audio.ProcessingState.ready;
    position = Duration.zero;
    source = null;
    loads = 0;
    plays = 0;
    volumeWrites = <double>[];
    pendingLoad = null;
    when(() => engine.playbackEventStream).thenAnswer((_) => errors.stream);
    when(
      () => engine.positionDiscontinuityStream,
    ).thenAnswer((_) => const Stream.empty());
    when(() => engine.playerStateStream).thenAnswer((_) => states.stream);
    when(() => engine.playingStream).thenAnswer((_) => playingEvents.stream);
    when(() => engine.positionStream).thenAnswer((_) => const Stream.empty());
    when(
      () => engine.bufferedPositionStream,
    ).thenAnswer((_) => const Stream.empty());
    when(() => engine.durationStream).thenAnswer((_) => const Stream.empty());
    when(
      () => engine.shuffleModeEnabledStream,
    ).thenAnswer((_) => const Stream.empty());
    when(() => engine.playing).thenAnswer((_) => playing);
    when(() => engine.processingState).thenAnswer((_) => processing);
    when(() => engine.position).thenAnswer((_) => position);
    when(() => engine.bufferedPosition).thenReturn(const Duration(seconds: 30));
    when(() => engine.duration).thenReturn(const Duration(seconds: 120));
    when(() => engine.audioSource).thenAnswer((_) => source);
    when(
      () => engine.setUrl(
        any(),
        headers: any(named: 'headers'),
        initialPosition: any(named: 'initialPosition'),
      ),
    ).thenAnswer((call) async {
      loads++;
      source = audio.AudioSource.uri(
        Uri.parse(call.positionalArguments.first as String),
      );
      position =
          call.namedArguments[#initialPosition] as Duration? ?? Duration.zero;
      return pendingLoad == null
          ? const Duration(seconds: 120)
          : pendingLoad!.future;
    });
    when(() => engine.play()).thenAnswer((_) async {
      playing = true;
      playingEvents.add(true);
      plays++;
    });
    when(() => engine.pause()).thenAnswer((_) async {
      playing = false;
      playingEvents.add(false);
    });
    when(() => engine.stop()).thenAnswer((_) async {
      playing = false;
    });
    when(() => engine.dispose()).thenAnswer((_) async {});
    when(() => engine.setVolume(any())).thenAnswer((call) async {
      volumeWrites.add(call.positionalArguments.first as double);
    });
    when(() => engine.setLoopMode(any())).thenAnswer((_) async {});
    when(() => engine.setShuffleModeEnabled(any())).thenAnswer((_) async {});
    when(() => engine.seek(any())).thenAnswer((call) async {
      position = call.positionalArguments.first as Duration;
    });
    final cache = MockCache();
    final downloads = MockDownloads();
    final api = MockApi();
    final pool = MockPool();
    final music = MockMusic();
    const route = ServerAddress(
      id: 'route',
      libraryId: 'library',
      label: 'Test',
      url: 'https://example.invalid',
      priority: 0,
      status: ServerAddressStatus.ok,
    );
    when(() => pool.activeAddress).thenReturn(route);
    when(() => pool.probeAll()).thenAnswer((_) async => route);
    when(() => api.dio).thenReturn(Dio(BaseOptions(baseUrl: route.url)));
    when(
      () => api.getStreamUrl(
        any(),
        maxBitRate: any(named: 'maxBitRate'),
        format: any(named: 'format'),
        timeOffset: any(named: 'timeOffset'),
      ),
    ).thenAnswer(
      (call) =>
          'https://example.invalid/audio?timeOffset=${call.namedArguments[#timeOffset] ?? 0}',
    );
    when(
      () => api.post(any(), queryParameters: any(named: 'queryParameters')),
    ).thenAnswer((_) async => {});
    when(() => music.getSong(any())).thenAnswer((_) async => null);
    when(
      () => downloads.getDownloadedPath(any(), any()),
    ).thenAnswer((_) async => null);
    when(
      () => cache.getCachedPath(
        songId: any(named: 'songId'),
        libraryId: any(named: 'libraryId'),
        quality: any(named: 'quality'),
      ),
    ).thenAnswer((_) async => null);
    container = ProviderContainer(
      overrides: [
        audioCacheServiceProvider.overrideWithValue(cache),
        downloadServiceProvider.overrideWithValue(downloads),
        subsonicApiClientProvider.overrideWithValue(api),
        addressPoolProvider.overrideWithValue(pool),
        musicRepositoryProvider.overrideWithValue(music),
        authStateProvider.overrideWith((_) => TestAuth()),
        effectiveQualityProvider.overrideWithValue(AudioQualityLevel.standard),
        connectivityMonitorProvider.overrideWithValue(network),
        playerProvider.overrideWith(
          (ref) => PlayerNotifier(
            ref,
            player: engine,
            restoreSession: restoreSession,
            clock: clock,
            wakeGuard: wakeGuard ?? PlaybackWakeGuard(enabled: false),
          ),
        ),
      ],
    );
    notifier = container.read(playerProvider.notifier);
  }

  tearDown(() async {
    await playingEvents.close();
    await errors.close();
    await states.close();
  });

  void playbackTest(
    String description,
    Future<void> Function(WidgetTester) body,
  ) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        container.dispose();
        await tester.pump();
      }
    });
  }

  testWidgets(
    'desktop exit preserves the last position through stop and dispose',
    (tester) async {
      createFixture();
      var disposed = false;
      try {
        await notifier.initialized;
        final initial = notifier.playSong(song);
        await tester.pump();
        await initial;
        notifier.state = notifier.state.copyWith(
          position: const Duration(seconds: 42),
        );

        when(() => engine.stop()).thenAnswer((_) async {
          playing = false;
          position = Duration.zero;
          notifier.state = notifier.state.copyWith(position: Duration.zero);
        });

        await notifier.stopForDesktopExit();
        container.dispose();
        disposed = true;
        await tester.pump();

        final savedSession = await LocalStorage.getPlaybackSession();
        expect(savedSession?['positionMs'], 42000);
        expect(savedSession?['entries'], isNotEmpty);
      } finally {
        if (!disposed) container.dispose();
        await tester.pump();
      }
    },
  );

  playbackTest('seek retry internal pause does not cancel playback intent', (
    tester,
  ) async {
    createFixture();
    await notifier.initialized;
    final initial = notifier.playSong(song);
    await tester.pump();
    await initial;
    position = const Duration(seconds: 12);
    var seeks = 0;
    when(() => engine.seek(any())).thenAnswer((call) async {
      if (++seeks > 1) position = call.positionalArguments.first as Duration;
    });
    final seek = notifier.seek(const Duration(seconds: 60));
    await tester.pump();
    expect(container.read(playerProvider).isLoading, isTrue);
    await notifier.togglePlayPause();
    await tester.pump(const Duration(milliseconds: 230));
    await tester.pump(const Duration(milliseconds: 130));
    await seek;
    expect(seeks, 2);
    expect(playing, isTrue);
    expect(position, const Duration(seconds: 60));
    expect(container.read(playerProvider).isLoading, isFalse);
  });

  playbackTest('buffering seek keeps target and does not retry prematurely', (
    tester,
  ) async {
    createFixture();
    await notifier.initialized;
    final initial = notifier.playSong(song);
    await tester.pump();
    await initial;
    position = const Duration(seconds: 12);
    when(() => engine.seek(any())).thenAnswer((_) async {
      processing = audio.ProcessingState.buffering;
      states.add(audio.PlayerState(playing, processing));
    });
    final seek = notifier.seek(const Duration(seconds: 60));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await seek;
    await tester.pump(const Duration(seconds: 2));
    expect(
      container.read(playerProvider).position,
      const Duration(seconds: 60),
    );
    expect(container.read(playerProvider).isLoading, isTrue);
    verify(() => engine.seek(any())).called(1);
    expect(loads, 1);
    position = const Duration(seconds: 60);
    processing = audio.ProcessingState.ready;
    states.add(audio.PlayerState(playing, processing));
    expect(container.read(playerProvider).isLoading, isFalse);
    expect(playing, isTrue);
  });

  playbackTest('slow source diagnostics observe without restarting playback', (
    tester,
  ) async {
    final guard = RecordingWakeGuard();
    createFixture(wakeGuard: guard);
    await notifier.initialized;
    pendingLoad = Completer<Duration?>();
    Logger.clearBuffer();
    final load = notifier.playSong(song);
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(loads, 1);
    expect(playing, isFalse);
    expect(guard.calls, [true]);
    expect(guard.snapshots, containsAll(['load_begin', 'load_waiting']));
    expect(Logger.exportLogs(), contains('phase=set_source'));
    pendingLoad!.complete(const Duration(seconds: 120));
    await tester.pump();
    await load;
    expect(guard.snapshots, contains('load_end'));
    expect(playing, isTrue);
    final count = guard.snapshots.length;
    await tester.pump(const Duration(seconds: 11));
    expect(guard.snapshots.length, count);
  });

  playbackTest('resume during transcoded seek does not reload from zero', (
    tester,
  ) async {
    createFixture();
    await notifier.initialized;
    final regular = Song(
      id: 'normal',
      title: 'Normal',
      suffix: 'mp3',
      bitRate: 320,
      duration: 120,
    );
    final initial = notifier.playSong(regular);
    await tester.pump();
    await initial;
    position = const Duration(seconds: 12);
    pendingLoad = Completer<Duration?>();
    final seek = notifier.seek(const Duration(seconds: 60));
    await tester.pump();
    expect(playing, isFalse);
    expect(container.read(playerProvider).isLoading, isTrue);
    expect(
      container.read(playerProvider).position,
      const Duration(seconds: 60),
    );
    await notifier.play();
    expect(loads, 2);
    pendingLoad!.complete(const Duration(seconds: 60));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await seek;
    expect(loads, 2);
    expect(playing, isTrue);
    expect(container.read(playerProvider).isLoading, isFalse);
    expect(
      container.read(playerProvider).position,
      const Duration(seconds: 60),
    );
    expect(
      (source as audio.UriAudioSource).uri.queryParameters['timeOffset'],
      '60',
    );
  });

  playbackTest('pause during seek retry remains paused after seek completes', (
    tester,
  ) async {
    createFixture();
    await notifier.initialized;
    final initial = notifier.playSong(song);
    await tester.pump();
    await initial;
    final seek = notifier.seek(const Duration(seconds: 60));
    await tester.pump();
    await notifier.pause();
    await tester.pump(const Duration(milliseconds: 300));
    await seek;
    expect(playing, isFalse);
    expect(container.read(playerProvider).isLoading, isFalse);
    expect(position, const Duration(seconds: 60));
  });

  playbackTest('buffering failure recovers at the requested lyric position', (
    tester,
  ) async {
    createFixture();
    await notifier.initialized;
    final initial = notifier.playSong(song);
    await tester.pump();
    await initial;
    position = const Duration(seconds: 12);
    when(() => engine.seek(any())).thenAnswer((_) async {
      processing = audio.ProcessingState.buffering;
      states.add(audio.PlayerState(playing, processing));
    });
    final seek = notifier.seek(const Duration(seconds: 60));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await seek;
    errors.addError(audio.PlayerException(0, 'range request failed'));
    processing = audio.ProcessingState.ready;
    when(() => engine.seek(any())).thenAnswer((call) async {
      position = call.positionalArguments.first as Duration;
    });
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 300));
    states.add(audio.PlayerState(playing, processing));
    expect(loads, 2);
    expect(position, const Duration(seconds: 60));
    expect(playing, isTrue);
    expect(container.read(playerProvider).isLoading, isFalse);
  });

  playbackTest('external pause during a seek is not treated as internal', (
    tester,
  ) async {
    createFixture();
    await notifier.initialized;
    final initial = notifier.playSong(song);
    await tester.pump();
    await initial;
    final seek = notifier.seek(const Duration(seconds: 60));
    await tester.pump();
    playing = false;
    playingEvents.add(false);
    await tester.pump(const Duration(milliseconds: 300));
    await seek;
    expect(playing, isFalse);
    expect(plays, 1);
    expect(container.read(playerProvider).isLoading, isFalse);
  });

  playbackTest('latest lyric seek during initial loading wins', (tester) async {
    createFixture();
    await notifier.initialized;
    pendingLoad = Completer<Duration?>();
    final initial = notifier.playSong(song);
    await tester.pump();
    await notifier.seek(const Duration(seconds: 30));
    await notifier.seek(const Duration(seconds: 75));
    expect(container.read(playerProvider).isLoading, isTrue);
    expect(
      container.read(playerProvider).position,
      const Duration(seconds: 75),
    );
    pendingLoad!.complete(const Duration(seconds: 120));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await initial;
    expect(position, const Duration(seconds: 75));
    expect(container.read(playerProvider).isLoading, isFalse);
    expect(playing, isTrue);
    expect(loads, 1);
  });

  playbackTest(
    'stream failure retries on unchanged Wi-Fi and restores position',
    (tester) async {
      createFixture();
      await notifier.initialized;
      final initial = notifier.playSong(song);
      await tester.pump();
      await initial;
      position = const Duration(seconds: 12);
      errors.addError(audio.PlayerException(0, 'connection lost'));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 300));
      expect(loads, 2);
      expect(position, const Duration(seconds: 12));
      expect(playing, isTrue);
    },
  );

  playbackTest('runtime failures have a bounded retry budget', (tester) async {
    createFixture();
    await notifier.initialized;
    final initial = notifier.playSong(song);
    await tester.pump();
    await initial;
    for (var attempt = 0; attempt < 5; attempt++) {
      errors.addError(audio.PlayerException(0, 'connection lost'));
      await tester.pump(Duration(seconds: 2 << attempt));
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(loads, 5); // initial load plus four recoveries
    expect(playing, isFalse);
    states.add(audio.PlayerState(false, audio.ProcessingState.buffering));
    expect(container.read(playerProvider).hasPlaybackError, isTrue);
    expect(container.read(playerProvider).isLoading, isFalse);
  });

  playbackTest('buffering watchdog retries after thirty seconds', (
    tester,
  ) async {
    createFixture(clock: () => tester.binding.clock.now());
    await notifier.initialized;
    final initial = notifier.playSong(song);
    await tester.pump();
    await initial;
    processing = audio.ProcessingState.buffering;
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 31));
    processing = audio.ProcessingState.ready;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 300));
    expect(loads, 2);
  });

  playbackTest(
    'failed transcoded seek reload restores the prior source and position',
    (tester) async {
      createFixture();
      await notifier.initialized;
      final regular = Song(
        id: 'normal',
        title: 'Normal',
        suffix: 'mp3',
        bitRate: 320,
        duration: 120,
      );
      final initial = notifier.playSong(regular);
      await tester.pump();
      await initial;
      position = const Duration(seconds: 12);
      final original = source;
      when(
        () => engine.setUrl(
          any(),
          initialPosition: any(named: 'initialPosition'),
        ),
      ).thenAnswer((_) async {
        source = audio.AudioSource.uri(
          Uri.parse('https://example.invalid/failed'),
        );
        throw audio.PlayerException(0, 'seek load failed');
      });
      when(
        () => engine.setAudioSource(
          any(),
          initialPosition: any(named: 'initialPosition'),
        ),
      ).thenAnswer((call) async {
        source = call.positionalArguments.first as audio.AudioSource;
        position = call.namedArguments[#initialPosition] as Duration;
        return const Duration(seconds: 120);
      });
      final seek = notifier.seek(const Duration(seconds: 60));
      await tester.pump();
      await seek;
      expect(source, same(original));
      expect(position, const Duration(seconds: 12));
      expect(
        container.read(playerProvider).position,
        const Duration(seconds: 12),
      );
      expect(playing, isTrue);
    },
  );

  playbackTest(
    'a failed recovery seek is not erased by a stale load-ready path',
    (tester) async {
      createFixture();
      await notifier.initialized;
      final initial = notifier.playSong(song);
      await tester.pump();
      await initial;
      position = const Duration(seconds: 12);
      when(
        () => engine.seek(any()),
      ).thenThrow(audio.PlayerException(0, 'seek failed'));
      errors.addError(audio.PlayerException(0, 'connection lost'));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(loads, 2);
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(loads, 3);
      expect(plays, 1);
    },
  );

  playbackTest('pause cancels a pending recovery', (tester) async {
    createFixture();
    await notifier.initialized;
    final initial = notifier.playSong(song);
    await tester.pump();
    await initial;
    errors.addError(audio.PlayerException(0, 'connection lost'));
    await notifier.pause();
    await tester.pump(const Duration(seconds: 20));
    expect(loads, 1);
    expect(playing, isFalse);
  });

  playbackTest('pause while loading is respected when the load completes', (
    tester,
  ) async {
    createFixture();
    await notifier.initialized;
    pendingLoad = Completer<Duration?>();
    final load = notifier.playSong(song);
    await tester.pump();
    await notifier.pause();
    pendingLoad!.complete(const Duration(seconds: 120));
    await load;
    expect(plays, 0);
    expect(playing, isFalse);
  });

  playbackTest(
    'old completion while replacing a source does not skip the new song',
    (tester) async {
      createFixture();
      await notifier.initialized;
      final initial = notifier.playSong(song);
      await tester.pump();
      await initial;
      final next = song.copyWith(
        id: 'next',
        previewStreamUrl: 'https://example.invalid/next.mp3',
      );
      pendingLoad = Completer<Duration?>();
      final load = notifier.playSong(next, queue: [song, next], index: 1);
      await tester.pump();
      states.add(audio.PlayerState(true, audio.ProcessingState.completed));
      await tester.pump();
      expect(loads, 2);
      expect(container.read(playerProvider).currentSong?.id, 'next');
      pendingLoad!.complete(const Duration(seconds: 120));
      await load;
    },
  );

  playbackTest('a late stop completion does not release a new playback lease', (
    tester,
  ) async {
    final guard = RecordingWakeGuard();
    createFixture(wakeGuard: guard);
    await notifier.initialized;
    final initial = notifier.playSong(song);
    await tester.pump();
    await initial;
    final pendingStop = Completer<void>();
    when(() => engine.stop()).thenAnswer((_) => pendingStop.future);
    final stop = notifier.stop();
    expect(guard.calls.last, isFalse);
    final nextPlay = notifier.playSong(song);
    await tester.pump();
    await nextPlay;
    expect(guard.calls.last, isTrue);
    pendingStop.complete();
    await stop;
    expect(guard.calls.last, isTrue);
  });

  playbackTest('repeat one reuses a full source without a network reload', (
    tester,
  ) async {
    createFixture();
    await notifier.initialized;
    final initial = notifier.playSong(song);
    await tester.pump();
    await initial;
    await notifier.setPlaybackMode(PlaybackMode.repeatOne, persist: false);
    states.add(audio.PlayerState(true, audio.ProcessingState.completed));
    await tester.pump();
    expect(loads, 1);
    verify(() => engine.setLoopMode(audio.LoopMode.one)).called(1);
    verify(() => engine.seek(Duration.zero)).called(1);
    expect(container.read(playerProvider).currentSong?.id, song.id);
  });

  playbackTest('sequential mode advances, then stops at the last song', (
    tester,
  ) async {
    createFixture();
    await notifier.initialized;
    final first = song.copyWith(id: 'first');
    final last = song.copyWith(id: 'last');
    await notifier.playQueue(<Song>[first, last]);
    await notifier.setPlaybackMode(PlaybackMode.sequential, persist: false);

    states.add(audio.PlayerState(true, audio.ProcessingState.completed));
    await tester.pump();
    expect(container.read(playerProvider).currentSong?.id, last.id);
    expect(container.read(playerProvider).currentIndex, 1);
    expect(playing, isTrue);

    states.add(audio.PlayerState(true, audio.ProcessingState.completed));
    await tester.pump();
    final ended = container.read(playerProvider);
    expect(ended.currentSong?.id, last.id);
    expect(ended.currentIndex, 1);
    expect(ended.hasNext, isFalse);
    expect(ended.isPlaying, isFalse);
    expect(playing, isFalse);
    expect(loads, 2);
  });

  playbackTest('play queue clamps the requested starting index', (
    tester,
  ) async {
    createFixture();
    await notifier.initialized;
    final first = song.copyWith(id: 'first');
    final last = song.copyWith(id: 'last');
    final songs = <Song>[first, last];

    await notifier.playQueue(songs, startIndex: -5);
    expect(container.read(playerProvider).currentSong?.id, first.id);
    expect(container.read(playerProvider).currentIndex, 0);

    await notifier.playQueue(songs, startIndex: songs.length + 4);
    expect(container.read(playerProvider).currentSong?.id, last.id);
    expect(container.read(playerProvider).currentIndex, 1);
  });

  playbackTest('sequential single-item queue stops and can replay', (
    tester,
  ) async {
    createFixture();
    await notifier.initialized;
    await notifier.setPlaybackMode(PlaybackMode.sequential, persist: false);
    await notifier.playSong(song);
    clearInteractions(engine);

    states.add(audio.PlayerState(true, audio.ProcessingState.completed));
    await tester.pump();
    expect(container.read(playerProvider).hasNext, isFalse);
    expect(playing, isFalse);
    verifyNever(() => engine.seek(Duration.zero));

    await notifier.play();
    expect(loads, 2);
    expect(playing, isTrue);
  });

  playbackTest('repeat-all mode wraps at the last song', (tester) async {
    createFixture();
    await notifier.initialized;
    final first = song.copyWith(id: 'first');
    final last = song.copyWith(id: 'last');
    await notifier.playQueue(<Song>[first, last], startIndex: 1);
    await notifier.setPlaybackMode(PlaybackMode.repeatAll, persist: false);

    states.add(audio.PlayerState(true, audio.ProcessingState.completed));
    await tester.pump();
    expect(container.read(playerProvider).currentSong?.id, first.id);
    expect(container.read(playerProvider).currentIndex, 0);
    expect(playing, isTrue);
  });

  playbackTest('sequential mode survives session restoration', (tester) async {
    var id = 0;
    final queue = PlaybackQueueState.fromSongs(
      <Song>[song.copyWith(id: 'first'), song.copyWith(id: 'last')],
      currentIndex: 1,
      idFactory: () => 'entry-${id++}',
    );
    createFixture(
      restoreSession: true,
      initialPreferences: <String, Object>{
        'playback_mode': PlaybackMode.sequential.name,
        'playback_session_v2': jsonEncode(<String, dynamic>{
          'version': 2,
          'mode': PlaybackMode.sequential.name,
          ...queue.toJson(),
          'positionMs': 0,
          'isPlaying': false,
        }),
      },
    );
    await notifier.initialized;

    final restored = container.read(playerProvider);
    expect(notifier.playbackMode, PlaybackMode.sequential);
    expect(restored.currentIndex, 1);
    expect(restored.hasNext, isFalse);
  });

  playbackTest('adding to a single-item queue disables native repeat', (
    tester,
  ) async {
    createFixture();
    await notifier.initialized;
    final initial = notifier.playSong(song);
    await tester.pump();
    await initial;
    clearInteractions(engine);
    notifier.addToQueue(song.copyWith(id: 'next'));
    await tester.pump();
    verify(() => engine.setLoopMode(audio.LoopMode.off)).called(1);
    notifier.removeFromQueue(1);
    await tester.pump();
    verify(() => engine.setLoopMode(audio.LoopMode.one)).called(1);
    expect(loads, 1);
  });

  playbackTest(
    'shuffle materializes the visible order and restores the filtered base',
    (tester) async {
      createFixture();
      await notifier.initialized;
      final songs = <Song>[
        for (var i = 0; i < 6; i++)
          song.copyWith(id: 'song-$i', title: 'Song $i'),
      ];
      await notifier.playQueue(songs, startIndex: 1);
      final before = container.read(playerProvider);
      final currentEntryId = before.currentEntryId;
      final baseBefore = before.playbackQueue.baseOrder;
      final loadsBeforeQueueEdits = loads;

      await notifier.setPlaybackMode(PlaybackMode.shuffle, persist: false);
      var shuffled = container.read(playerProvider);
      expect(shuffled.queueEntryIds.take(2), baseBefore.take(2));
      expect(shuffled.currentEntryId, currentEntryId);

      final removedEntryId = shuffled.queueEntryIds.last;
      notifier.removeFromQueue(shuffled.queue.length - 1);
      notifier.reorderQueue(2, shuffled.queue.length - 1);
      await notifier.setPlaybackMode(PlaybackMode.repeatAll, persist: false);

      final restored = container.read(playerProvider);
      expect(restored.queueEntryIds, restored.playbackQueue.baseOrder);
      expect(restored.queueEntryIds, isNot(contains(removedEntryId)));
      expect(restored.currentEntryId, currentEntryId);
      expect(loads, loadsBeforeQueueEdits);
    },
  );

  playbackTest('shuffle next follows the visible order and renews at the end', (
    tester,
  ) async {
    createFixture();
    await notifier.initialized;
    final songs = <Song>[
      for (var i = 0; i < 5; i++) song.copyWith(id: 'round-$i'),
    ];
    await notifier.playQueue(songs, startIndex: 1);
    await notifier.setPlaybackMode(PlaybackMode.shuffle, persist: false);
    var state = container.read(playerProvider);
    final expectedNextId = state.queueEntryIds[state.currentIndex + 1];

    await notifier.next();

    state = container.read(playerProvider);
    expect(state.currentEntryId, expectedNextId);

    await notifier.skipToQueueItem(state.queue.length - 1);
    state = container.read(playerProvider);
    final previousSongId = state.currentSong!.id;
    final previousEntries = state.queueEntryIds.toSet();
    await notifier.next();

    final nextRound = container.read(playerProvider);
    expect(nextRound.currentIndex, 0);
    expect(nextRound.currentSong!.id, isNot(previousSongId));
    expect(nextRound.queueEntryIds.toSet(), previousEntries);
  });

  playbackTest('repeat and shuffle commands preserve the other setting', (
    tester,
  ) async {
    createFixture();
    await notifier.initialized;
    await notifier.playQueue(<Song>[
      for (var index = 0; index < 6; index++)
        song.copyWith(id: 'mode-song-$index'),
    ]);

    await notifier.setLoopMode(audio.LoopMode.all);
    await notifier.setShuffleEnabled(true);
    var state = container.read(playerProvider);
    expect(state.loopMode, audio.LoopMode.all);
    expect(state.shuffleEnabled, isTrue);

    await notifier.setLoopMode(audio.LoopMode.one);
    state = container.read(playerProvider);
    expect(state.loopMode, audio.LoopMode.one);
    expect(state.shuffleEnabled, isTrue);

    await notifier.setShuffleEnabled(false);
    state = container.read(playerProvider);
    expect(state.loopMode, audio.LoopMode.one);
    expect(state.shuffleEnabled, isFalse);
  });

  playbackTest('concurrent repeat and shuffle writes preserve both changes', (
    _,
  ) async {
    createFixture();
    await notifier.initialized;

    final repeatWrite = notifier.setLoopMode(audio.LoopMode.one);
    final shuffleWrite = notifier.setShuffleEnabled(true);
    await Future.wait(<Future<void>>[repeatWrite, shuffleWrite]);

    final state = container.read(playerProvider);
    expect(state.loopMode, audio.LoopMode.one);
    expect(state.shuffleEnabled, isTrue);
  });

  playbackTest('shuffle with repeat off stops at the end of a one-song queue', (
    tester,
  ) async {
    createFixture();
    await notifier.initialized;
    await notifier.playSong(song);
    await notifier.setLoopMode(audio.LoopMode.off);
    await notifier.setShuffleEnabled(true);

    expect(container.read(playerProvider).hasNext, isFalse);
    states.add(audio.PlayerState(true, audio.ProcessingState.completed));
    await tester.pump();

    expect(container.read(playerProvider).hasNext, isFalse);
    expect(container.read(playerProvider).isPlaying, isFalse);
    expect(loads, 1);
  });

  playbackTest('normal reorder updates the durable base without reloading', (
    tester,
  ) async {
    createFixture();
    await notifier.initialized;
    final songs = <Song>[
      for (var i = 0; i < 3; i++) song.copyWith(id: 'ordered-$i'),
    ];
    await notifier.playQueue(songs, startIndex: 0);
    final currentEntryId = container.read(playerProvider).currentEntryId;
    final loadsBeforeMove = loads;

    notifier.reorderQueue(0, 3);

    final moved = container.read(playerProvider);
    expect(moved.queue.map((item) => item.id), <String>[
      'ordered-1',
      'ordered-2',
      'ordered-0',
    ]);
    expect(moved.queueEntryIds, moved.playbackQueue.baseOrder);
    expect(moved.currentEntryId, currentEntryId);
    expect(moved.currentIndex, 2);
    expect(loads, loadsBeforeMove);
  });

  playbackTest('v2 session restores exact shuffle order and entry identity', (
    tester,
  ) async {
    var id = 0;
    final queue = PlaybackQueueState.fromSongs(
      <Song>[
        song.copyWith(id: 'persist-a'),
        song.copyWith(id: 'persist-b'),
        song.copyWith(id: 'persist-c'),
      ],
      currentIndex: 1,
      idFactory: () => 'persist-entry-${id++}',
    ).move(2, 0, shuffleEnabled: true);
    final payload = <String, dynamic>{
      'version': 2,
      'mode': PlaybackMode.shuffle.name,
      'loopMode': audio.LoopMode.all.name,
      'shuffleEnabled': true,
      ...queue.toJson(),
      'positionMs': 0,
      'isPlaying': true,
    };
    createFixture(
      restoreSession: true,
      initialPreferences: <String, Object>{
        'playback_session_v2': jsonEncode(payload),
      },
    );

    await notifier.initialized;

    final restored = container.read(playerProvider);
    expect(restored.shuffleEnabled, isTrue);
    expect(restored.loopMode, audio.LoopMode.all);
    expect(restored.queueEntryIds, queue.playOrder);
    expect(restored.playbackQueue.baseOrder, queue.baseOrder);
    expect(restored.currentEntryId, queue.currentEntryId);
    expect(restored.isPlaying, isFalse);
  });

  playbackTest('v1 session migrates once without reviving a legacy snapshot', (
    tester,
  ) async {
    final legacySongs = <Song>[
      song.copyWith(id: 'legacy-a'),
      song.copyWith(id: 'legacy-b'),
      song.copyWith(id: 'legacy-c'),
      song.copyWith(id: 'legacy-d'),
    ];
    createFixture(
      restoreSession: true,
      initialPreferences: <String, Object>{
        'playback_mode': PlaybackMode.shuffle.name,
        'playback_session_v1': jsonEncode(<String, dynamic>{
          'version': 1,
          'queue': legacySongs.map((item) => item.toJson()).toList(),
          'currentIndex': 1,
          'currentSongId': 'legacy-b',
          'positionMs': 0,
          'isPlaying': true,
        }),
      },
    );

    await notifier.initialized;
    await tester.pump();

    final restored = container.read(playerProvider);
    expect(restored.shuffleEnabled, isTrue);
    expect(
      restored.playbackQueue.baseOrder.map(
        (id) => restored.playbackQueue.entries[id]!.song.id,
      ),
      legacySongs.map((item) => item.id),
    );
    expect(restored.queue.take(2).map((item) => item.id), <String>[
      'legacy-a',
      'legacy-b',
    ]);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.containsKey('playback_session_v2'), isTrue);
    expect(preferences.containsKey('playback_session_v1'), isFalse);
  });

  playbackTest('unrepairable v2 session falls back to a valid v1 snapshot', (
    tester,
  ) async {
    final legacySong = song.copyWith(id: 'fallback-song');
    createFixture(
      restoreSession: true,
      initialPreferences: <String, Object>{
        'playback_session_v2': jsonEncode(<String, dynamic>{
          'version': 2,
          'mode': PlaybackMode.repeatAll.name,
          'entries': <Object>[],
          'baseOrder': <Object>[],
          'playOrder': <Object>[],
        }),
        'playback_session_v1': jsonEncode(<String, dynamic>{
          'version': 1,
          'queue': <Object>[legacySong.toJson()],
          'currentIndex': 0,
          'currentSongId': legacySong.id,
          'positionMs': 0,
          'isPlaying': false,
        }),
      },
    );

    await notifier.initialized;

    expect(container.read(playerProvider).currentSong?.id, legacySong.id);
  });

  playbackTest(
    'repeat after timeOffset seek reloads the full song once then uses native looping',
    (tester) async {
      createFixture();
      await notifier.initialized;
      final regular = Song(
        id: 'normal',
        title: 'Normal',
        suffix: 'mp3',
        bitRate: 320,
        duration: 120,
      );
      final initial = notifier.playSong(regular);
      await tester.pump();
      await initial;
      await notifier.setPlaybackMode(PlaybackMode.repeatOne, persist: false);
      final seek = notifier.seek(const Duration(seconds: 60));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await seek;
      expect(
        (source as audio.UriAudioSource).uri.queryParameters['timeOffset'],
        '60',
      );
      clearInteractions(engine);
      states.add(audio.PlayerState(true, audio.ProcessingState.completed));
      await tester.pump();
      expect(loads, 3);
      expect(
        (source as audio.UriAudioSource).uri.queryParameters['timeOffset'],
        '0',
      );
      verify(() => engine.setLoopMode(audio.LoopMode.one)).called(1);
    },
  );

  playbackTest('system-style resume after app fade-out restores full volume', (
    tester,
  ) async {
    createFixture();
    await notifier.initialized;
    final initial = notifier.playSong(song);
    await tester.pump();
    await initial;
    await container
        .read(crossfadeDurationMsProvider.notifier)
        .setDuration(1000);
    playingEvents.add(true);
    final pause = notifier.pause();
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await pause;
    clearInteractions(engine);
    await notifier.play();
    verify(() => engine.setVolume(1.0)).called(1);
    expect(playing, isTrue);
  });

  playbackTest('user volume and mute survive crossfade changes', (
    tester,
  ) async {
    createFixture(
      initialPreferences: const <String, Object>{'playback_volume_v1': 0.2},
    );
    await notifier.initialized;
    expect(notifier.state.userVolume, 0.2);
    expect(volumeWrites.last, 0.2);

    final initial = notifier.playSong(song);
    await tester.pump();
    await initial;
    await notifier.setMuted(true);
    expect(volumeWrites.last, 0);
    await notifier.setMuted(false);
    expect(volumeWrites.last, 0.2);

    await notifier.setUserVolume(0.23);
    await tester.pump(const Duration(milliseconds: 260));
    expect(await LocalStorage.getPlaybackVolume(), 0.23);
    await container.read(crossfadeDurationMsProvider.notifier).setDuration(400);
    volumeWrites.clear();
    final pause = notifier.pause();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(volumeWrites.every((volume) => volume <= 0.23), isTrue);

    await notifier.setUserVolume(0.35);
    expect(volumeWrites.last, closeTo(0.35 * 0.6, 0.001));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await pause;
    expect(volumeWrites, isNotEmpty);
    expect(volumeWrites.every((volume) => volume <= 0.35), isTrue);
    expect(volumeWrites.last, 0);

    await tester.pump(const Duration(milliseconds: 260));
    expect(await LocalStorage.getPlaybackVolume(), 0.35);
    await notifier.play();
    expect(volumeWrites.last, 0.35);
  });

  playbackTest('zero volume mutes and unmuting restores the last volume', (
    tester,
  ) async {
    createFixture(
      initialPreferences: const <String, Object>{'playback_volume_v1': 0.4},
    );
    await notifier.initialized;

    await notifier.setUserVolume(0);
    expect(notifier.state.userVolume, 0);
    expect(notifier.state.isMuted, isTrue);
    expect(volumeWrites.last, 0);

    await notifier.setMuted(false);
    expect(notifier.state.userVolume, 0.4);
    expect(notifier.state.isMuted, isFalse);
    expect(volumeWrites.last, 0.4);

    await notifier.setMuted(true);
    await notifier.setUserVolume(0.25);
    expect(notifier.state.userVolume, 0.25);
    expect(notifier.state.isMuted, isFalse);
    expect(volumeWrites.last, 0.25);
  });
}
