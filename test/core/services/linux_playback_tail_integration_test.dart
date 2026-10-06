import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/src/player/native/player/real.dart';

/// Runs the actual Linux backend with silent audio output against a local file:
/// ECHO_TEST_AUDIO_FILE=/absolute/path/to/song.flac flutter test --no-pub
///   test/core/services/linux_playback_tail_integration_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final path = Platform.environment['ECHO_TEST_AUDIO_FILE'];

  test(
    'Linux decoder completes the file tail without releasing the backend',
    () async {
      expect(File(path!).existsSync(), isTrue);
      NativePlayer.test = true;
      JustAudioMediaKit.ensureInitialized(windows: false);
      final player = AudioPlayer();
      addTearDown(() async {
        await player.dispose();
        NativePlayer.test = false;
      });
      final duration = await player.setFilePath(path);
      expect(duration, isNotNull);
      expect(duration, greaterThan(const Duration(seconds: 5)));
      await player.seek(duration! - const Duration(seconds: 4));

      final errors = <Object>[];
      final states = <ProcessingState>[];
      final completed = Completer<void>();
      final subscription = player.playbackEventStream.listen((event) {
        states.add(event.processingState);
        if (event.processingState == ProcessingState.completed &&
            !completed.isCompleted) {
          completed.complete();
        }
      }, onError: (Object error) => errors.add(error));
      addTearDown(subscription.cancel);

      unawaited(player.play());
      await completed.future.timeout(const Duration(seconds: 12));
      // Decoder logs can arrive just after EOF; they must not overwrite it.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(errors, isEmpty);
      expect(states, isNot(contains(ProcessingState.idle)));
      expect(player.processingState, ProcessingState.completed);
    },
    skip: !Platform.isLinux || path == null
        ? 'Requires Linux libmpv and ECHO_TEST_AUDIO_FILE'
        : false,
  );
}
