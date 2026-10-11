import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/services/audio_cache_service.dart';
import '../data/repositories/audio_cache_repository.dart';
import '../data/sources/database/database_provider.dart';
import '../data/sources/local_storage.dart';

/// 缓存仓库 Provider
final audioCacheRepositoryProvider = Provider<AudioCacheRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return AudioCacheRepository(db);
});

/// 缓存服务 Provider
final audioCacheServiceProvider = Provider<AudioCacheService>((ref) {
  final repository = ref.watch(audioCacheRepositoryProvider);
  final db = ref.watch(appDatabaseProvider);
  final maxSize = ref.watch(maxCacheSizeProvider);
  final service = AudioCacheService(
    repository: repository,
    db: db,
    maxCacheSizeBytes: maxSize,
  );
  final settingsLoaded = ref.read(maxCacheSizeProvider.notifier).loaded;
  var disposed = false;
  ref.onDispose(() => disposed = true);
  // Wait for persisted settings before deciding whether to evict old files.
  Future.microtask(() async {
    await settingsLoaded;
    if (!disposed && maxSize > 0 && ref.read(maxCacheSizeProvider) == maxSize) {
      await service.evictIfNeeded();
    }
  });
  return service;
});

/// 音频缓存大小 Provider（磁盘扫描）
final audioCacheSizeProvider = FutureProvider<int>((ref) async {
  final service = ref.watch(audioCacheServiceProvider);
  return service.getAudioCacheSize();
});

/// 图片缓存大小 Provider
final imageCacheSizeProvider = FutureProvider<int>((ref) async {
  final service = ref.watch(audioCacheServiceProvider);
  return service.getImageCacheSize();
});

/// 歌词缓存条数 Provider
final lyricsCacheCountProvider = FutureProvider<int>((ref) async {
  final service = ref.watch(audioCacheServiceProvider);
  return service.getLyricsCacheCount();
});

/// 音频缓存上限 Provider（字节）
final maxCacheSizeProvider = StateNotifierProvider<MaxCacheSizeNotifier, int>((
  ref,
) {
  return MaxCacheSizeNotifier();
});

/// A zero cache limit disables automatic audio caching and cache playback.
final audioCacheEnabledProvider = Provider<bool>((ref) {
  return ref.watch(maxCacheSizeProvider) > 0;
});

class MaxCacheSizeNotifier extends StateNotifier<int> {
  // 默认 2GB
  static const int defaultMaxSize = 2 * 1024 * 1024 * 1024;

  MaxCacheSizeNotifier() : super(defaultMaxSize) {
    loaded = _load();
  }

  late final Future<void> loaded;

  Future<void> _load() async {
    final stored = await LocalStorage.getMaxCacheSize();
    if (mounted && stored != null) {
      state = stored;
    }
  }

  Future<void> set(int bytes) async {
    await loaded;
    if (!mounted) return;
    state = bytes;
    await LocalStorage.setMaxCacheSize(bytes);
  }
}

/// 向后兼容：旧 cacheSizeProvider
final cacheSizeProvider = FutureProvider<int>((ref) async {
  final service = ref.watch(audioCacheServiceProvider);
  return service.getTotalCacheSize();
});
