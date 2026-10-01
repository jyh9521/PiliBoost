// ignore_for_file: cascade_invocations
import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/services/video_accelerator/range_downloader.dart';
import 'package:PiliPlus/services/video_accelerator/range_memory_cache.dart';
import 'package:PiliPlus/services/video_accelerator/range_cdn_pool.dart';
import 'package:PiliPlus/services/video_accelerator/range_protocol.dart';

void main() {
  late HttpServer server;
  late RangeResource primary;
  late RangePoolDownloader pool;
  var mismatch = false, transient = false, forbidden = false;
  Duration now = Duration.zero;
  Completer<void>? recoveryGate, optionalGate;
  final counts = <String, int>{};
  final bytes = List<int>.generate(1024 * 1024, (i) => i % 251);
  setUp(() async {
    mismatch = transient = forbidden = false;
    counts.clear();
    now = Duration.zero;
    recoveryGate = optionalGate = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      try {
        final name = r.uri.path;
        counts.update(name, (n) => n + 1, ifAbsent: () => 1);
        final (a, b) = ByteRange.parse(r.headers.value('range')!)
            .resolve(bytes.length)!;
        expect(r.headers.value('if-match'), '"fixture"');
        if (name == '/b' && optionalGate != null) await optionalGate!.future;
        if (name == '/a' && recoveryGate != null && b - a + 1 > 65536) {
          await recoveryGate!.future;
        }
        final payload = bytes.sublist(a, b + 1);
        if (mismatch && name == '/b') payload[0] ^= 1;
        r.response.statusCode = transient && name == '/a' && b - a + 1 > 65536
            ? 503
            : forbidden && b - a + 1 > 65536
            ? 403
            : 206;
        if (r.response.statusCode == 206) {
          r.response.headers.set('etag', '"fixture"');
          r.response.headers.set(
            'content-range',
            'bytes $a-$b/${bytes.length}',
          );
          r.response.contentLength = payload.length;
          r.response.add(payload);
        } else {
          r.response.contentLength = 0;
        }
        await r.response.close();
      } catch (_) {}
    });
    final base = 'http://127.0.0.1:${server.port}';
    primary = RangeResource(
      uri: Uri.parse('$base/a'),
      totalBytes: bytes.length,
      etag: '"fixture"',
    );
    pool = RangePoolDownloader(
      headers: const {},
      clientFactory: HttpClient.new,
      cache: RangeMemoryCache(),
      primary: primary,
      now: () => now,
      candidates: [Uri.parse('$base/b')],
    );
  });
  tearDown(() async {
    if (recoveryGate != null && !recoveryGate!.isCompleted) {
      recoveryGate!.complete();
    }
    if (optionalGate != null && !optionalGate!.isCompleted) {
      optionalGate!.complete();
    }
    await server.close(force: true);
  });
  test('matching anchors admit candidates; assignment uses measured completion cost', () async {
    await pool.prepare(RangeCancellation());
    expect(pool.lanes.length, 2);
    final a = pool.lanes[0], b = pool.lanes[1];
    a.fastBps = a.slowBps = 1000000;
    b.fastBps = b.slowBps = 100000000;
    final c = await pool.fetch(primary, 131072, 393215, RangeCancellation());
    expect(c.bytes, bytes.sublist(131072, 393216));
    expect(counts['/b'], 3);
    expect(counts['/a'], 2);
    expect(
      pool.upstreamBytes,
      524288,
    ); // four 64 KiB anchors plus one 256 KiB chunk.
    final before = counts.values.fold<int>(0, (a, b) => a + b);
    final cached = await pool.fetch(
      primary,
      131072,
      393215,
      RangeCancellation(),
    );
    expect(cached.attempts, 0);
    expect(counts.values.fold<int>(0, (a, b) => a + b), before);
  });
  test('same length and ETag but different anchors are rejected', () async {
    mismatch = true;
    await pool.prepare(RangeCancellation());
    expect(pool.lanes.length, 1);
    expect(pool.rejectedCandidates, 1);
    expect(pool.rejectionReasons, {'anchorMismatch': 1});
  });
  test(
    'transient failed chunk moves to healthy lane and failed lane cools down',
    () async {
      await pool.prepare(RangeCancellation());
      pool.lanes[0].fastBps = pool.lanes[0].slowBps = 1000000000;
      pool.lanes[1].fastBps = pool.lanes[1].slowBps = 1000;
      transient = true;
      final c = await pool.fetch(primary, 131072, 393215, RangeCancellation());
      expect(c.bytes, bytes.sublist(131072, 393216));
      expect(pool.failovers, 1);
      expect(pool.lanes[0].cooldownUntil, greaterThan(Duration.zero));
      expect(pool.attempts, 2);
      expect(pool.activeRequests, 0);
    },
  );
  test(
    '403 is terminal; no CDN retry amplifies expired authorization',
    () async {
      await pool.prepare(RangeCancellation());
      forbidden = true;
      await expectLater(
        pool.fetch(primary, 131072, 393215, RangeCancellation()),
        throwsA(
          isA<RangeTransferException>().having(
            (e) => e.reason,
            'reason',
            'http403',
          ),
        ),
      );
      expect(pool.attempts, 1);
      expect(pool.failovers, 0);
      expect(pool.activeRequests, 0);
    },
  );
  test('pre-cancelled discovery opens no socket', () async {
    final token = RangeCancellation()..cancel();
    await expectLater(pool.prepare(token), throwsA(isA<RangeCancelled>()));
    expect(counts, isEmpty);
  });
  test(
    'cooldown expiry permits only one half-open request before success',
    () async {
      await pool.prepare(RangeCancellation());
      final a = pool.lanes[0], b = pool.lanes[1];
      a.fastBps = a.slowBps = 1e9;
      b.fastBps = b.slowBps = 1000;
      transient = true;
      await pool.fetch(primary, 131072, 393215, RangeCancellation());
      expect(a.needsRecovery, isTrue);
      expect(a.failures, 1);
      transient = false;
      now = const Duration(seconds: 31);
      recoveryGate = Completer<void>();
      a.fastBps = a.slowBps = 1e9;
      b.fastBps = b.slowBps = 1000;
      final before = counts['/a']!;
      final jobs = List.generate(
        4,
        (i) => pool.fetch(
          primary,
          i * 131072,
          i * 131072 + 131071,
          RangeCancellation(),
        ),
      );
      final joined = Future.wait(jobs);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(a.active, 1);
      expect(counts['/a'], before + 1);
      expect(pool.diagnostics.first['recoveryState'], 'halfOpen');
      recoveryGate!.complete();
      final results = await joined;
      expect(results.length, 4);
      expect(a.needsRecovery, isFalse);
      expect(pool.activeRequests, 0);
    },
  );
  test('optional discovery budget leaves validated primary usable', () async {
    optionalGate = Completer<void>();
    pool = RangePoolDownloader(
      headers: const {},
      clientFactory: HttpClient.new,
      cache: RangeMemoryCache(),
      primary: primary,
      candidates: pool.candidates,
      prepareTimeout: const Duration(milliseconds: 150),
    );
    final parent = RangeCancellation();
    await pool.prepare(parent);
    expect(parent.cancelled, isFalse);
    expect(pool.prepared, isTrue);
    expect(pool.lanes.length, 1);
    expect(pool.rejectionReasons, {'validationBudget': 1});
    final c = await pool.fetch(primary, 131072, 393215, RangeCancellation());
    expect(c.bytes, bytes.sublist(131072, 393216));
  });
  test(
    'explicit cancellation does not turn into successful partial discovery',
    () async {
      optionalGate = Completer<void>();
      final token = RangeCancellation();
      final prepared = pool.prepare(token);
      final checked = expectLater(prepared, throwsA(isA<RangeCancelled>()));
      while ((counts['/b'] ?? 0) == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      await expectLater(pool.prepare(RangeCancellation()), throwsStateError);
      token.cancel();
      await checked;
      expect(pool.prepared, isFalse);
      expect(pool.lanes, isEmpty);
      optionalGate!.complete();
      optionalGate = null;
      await pool.prepare(RangeCancellation());
      expect(pool.lanes.length, 2);
      expect(pool.prepared, isTrue);
    },
  );
  test(
    'failed discovery can retry without retaining duplicate primary lanes',
    () async {
      final token = RangeCancellation()..cancel();
      await expectLater(pool.prepare(token), throwsA(isA<RangeCancelled>()));
      await pool.prepare(RangeCancellation());
      expect(pool.lanes.length, 2);
      await expectLater(
        pool.prepare(RangeCancellation()..cancel()),
        throwsA(isA<RangeCancelled>()),
      );
    },
  );
  for (final sample in [0, -1, 262145]) {
    test('invalid sample budget $sample opens no pool', () {
      expect(
        () => RangePoolDownloader(
          headers: const {},
          clientFactory: HttpClient.new,
          cache: RangeMemoryCache(),
          primary: primary,
          candidates: const [],
          sampleBytes: sample,
        ),
        throwsArgumentError,
      );
      expect(counts, isEmpty);
    });
  }
}
