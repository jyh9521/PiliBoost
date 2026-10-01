// ignore_for_file: cascade_invocations
import 'dart:io';

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
  final counts = <String, int>{};
  final bytes = List<int>.generate(1024 * 1024, (i) => i % 251);
  setUp(() async {
    mismatch = transient = forbidden = false;
    counts.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      try {
        final name = r.uri.path;
        counts.update(name, (n) => n + 1, ifAbsent: () => 1);
        final (a, b) = ByteRange.parse(r.headers.value('range')!)
            .resolve(bytes.length)!;
        expect(r.headers.value('if-match'), '"fixture"');
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
      candidates: [Uri.parse('$base/b')],
    );
  });
  tearDown(() async {
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
}
