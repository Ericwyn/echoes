import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;
import '../../core/services/audio_prefetch_service.dart';
import '../../core/platform/platform_file_bridge.dart';
import '../../data/models/audio_quality.dart';
import '../../data/sources/subsonic_api_client.dart';
import '../../core/utils/logger.dart';
import '../api_provider.dart';
import '../audio_cache_provider.dart';
import '../audio_quality_provider.dart';
import '../download_provider.dart';
import '../auth_provider.dart';
import 'player_state.dart';

/// 缓存管理处理器
///
/// 处理缓存注册和预缓存逻辑，从 PlayerNotifier 中提取。
class CacheManagerHandler {
  final Ref _ref;

  CacheManagerHandler(this._ref);
  final AudioPrefetchService _prefetch = AudioPrefetchService();
  int _generation = 0;

  Future<void> cancelPrecache() {
    _generation++;
    return _prefetch.cancel();
  }

  SubsonicApiClient get _apiClient => _ref.read(subsonicApiClientProvider);

  /// 从缓存文件注册缓存元数据（downloadProgressStream 到 1.0 时调用）
  Future<void> registerCacheFromFile(
    String cacheFilePath,
    String songId,
    String libraryId,
    AudioQualityLevel quality, {
    Set<String> activeSongIds = const {},
  }) async {
    try {
      // just_audio can publish 100% before renaming its .part file.
      for (
        var attempt = 0;
        attempt < 10 && !await fileExists(cacheFilePath);
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (!await fileExists(cacheFilePath)) return;
      final fileSize = await fileLength(cacheFilePath);
      if (fileSize <= 0) return;

      final cacheService = _ref.read(audioCacheServiceProvider);
      await cacheService.registerCache(
        songId: songId,
        libraryId: libraryId,
        filePath: cacheFilePath,
        fileSize: fileSize,
        quality: quality,
        activeSongIds: activeSongIds,
      );
      Logger.info(
        'Cache registered (download complete): $songId '
        '(${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB)',
      );
    } catch (e) {
      Logger.warn('Failed to register cache for $songId', e);
    }
  }

  /// 预缓存队列中下一首歌
  ///
  /// [needsTranscoding] 回调用于判断是否需要转码。
  Future<void> preCacheNextSong({
    required PlayerState state,
    required String? Function(String? suffix) needsTranscoding,
    required void Function(String message) seekDbg,
  }) async {
    final generation = ++_generation;
    await _prefetch.cancel();
    if (generation != _generation ||
        !_ref.read(audioCacheEnabledProvider) ||
        !state.hasNext) {
      return;
    }
    if (kIsWeb) return;
    if (state.queue.length < 2 || state.currentIndex < 0) return;
    if (state.loopMode == LoopMode.one) return;
    final nextIndex = state.currentIndex + 1;
    if (state.shuffleEnabled && nextIndex >= state.queue.length) return;
    final nextSong = state.queue[nextIndex % state.queue.length];
    if (nextSong.isPreview || (nextSong.duration ?? 0) > 1200) return;
    final authState = _ref.read(authStateProvider);
    final libraryId = authState.currentLibrary?.id ?? '';
    if (libraryId.isEmpty) return;

    final downloadService = _ref.read(downloadServiceProvider);
    final cacheService = _ref.read(audioCacheServiceProvider);
    final effectiveQuality = _ref.read(effectiveQualityProvider);
    final maxBitRate = effectiveQuality.maxBitRate;
    // 已下载则不需要预缓存
    final downloaded = await downloadService.isDownloaded(
      nextSong.id,
      libraryId,
    );
    if (downloaded) return;

    // 已缓存则不需要预缓存
    final cached = await cacheService.getCachedPath(
      songId: nextSong.id,
      libraryId: libraryId,
      quality: effectiveQuality,
    );
    if (cached != null) return;

    if (generation != _generation) return;
    try {
      final streamUrl = _apiClient.getStreamUrl(
        nextSong.id,
        format: needsTranscoding(nextSong.suffix),
        maxBitRate: maxBitRate,
      );
      final cacheFilePath = await cacheService.getCacheFilePath(
        songId: nextSong.id,
        libraryId: libraryId,
        quality: effectiveQuality,
      );
      if (generation != _generation ||
          !_ref.read(audioCacheEnabledProvider) ||
          streamUrl.isEmpty) {
        return;
      }
      Logger.infoWithTag(
        'PRECACHE',
        'start song=${nextSong.id} quality=${effectiveQuality.name}',
      );
      final completedPath = await _prefetch.download(streamUrl, cacheFilePath);
      if (generation != _generation) return;
      if (completedPath == null) {
        Logger.infoWithTag(
          'PRECACHE',
          'cancelled_or_failed song=${nextSong.id}',
        );
        return;
      }
      await registerCacheFromFile(
        completedPath,
        nextSong.id,
        libraryId,
        effectiveQuality,
        activeSongIds: {if (state.currentSong != null) state.currentSong!.id},
      );
      Logger.infoWithTag('PRECACHE', 'complete song=${nextSong.id}');
    } catch (e) {
      Logger.warnWithTag(
        'PRECACHE',
        'failed song=${nextSong.id} type=${e.runtimeType}',
      );
    }
  }
}
