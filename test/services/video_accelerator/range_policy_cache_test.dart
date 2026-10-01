import 'dart:async';
// ignore_for_file: cascade_invocations
import 'dart:typed_data';
import 'dart:io';

import 'package:PiliPlus/services/video_accelerator/range_scheduler.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/services/video_accelerator/range_concurrency_policy.dart';
import 'package:PiliPlus/services/video_accelerator/range_memory_cache.dart';
import 'package:PiliPlus/services/video_accelerator/range_downloader.dart';

class _DemandDownloader extends RangeDownloader {
  _DemandDownloader()
    : super(
        headers: const {},
        clientFactory: HttpClient.new,
        maxChunkBytes: 1024,
      );
  int started = 0;
  @override
  Future<RangeChunk> fetch(
    RangeResource resource,
    int start,
    int end,
    RangeCancellation token,
  ) async {
    token.check();
    started++;
    return RangeChunk(
      start,
      Uint8List(end - start + 1),
      Duration.zero,
      Duration.zero,
      1,
    );
  }
}

void main() {
  test(
    'dynamic width changes only next window, with paused demand bounded',
    () async {
      final d = _DemandDownloader();
      var width = 4;
      final s = OrderedRangeScheduler(
        downloader: d,
        concurrency: 16,
        chunkBytes: 1024,
        maxMemoryBytes: 16 * 1024,
        windowConcurrency: () => width,
      );
      final r = RangeResource(
        uri: Uri.parse('https://fixture/v'),
        totalBytes: 12 * 1024,
        etag: '"v"',
      );
      final iterator = StreamIterator(s.read(r, 0, r.totalBytes - 1));
      expect(await iterator.moveNext(), isTrue);
      expect(d.started, 4);
      width = 8;
      for (var i = 0; i < 3; i++) {
        expect(await iterator.moveNext(), isTrue);
      }
      expect(d.started, 4);
      expect(await iterator.moveNext(), isTrue);
      expect(d.started, 12);
      while (await iterator.moveNext()) {}
      expect(s.deliveredBytes, r.totalBytes);
      expect(s.peakReservedBytes, 8 * 1024);
      expect(s.pendingRanges, 0);
      expect(s.reservedBytes, 0);
    },
  );
  test('adaptive steps require persistent deficit; target sufficiency stops growth', () {
    final p = RangeConcurrencyPolicy();
    void observe(
      int seconds,
      double buffer,
      double rate, {
      bool playing = true,
      double target = 100,
    }) => p.observe(
      now: Duration(seconds: seconds),
      bufferSeconds: buffer,
      throughputBps: rate,
      requiredBps: target,
      playing: playing,
    );
    observe(0, 0, 1);
    observe(4, 0, 1);
    expect(p.concurrency, 4);
    observe(5, 0, 1);
    expect(p.concurrency, 8);
    observe(6, 0, 1);
    expect(p.concurrency, 8);
    observe(10, 0, 100);
    observe(15, 0, 100);
    expect(p.concurrency, 8);
    observe(20, 0, 1);
    observe(25, 0, 1);
    expect(p.concurrency, 12);
    observe(30, 0, 1);
    observe(35, 0, 1);
    expect(p.concurrency, 16);
    observe(40, 25, 0);
    expect(p.concurrency, 12);
    observe(45, 25, 0);
    expect(p.concurrency, 8);
    observe(50, 25, 0);
    expect(p.concurrency, 4);
    observe(60, 0, 0, playing: false);
    observe(65, 0, 0, playing: false);
    expect(p.concurrency, 4);
    observe(70, 0, 0, target: 0);
    observe(75, 0, 0, target: 0);
    expect(p.concurrency, 4);
  });
  test(
    'cache LRU byte cap, read-only ownership, and representation isolation',
    () {
      final c = RangeMemoryCache(
        maxBytes: 8,
        maxBehindBytes: 100,
        maxAheadBytes: 100,
      );
      RangeResource r(String tag, {String query = 'a'}) => RangeResource(
        uri: Uri.parse('https://fixture/v?s=$query'),
        totalBytes: 100,
        etag: tag,
      );
      final resource = r('"a"');
      final input = Uint8List.fromList([1, 2, 3, 4]);
      c.put(resource, 0, 3, input);
      input[0] = 9;
      expect(c.get(resource, 0, 3), [1, 2, 3, 4]);
      expect(() => c.get(resource, 0, 3)![0] = 0, throwsUnsupportedError);
      c.put(resource, 4, 7, Uint8List(4));
      c.get(resource, 0, 3);
      c.put(resource, 8, 11, Uint8List(4));
      expect(c.bytes, 8);
      expect(c.get(resource, 4, 7), isNull);
      expect(c.get(r('"b"'), 0, 3), isNull);
      expect(c.get(r('"a"', query: 'b'), 0, 3), isNull);
      c.clear();
      expect(c.bytes, 0);
    },
  );
  test('cache evicts far behind seek and refuses unvalidated identities', () {
    final c = RangeMemoryCache(
      maxBytes: 16,
      maxBehindBytes: 4,
      maxAheadBytes: 4,
    );
    final r = RangeResource(
      uri: Uri.parse('https://fixture/v'),
      totalBytes: 100,
      etag: '"a"',
    );
    c.put(r, 0, 3, Uint8List(4));
    c.put(r, 50, 53, Uint8List(4));
    expect(c.bytes, 4);
    expect(c.get(r, 0, 3), isNull);
    final weak = RangeResource(uri: r.uri, totalBytes: 100);
    c.put(weak, 0, 3, Uint8List(4));
    expect(c.get(weak, 0, 3), isNull);
  });
}
