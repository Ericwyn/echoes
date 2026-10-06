import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

/// A release-safe classification; never exports exception messages or URLs.
String playbackErrorSummary(Object error) {
  final detail = error is DioException
      ? '${error.message} ${error.error}'.toLowerCase()
      : error.toString().toLowerCase();
  final cause =
      detail.contains('failed host lookup') ||
          detail.contains('unable to resolve host') ||
          detail.contains('unknownhostexception')
      ? 'dns'
      : detail.contains('foregroundservicestartnotallowed') ||
            detail.contains('startforegroundservice() not allowed')
      ? 'foreground_start_not_allowed'
      : detail.contains('foregroundservicedidnotstartintime') ||
            detail.contains('did not then call service.startforeground')
      ? 'foreground_start_timeout'
      : detail.contains('securityexception') ||
            detail.contains('permission denial')
      ? 'permission_denied'
      : detail.contains('connection refused')
      ? 'connection_refused'
      : detail.contains('network is unreachable') ||
            detail.contains('no route to host')
      ? 'network_unreachable'
      : detail.contains('ssl') || detail.contains('handshake')
      ? 'tls'
      : detail.contains('timeout') || detail.contains('timed out')
      ? 'timeout'
      : 'unknown';
  // Platform error codes can contain arbitrary text; keep only bounded tokens.
  String safeCode(Object? code) =>
      code != null && RegExp(r'^[a-zA-Z0-9_.-]{1,64}$').hasMatch('$code')
      ? '$code'
      : 'unknown';
  return 'errorType=${error.runtimeType} cause=$cause'
      '${error is DioException ? ' dioType=${error.type.name} httpStatus=${error.response?.statusCode}' : ''}'
      '${error is PlatformException ? ' code=${safeCode(error.code)}' : ''}'
      '${error is PlayerException ? ' code=${safeCode(error.code)}' : ''}';
}
