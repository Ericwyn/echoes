import 'package:dio/dio.dart';
import 'package:echoes/core/utils/playback_error_summary.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

void main() {
  test('DNS classification retains useful details without request secrets', () {
    final summary = playbackErrorSummary(
      DioException(
        requestOptions: RequestOptions(
          path: 'https://private.example/stream?t=secret',
        ),
        type: DioExceptionType.connectionError,
        error: "SocketException: Failed host lookup: 'private.example'",
      ),
    );
    expect(summary, contains('cause=dns'));
    expect(summary, contains('dioType=connectionError'));
    expect(summary, isNot(contains('private.example')));
    expect(summary, isNot(contains('secret')));
  });

  test(
    'native decoder errors preserve classification and safe numeric code',
    () {
      final summary = playbackErrorSummary(
        PlayerException(
          0,
          'Unable to resolve host private.example?token=secret',
        ),
      );
      expect(summary, contains('cause=dns'));
      expect(summary, contains('code=0'));
      expect(summary, isNot(contains('private.example')));
    },
  );

  test('platform errors never export arbitrary error code text', () {
    final summary = playbackErrorSummary(
      PlatformException(code: 'https://private.example?token=secret'),
    );
    expect(summary, contains('code=unknown'));
    expect(summary, isNot(contains('secret')));
  });

  test('platform foreground service failures retain the actual cause', () {
    final summary = playbackErrorSummary(
      PlatformException(
        code: 'Error',
        message:
            'android.app.ForegroundServiceStartNotAllowedException: private details',
      ),
    );
    expect(summary, contains('cause=foreground_start_not_allowed'));
    expect(summary, isNot(contains('private details')));
  });
}
