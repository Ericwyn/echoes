import 'package:just_audio/just_audio.dart';

import '../../data/models/audio_quality.dart';
import 'playback_queue_state.dart';
import 'player_state.dart';

/// Identity belongs to a queue occurrence, including duplicate song IDs.
class AndroidNativeQueueTrack {
  const AndroidNativeQueueTrack({
    required this.entryId,
    required this.quality,
    required this.source,
  });

  final String entryId;
  final AudioQualityLevel quality;
  final PlaybackSource source;
}

/// A small native window follows the notifier's visible order. Native shuffle
/// stays disabled; a new shuffle round is still chosen by the notifier.
List<QueueEntry> androidNativeUpcomingEntries(
  PlaybackQueueState queue, {
  required LoopMode loopMode,
  required bool shuffleEnabled,
  int count = 2,
}) {
  if (queue.currentIndex < 0 || queue.length < 2 || loopMode == LoopMode.one) {
    return const [];
  }
  final result = <QueueEntry>[];
  for (var step = 1; step <= count; step++) {
    final index = queue.currentIndex + step;
    if (index >= queue.length && (loopMode == LoopMode.off || shuffleEnabled)) {
      break;
    }
    result.add(queue.entryAt(index % queue.length));
  }
  return result;
}
