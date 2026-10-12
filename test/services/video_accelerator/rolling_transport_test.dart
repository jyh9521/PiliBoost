// ignore_for_file: cascade_invocations
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/services/video_accelerator/range_downloader.dart';
import 'package:PiliPlus/services/video_accelerator/range_protocol.dart';
import 'package:PiliPlus/services/video_accelerator/range_scheduler.dart';

class GateDownloader extends RangeDownloader {
  GateDownloader({this.failing = false})
    : super(headers: const {}, clientFactory: HttpClient.new);
  final bool failing;
  final starts = <int>[];
  final gate = Completer<void>();
  @override
  Future<RangeChunk> fetch(
    RangeResource r,
    int a,
    int b,
    RangeCancellation token,
  ) async {
    starts.add(a);
    if (failing && a == 2) throw const RangeTransferException('etagIdentity');
    if (a == (failing ? 0 : 3)) {
      final cancelled = Completer<void>();
      void close() {
        if (!cancelled.isCompleted) cancelled.complete();
      }

      token.attach(close);
      try {
        await Future.any([gate.future, cancelled.future]);
        token.check();
      } finally {
        token.detach(close);
      }
    }
    return RangeChunk(
      a,
      Uint8List.fromList([a]),
      Duration.zero,
      Duration.zero,
      1,
    );
  }
}

