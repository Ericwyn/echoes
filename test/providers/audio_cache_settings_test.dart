import 'package:echoes/core/services/audio_cache_service.dart';
import 'package:echoes/data/models/song.dart';
import 'package:echoes/data/repositories/audio_cache_repository.dart';
import 'package:echoes/data/sources/database/app_database.dart';
import 'package:echoes/data/sources/local_storage.dart';
import 'package:echoes/providers/audio_cache_provider.dart';
import 'package:echoes/providers/player/cache_manager_handler.dart';
import 'package:echoes/providers/player/player_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockRepository extends Mock implements AudioCacheRepository {}

class _MockDatabase extends Mock implements AppDatabase {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('disabled cache persists across a new provider container', () async {
    SharedPreferences.setMockInitialValues({});
    final first = ProviderContainer();
    await first.read(maxCacheSizeProvider.notifier).set(0);
    expect(await LocalStorage.getMaxCacheSize(), 0);
    first.dispose();

    final second = ProviderContainer();
    addTearDown(second.dispose);
    await second.read(maxCacheSizeProvider.notifier).loaded;
    expect(second.read(audioCacheEnabledProvider), isFalse);
    await second.read(maxCacheSizeProvider.notifier).set(512 * 1024 * 1024);
    expect(second.read(audioCacheEnabledProvider), isTrue);
  });

  test(
    'disabled cache skips next-song prefetch before touching services',
    () async {
      SharedPreferences.setMockInitialValues({'max_cache_size_bytes': 0});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(maxCacheSizeProvider.notifier).loaded;
      final handler = container.read(
        Provider<CacheManagerHandler>((ref) => CacheManagerHandler(ref)),
      );
      final current = Song(id: 'current', title: 'Current');
      final next = Song(id: 'next', title: 'Next');
      await handler.preCacheNextSong(
        state: PlayerState(currentSong: current, queue: [current, next]),
        needsTranscoding: (_) => null,
        seekDbg: (_) {},
      );
    },
  );

  test('zero limit does not evict existing audio cache', () async {
    final repository = _MockRepository();
    final service = AudioCacheService(
      repository: repository,
      db: _MockDatabase(),
      maxCacheSizeBytes: 0,
    );
    await service.evictIfNeeded();
    verifyZeroInteractions(repository);
  });
}
