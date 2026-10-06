import 'package:echoes/core/services/playback_wake_guard.dart';
import 'package:echoes/core/utils/logger.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('echo-test-wake-guard');

  testWidgets('snapshots are read-only and native history exports once', (
    tester,
  ) async {
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          methods.add(call.method);
          return {
            'nativeEvents': [
              {
                'sequence': 1,
                'reason': 'SCREEN_ON',
                'servicePresent': false,
                'serviceForeground': null,
              },
            ],
          };
        });
    final guard = PlaybackWakeGuard(enabled: true, channel: channel);
    try {
      Logger.clearBuffer();
      await guard.capture(reason: 'load_failed', context: 'song=test');
      await guard.capture(reason: 'load_end');
      await tester.pump(const Duration(seconds: 40));
      expect(methods, ['getStatus', 'getStatus']);
      final logs = Logger.exportLogs();
      expect(RegExp('reason: SCREEN_ON').allMatches(logs).length, 1);
      expect(logs, contains('servicePresent: false'));
      expect(logs, contains('serviceForeground: null'));
      expect(logs, contains('snapshot reason=load_failed'));
      expect(logs, contains('requested=false song=test'));
    } finally {
      await guard.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });

  testWidgets('CPU lease renews only while requested and releases on pause', (
    tester,
  ) async {
    final calls = <bool>[];
    final reasons = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final active = (call.arguments as Map)['active'] as bool;
          reasons.add((call.arguments as Map)['reason'] as String);
          calls.add(active);
          return {
            'held': active,
            'serviceForeground': true,
            'interactive': false,
            'deviceIdle': false,
            'batteryExempt': false,
            'elapsedMs': 100,
            'uptimeMs': 100,
          };
        });
    final guard = PlaybackWakeGuard(enabled: true, channel: channel);
    try {
      await guard.setActive(true, reason: 'play');
      await guard.setActive(true, reason: 'duplicate_play');
      expect(calls, [true]);
      await tester.pump(const Duration(seconds: 20));
      expect(calls, [true, true]);
      expect(reasons, ['play', 'renew']);
      await guard.setActive(true, reason: 'song_request');
      expect(calls, [true, true, true]);
      expect(reasons.last, 'song_request');
      await guard.setActive(false, reason: 'pause');
      await tester.pump(const Duration(minutes: 3));
      expect(calls, [true, true, true, false]);
      expect(reasons.last, 'pause');
      await guard.setActive(true, reason: 'resume');
      await guard.dispose();
      expect(calls.last, isFalse);
    } finally {
      await guard.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });

  testWidgets('missing native plugin stops renewal without failing playback', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          throw MissingPluginException();
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final guard = PlaybackWakeGuard(enabled: true, channel: channel);
    await guard.setActive(true, reason: 'play');
    await tester.pump(const Duration(minutes: 3));
    await guard.dispose();
  });
}