void main() {
  final r = RangeResource(
    uri: Uri.parse('https://fixture.invalid/v'),
    totalBytes: 12,
    etag: '"a"',
  );
  test('refill starts before slow previous-window tail completes, within memory cap', () async {
    final d = GateDownloader();
    final s = OrderedRangeScheduler(
      downloader: d,
      concurrency: 4,
      chunkBytes: 1,
      maxMemoryBytes: 4,
    );
    final reader = StreamIterator(s.read(r, 0, 11));
    final output = <int>[];
    try {
      expect(await reader.moveNext(), isTrue);
      output.addAll(reader.current);
      expect(d.starts, [0, 1, 2, 3]);
      expect(await reader.moveNext(), isTrue);
      output.addAll(reader.current);
      expect(d.starts, contains(4));
      expect(d.gate.isCompleted, isFalse);
      d.gate.complete();
      while (await reader.moveNext()) {
        output.addAll(reader.current);
      }
      expect(output, List.generate(12, (i) => i));
      expect(s.peakReservedBytes, 4);
      expect(s.reservedBytes, 0);
    } finally {
      if (!d.gate.isCompleted) d.gate.complete();
      await reader.cancel();
      d.releaseClients();
    }
  });
  test('later identity failure aborts blocked head immediately with original error', () async {
    final d = GateDownloader(failing: true);
    final s = OrderedRangeScheduler(
      downloader: d,
      concurrency: 4,
      chunkBytes: 1,
      maxMemoryBytes: 4,
    );
    await expectLater(
      s.read(r, 0, 11).toList().timeout(const Duration(seconds: 1)),
      throwsA(
        isA<RangeTransferException>().having(
          (e) => e.reason,
          'reason',
          'etagIdentity',
        ),
      ),
    );
    expect(s.deliveredBytes, 0);
    expect(s.reservedBytes, 0);
    expect(d.starts.length, lessThanOrEqualTo(4));
  });
  test('paused consumer does not refill and reduced desired width drains before refill', () async {
    final d = GateDownloader();
    d.gate.complete();
    var width = 4;
    final s = OrderedRangeScheduler(
      downloader: d,
      concurrency: 4,
      chunkBytes: 1,
      maxMemoryBytes: 4,
      windowConcurrency: () => width,
    );
    final reader = StreamIterator(s.read(r, 0, 11));
    try {
      await reader.moveNext();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(d.starts, [0, 1, 2, 3]);
      expect(s.reservedBytes, 4);
      width = 2;
      await reader.moveNext();
      expect(d.starts.length, 4);
      await reader.moveNext();
      expect(d.starts.length, 4);
      await reader.moveNext();
      expect(d.starts.length, 5);
    } finally {
      await reader.cancel();
      d.releaseClients();
    }
    expect(s.reservedBytes, 0);
  });
  group('HTTP client leases', () {
    late HttpServer origin;
    late RangeDownloader d;
    late RangeResource resource;
    final ports = <int>{};
    var wrong = false, hang = false;
    final accepted = Completer<void>();
    setUp(() async {
      ports.clear();
      wrong = hang = false;
      origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((q) async {
        try {
          ports.add(q.connectionInfo!.remotePort);
          final (a, b) = ByteRange.parse(q.headers.value('range')!)
              .resolve(4096)!;
          if (hang && a == 0) {
            if (!accepted.isCompleted) accepted.complete();
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          q.response.statusCode = 206;
          q.response.contentLength = b - a + 1;
          q.response.headers.set('content-range', 'bytes $a-$b/4096');
          q.response.headers.set('etag', wrong ? '"wrong"' : '"tag"');
          q.response.add(List.generate(b - a + 1, (i) => (a + i) % 251));
          await q.response.close();
        } catch (_) {
          /* abort intentionally closes this lease */
        }
      });
      resource = RangeResource(
        uri: Uri.parse('http://127.0.0.1:${origin.port}/v'),
        totalBytes: 4096,
        etag: '"tag"',
      );
      d = RangeDownloader(
        headers: const {},
        clientFactory: HttpClient.new,
        maxAttempts: 1,
      );
    });
    tearDown(() async {
      d.releaseClients();
      await origin.close(force: true);
    });
    test(
      'sequential valid chunks reuse one socket; release disposes idle client',
      () async {
        for (var i = 0; i < 16; i++) {
          final c = await d.fetch(
            resource,
            i * 256,
            i * 256 + 255,
            RangeCancellation(),
          );
          expect(c.bytes, List.generate(256, (j) => (i * 256 + j) % 251));
        }
        expect(ports.length, 1);
        expect(d.clientsCreated, 1);
        expect(d.clientsReused, 15);
        expect(d.idleClients, 1);
        d.releaseClients();
        expect(d.idleClients, 0);
      },
    );
    test(
      'identity rejection discards its connection before a later valid request',
      () async {
        wrong = true;
        await expectLater(
          d.fetch(resource, 0, 255, RangeCancellation()),
          throwsA(isA<RangeTransferException>()),
        );
        expect(d.idleClients, 0);
        wrong = false;
        await d.fetch(resource, 256, 511, RangeCancellation());
        expect(ports.length, 2);
        expect(d.clientsCreated, 2);
        expect(d.clientsReused, 0);
      },
    );
    test('client reuse remains scoped to the exact signed URI', () async {
      await d.fetch(resource, 0, 255, RangeCancellation());
      final other = RangeResource(
        uri: resource.uri.replace(query: 'signature=other'),
        totalBytes: resource.totalBytes,
        etag: resource.etag,
      );
      await d.fetch(other, 256, 511, RangeCancellation());
      await d.fetch(resource, 512, 767, RangeCancellation());
      expect(d.clientsCreated, 2);
      expect(d.clientsReused, 1);
      expect(ports.length, 2);
    });
    test(
      'idle client budget stays capped even after a concurrent burst',
      () async {
        d = RangeDownloader(
          headers: const {},
          clientFactory: HttpClient.new,
          maxIdleClients: 1,
        );
        await Future.wait([
          d.fetch(resource, 0, 255, RangeCancellation()),
          d.fetch(resource, 256, 511, RangeCancellation()),
        ]);
        expect(d.clientsCreated, 2);
        expect(d.idleClients, 1);
        expect(d.leasedClients, 0);
        d.releaseClients();
        expect(d.idleClients, 0);
      },
    );
    test(
      'cancelling one lease leaves an independently owned request intact',
      () async {
        hang = true;
        final token = RangeCancellation();
        final pending = d.fetch(resource, 0, 255, token);
        final assertion = expectLater(pending, throwsA(isA<RangeCancelled>()));
        await accepted.future;
        final other = d.fetch(resource, 256, 511, RangeCancellation());
        token.cancel();
        await assertion;
        expect((await other).bytes.length, 256);
        expect(d.activeRequests, 0);
        expect(d.leasedClients, 0);
        expect(d.idleClients, 1);
      },
    );
  });
}
