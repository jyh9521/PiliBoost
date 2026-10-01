// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: cascade_invocations
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/services/video_accelerator/local_stream_server.dart';
import 'package:PiliPlus/services/video_accelerator/range_protocol.dart';

void main() {
  final data = List<int>.generate(2 * 1024 * 1024 + 97, (i) => i % 251);
  late HttpServer origin;
  late LocalStreamServer relay;
  late HttpClient consumer;
  var mode = 'valid', active = 0, peak = 0, failed = 0, chunkHits = 0;
  setUp(() async {
    mode = 'valid';
    active = peak = failed = chunkHits = 0;
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((r) async {
      final isChunk = r.headers.value('if-match') != null;
      try {
        expect(r.uri.query, 'signature=a%2Fb');
        expect(r.headers.value('referer'), 'fixture');
        if (isChunk) {
          chunkHits++;
          active++;
          if (active > peak) peak = active;
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        final raw = r.headers.value('range');
        final range = raw == null ? null : ByteRange.parse(raw);
        final bounds = range?.resolve(data.length);
        if (range != null && bounds == null) {
          r.response.statusCode = 416;
          r.response.headers.set('content-range', 'bytes */${data.length}');
          r.response.contentLength = 0;
        } else {
          final (a, b) = bounds ?? (0, data.length - 1);
          r.response.statusCode = raw == null ? 200 : 206;
          if (raw != null)
            r.response.headers.set(
              'content-range',
              'bytes $a-$b/${data.length}',
            );
          if (mode != 'missing')
            r.response.headers.set(
              'etag',
              mode == 'weak'
                  ? 'W/"fixture"'
                  : mode == 'changed' && isChunk
                  ? '"changed"'
                  : '"fixture"',
            );
          r.response.contentLength = b - a + 1;
          if (r.method != 'HEAD') r.response.add(data.sublist(a, b + 1));
        }
        await r.response.close();
      } catch (_) {
        // New seek generations close the previous origin reader.
      } finally {
        if (isChunk) active--;
      }
    });
    relay = LocalStreamServer(
      source: () =>
          Uri.parse('http://127.0.0.1:${origin.port}/v?signature=a%2Fb'),
      headers: const {'referer': 'fixture'},
      clientFactory: HttpClient.new,
      rangeConcurrency: 4,
      onFailure: () => failed++,
    );
    await relay.start();
    consumer = HttpClient();
  });
  tearDown(() async {
    consumer.close(force: true);
    await relay.close();
    await origin.close(force: true);
  });
  Future<(int, List<int>)> read({String? range, String method = 'GET'}) async {
    final r = await consumer.openUrl(method, relay.uri);
    if (range != null) r.headers.set('range', range);
    final response = await r.close();
    return (
      response.statusCode,
      await response.fold<List<int>>([], (a, b) => a..addAll(b)),
    );
  }

  for (final range in [
    null,
    'bytes=1023-1048599',
    'bytes=262144-',
    'bytes=-300000',
  ]) {
    test('parallel exact ordered bytes $range', () async {
      final result = await read(range: range);
      final (a, b) = range == null
          ? (0, data.length - 1)
          : ByteRange.parse(range).resolve(data.length)!;
      expect(result.$1, range == null ? 200 : 206);
      expect(result.$2, data.sublist(a, b + 1));
      expect(relay.actualConcurrency, 4);
      expect(peak, lessThanOrEqualTo(4));
      if (b - a + 1 > 1024 * 1024) expect(peak, 4);
      expect(relay.errors, 0);
      expect(failed, 0);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(relay.reservedBytes, 0);
    });
  }
  for (final absent in ['missing', 'weak']) {
    test('$absent validator stays single without a failure', () async {
      mode = absent;
      final result = await read(range: 'bytes=0-300000');
      expect(result.$2, data.sublist(0, 300001));
      expect(chunkHits, 0);
      expect(relay.actualConcurrency, 1);
      expect(relay.parallelStatus, 'missingStrongValidator');
      expect(failed, 0);
    });
  }
  test('HEAD and 416 do not start chunk workers', () async {
    expect((await read(method: 'HEAD')).$2, isEmpty);
    expect((await read(range: 'bytes=${data.length}-')).$1, 416);
    expect(chunkHits, 0);
    expect(failed, 0);
  });
  test('changed chunk validator never produces accepted body', () async {
    mode = 'changed';
    try {
      await read(range: 'bytes=0-500000');
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(failed, 1);
    expect(relay.forwardedBytes, 0);
    expect(relay.errors, 1);
  });
  test(
    'overlapping seek cancels old generation and new range is exact',
    () async {
      final first = read(range: 'bytes=0-');
      final settled = first.then<void>((_) {}, onError: (Object _) {});
      while (chunkHits == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      final result = await read(range: 'bytes=1048576-1348576');
      await settled;
      expect(result.$2, data.sublist(1048576, 1348577));
      expect(failed, 0);
      expect(relay.errors, 0);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(relay.activeRanges, 0);
    },
  );
}
