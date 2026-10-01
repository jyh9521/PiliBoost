// ignore_for_file: cascade_invocations
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/services/video_accelerator/range_downloader.dart';
import 'package:PiliPlus/services/video_accelerator/range_scheduler.dart';

void main() {
  late HttpServer server;
  late RangeDownloader downloader;
  late RangeResource resource;
  final data = List<int>.generate(8192, (i) => i % 251);
  var status = 206, failures = 0, delayMs = 0;
  int? failedOffset;
  var wrongRange = false,
      wrongTotal = false,
      wrongEtag = false,
      encoded = false;
  final requested = <String>[];
  final completed = <int>[];
  String? seenQuery, seenReferer, seenIfMatch;
  setUp(() async {
    status = 206;
    failures = delayMs = 0;
    failedOffset = null;
    wrongRange = wrongTotal = wrongEtag = encoded = false;
    requested.clear();
    completed.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      try {
        final raw = r.headers.value('range')!;
        requested.add(raw);
        seenQuery = r.uri.query;
        seenReferer = r.headers.value('referer');
        seenIfMatch = r.headers.value('if-match');
        final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(raw)!;
        final start = int.parse(match[1]!), end = int.parse(match[2]!);
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        // Earlier offsets deliberately finish later to exercise ordered output.
        if (r.uri.path == '/reorder') {
          await Future<void>.delayed(
            Duration(milliseconds: start < 1024 ? 50 : 2),
          );
        }
        final replyStatus = failures > 0 || failedOffset == start
            ? 503
            : status;
        if (failures > 0) failures--;
        r.response.statusCode = replyStatus;
        if (replyStatus == 206) {
          r.response.headers.set(
            'content-range',
            'bytes ${wrongRange ? start + 1 : start}-$end/${wrongTotal ? data.length + 1 : data.length}',
          );
          r.response.headers.set(
            'etag',
            wrongEtag ? '"different"' : '"fixture-v1"',
          );
          if (encoded) r.response.headers.set('content-encoding', 'gzip');
          r.response.contentLength = end - start + 1;
          r.response.add(data.sublist(start, end + 1));
        } else {
          r.response.contentLength = 0;
        }
        await r.response.close();
        completed.add(start);
      } catch (_) {
        /* Deadline/seek cancels the fixture socket. */
      }
    });
    resource = RangeResource(
      uri: Uri.parse('http://127.0.0.1:${server.port}/video?sign=a%2Fb'),
      totalBytes: data.length,
      etag: '"fixture-v1"',
    );
    downloader = RangeDownloader(
      headers: {'referer': 'https://www.bilibili.com'},
      clientFactory: HttpClient.new,
      maxChunkBytes: 1024,
      timeout: const Duration(milliseconds: 200),
      retryDelay: Duration.zero,
    );
  });
  tearDown(() => server.close(force: true));

  test(
    'partial upstream bodies count retry bytes but never yield a chunk',
    () async {
      final raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var hits = 0;
      raw.listen((socket) {
        var answered = false;
        socket.listen((_) async {
          if (answered) return;
          answered = true;
          hits++;
          socket.write(
            'HTTP/1.1 206 Partial Content\r\nContent-Length: 1024\r\nContent-Range: bytes 0-1023/8192\r\nETag: "fixture-v1"\r\nConnection: close\r\n\r\n',
          );
          socket.add(List<int>.filled(32, 7));
          await socket.flush();
          await socket.close();
        });
      });
      try {
        final source = RangeResource(
          uri: Uri.parse('http://127.0.0.1:${raw.port}/video'),
          totalBytes: 8192,
          etag: '"fixture-v1"',
        );
        await expectLater(
          downloader.fetch(source, 0, 1023, RangeCancellation()),
          throwsA(isA<RangeTransferException>()),
        );
        expect(hits, 2);
        expect(downloader.upstreamBytes, 64);
        expect(downloader.activeRequests, 0);
      } finally {
        await raw.close();
      }
    },
  );
  for (final count in [4, 8, 12, 16]) {
    test('$count-way scheduler retains bounded ordered windows', () async {
      final scheduler = OrderedRangeScheduler(
        downloader: downloader,
        chunkBytes: 256,
        concurrency: count,
        maxMemoryBytes: count * 256,
      );
      expect(
        await scheduler.read(resource, 0, 8191).expand((x) => x).toList(),
        data,
      );
      expect(downloader.peakActiveRequests, count);
      expect(scheduler.peakReservedBytes, count * 256);
      expect(downloader.activeRequests, 0);
    });
  }

  test(
    'exact validated chunk preserves signed query and strong validator',
    () async {
      final chunk = await downloader.fetch(
        resource,
        13,
        1036,
        RangeCancellation(),
      );
      expect(chunk.start, 13);
      expect(chunk.bytes, data.sublist(13, 1037));
      expect(chunk.attempts, 1);
      expect(seenQuery, 'sign=a%2Fb');
      expect(seenReferer, 'https://www.bilibili.com');
      expect(seenIfMatch, '"fixture-v1"');
      expect(downloader.upstreamBytes, 1024);
      expect(downloader.activeRequests, 0);
    },
  );
  for (final bad in [200, 302, 403, 412, 416, 429]) {
    test('status $bad fails without body, retry or redirect', () async {
      status = bad;
      await expectLater(
        downloader.fetch(resource, 0, 1023, RangeCancellation()),
        throwsA(isA<RangeTransferException>()),
      );
      expect(requested, hasLength(1));
      expect(downloader.upstreamBytes, 0);
      expect(downloader.activeRequests, 0);
    });
  }
  for (final bad in ['range', 'total', 'etag', 'encoding']) {
    test('reject $bad identity without mixing representations', () async {
      wrongRange = bad == 'range';
      wrongTotal = bad == 'total';
      wrongEtag = bad == 'etag';
      encoded = bad == 'encoding';
      await expectLater(
        downloader.fetch(resource, 0, 1023, RangeCancellation()),
        throwsA(isA<RangeTransferException>()),
      );
      expect(requested, hasLength(1));
      expect(downloader.upstreamBytes, 0);
    });
  }
  test('transient failure retries identical range at most twice', () async {
    failures = 1;
    final chunk = await downloader.fetch(
      resource,
      0,
      1023,
      RangeCancellation(),
    );
    expect(chunk.bytes, data.take(1024));
    expect(chunk.attempts, 2);
    expect(requested, ['bytes=0-1023', 'bytes=0-1023']);
    expect(downloader.retries, 1);
    failures = 10;
    await expectLater(
      downloader.fetch(resource, 1024, 2047, RangeCancellation()),
      throwsA(isA<RangeTransferException>()),
    );
    expect(requested, hasLength(4));
    expect(downloader.activeRequests, 0);
  });
  test(
    'absolute deadline bounds attempts and cancellation aborts no retry',
    () async {
      delayMs = 300;
      await expectLater(
        downloader.fetch(resource, 0, 1023, RangeCancellation()),
        throwsA(isA<RangeTransferException>()),
      );
      expect(requested, hasLength(2));
      final token = RangeCancellation();
      final pending = downloader.fetch(resource, 1024, 2047, token);
      final assertion = expectLater(pending, throwsA(isA<RangeCancelled>()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      token.cancel();
      await assertion;
      expect(requested, hasLength(3));
      expect(downloader.activeRequests, 0);
    },
  );
  test('pre-cancelled token and invalid budgets allocate no sockets', () async {
    final token = RangeCancellation()..cancel();
    await expectLater(
      downloader.fetch(resource, 0, 1023, token),
      throwsA(isA<RangeCancelled>()),
    );
    await expectLater(
      downloader.fetch(resource, 0, 1024, RangeCancellation()),
      throwsArgumentError,
    );
    expect(
      () => RangeResource(uri: resource.uri, totalBytes: 1, etag: 'W/"weak"'),
      throwsArgumentError,
    );
    expect(
      () => OrderedRangeScheduler(downloader: downloader, concurrency: 17),
      throwsArgumentError,
    );
    expect(
      () => OrderedRangeScheduler(
        downloader: downloader,
        concurrency: 4,
        chunkBytes: 1024,
        maxMemoryBytes: 1024,
      ),
      throwsArgumentError,
    );
    expect(requested, isEmpty);
  });
  test(
    'four out-of-order chunks produce exact ordered subrange within budget',
    () async {
      resource = RangeResource(
        uri: resource.uri.replace(path: '/reorder'),
        totalBytes: data.length,
        etag: resource.etag,
      );
      final scheduler = OrderedRangeScheduler(
        downloader: downloader,
        chunkBytes: 1024,
        concurrency: 4,
        maxMemoryBytes: 4096,
      );
      final output = await scheduler
          .read(resource, 13, 7500)
          .expand((x) => x)
          .toList();
      expect(output, data.sublist(13, 7501));
      expect(completed.indexOf(1037), lessThan(completed.indexOf(13)));
      expect(scheduler.deliveredBytes, output.length);
      expect(downloader.peakActiveRequests, lessThanOrEqualTo(4));
      expect(downloader.peakActiveRequests, greaterThan(1));
      expect(scheduler.peakReservedBytes, lessThanOrEqualTo(4096));
      expect(scheduler.reservedBytes, 0);
      expect(downloader.activeRequests, 0);
    },
  );
  test(
    'paused consumer starts no second window; cancelling releases reader',
    () async {
      final scheduler = OrderedRangeScheduler(
        downloader: downloader,
        chunkBytes: 1024,
        concurrency: 4,
        maxMemoryBytes: 4096,
      );
      final first = Completer<void>();
      late StreamSubscription<List<int>> sub;
      sub = scheduler.read(resource, 0, 8191).listen((_) {
        sub.pause();
        first.complete();
      });
      await first.future;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(requested, hasLength(4));
      expect(scheduler.reservedBytes, 4096);
      await expectLater(
        scheduler.read(resource, 0, 100).toList(),
        throwsStateError,
      );
      await sub.cancel();
      expect(scheduler.reservedBytes, 0);
      expect(downloader.activeRequests, 0);
      expect(
        await scheduler.read(resource, 7000, 7099).expand((x) => x).toList(),
        data.sublist(7000, 7100),
      );
    },
  );
  test(
    'generation cancellation excludes late output and permits next seek',
    () async {
      delayMs = 80;
      final scheduler = OrderedRangeScheduler(
        downloader: downloader,
        chunkBytes: 1024,
      );
      final pending = scheduler.read(resource, 0, 8191).toList();
      final assertion = expectLater(pending, throwsA(isA<RangeCancelled>()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      scheduler.invalidate();
      await assertion;
      expect(scheduler.deliveredBytes, 0);
      expect(downloader.activeRequests, 0);
      delayMs = 0;
      expect(
        await scheduler.read(resource, 7777, 8191).expand((x) => x).toList(),
        data.sublist(7777),
      );
    },
  );
  test(
    'failure in a later chunk is observed and remaining jobs are cancelled',
    () async {
      failedOffset = 1024;
      resource = RangeResource(
        uri: resource.uri.replace(path: '/reorder'),
        totalBytes: data.length,
        etag: resource.etag,
      );
      final scheduler = OrderedRangeScheduler(
        downloader: downloader,
        chunkBytes: 1024,
      );
      await expectLater(
        scheduler.read(resource, 0, 8191).toList(),
        throwsA(isA<RangeTransferException>()),
      );
      expect(scheduler.deliveredBytes, 1024);
      expect(scheduler.reservedBytes, 0);
      expect(downloader.activeRequests, 0);
      expect(requested.length, lessThanOrEqualTo(8));
    },
  );
}
