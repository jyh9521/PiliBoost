import 'dart:async';
import 'dart:typed_data';
import 'dart:math';

import 'package:PiliPlus/services/video_accelerator/range_downloader.dart';

class _Outcome {
  const _Outcome(this.chunk, this.error);
  final RangeChunk? chunk;
  final Object? error;
}

/// Demand-driven bounded reorder windows; no speculative cache or disk writes.
/// One active consumer. Cancel its subscription before opening a seek generation.
class OrderedRangeScheduler {
  OrderedRangeScheduler({
    required this.downloader,
    this.concurrency = 4,
    this.chunkBytes = 256 * 1024,
    this.maxMemoryBytes = 4 * 1024 * 1024,
  }) {
    if (concurrency < 1 ||
        concurrency > 16 ||
        chunkBytes <= 0 ||
        chunkBytes > downloader.maxChunkBytes ||
        maxMemoryBytes < concurrency * chunkBytes) {
      throw ArgumentError('Invalid scheduler budget');
    }
  }
  final RangeDownloader downloader;
  final int concurrency, chunkBytes, maxMemoryBytes;
  RangeCancellation? _token;
  bool _busy = false;
  final _clock = Stopwatch();
  int generation = 0,
      reservedBytes = 0,
      peakReservedBytes = 0,
      deliveredBytes = 0;

  /// Ordered bytes handed to this read's consumer / wall time, including pauses.
  double get deliveredBps => _clock.elapsedMicroseconds == 0
      ? 0
      : deliveredBytes * 8e6 / _clock.elapsedMicroseconds;

  void invalidate() {
    generation++;
    _token?.cancel();
  }

  Stream<Uint8List> read(RangeResource resource, int start, int end) async* {
    if (_busy) {
      throw StateError('Cancel the previous reader before starting a range');
    }
    if (start < 0 || end < start || end >= resource.totalBytes) {
      throw ArgumentError('Invalid read range');
    }
    _busy = true;
    deliveredBytes = 0;
    _clock
      ..reset()
      ..start();
    final epoch = generation;
    final token = RangeCancellation();
    _token = token;
    var pending = <Future<_Outcome>>[];
    try {
      var cursor = start;
      while (cursor <= end) {
        token.check();
        reservedBytes = 0;
        pending = [];
        for (var i = 0; i < concurrency && cursor <= end; i++) {
          final last = min(cursor + chunkBytes - 1, end);
          reservedBytes += last - cursor + 1;
          // Handle every Future immediately, including out-of-order failures.
          pending.add(
            downloader
                .fetch(resource, cursor, last, token)
                .then(
                  (chunk) => _Outcome(chunk, null),
                  onError: (Object error) => _Outcome(null, error),
                ),
          );
          cursor = last + 1;
        }
        if (reservedBytes > peakReservedBytes) {
          peakReservedBytes = reservedBytes;
        }
        for (final future in pending) {
          final outcome = await future;
          token.check();
          if (epoch != generation) throw const RangeCancelled();
          if (outcome.error != null) throw outcome.error!;
          deliveredBytes += outcome.chunk!.bytes.length;
          yield outcome.chunk!.bytes;
        }
        // Start no additional window while the consumer is paused at yield.
        pending = [];
        reservedBytes = 0;
      }
    } finally {
      token.cancel();
      await Future.wait(pending);
      reservedBytes = 0;
      if (identical(_token, token)) _token = null;
      _busy = false;
      _clock.stop();
    }
  }
}
