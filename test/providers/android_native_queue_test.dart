import 'package:echoes/data/models/song.dart';
import 'package:echoes/providers/player/android_native_queue.dart';
import 'package:echoes/providers/player/playback_queue_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

void main() {
  PlaybackQueueState queue({int index = 0}) {
    var occurrence = 0;
    return PlaybackQueueState.fromSongs(
      [
        Song(id: 'same', title: 'First'),
        Song(id: 'same', title: 'Duplicate'),
        Song(id: 'last', title: 'Last'),
      ],
      currentIndex: index,
      idFactory: () => 'entry-${occurrence++}',
    );
  }

  test(
    'native lookahead preserves duplicate occurrences and visible order',
    () {
      final entries = androidNativeUpcomingEntries(
        queue(),
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );
      expect(entries.map((e) => e.entryId), ['entry-1', 'entry-2']);
      expect(entries.first.song.id, 'same');
    },
  );

  test('sequential playback stops at the last entry', () {
    expect(
      androidNativeUpcomingEntries(
        queue(index: 2),
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      ),
      isEmpty,
    );
  });

  test('repeat all wraps but native shuffle does not invent a new round', () {
    final entries = androidNativeUpcomingEntries(
      queue(index: 2),
      loopMode: LoopMode.all,
      shuffleEnabled: false,
    );
    expect(entries.map((e) => e.entryId), ['entry-0', 'entry-1']);
    expect(
      androidNativeUpcomingEntries(
        queue(index: 2),
        loopMode: LoopMode.all,
        shuffleEnabled: true,
      ),
      isEmpty,
    );
  });

  test('repeat one leaves the next track out of the native window', () {
    expect(
      androidNativeUpcomingEntries(
        queue(),
        loopMode: LoopMode.one,
        shuffleEnabled: false,
      ),
      isEmpty,
    );
  });

  test('reordering and removal change the prepared occurrences', () {
    final reordered = queue().move(2, 1, shuffleEnabled: false);
    expect(
      androidNativeUpcomingEntries(
        reordered,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      ).map((e) => e.entryId),
      ['entry-2', 'entry-1'],
    );
    expect(
      androidNativeUpcomingEntries(
        reordered.removeEntry('entry-2'),
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      ).map((e) => e.entryId),
      ['entry-1'],
    );
  });
}
