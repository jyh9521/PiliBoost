import 'dart:async';
import 'dart:typed_data';
import 'dart:math';

import 'package:PiliPlus/services/video_accelerator/range_downloader.dart';

class _Outcome {
  const _Outcome(this.chunk, this.error);
  final RangeChunk? chunk;
  final Object? error;
}

/// Demand-driven rolling reorder queue; refill only after consumer resumes.
/// One active consumer. Cancel its subscription before opening a seek generation.
class OrderedRangeScheduler {
  OrderedRangeScheduler({
    required this.downloader,
    this.concurrency = 4,
    this.chunkBytes = 256 * 1024,
    this.maxMemoryBytes = 4 * 1024 * 1024,
    this.windowConcurrency,
    this.onChunkReady,
  }) {
    if (concurrency < 1 ||
        concurrency > 16 ||
        chunkBytes <= 0 ||
        chunkBytes > downloader.maxChunkBytes ||
        maxMemoryBytes < concurrency * chunkBytes) {
      throw ArgumentError('Invalid scheduler budget');
    }
  }
  final void Function(RangeChunk)? onChunkReady;
  final int Function()? windowConcurrency;
  final RangeDownloader downloader;
  final int concurrency, chunkBytes, maxMemoryBytes;
  RangeCancellation? _token;
  bool _busy = false;
  final _clock = Stopwatch();
  int generation = 0,
      reservedBytes = 0,
      peakReservedBytes = 0,
      deliveredBytes = 0,
      pendingRanges = 0;

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
    final pending = <(int, Future<_Outcome>)>[];
    Object? firstFailure;
    var cursor = start;
    void fill() {
      final width = (windowConcurrency?.call() ?? concurrency).clamp(
        1,
        concurrency,
      );
      while (pending.length < width && cursor <= end && !token.cancelled) {
        final first = cursor, last = min(cursor + chunkBytes - 1, end);
        final length = last - first + 1;
        reservedBytes += length;
        final future = downloader
            .fetch(resource, first, last, token)
            .then(
              (chunk) => _Outcome(chunk, null),
              onError: (Object error) {
                if (error is! RangeCancelled) {
                  firstFailure ??= error;
                  token.cancel();
                }
                return _Outcome(null, error);
              },
            );
        pending.add((length, future));
        cursor = last + 1;
      }
      pendingRanges = pending.length;
      peakReservedBytes = max(peakReservedBytes, reservedBytes);
    }

    try {
      while (cursor <= end || pending.isNotEmpty) {
        if (firstFailure != null) throw firstFailure!;
        token.check();
        fill();
        final entry = pending.removeAt(0);
        final outcome = await entry.$2;
        if (firstFailure != null) throw firstFailure!;
        token.check();
        if (epoch != generation) throw const RangeCancelled();
        if (outcome.error != null) throw outcome.error!;
        pendingRanges = pending.length;
        deliveredBytes += outcome.chunk!.bytes.length;
        onChunkReady?.call(outcome.chunk!);
        yield outcome.chunk!.bytes;
        // Keep yielded bytes reserved while paused. Refill on next iteration only.
        reservedBytes -= entry.$1;
      }
    } finally {
      token.cancel();
      await Future.wait(pending.map((entry) => entry.$2));
      reservedBytes = 0;
      pendingRanges = 0;
      if (identical(_token, token)) _token = null;
      _busy = false;
      _clock.stop();
    }
  }
}
