import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:PiliPlus/services/video_accelerator/range_protocol.dart';

/// Immutable representation identity supplied by the caller, not by a client URL.
class RangeResource {
  RangeResource({
    required this.uri,
    required this.totalBytes,
    this.etag,
    this.verifiedBare,
  }) {
    if (!['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        totalBytes <= 0) {
      throw ArgumentError('Invalid range resource');
    }
    if (verifiedBare != null && !verifiedBare!.matches(uri, etag, totalBytes)) {
      throw ArgumentError('Bare proof does not match resource');
    }
    if (etag != null &&
        !EntityTag.isTransportableStrong(etag) &&
        !(verifiedBare?.matches(uri, etag, totalBytes) ?? false)) {
      throw ArgumentError('A strong ETag is required when provided');
    }
  }
  final Uri uri;
  final int totalBytes;
  final String? etag;
  final BareEtagProof? verifiedBare;
  String? get conditionalEtag =>
      verifiedBare == null || verifiedBare!.conditionFormat == 'raw'
      ? etag
      : '"$etag"';
}

/// Same-URI proof minted by conditional probes, not a standard strong validator.
class BareEtagProof {
  BareEtagProof._(this._uri, this._etag, this._total, this.conditionFormat);
  final String conditionFormat;
  final Uri _uri;
  final String _etag;
  final int _total;
  final _age = Stopwatch()..start();
  bool matches(Uri uri, String? etag, int total) =>
      uri == _uri &&
      etag == _etag &&
      total == _total &&
      _age.elapsed < const Duration(seconds: 60);
}

class BareEtagResult {
  const BareEtagResult(this.status, [this.proof, this.evidence = const {}]);
  final Map<String, Object?> evidence;
  final String status;
  final BareEtagProof? proof;
}

/// At most four one-byte probes; one deadline, no redirects or unbounded bodies.
abstract final class BareEtagVerifier {
  static Future<BareEtagResult> verify({
    required Uri uri,
    required String etag,
    required int totalBytes,
    required Map<String, String> headers,
    required HttpClient Function() clientFactory,
    required RangeCancellation token,
    Duration timeout = const Duration(seconds: 4),
    void Function(int)? onBytesReceived,
  }) async {
    token.check();
    if (!EntityTag.isBareCandidate(etag) ||
        totalBytes <= 0 ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      return const BareEtagResult('bareFormatRejected');
    }
    final client = clientFactory()..autoUncompress = false;
    void close() => client.close(force: true);
    token.attach(close);
    var expired = false;
    final evidence = <String, Object?>{'conditionFormat': 'quoted'};
    BareEtagResult result(String status, [BareEtagProof? proof]) =>
        BareEtagResult(status, proof, Map.unmodifiable(evidence));
    final timer = Timer(timeout, () {
      expired = true;
      close();
    });
    try {
      Future<HttpClientResponse> probe(String condition) async {
        final request = await client.getUrl(uri);
        token.check();
        request.followRedirects = false;
        headers.forEach(request.headers.set);
        request.headers.set('accept-encoding', 'identity');
        request.headers.set('range', 'bytes=0-0');
        request.headers.set('if-match', condition);
        final response = await request.close();
        token.check();
        return response;
      }

      Future<void> abandon(HttpClientResponse response) async {
        await response.detachSocket().then((socket) => socket.destroy());
      }

      String? metadataFailure(HttpClientResponse response) {
        if (response.statusCode != 206) return 'unexpectedStatus';
        if (response.contentLength != 1) return 'lengthMismatch';
        if (response.headers.value('content-range') !=
            'bytes 0-0/$totalBytes') {
          return 'rangeMismatch';
        }
        if (response.headers.value('etag') != etag) return 'etagIdentity';
        if ((response.headers.value('content-encoding') ?? 'identity') !=
            'identity') {
          return 'encodedContent';
        }
        return null;
      }

      // Quoted form follows RFC syntax. Only an explicit 412 enables a raw trial.
      final nonce = List.generate(
        16,
        (_) => Random.secure().nextInt(256),
      ).map((n) => n.toRadixString(16).padLeft(2, '0')).join();
      final negative = await probe('"pili-mismatch.$nonce"');
      evidence['quotedNegativeStatusCode'] = negative.statusCode;
      if (negative.statusCode != 412) return result('bareConditionIgnored');
      await abandon(negative);
      var positive = await probe('"$etag"');
      evidence['quotedPositiveStatusCode'] = positive.statusCode;
      if (positive.statusCode == 412) {
        await abandon(positive);
        evidence['conditionFormat'] = 'raw';
        // Same token shape, guaranteed different value. Both raw controls must pass.
        final first = etag[0];
        final wrongFirst = RegExp(r'[0-9]').hasMatch(first)
            ? (first == '0' ? '1' : '0')
            : RegExp(r'[A-Z]').hasMatch(first)
            ? (first == 'A' ? 'B' : 'A')
            : (first == 'a' ? 'b' : 'a');
        final rawNegative = await probe(wrongFirst + etag.substring(1));
        evidence['rawNegativeStatusCode'] = rawNegative.statusCode;
        if (rawNegative.statusCode != 412) {
          return result('bareConditionIgnored');
        }
        await abandon(rawNegative);
        positive = await probe(etag);
        evidence['rawPositiveStatusCode'] = positive.statusCode;
      }
      final failure = metadataFailure(positive);
      if (failure != null) {
        evidence['positiveFailureReason'] = failure;
        return result('barePositiveRejected');
      }
      var received = 0;
      await for (final chunk in positive) {
        token.check();
        onBytesReceived?.call(chunk.length);
        received += chunk.length;
        if (received > 1) {
          evidence['positiveFailureReason'] = 'oversizedBody';
          return result('barePositiveRejected');
        }
      }
      token.check();
      if (expired) return result('bareProbeFailed');
      if (received != 1) {
        evidence['positiveFailureReason'] = 'truncatedBody';
        return result('barePositiveRejected');
      }
      return result(
        'bareConditionalVerified',
        BareEtagProof._(
          uri,
          etag,
          totalBytes,
          evidence['conditionFormat']! as String,
        ),
      );
    } on RangeCancelled {
      rethrow;
    } catch (_) {
      token.check();
      evidence['positiveFailureReason'] = expired ? 'deadline' : 'transport';
      return result('bareProbeFailed');
    } finally {
      timer.cancel();
      token.detach(close);
      close();
    }
  }
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
        request.headers.set('if-match', resource.conditionalEtag!);
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
