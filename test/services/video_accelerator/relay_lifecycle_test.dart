// ignore_for_file: cascade_invocations
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/services/video_accelerator/local_stream_server.dart';
import 'package:PiliPlus/services/video_accelerator/range_protocol.dart';

void main() {
  test(
    'first demand payload reaches player before complete parallel chunks',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final gate = Completer<void>();
      final bytes = List.generate(524288, (i) => i % 251);
      origin.listen((r) async {
        try {
          final (a, b) = ByteRange.parse(r.headers.value('range') ?? 'bytes=0-')
              .resolve(bytes.length)!;
          r.response.statusCode = 206;
          r.response.contentLength = b - a + 1;
          r.response.headers.set(
            'content-range',
            'bytes $a-$b/${bytes.length}',
          );
          r.response.headers.set('etag', '"lifecycle"');
          r.response.bufferOutput = false;
          if (r.headers.value('if-match') == null) {
            r.response.add(bytes.sublist(a, a + 1024));
            await r.response.flush();
            await gate.future;
            r.response.add(bytes.sublist(a + 1024, b + 1));
          } else {
            await gate.future;
            r.response.add(bytes.sublist(a, b + 1));
          }
          await r.response.close();
        } catch (_) {
          /* cancelled metadata body */
        }
      });
      final relay = LocalStreamServer(
        source: () => Uri.parse('http://127.0.0.1:${origin.port}/v'),
        headers: const {},
        clientFactory: HttpClient.new,
        rangeConcurrency: 8,
      );
      final client = HttpClient();
      try {
        await relay.start();
        final q = await client.getUrl(relay.uri);
        q.headers.set('range', 'bytes=0-524287');
        // No body exists until AFTER headers are received; not a throughput assertion.
        final response = await q.close().timeout(
          const Duration(milliseconds: 500),
        );
        expect(response.statusCode, 206);
        expect(response.contentLength, bytes.length);
        expect(
          response.headers.value('content-range'),
          'bytes 0-524287/524288',
        );
        gate.complete();
        expect(
          await response.fold<List<int>>([], (a, b) => a..addAll(b)),
          bytes,
        );
        expect(relay.errors, 0);
      } finally {
        if (!gate.isCompleted) gate.complete();
        client.close(force: true);
        await relay.close();
        await origin.close(force: true);
      }
    },
  );
  for (final brokenHead in [false, true]) {
    test(
      'HEAD ($brokenHead) never cancels active GET or invokes playback recovery',
      () async {
        final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final gate = Completer<void>(), first = Completer<void>();
        final bytes = List.generate(65536, (i) => i % 251);
        var failures = 0;
        origin.listen((r) async {
          try {
            if (r.method == 'HEAD') {
              r.response.statusCode = brokenHead ? 403 : 200;
              r.response.contentLength = brokenHead ? 0 : bytes.length;
              await r.response.close();
              return;
            }
            r.response.contentLength = bytes.length;
            r.response.add(bytes.sublist(0, 32768));
            await r.response.flush();
            await gate.future;
            r.response.add(bytes.sublist(32768));
            await r.response.close();
          } catch (_) {
            /* old baseline intentionally aborts GET */
          }
        });
        final relay = LocalStreamServer(
          source: () => Uri.parse('http://127.0.0.1:${origin.port}/v'),
          headers: const {},
          clientFactory: HttpClient.new,
          onFailure: () => failures++,
        );
        final client = HttpClient();
        try {
          await relay.start();
          final response = await (await client.getUrl(relay.uri)).close();
          final body = <int>[];
          final complete = Completer<void>();
          response.listen(
            (data) {
              body.addAll(data);
              if (!first.isCompleted) first.complete();
            },
            onDone: complete.complete,
            onError: complete.completeError,
          );
          // Immediately handle errors to avoid leaking a detached subscription error.
          final outcome = complete.future.then<Object?>(
            (_) => null,
            onError: (Object e) => e,
          );
          await first.future.timeout(const Duration(seconds: 1));
          final head = await (await client.headUrl(relay.uri)).close();
          await head.drain<void>();
          expect(head.statusCode, brokenHead ? 502 : 200);
          expect(relay.activeRequests, 1);
          expect(relay.cancellations, 0);
          gate.complete();
          expect(await outcome, isNull);
          expect(body, bytes);
          expect(failures, 0);
          expect(relay.errors, 0);
        } finally {
          if (!gate.isCompleted) gate.complete();
          client.close(force: true);
          await relay.close();
          await origin.close(force: true);
        }
      },
    );
  }
  test(
    'closing relay aborts a pending isolated HEAD and drains handler',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = Completer<void>();
      origin.listen((r) {
        if (!accepted.isCompleted) accepted.complete();
      });
      final relay = LocalStreamServer(
        source: () => Uri.parse('http://127.0.0.1:${origin.port}/v'),
        headers: const {},
        clientFactory: HttpClient.new,
      );
      final client = HttpClient();
      try {
        await relay.start();
        final q = await client.headUrl(relay.uri);
        final response = q.close().then<Object?>(
          (r) => r,
          onError: (Object e) => e,
        );
        await accepted.future.timeout(const Duration(seconds: 1));
        await relay.close().timeout(const Duration(seconds: 1));
        expect(relay.pendingHandlers, 0);
        await response;
      } finally {
        client.close(force: true);
        await relay.close();
        await origin.close(force: true);
      }
    },
  );
}
