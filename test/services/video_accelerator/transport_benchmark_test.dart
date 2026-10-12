// ignore_for_file: cascade_invocations, avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/services/video_accelerator/range_downloader.dart';
import 'package:PiliPlus/services/video_accelerator/range_protocol.dart';
import 'package:PiliPlus/services/video_accelerator/range_scheduler.dart';

// Same legacy API runs against preserved and modified sources. HTTP fixture, not
// real CDN/TLS/video throughput; only first requests on a socket pay setup delay.
void main() {
  for (final width in [4, 8]) {
    test('controlled $width-lane connection overhead benchmark', () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      const chunk = 256 * 1024, total = 64 * chunk;
      final ports = <int>{};
      var requests = 0, factories = 0;
      origin.listen((r) async {
        try {
          requests++;
          if (ports.add(r.connectionInfo!.remotePort)) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
          final (a, b) = ByteRange.parse(r.headers.value('range')!)
              .resolve(total)!;
          r.response.statusCode = 206;
          r.response.contentLength = b - a + 1;
          r.response.headers.set('content-range', 'bytes $a-$b/$total');
          r.response.headers.set('etag', '"bench"');
          r.response.add(List.filled(b - a + 1, 42));
          await r.response.close();
        } catch (_) {
          /* cleanup may abort origin sockets */
        }
      });
      final d = RangeDownloader(
        headers: const {},
        clientFactory: () {
          factories++;
          return HttpClient();
        },
      );
      final scheduler = OrderedRangeScheduler(
        downloader: d,
        concurrency: width,
      );
      final watch = Stopwatch()..start();
      var bytes = 0;
      try {
        await for (final data in scheduler.read(
          RangeResource(
            uri: Uri.parse('http://127.0.0.1:${origin.port}/v'),
            totalBytes: total,
            etag: '"bench"',
          ),
          0,
          total - 1,
        )) {
          expect(data.every((b) => b == 42), isTrue);
          bytes += data.length;
        }
        watch.stop();
        print(
          'TRANSPORT_MEASURE lanes=$width bytes=$bytes requests=$requests sockets=${ports.length} clients=$factories wallMs=${watch.elapsedMilliseconds}',
        );
        expect(bytes, total);
        expect(requests, 64);
        expect(ports.length, lessThanOrEqualTo(width));
        expect(factories, lessThanOrEqualTo(width));
        expect(scheduler.peakReservedBytes, lessThanOrEqualTo(width * chunk));
      } finally {
        // New release API is intentionally optional only in this comparison fixture.
        try {
          (d as dynamic).releaseClients();
        } on NoSuchMethodError {
          /* preserved source closes each attempt */
        }
        await origin.close(force: true);
      }
    });
  }
}
