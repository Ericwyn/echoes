import 'dart:math';

import 'package:uuid/uuid.dart';

import '../../data/models/song.dart';

typedef QueueEntryIdFactory = String Function();

/// One occurrence of a song in the playback queue.
///
/// Song IDs are not unique in a queue. The entry ID is therefore the stable
/// identity used by reordering, removal, persistence and async playback work.
class QueueEntry {
  const QueueEntry({required this.entryId, required this.song});

  final String entryId;
  final Song song;

  QueueEntry copyWith({Song? song}) =>
      QueueEntry(entryId: entryId, song: song ?? this.song);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'entryId': entryId,
    'song': song.toJson(),
  };

  static QueueEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final entryId = raw['entryId']?.toString();
    final songJson = raw['song'];
    if (entryId == null || entryId.isEmpty || songJson is! Map) return null;
    try {
      return QueueEntry(
        entryId: entryId,
        song: Song.fromJson(
          songJson.map((key, value) => MapEntry(key.toString(), value)),
        ),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Immutable queue model with a durable base order and a visible play order.
class PlaybackQueueState {
  PlaybackQueueState._({
    required Map<String, QueueEntry> entries,
    required List<String> baseOrder,
    required List<String> playOrder,
    required this.currentEntryId,
    required this.revision,
  }) : entries = Map<String, QueueEntry>.unmodifiable(entries),
       baseOrder = List<String>.unmodifiable(baseOrder),
       playOrder = List<String>.unmodifiable(playOrder) {
    assert(_isValid(entries, baseOrder, playOrder, currentEntryId));
  }

  factory PlaybackQueueState.empty() => PlaybackQueueState._(
    entries: const <String, QueueEntry>{},
    baseOrder: const <String>[],
    playOrder: const <String>[],
    currentEntryId: null,
    revision: 0,
  );

  factory PlaybackQueueState.fromSongs(
    List<Song> songs, {
    int? currentIndex,
    QueueEntryIdFactory? idFactory,
  }) {
    final makeId = idFactory ?? const Uuid().v4;
    final entries = <String, QueueEntry>{};
    final order = <String>[];
    for (final song in songs) {
      var id = makeId();
      while (id.isEmpty || entries.containsKey(id)) {
        id = makeId();
      }
      entries[id] = QueueEntry(entryId: id, song: song);
      order.add(id);
    }
    final validIndex =
        currentIndex != null &&
        currentIndex >= 0 &&
        currentIndex < order.length;
    return PlaybackQueueState._(
      entries: entries,
      baseOrder: order,
      playOrder: order,
      currentEntryId: validIndex ? order[currentIndex] : null,
      revision: 0,
    );
  }

  final Map<String, QueueEntry> entries;
  final List<String> baseOrder;
  final List<String> playOrder;
  final String? currentEntryId;
  final int revision;
  late final List<Song> _songs = List<Song>.unmodifiable(
    playOrder.map((id) => entries[id]!.song),
  );

  bool get isEmpty => playOrder.isEmpty;
  int get length => playOrder.length;

  /// Memoized because the state is immutable and long queues make the
  /// `indexOf` scan a hot path: list builders read [currentIndex] for every
  /// visible row on every frame, turning an O(n) lookup into O(n²) work.
  late final int _currentIndex = currentEntryId == null
      ? -1
      : playOrder.indexOf(currentEntryId!);
  int get currentIndex => _currentIndex;
  QueueEntry? get currentEntry =>
      currentEntryId == null ? null : entries[currentEntryId!];
  Song? get currentSong => currentEntry?.song;
  List<Song> get songs => _songs;
  List<String> get entryIds => playOrder;

  QueueEntry entryAt(int index) => entries[playOrder[index]]!;
  Song songAt(int index) => entryAt(index).song;
  int indexOfEntry(String entryId) => playOrder.indexOf(entryId);

  PlaybackQueueState selectIndex(int? index) {
    final nextId = index != null && index >= 0 && index < playOrder.length
        ? playOrder[index]
        : null;
    if (nextId == currentEntryId) return this;
    return _copy(currentEntryId: nextId);
  }

  PlaybackQueueState selectEntry(String? entryId) {
    final nextId = entryId != null && entries.containsKey(entryId)
        ? entryId
        : null;
    if (nextId == currentEntryId) return this;
    return _copy(currentEntryId: nextId);
  }

  PlaybackQueueState updateEntrySong(String entryId, Song song) {
    final entry = entries[entryId];
    if (entry == null || identical(entry.song, song)) return this;
    return _copy(
      entries: <String, QueueEntry>{
        ...entries,
        entryId: entry.copyWith(song: song),
      },
    );
  }

  PlaybackQueueState updateSongsBySongId(String songId, Song song) {
    var changed = false;
    final nextEntries = <String, QueueEntry>{...entries};
    for (final id in playOrder) {
      final entry = entries[id]!;
      if (entry.song.id != songId) continue;
      nextEntries[id] = entry.copyWith(song: song);
      changed = true;
    }
    return changed ? _copy(entries: nextEntries) : this;
  }

  /// Replaces song metadata positionally while preserving queue identities.
  /// Structural edits should use append/insert/remove/move instead.
  PlaybackQueueState replaceVisibleSongs(List<Song> songs) {
    if (songs.length != playOrder.length) {
      return PlaybackQueueState.fromSongs(
        songs,
        currentIndex: currentIndex >= 0 ? currentIndex : null,
      );
    }
    final nextEntries = <String, QueueEntry>{...entries};
    for (var i = 0; i < songs.length; i++) {
      final id = playOrder[i];
      nextEntries[id] = nextEntries[id]!.copyWith(song: songs[i]);
    }
    return _copy(entries: nextEntries);
  }

  PlaybackQueueState move(
    int oldIndex,
    int newIndex, {
    required bool shuffleEnabled,
  }) {
    if (oldIndex < 0 || oldIndex >= playOrder.length) return this;
    var destination = newIndex;
    if (destination > oldIndex) destination -= 1;
    destination = destination.clamp(0, playOrder.length - 1);
    if (destination == oldIndex) return this;

    final nextPlay = <String>[...playOrder];
    final movedId = nextPlay.removeAt(oldIndex);
    nextPlay.insert(destination, movedId);
    return _copy(
      playOrder: nextPlay,
      baseOrder: shuffleEnabled ? baseOrder : nextPlay,
      revision: revision + 1,
    );
  }

  PlaybackQueueState append(
    List<Song> songs, {
    QueueEntryIdFactory? idFactory,
  }) {
    if (songs.isEmpty) return this;
    final additions = PlaybackQueueState.fromSongs(songs, idFactory: idFactory);
    return _copy(
      entries: <String, QueueEntry>{...entries, ...additions.entries},
      baseOrder: <String>[...baseOrder, ...additions.baseOrder],
      playOrder: <String>[...playOrder, ...additions.playOrder],
      revision: revision + 1,
    );
  }

  PlaybackQueueState insertNext(Song song, {QueueEntryIdFactory? idFactory}) {
    final addition = PlaybackQueueState.fromSongs(<Song>[
      song,
    ], idFactory: idFactory);
    final id = addition.playOrder.single;
    final nextPlay = <String>[...playOrder];
    final playCurrent = currentEntryId == null
        ? -1
        : nextPlay.indexOf(currentEntryId!);
    nextPlay.insert(playCurrent < 0 ? nextPlay.length : playCurrent + 1, id);

    final nextBase = <String>[...baseOrder];
    final baseCurrent = currentEntryId == null
        ? -1
        : nextBase.indexOf(currentEntryId!);
    nextBase.insert(baseCurrent < 0 ? nextBase.length : baseCurrent + 1, id);
    return _copy(
      entries: <String, QueueEntry>{...entries, ...addition.entries},
      baseOrder: nextBase,
      playOrder: nextPlay,
      revision: revision + 1,
    );
  }

  PlaybackQueueState removeAt(int index) {
    if (index < 0 || index >= playOrder.length) return this;
    return removeEntry(playOrder[index]);
  }

  PlaybackQueueState removeEntry(String entryId) {
    if (!entries.containsKey(entryId)) return this;
    final nextEntries = <String, QueueEntry>{...entries}..remove(entryId);
    return _copy(
      entries: nextEntries,
      baseOrder: baseOrder.where((id) => id != entryId).toList(),
      playOrder: playOrder.where((id) => id != entryId).toList(),
      currentEntryId: currentEntryId == entryId ? null : currentEntryId,
      revision: revision + 1,
    );
  }

  PlaybackQueueState clearUpcoming() {
    final index = currentIndex;
    if (index < 0) return PlaybackQueueState.empty();
    if (index == playOrder.length - 1) return this;
    final removed = playOrder.skip(index + 1).toSet();
    final nextEntries = <String, QueueEntry>{...entries}
      ..removeWhere((id, _) => removed.contains(id));
    return _copy(
      entries: nextEntries,
      baseOrder: baseOrder.where((id) => !removed.contains(id)).toList(),
      playOrder: playOrder.take(index + 1).toList(),
      revision: revision + 1,
    );
  }

  PlaybackQueueState enableShuffle(Random random) {
    if (playOrder.length < 2) return this;
    final split = currentIndex < 0 ? 0 : currentIndex + 1;
    final prefix = playOrder.take(split).toList();
    final suffix = playOrder.skip(split).toList()..shuffle(random);
    final next = <String>[...prefix, ...suffix];
    if (_sameOrder(next, playOrder)) return this;
    return _copy(playOrder: next, revision: revision + 1);
  }

  PlaybackQueueState restoreBaseOrder() {
    if (_sameOrder(playOrder, baseOrder)) return this;
    return _copy(playOrder: baseOrder, revision: revision + 1);
  }

  /// Creates the next shuffle round and selects its first entry.
  PlaybackQueueState nextShuffleRound(Random random) {
    if (playOrder.isEmpty) return this;
    if (playOrder.length == 1) return selectIndex(0);

    final previousSongId = currentSong?.id;
    final candidates = <String>[
      for (final id in playOrder)
        if (entries[id]!.song.id != previousSongId) id,
    ];
    final firstPool = candidates.isEmpty ? playOrder : candidates;
    final first = firstPool[random.nextInt(firstPool.length)];
    final rest = playOrder.where((id) => id != first).toList()..shuffle(random);
    final next = <String>[first, ...rest];
    return _copy(
      playOrder: next,
      currentEntryId: first,
      revision: revision + 1,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'entries': playOrder.map((id) => entries[id]!.toJson()).toList(),
    'baseOrder': baseOrder,
    'playOrder': playOrder,
    'currentEntryId': currentEntryId,
  };

  /// Decodes and repairs a persisted queue without inventing deleted entries.
  static PlaybackQueueState? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final decodedEntries = <String, QueueEntry>{};
    final rawEntries = raw['entries'];
    if (rawEntries is! List) return null;
    for (final rawEntry in rawEntries) {
      final entry = QueueEntry.fromJson(rawEntry);
      if (entry == null || decodedEntries.containsKey(entry.entryId)) continue;
      decodedEntries[entry.entryId] = entry;
    }
    if (decodedEntries.isEmpty) return null;

    List<String> repairOrder(Object? value) {
      final result = <String>[];
      if (value is List) {
        for (final item in value) {
          final id = item.toString();
          if (decodedEntries.containsKey(id) && !result.contains(id)) {
            result.add(id);
          }
        }
      }
      for (final id in decodedEntries.keys) {
        if (!result.contains(id)) result.add(id);
      }
      return result;
    }

    final base = repairOrder(raw['baseOrder']);
    final play = repairOrder(raw['playOrder']);
    final persistedCurrent = raw['currentEntryId']?.toString();
    final current = decodedEntries.containsKey(persistedCurrent)
        ? persistedCurrent
        : null;
    return PlaybackQueueState._(
      entries: decodedEntries,
      baseOrder: base,
      playOrder: play,
      currentEntryId: current,
      revision: 0,
    );
  }

  PlaybackQueueState _copy({
    Map<String, QueueEntry>? entries,
    List<String>? baseOrder,
    List<String>? playOrder,
    Object? currentEntryId = _keepCurrentEntry,
    int? revision,
  }) => PlaybackQueueState._(
    entries: entries ?? this.entries,
    baseOrder: baseOrder ?? this.baseOrder,
    playOrder: playOrder ?? this.playOrder,
    currentEntryId: identical(currentEntryId, _keepCurrentEntry)
        ? this.currentEntryId
        : currentEntryId as String?,
    revision: revision ?? this.revision,
  );

  static bool _sameOrder(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _isValid(
    Map<String, QueueEntry> entries,
    List<String> baseOrder,
    List<String> playOrder,
    String? currentEntryId,
  ) {
    if (baseOrder.length != entries.length ||
        playOrder.length != entries.length) {
      return false;
    }
    if (baseOrder.toSet().length != entries.length ||
        playOrder.toSet().length != entries.length) {
      return false;
    }
    if (!baseOrder.every(entries.containsKey) ||
        !playOrder.every(entries.containsKey)) {
      return false;
    }
    return currentEntryId == null || entries.containsKey(currentEntryId);
  }
}

const Object _keepCurrentEntry = Object();
