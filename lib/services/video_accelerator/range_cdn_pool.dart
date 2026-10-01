import 'dart:async';
import 'dart:math';

import 'package:PiliPlus/services/video_accelerator/range_downloader.dart';
import 'package:PiliPlus/services/video_accelerator/range_memory_cache.dart';

class RangePoolLane {
  RangePoolLane(this.resource, this.downloader);
  final RangeResource resource;
  final RangeDownloader downloader;
  double fastBps = 0, slowBps = 0, ttfbMs = 0;
  int active = 0, successes = 0, failures = 0, timeouts = 0;
  Duration cooldownUntil = Duration.zero;
  bool excluded = false, needsRecovery = false;
  double score(int bytes) =>
      (active + 1) *
      (bytes * 8 / max(1, min(fastBps, slowBps)) + ttfbMs / 1000);
  void sample(RangeChunk c) {
    final rate = c.bytes.length * 8e6 / max(1, c.elapsed.inMicroseconds);
    fastBps = fastBps == 0 ? rate : fastBps * 0.5 + rate * 0.5;
    slowBps = slowBps == 0 ? rate : slowBps * 0.8 + rate * 0.2;
    ttfbMs = c.ttfb.inMicroseconds / 1000;
    successes++;
  }

  Map<String, Object?> get diagnostics => {
    'host': resource.uri.host,
    'throughputBps': min(fastBps, slowBps),
    'ttfbMs': ttfbMs,
    'active': active,
    'successes': successes,
    'errors': failures,
    'excluded': excluded,
    'recoveryProbePending': needsRecovery,
    'timeouts': timeouts,
    'rttMs': null,
  };
}

/// Only matching strong validator + exact total + matching head/tail samples enter.
/// Anchors are admission checks, not a cryptographic whole-file equality proof.
class RangePoolDownloader extends CachedRangeDownloader {
  RangePoolDownloader({
    required super.headers,
    required super.clientFactory,
    required super.cache,
    super.onBytesReceived,
    required this.primary,
    required this.candidates,
    this.sampleBytes = 64 * 1024,
    this.probeTimeout = const Duration(seconds: 4),
    this.prepareTimeout = const Duration(seconds: 8),
    this.cooldown = const Duration(seconds: 30),
    Duration Function()? now,
  }) {
    if (sampleBytes <= 0 ||
        sampleBytes > maxChunkBytes ||
        probeTimeout <= Duration.zero ||
        prepareTimeout <= Duration.zero ||
        cooldown < Duration.zero) {
      throw ArgumentError('Invalid pool recovery budget');
    }
    _now = now ?? (() => _clock.elapsed);
  }
  final int sampleBytes;
  final Duration probeTimeout, prepareTimeout, cooldown;
  final RangeResource primary;
  final List<Uri> candidates;
  final lanes = <RangePoolLane>[];
  final _clock = Stopwatch()..start();
  late final Duration Function() _now;
  bool _preparing = false;
  int rejectedCandidates = 0, failovers = 0;
  final rejectionReasons = <String, int>{};
  void _reject(String reason) {
    rejectedCandidates++;
    rejectionReasons.update(reason, (n) => n + 1, ifAbsent: () => 1);
  }

  List<Map<String, Object?>> get diagnostics => lanes
      .map(
        (l) => {
          ...l.diagnostics,
          'cooldownMs': max(
            0,
            (l.cooldownUntil - _now()).inMilliseconds,
          ),
          'recoveryState': l.excluded
              ? 'excluded'
              : l.needsRecovery
              ? (l.cooldownUntil > _now() ? 'cooling' : 'halfOpen')
              : 'ready',
          'weight': l.excluded || l.cooldownUntil > _now()
              ? 0.0
              : 1 / l.score(256 * 1024),
        },
      )
      .toList();
  bool prepared = false;
  int _rejectedProbeBytes = 0;
  void _syncBytes() {
    upstreamBytes =
        _rejectedProbeBytes +
        lanes.fold<int>(0, (sum, l) => sum + l.downloader.upstreamBytes);
  }

