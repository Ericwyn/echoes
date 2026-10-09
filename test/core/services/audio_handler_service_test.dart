import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:echoes/core/services/audio_handler_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mocktail/mocktail.dart';

class _MockAudioPlayer extends Mock implements AudioPlayer {}

void main() {
  late _MockAudioPlayer player;
  late EchoAudioHandler handler;

  setUp(() {
    player = _MockAudioPlayer();
    when(
      () => player.playbackEventStream,
    ).thenAnswer((_) => const Stream.empty());
    when(() => player.playingStream).thenAnswer((_) => const Stream.empty());
    when(() => player.positionStream).thenAnswer((_) => const Stream.empty());
    when(
      () => player.processingStateStream,
    ).thenAnswer((_) => const Stream.empty());
    when(() => player.playing).thenReturn(true);
    when(() => player.processingState).thenReturn(ProcessingState.ready);
    when(() => player.position).thenReturn(const Duration(seconds: 2));
    when(() => player.bufferedPosition).thenReturn(const Duration(seconds: 3));
    when(() => player.speed).thenReturn(1.0);
    handler = EchoAudioHandler(player);
  });

  test('media session advertises seek support for notification progress', () {
    expect(echoPlaybackSystemActions, contains(MediaAction.seek));
  });

  test(
    'delegates media-session seeks to the player notifier callback',
    () async {
      Duration? received;
      handler.onSeek = (position) async {
        received = position;
      };

      await handler.seek(const Duration(seconds: 45));

      expect(received, const Duration(seconds: 45));
      verifyNever(() => player.seek(any()));
    },
  );

  test(
    'source replacement never publishes idle until the transition ends',
    () async {
      final events = StreamController<PlaybackEvent>();
      when(() => player.playbackEventStream).thenAnswer((_) => events.stream);
      final transitioning = EchoAudioHandler(player);
      when(() => player.processingState).thenReturn(ProcessingState.idle);
      transitioning.beginSourceTransition(1, playing: true);
      events.add(PlaybackEvent(processingState: ProcessingState.idle));
      await Future<void>.delayed(Duration.zero);
      expect(
        transitioning.playbackState.value.processingState,
        AudioProcessingState.loading,
      );
      expect(transitioning.playbackState.value.playing, isTrue);
      transitioning.beginSourceTransition(2, playing: true);
      transitioning.endSourceTransition(1);
      expect(
        transitioning.playbackState.value.processingState,
        AudioProcessingState.loading,
      );
      when(() => player.processingState).thenReturn(ProcessingState.ready);
      transitioning.endSourceTransition(2);
      expect(
        transitioning.playbackState.value.processingState,
        AudioProcessingState.ready,
      );
      await events.close();
    },
  );

  test('failed prepare keeps service buffering until explicit pause', () async {
    await handler.updateMediaItem(const MediaItem(id: 'song', title: 'Song'));
    handler.beginSourceTransition(1, playing: true);
    when(() => player.processingState).thenReturn(ProcessingState.idle);
    when(() => player.playing).thenReturn(false);
    handler.endSourceTransition(1);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.buffering,
    );
    expect(handler.playbackState.value.playing, isTrue);
    handler.updateTransportIntent(false);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.idle,
    );
    expect(handler.playbackState.value.playing, isFalse);
  });

  test('metadata updates do not turn paused playback into playing', () async {
    when(() => player.playing).thenReturn(false);
    await handler.updateMediaItem(const MediaItem(id: 'song', title: 'Song'));
    expect(handler.playbackState.value.playing, isFalse);
  });

  test(
    'bound transport intent stays playing across prepare and native handoff',
    () {
      handler.bindCommands(
        owner: Object(),
        onPlay: () async {},
        onPause: () async {},
        onStop: () async {},
        onSeek: (_) async {},
        onSkipToNext: () async {},
        onSkipToPrevious: () async {},
      );
      handler.updateTransportIntent(true);
      handler.beginSourceTransition(1, playing: true);
      when(() => player.playing).thenReturn(false);
      handler.endSourceTransition(1);
      expect(handler.playbackState.value.playing, isTrue);
      handler.updateTransportIntent(false);
      expect(handler.playbackState.value.playing, isFalse);
    },
  );

  test('system controls delegate to the same transport as the app', () async {
    final calls = <String>[];
    handler.onPlay = () async {
      calls.add('play');
    };
    handler.onPause = () async {
      calls.add('pause');
    };
    await handler.play();
    await handler.pause();
    expect(calls, ['play', 'pause']);
    verifyNever(() => player.play());
    verifyNever(() => player.pause());
  });

  test('media commands safely rebind to the current player notifier', () async {
    final calls = <String>[];
    final firstOwner = Object();
    final secondOwner = Object();

    handler.bindCommands(
      owner: firstOwner,
      onPlay: () async => calls.add('first'),
      onPause: () async {},
      onStop: () async {},
      onSeek: (_) async {},
      onSkipToNext: () async {},
      onSkipToPrevious: () async {},
    );
    await handler.play();
    handler.unbindCommands(firstOwner);
    handler.bindCommands(
      owner: secondOwner,
      onPlay: () async => calls.add('second'),
      onPause: () async {},
      onStop: () async {},
      onSeek: (_) async {},
      onSkipToNext: () async {},
      onSkipToPrevious: () async {},
    );
    handler.unbindCommands(firstOwner);
    await handler.play();

    expect(calls, <String>['first', 'second']);
    verifyNever(() => player.play());
  });

  test('clearing the current library removes stale media metadata', () async {
    await handler.updateMediaItem(const MediaItem(id: 'song', title: 'Song'));

    await handler.clearMediaItem();

    expect(handler.mediaItem.value, isNull);
  });

  test('fallback system play does not reset the user volume', () async {
    when(() => player.play()).thenAnswer((_) async {});

    await handler.play();

    verify(() => player.play()).called(1);
    verifyNever(() => player.setVolume(any()));
  });

  test(
    'native events update seek progress without UI position ticks',
    () async {
      final events = StreamController<PlaybackEvent>.broadcast(sync: true);
      when(() => player.playbackEventStream).thenAnswer((_) => events.stream);
      final session = EchoAudioHandler(player);
      when(() => player.position).thenReturn(const Duration(seconds: 45));
      events.add(PlaybackEvent(processingState: ProcessingState.ready));
      expect(
        session.playbackState.value.updatePosition,
        const Duration(seconds: 45),
      );
      // Neither handler subscribes to high-frequency UI interpolation ticks.
      verifyNever(() => player.positionStream);
      await events.close();
    },
  );

  test('adds the server timeOffset to media-session progress', () {
    handler.setPositionOffset(const Duration(seconds: 45));

    expect(
      handler.playbackState.value.updatePosition,
      const Duration(seconds: 47),
    );
    expect(
      handler.playbackState.value.bufferedPosition,
      const Duration(seconds: 48),
    );
  });
}
