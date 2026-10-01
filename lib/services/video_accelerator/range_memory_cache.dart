import 'dart:typed_data';

import 'package:PiliPlus/services/video_accelerator/range_downloader.dart';

/// Session-only LRU payload cache. Keys include the exact signed URI and validator.
class RangeMemoryCache {
  RangeMemoryCache({
    this.maxBytes = 8 * 1024 * 1024,
    this.maxBehindBytes = 4 * 1024 * 1024,
    this.maxAheadBytes = 4 * 1024 * 1024,
  });
  final int maxBytes, maxBehindBytes, maxAheadBytes;
  final _entries = <(Uri, String, int, int, int), Uint8List>{};
  int bytes = 0, hits = 0;
  (Uri, String, int, int, int)? _key(RangeResource r, int a, int b) =>
      r.etag == null ? null : (r.uri, r.etag!, r.totalBytes, a, b);
  Uint8List? get(RangeResource r, int a, int b) {
    final key = _key(r, a, b);
    if (key == null) return null;
    final value = _entries.remove(key);
    if (value != null) {
      _entries[key] = value;
      hits++;
    }
    return value;
  }

  Uint8List put(RangeResource r, int a, int b, Uint8List value) {
    final key = _key(r, a, b);
    if (key == null || value.length > maxBytes || maxBytes <= 0) return value;
    _entries.removeWhere((k, v) {
      final discard =
          k.$1 != r.uri ||
          k.$2 != r.etag ||
          k.$3 != r.totalBytes ||
          k.$5 < a - maxBehindBytes ||
          k.$4 > a + maxAheadBytes;
      if (discard) bytes -= v.length;
      return discard;
    });
    final old = _entries.remove(key);
    bytes -= old?.length ?? 0;
    while (_entries.isNotEmpty && bytes + value.length > maxBytes) {
      final first = _entries.keys.first;
      bytes -= _entries.remove(first)!.length;
    }
    final owned = Uint8List.fromList(value).asUnmodifiableView();
    _entries[key] = owned;
    bytes += owned.length;
    return owned;
  }

  void clear() {
    _entries.clear();
    bytes = 0;
  }
}

class CachedRangeDownloader extends RangeDownloader {
  CachedRangeDownloader({
    required super.headers,
    required super.clientFactory,
    required this.cache,
  });
  final RangeMemoryCache cache;
  @override
  Future<RangeChunk> fetch(
    RangeResource resource,
    int start,
    int end,
    RangeCancellation token,
  ) async {
    token.check();
    if (start < 0 ||
        end < start ||
        end >= resource.totalBytes ||
        end - start + 1 > maxChunkBytes) {
      throw ArgumentError('Chunk outside resource or budget');
    }
    final bytes = cache.get(resource, start, end);
    if (bytes != null) {
      return RangeChunk(start, bytes, Duration.zero, Duration.zero, 0);
    }
    final chunk = await downloadChunk(resource, start, end, token);
    token.check();
    final immutable = cache.put(resource, start, end, chunk.bytes);
    return RangeChunk(
      start,
      immutable,
      chunk.elapsed,
      chunk.ttfb,
      chunk.attempts,
    );
  }

  Future<RangeChunk> downloadChunk(
    RangeResource resource,
    int start,
    int end,
    RangeCancellation token,
  ) => super.fetch(resource, start, end, token);
}