  bool matches(RangeResource r) =>
      r.uri == primary.uri &&
      r.etag == primary.etag &&
      r.totalBytes == primary.totalBytes;
  RangePoolLane lane(RangeResource r) => RangePoolLane(
    r,
    RangeDownloader(
      headers: headers,
      clientFactory: clientFactory,
      onBytesReceived: onBytesReceived,
      maxAttempts: 1,
      timeout: probeTimeout,
    ),
  );
  Future<void> prepare(RangeCancellation token) async {
    token.check();
    if (prepared) return;
    if (_preparing) throw StateError('Pool discovery already active');
    if (primary.etag == null || primary.verifiedBare != null) {
      throw ArgumentError('Validated pool requires strong identity');
    }
    _preparing = true;
    final validation = RangeCancellation();
    void cancelValidation() => validation.cancel();
    token.attach(cancelValidation);
    var budgetExpired = false;
    final timer = Timer(prepareTimeout, () {
      budgetExpired = true;
      validation.cancel();
    });
    try {
      final first = lane(primary);
      lanes.add(first);
      final headEnd = min(primary.totalBytes - 1, sampleBytes - 1);
      final tailStart = max(0, primary.totalBytes - sampleBytes);
      Future<RangeChunk> anchor(RangePoolLane l, int a, int b) async {
        try {
          final c = await l.downloader.fetch(l.resource, a, b, validation);
          l.sample(c);
          return c;
        } finally {
          _syncBytes();
        }
      }

      final head = await anchor(first, 0, headEnd);
      final tail = await anchor(first, tailStart, primary.totalBytes - 1);
      for (final uri
          in candidates.where((u) => u != primary.uri).toSet().take(2)) {
        token.check();
        final next = lane(
          RangeResource(
            uri: uri,
            totalBytes: primary.totalBytes,
            etag: primary.etag,
          ),
        );
        // If-Match and response ETag must match exactly on every probe and chunk.
        try {
          final h = await next.downloader.fetch(
            next.resource,
            0,
            headEnd,
            validation,
          );
          final t = await next.downloader.fetch(
            next.resource,
            tailStart,
            primary.totalBytes - 1,
            validation,
          );
          if (!_equal(head.bytes, h.bytes) || !_equal(tail.bytes, t.bytes)) {
            _reject('anchorMismatch');
            continue;
          }
          next
            ..sample(h)
            ..sample(t);
          lanes.add(next);
        } on RangeCancelled {
          // Explicit seek/close cancellation takes precedence over optional budget.
          token.check();
          if (budgetExpired) {
            _reject('validationBudget');
            break;
          }
          rethrow;
        } on RangeTransferException catch (error) {
          _reject(error.reason);
        } catch (_) {
          _reject('candidateValidationError');
        } finally {
          if (!lanes.contains(next)) {
            _rejectedProbeBytes += next.downloader.upstreamBytes;
          }
          _syncBytes();
        }
      }
      token.check();
      prepared = true;
    } finally {
      timer.cancel();
      token.detach(cancelValidation);
      validation.cancel();
      _preparing = false;
      if (!prepared) {
        _rejectedProbeBytes += lanes.fold<int>(
          0,
          (sum, l) => sum + l.downloader.upstreamBytes,
        );
        lanes.clear();
        _syncBytes();
      }
    }
  }

  static bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Future<RangeChunk> downloadChunk(
    RangeResource resource,
    int start,
    int end,
    RangeCancellation token,
  ) async {
    if (!prepared || !matches(resource)) {
      throw StateError('Unprepared representation pool');
    }
    final tried = <RangePoolLane>{};
    for (var attempt = 0; attempt < 2; attempt++) {
      token.check();
      final available =
          lanes
              .where(
                (l) =>
                    !l.excluded &&
                    !tried.contains(l) &&
                    l.cooldownUntil <= _now() &&
                    (!l.needsRecovery || l.active == 0),
              )
              .toList()
            ..sort(
              (a, b) =>
                  a.score(end - start + 1).compareTo(b.score(end - start + 1)),
            );
      if (available.isEmpty) {
        throw const RangeTransferException('poolUnavailable');
      }
      final selected = available.first;
      tried.add(selected);
      selected.active++;
      activeRequests++;
      if (activeRequests > peakActiveRequests) {
        peakActiveRequests = activeRequests;
      }

      try {
        attempts++;
        final c = await selected.downloader.fetch(
          selected.resource,
          start,
          end,
          token,
        );
        selected
          ..sample(c)
          ..needsRecovery = false;
        return c;
      } on RangeTransferException catch (error) {
        selected.failures++;
        selected.needsRecovery = true;
        if (error.reason == 'deadline') selected.timeouts++;
        selected.cooldownUntil = _now() + cooldown;
        if (!error.retryable) {
          selected.excluded = true;
          rethrow;
        }
        if (attempt == 1) rethrow;
        failovers++;
        retries++;
      } finally {
        _syncBytes();
        selected.active--;
        activeRequests--;
      }
    }
    throw const RangeTransferException('poolUnavailable');
  }
}
