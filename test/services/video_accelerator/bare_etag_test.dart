// ignore_for_file: cascade_invocations
import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/services/video_accelerator/range_protocol.dart';
import 'package:PiliPlus/services/video_accelerator/range_downloader.dart';
import 'package:PiliPlus/services/video_accelerator/local_stream_server.dart';
import 'package:PiliPlus/services/video_accelerator/range_memory_cache.dart';
import 'package:PiliPlus/services/video_accelerator/range_cdn_pool.dart';
import 'package:PiliPlus/services/video_accelerator/diagnostic_export.dart';

const tag = '0123456789abcdef0123456789abcdef';
void main() {
  for (final candidate in [
    'short',
    '$tag\n',
    '$tag\r',
    '*',
    'W/"abcdef"',
    'w/"abcdef"',
    'a' * 129,
    'a b' * 16,
    'é' * 32,
    'a,b' * 16,
    '"$tag"',
  ]) {
    test('exclude invalid bare shape ${jsonEncode(candidate)}', () {
      expect(EntityTag.isBareCandidate(candidate), isFalse);
    });
  }
  test('bare candidate never becomes an RFC strong tag by shape alone', () {
    expect(EntityTag.isBareCandidate(tag), isTrue);
    expect(EntityTag.status(tag), 'unsupported');
    expect(
      () => RangeResource(
        uri: Uri.parse('https://test.invalid/v'),
        totalBytes: 100,
        etag: tag,
      ),
      throwsArgumentError,
    );
  });
  group('real HTTP conditional proof', () {
    late HttpServer origin;
    late Uri uri;
    final bytes = List.generate(1024 * 1024, (i) => i % 251);
    var mode = 'verified', negatives = 0, positives = 0, active = 0, peak = 0;
    final conditions = <String>[];
    setUp(() async {
      mode = 'verified';
      negatives = positives = active = peak = 0;
      conditions.clear();
      origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      uri = Uri.parse('http://127.0.0.1:${origin.port}/video?sign=private');
      origin.listen((r) async {
        try {
          final condition = r.headers.value('if-match');
          if (condition != null) conditions.add(condition);
          final negative = condition?.startsWith('"pili-mismatch.') ?? false;
          if (negative) negatives++;
          if (condition == '"$tag"') positives++;
          if (mode == 'hang' && negative) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
          if (condition != null &&
              mode != 'ignored' &&
              (condition != '"$tag"' || mode == 'reject')) {
            r.response.statusCode = mode == 'redirect' ? 302 : 412;
            r.response.contentLength = 0;
            await r.response.close();
            return;
          }
          final bounds = ByteRange.parse(r.headers.value('range') ?? 'bytes=0-')
              .resolve(bytes.length)!;
          final (a, b) = bounds;
          r.response.statusCode = mode == 'rangeIgnored' && condition != null
              ? 200
              : 206;
          r.response.contentLength = b - a + 1;
          r.response.headers.set(
            'content-range',
            'bytes $a-$b/${mode == 'lengthChanged' && condition != null ? bytes.length + 1 : bytes.length}',
          );
          r.response.headers.set(
            'etag',
            mode == 'tagChanged' && condition != null
                ? 'fedcba9876543210fedcba9876543210'
                : tag,
          );
          if (mode == 'encoded' && condition != null) {
            r.response.headers.set('content-encoding', 'gzip');
          }
          active++;
          if (active > peak) peak = active;
          try {
            if (condition != null && b - a > 1) {
              await Future<void>.delayed(const Duration(milliseconds: 15));
            }
            r.response.add(bytes.sublist(a, b + 1));
            await r.response.close();
          } finally {
            active--;
          }
        } catch (_) {
          /* deliberate cancellation */
        }
      });
    });
    tearDown(() async {
      await origin.close(force: true);
    });
    Future<BareEtagResult> verify({
      RangeCancellation? token,
      Duration? timeout,
    }) => BareEtagVerifier.verify(
      uri: uri,
      etag: tag,
      totalBytes: bytes.length,
      headers: const {},
      clientFactory: HttpClient.new,
      token: token ?? RangeCancellation(),
      timeout: timeout ?? const Duration(seconds: 1),
    );

    test('verified proof is URI, exact tag and total scoped; chunk uses quoted condition', () async {
      final result = await verify();
      expect(result.status, 'bareConditionalVerified');
      final proof = result.proof!;
      expect(proof.matches(uri, tag, bytes.length), isTrue);
      expect(
        proof.matches(uri.replace(query: 'sign=other'), tag, bytes.length),
        isFalse,
      );
      expect(proof.matches(uri, tag, bytes.length + 1), isFalse);
      expect(
        () => RangeResource(
          uri: uri,
          totalBytes: bytes.length,
          etag: '"$tag"',
          verifiedBare: proof,
        ),
        throwsArgumentError,
      );
      expect(
        () => RangeResource(
          uri: uri,
          totalBytes: bytes.length,
          verifiedBare: proof,
        ),
        throwsArgumentError,
      );
      expect(
        () => RangeResource(
          uri: uri.replace(path: '/other'),
          totalBytes: bytes.length,
          etag: tag,
          verifiedBare: proof,
        ),
        throwsArgumentError,
      );
      final resource = RangeResource(
        uri: uri,
        totalBytes: bytes.length,
        etag: tag,
        verifiedBare: proof,
      );
      final d = RangeDownloader(
        headers: const {},
        clientFactory: HttpClient.new,
      );
      final c = await d.fetch(resource, 100, 199, RangeCancellation());
      expect(c.bytes, bytes.sublist(100, 200));
      expect(conditions.last, '"$tag"');
      mode = 'tagChanged';
      await expectLater(
        d.fetch(resource, 200, 299, RangeCancellation()),
        throwsA(
          isA<RangeTransferException>().having(
            (e) => e.reason,
            'reason',
            'etagIdentity',
          ),
        ),
      );
    });
    for (final pair in [
      ('ignored', 'bareConditionIgnored'),
      ('reject', 'barePositiveRejected'),
      ('redirect', 'bareConditionIgnored'),
      ('rangeIgnored', 'barePositiveRejected'),
      ('tagChanged', 'barePositiveRejected'),
      ('lengthChanged', 'barePositiveRejected'),
      ('encoded', 'barePositiveRejected'),
    ]) {
      test('${pair.$1} never admits parallel proof', () async {
        mode = pair.$1;
        final result = await verify();
        expect(result.status, pair.$2);
        expect(result.proof, isNull);
        expect(negatives, 1);
        expect(
          positives,
          pair.$1 == 'ignored' || pair.$1 == 'redirect' ? 0 : 1,
        );
      });
    }
    test(
      'global deadline and explicit cancellation close probe sockets',
      () async {
        mode = 'hang';
        final timed = await verify(timeout: const Duration(milliseconds: 25));
        expect(timed.status, 'bareProbeFailed');
        final token = RangeCancellation();
        final job = verify(token: token);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        token.cancel();
        await expectLater(job, throwsA(isA<RangeCancelled>()));
      },
    );
    test('nonstandard proof cannot enter a cross-CDN pool', () async {
      final proof = (await verify()).proof!;
      final pool = RangePoolDownloader(
        headers: const {},
        clientFactory: HttpClient.new,
        cache: RangeMemoryCache(),
        primary: RangeResource(
          uri: uri,
          totalBytes: bytes.length,
          etag: tag,
          verifiedBare: proof,
        ),
        candidates: const [],
      );
      await expectLater(pool.prepare(RangeCancellation()), throwsArgumentError);
    });
    for (final scenario in ['verified', 'ignored']) {
      test(
        'relay $scenario returns exact ordered bytes and diagnostic status',
        () async {
          mode = scenario;
          final relay = LocalStreamServer(
            source: () => uri,
            headers: const {},
            clientFactory: HttpClient.new,
            rangeConcurrency: 8,
            candidates: [uri.replace(path: '/other')],
          );
          final consumer = HttpClient();
          try {
            await relay.start();
            Future<List<int>> read() async {
              final q = await consumer.getUrl(relay.uri);
              q.headers.set('range', 'bytes=0-1048575');
              final response = await q.close();
              expect(response.statusCode, 206);
              return response.fold<List<int>>([], (a, b) => a..addAll(b));
            }

            expect(await read(), bytes);
            expect(
              relay.parallelStatus,
              scenario == 'verified'
                  ? 'bareEtagParallel'
                  : 'bareConditionIgnored',
            );
            expect(
              relay.observedConcurrency,
              scenario == 'verified' ? greaterThan(1) : 1,
            );
            expect(relay.poolStats, isEmpty);
            final output = DiagnosticExport.encode({
              'parallelStatus': relay.parallelStatus,
              'cdnCapabilities': relay.cdnCapabilities,
            });
            expect(
              output,
              contains(
                scenario == 'verified'
                    ? 'bareConditionalVerified'
                    : 'bareConditionIgnored',
              ),
            );
            expect(output, isNot(contains(tag)));
            expect(output, isNot(contains('sign=private')));
            // Second demand reuses only the same key and avoids probe amplification.
            expect(await read(), bytes);
            expect(negatives, 1);
            expect(relay.errors, 0);
          } finally {
            consumer.close(force: true);
            await relay.close();
          }
        },
      );
    }
  });
}
