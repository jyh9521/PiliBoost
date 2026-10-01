// ignore_for_file: cascade_invocations
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/services/video_accelerator/cdn_capability.dart';
import 'package:PiliPlus/services/video_accelerator/range_protocol.dart';
import 'package:PiliPlus/services/video_accelerator/range_downloader.dart';
import 'package:PiliPlus/services/video_accelerator/local_stream_server.dart';

void main() {
  for (final tag in ['""', '"ascii!#~"', '"a\\b"', '"\u0080\u00ff"']) {
    test('strong opaque tag accepted $tag', () {
      expect(EntityTag.status(tag), 'strong');
      if (tag.codeUnits.every((c) => c < 0x80)) {
        expect(
          RangeResource(
            uri: Uri.parse('https://fixture.test/v'),
            totalBytes: 10,
            etag: tag,
          ).etag,
          tag,
        );
      } else {
        expect(
          () => RangeResource(
            uri: Uri.parse('https://fixture.test/v'),
            totalBytes: 10,
            etag: tag,
          ),
          throwsArgumentError,
        );
      }
      expect(EntityTag.status('W/$tag'), 'weak');
    });
  }
  for (final tag in [
    'W/broken',
    'w/"x"',
    '"a b"',
    '"a\t"',
    '"a\n"',
    '"\u007f"',
    '"\u0100"',
    '"a"b"',
    '"a", "b"',
    'unquoted',
  ]) {
    test('malformed tag excluded ${jsonEncode(tag)}', () {
      expect(EntityTag.status(tag), 'unsupported');
      expect(
        () => RangeResource(
          uri: Uri.parse('https://fixture.test/v'),
          totalBytes: 10,
          etag: tag,
        ),
        throwsArgumentError,
      );
    });
  }
  CdnCapability inspect({
    int status = 206,
    String? cr = 'bytes 0-9/20',
    int length = 10,
    String? tag = '"private-validator"',
    String? encoding,
    bool range = true,
  }) => CdnCapability.inspect(
    statusCode: status,
    contentLength: length,
    requestedRange: range ? ByteRange.parse('bytes=0-9') : null,
    contentRange: cr,
    etag: tag,
    encoding: encoding,
  );

  test('matched range requires a strong validator, not only equal length', () {
    expect(inspect().parallelEligible, isTrue);
    for (final tag in [null, 'W/"x"', 'invalid']) {
      final c = inspect(tag: tag);
      expect(c.rangeStatus, 'matched');
      expect(c.failureReason, isNull);
      expect(c.parallelEligible, isFalse);
      expect(c.toJson()['reason'], 'missingStrongValidator');
    }
    expect(
      jsonEncode(inspect().toJson()),
      isNot(contains('private-validator')),
    );
  });
  test('range evidence is not inferred from a full response', () {
    expect(inspect(status: 200, range: false).rangeStatus, 'unmeasured');
    expect(inspect(status: 200).failureReason, 'rangeIgnored');
    expect(inspect(cr: null).failureReason, 'invalidContentRange');
    expect(inspect(cr: 'bytes 1-10/20').failureReason, 'rangeMismatch');
    expect(inspect(length: 9).failureReason, 'rangeMismatch');
    expect(
      inspect(status: 200, range: false, length: -1).failureReason,
      'unknownLength',
    );
    expect(inspect(encoding: 'gzip').failureReason, 'encodedContent');
    expect(inspect(encoding: 'IDENTITY').identityEncoding, isTrue);
    for (final status in [302, 403, 412, 429, 503]) {
      expect(inspect(status: status).failureReason, 'http$status');
    }
  });
  test('unsatisfied range never enables workers; invalid total rejected', () {
    expect(inspect(status: 416, cr: 'bytes */20').parallelEligible, isFalse);
    expect(inspect(status: 416, cr: 'bytes */20').totalBytes, 20);
    for (final cr in [null, 'bytes */-1', 'bytes */9999999999999999999999']) {
      expect(
        inspect(status: 416, cr: cr).failureReason,
        'invalidUnsatisfiedRange',
      );
    }
  });

  test('valid opaque octets remain single relay on the real wire', () async {
    final origin = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    var requests = 0;
    origin.listen((socket) {
      sockets.add(socket);
      socket.listen((_) {
        if (requests++ == 0) {
          socket.add(
            latin1.encode(
              'HTTP/1.1 206 Partial Content\r\n'
              'Content-Length: 10\r\nContent-Range: bytes 0-9/20\r\n'
              'ETag: "\u0080\u00ff"\r\nConnection: close\r\n\r\n0123456789',
            ),
          );
        }
      });
    });
    final relay = LocalStreamServer(
      source: () => Uri.parse('http://127.0.0.1:${origin.port}/v'),
      headers: const {},
      clientFactory: HttpClient.new,
      rangeConcurrency: 4,
    );
    final client = HttpClient();
    try {
      await relay.start();
      final request = await client.getUrl(relay.uri);
      request.headers.set('range', 'bytes=0-9');
      final response = await request.close();
      expect(await response.transform(utf8.decoder).join(), '0123456789');
      expect(response.statusCode, 206);
      expect(relay.validatorStatus, 'strong');
      expect(relay.parallelStatus, 'validatorTransportUnsupported');
      expect(relay.actualConcurrency, 1);
      expect(requests, 1);
      expect(relay.errors, 0);
    } finally {
      client.close(force: true);
      await relay.close();
      for (final socket in sockets) {
        socket.destroy();
      }
      await origin.close();
    }
  });

  for (final mode in [
    'strong',
    'weak',
    'malformed',
    'ignored',
    'redirect',
    'mismatch',
  ]) {
    test('real HTTP capability $mode preserves identity gating', () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var chunkRequests = 0;
      origin.listen((r) async {
        try {
          if (r.headers.value('if-match') != null) chunkRequests++;
          final response = r.response;
          response.statusCode = mode == 'ignored'
              ? 200
              : mode == 'redirect'
              ? 302
              : 206;
          response.headers.set(
            'etag',
            mode == 'weak'
                ? 'W/"private"'
                : mode == 'malformed'
                ? 'unquoted-private'
                : '"private"',
          );
          response.headers.set(
            'content-range',
            mode == 'mismatch' ? 'bytes 1-10/20' : 'bytes 0-9/20',
          );
          response.contentLength = 10;
          response.add(List.generate(10, (i) => i));
          await response.close();
        } catch (_) {
          // Metadata body can be closed before the parallel worker starts.
        }
      });
      final relay = LocalStreamServer(
        source: () => Uri.parse(
          'http://127.0.0.1:${origin.port}/private-path?signature=secret',
        ),
        headers: const {},
        clientFactory: HttpClient.new,
        rangeConcurrency: 4,
      );
      final client = HttpClient();
      try {
        await relay.start();
        final request = await client.getUrl(relay.uri);
        request.headers.set('range', 'bytes=0-9');
        final response = await request.close();
        final bytes = await response.fold<List<int>>(
          [],
          (a, b) => a..addAll(b),
        );
        final valid = ['strong', 'weak', 'malformed'].contains(mode);
        expect(response.statusCode, valid ? 206 : 502);
        expect(bytes, valid ? List.generate(10, (i) => i) : isEmpty);
        expect(chunkRequests, (mode == 'strong') ? 1 : 0);
        final evidence = relay.cdnCapabilities.single;
        expect(
          evidence['parallelEligible'],
          (mode == 'strong'),
        );
        expect(evidence['reason'], switch (mode) {
          'strong' => 'eligible',
          'weak' || 'malformed' => 'missingStrongValidator',
          'ignored' => 'rangeIgnored',
          'redirect' => 'http302',
          _ => 'rangeMismatch',
        });
        final encoded = jsonEncode(evidence);
        for (final secret in [
          'private',
          'signature',
          'secret',
          relay.uri.path,
        ]) {
          expect(encoded, isNot(contains(secret)));
        }
        relay.resetPool();
        expect(relay.cdnCapabilities, isEmpty);
        expect(relay.validatorStatus, 'unmeasured');
      } finally {
        client.close(force: true);
        await relay.close();
        await origin.close(force: true);
      }
    });
  }
}
