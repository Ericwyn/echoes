import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../constants/app_identity.dart';
import '../utils/logger.dart';

/// Playback CPU lock with a native heartbeat watchdog, separate from screen wake.
class PlaybackWakeGuard with WidgetsBindingObserver {
  PlaybackWakeGuard({bool? enabled, MethodChannel? channel})
    : _enabled =
          enabled ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.android),
      _channel =
          channel ??
          const MethodChannel('$echoApplicationId/playback_wake_guard') {
    if (_enabled) WidgetsBinding.instance.addObserver(this);
  }
  final bool _enabled;
  final MethodChannel _channel;
  Timer? _renewal;
  bool _active = false;
  bool _unavailable = false;
  int? _lastElapsed;
  int? _lastUptime;
  int _lastNativeSequence = 0;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_active) unawaited(capture(reason: 'lifecycle_${state.name}'));
  }

  /// Read-only: observing a failure must not renew a lock or its watchdog.
  Future<void> capture({required String reason, String context = ''}) async {
    if (!_enabled || _unavailable) return;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getStatus',
        {'reason': reason},
      );
      if (result == null) return;
      Logger.infoWithTag(
        'PLAYBACK_NATIVE',
        'snapshot reason=$reason sequence=${result['sequence']} '
            'nativeElapsedMs=${result['elapsedMs']} requested=$_active $context',
      );
      _logNativeEvents(result);
    } on MissingPluginException {
      // An older native plugin may not support this diagnostic call.
    } on PlatformException catch (error) {
      Logger.warnWithTag(
        'PLAYBACK_NATIVE',
        'snapshot_failed code=${error.code}',
      );
    }
  }

  void _logNativeEvents(Map<String, dynamic> result) {
    final events = result['nativeEvents'] as List?;
    if (events == null) return;
    for (final raw in events) {
      final event = Map<String, dynamic>.from(raw as Map);
      final sequence = event['sequence'] as int;
      if (sequence <= _lastNativeSequence) continue;
      if (sequence > _lastNativeSequence + 1) {
        Logger.warnWithTag(
          'PLAYBACK_NATIVE',
          'history_gap missing=${sequence - _lastNativeSequence - 1}',
        );
      }
      _lastNativeSequence = sequence;
      Logger.infoWithTag('PLAYBACK_NATIVE', 'event $event');
    }
  }

  Future<void> setActive(bool active, {required String reason}) async {
    if (!_enabled || _unavailable) return;
    if (_active == active) {
      // A new song must reassert the native lock even if playback intent did
      // not change; the OS may have disabled it since the last heartbeat.
      if (active && reason == 'song_request') await _send(reason);
      return;
    }
    _active = active;
    if (active) {
      _lastElapsed = null;
      _lastUptime = null;
    }
    _renewal?.cancel();
    _renewal = active
        ? Timer.periodic(const Duration(seconds: 20), (_) {
            unawaited(_send('renew'));
          })
        : null;
    await _send(reason);
  }

  Future<void> _send(String reason) async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'setActive',
        {'active': _active, 'reason': reason},
      );
      if (result == null) return;
      _logNativeEvents(result);
      final elapsed = result['elapsedMs'] as int;
      final uptime = result['uptimeMs'] as int;
      final gap = _lastElapsed == null ? 0 : elapsed - _lastElapsed!;
      final slept = _lastUptime == null ? 0 : gap - (uptime - _lastUptime!);
      _lastElapsed = elapsed;
      _lastUptime = uptime;
      Logger.infoWithTag(
        'PLAYBACK',
        'cpu_guard reason=$reason requested=$_active '
            'held=${result['held']} foreground=${result['serviceForeground']} '
            'interactive=${result['interactive']} idle=${result['deviceIdle']} '
            'batteryExempt=${result['batteryExempt']} powerSave=${result['powerSaveMode']} '
            'gapMs=$gap sleptMs=$slept',
      );
    } on MissingPluginException {
      _unavailable = true;
      _renewal?.cancel();
      Logger.warnWithTag('PLAYBACK', 'cpu_guard unavailable');
    } on PlatformException catch (error) {
      Logger.warnWithTag('PLAYBACK', 'cpu_guard failed code=${error.code}');
    }
  }

  Future<void> dispose() {
    if (_enabled) WidgetsBinding.instance.removeObserver(this);
    return setActive(false, reason: 'dispose');
  }
}
