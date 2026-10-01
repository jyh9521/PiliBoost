import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/services/video_accelerator/range_protocol.dart';

/// Immutable representation identity supplied by the caller, not by a client URL.
class RangeResource {
  RangeResource({required this.uri, required this.totalBytes, this.etag}) {
    if (!['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        totalBytes <= 0) {
      throw ArgumentError('Invalid range resource');
    }
    if (etag != null && !EntityTag.isTransportableStrong(etag)) {
      throw ArgumentError('A strong ETag is required when provided');
    }
  }
  final Uri uri;
  final int totalBytes;
  final String? etag;
}

class RangeCancelled implements Exception {
  const RangeCancelled();
  @override
  String toString() => 'RangeCancelled';
}

class RangeCancellation {
  bool _cancelled = false;
  final _closers = <void Function()>{};
  bool get cancelled => _cancelled;
  void check() {
    if (_cancelled) throw const RangeCancelled();
  }

  void attach(void Function() close) {
    check();
    _closers.add(close);
  }

  void detach(void Function() close) => _closers.remove(close);
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final close in _closers.toList()) {
      close();
    }
    _closers.clear();
  }
}

class RangeTransferException implements Exception {
  const RangeTransferException(this.reason, {this.retryable = false});
  final String reason;
  final bool retryable;
  @override
  String toString() => 'RangeTransferException($reason)';
}

class RangeChunk {
  const RangeChunk(
    this.start,
    this.bytes,
    this.elapsed,
    this.ttfb,
    this.attempts,
  );
  final int start, attempts;
  final Uint8List bytes;
  final Duration elapsed, ttfb;
}

/// Strict bounded chunk transport. Only transient failures retry the exact range.
class RangeDownloader {
  RangeDownloader({
    required this.headers,
    required this.clientFactory,
    this.onBytesReceived,
    this.maxChunkBytes = 256 * 1024,
    this.maxAttempts = 2,
    this.timeout = const Duration(seconds: 8),
    this.retryDelay = const Duration(milliseconds: 150),
  }) {
    if (maxChunkBytes <= 0 ||
        maxChunkBytes > 1024 * 1024 ||
        maxAttempts < 1 ||
        maxAttempts > 3 ||
        timeout <= Duration.zero ||
        retryDelay < Duration.zero ||
        retryDelay > const Duration(seconds: 1)) {
      throw ArgumentError('Invalid download budget');
    }
  }
  final void Function(int)? onBytesReceived;
  final Map<String, String> headers;
  final HttpClient Function() clientFactory;
  final int maxChunkBytes, maxAttempts;
  final Duration timeout, retryDelay;
  int attempts = 0, retries = 0, upstreamBytes = 0;
  int activeRequests = 0, peakActiveRequests = 0;

  Future<RangeChunk> fetch(
    RangeResource resource,
    int start,
    int end,
    RangeCancellation token,
  ) async {
    if (start < 0 ||
        end < start ||
        end >= resource.totalBytes ||
        end - start + 1 > maxChunkBytes) {
      throw ArgumentError('Chunk outside resource or budget');
    }
    for (var attempt = 1; ; attempt++) {
      token.check();
      try {
        return await _attempt(resource, start, end, token, attempt);
      } on RangeTransferException catch (error) {
        token.check();
        if (!error.retryable || attempt >= maxAttempts) rethrow;
        retries++;
        // Short backoff; cancellation is checked before starting another socket.
        await Future<void>.delayed(retryDelay);
      }
    }
  }

  Future<RangeChunk> _attempt(
    RangeResource resource,
    int start,
    int end,
    RangeCancellation token,
    int attempt,
  ) async {
    token.check();
    final client = clientFactory()..autoUncompress = false;
    void close() => client.close(force: true);
    token.attach(close);
    attempts++;
    activeRequests++;
    if (activeRequests > peakActiveRequests) {
      peakActiveRequests = activeRequests;
    }
    final watch = Stopwatch()..start();
    Timer? deadline;
    var timedOut = false;
    try {
      // Includes connection, headers and entire bounded body, not just idle time.
      deadline = Timer(timeout, () {
        timedOut = true;
        close();
      });
      final request = await client.getUrl(resource.uri);
      token.check();
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      request.headers.set('accept-encoding', 'identity');
      request.headers.set('range', 'bytes=$start-$end');
      if (resource.etag != null) {
        request.headers.set('if-match', resource.etag!);
      }
      final response = await request.close();
      token.check();
      final status = response.statusCode;
      if ([500, 502, 503, 504, 408].contains(status)) {
        throw const RangeTransferException('transientStatus', retryable: true);
      }
      // 429/403/412, redirects and Range-ignored 200 never amplify traffic.
      if (status != 206) throw RangeTransferException('http$status');
      final cr = ContentRange.parse(
        response.headers.value('content-range') ?? '',
      );
      if (cr.start != start ||
          cr.end != end ||
          cr.total != resource.totalBytes ||
          response.contentLength != end - start + 1 ||
          (response.headers.value('content-encoding') ?? 'identity') !=
              'identity') {
        throw const RangeTransferException('rangeIdentity');
      }
      if (resource.etag != null &&
          response.headers.value('etag') != resource.etag) {
        throw const RangeTransferException('etagIdentity');
      }
      final bytes = Uint8List(end - start + 1);
      var received = 0;
      Duration? firstByte;
      await for (final chunk in response) {
        token.check();
        upstreamBytes += chunk.length;
        onBytesReceived?.call(chunk.length);
        firstByte ??= watch.elapsed;
        if (received + chunk.length > bytes.length) {
          throw const RangeTransferException('oversizedBody');
        }
        bytes.setRange(received, received + chunk.length, chunk);
        received += chunk.length;
      }
      token.check();
      if (timedOut) {
        throw const RangeTransferException('deadline', retryable: true);
      }
      if (received != bytes.length) {
        throw const RangeTransferException('truncatedBody', retryable: true);
      }
      return RangeChunk(
        start,
        bytes,
        watch.elapsed,
        firstByte ?? watch.elapsed,
        attempt,
      );
    } on RangeCancelled {
      rethrow;
    } on RangeTransferException {
      rethrow;
    } on FormatException {
      throw const RangeTransferException('rangeSyntax');
    } on IOException {
      token.check();
      throw RangeTransferException(
        timedOut ? 'deadline' : 'transport',
        retryable: true,
      );
    } finally {
      deadline?.cancel();
      token.detach(close);
      close();
      activeRequests--;
    }
  }
}
