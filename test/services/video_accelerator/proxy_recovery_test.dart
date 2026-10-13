// ignore_for_file: cascade_invocations
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/services/video_accelerator/accelerator_config.dart';
import 'package:PiliPlus/services/video_accelerator/accelerator_session.dart';
import 'package:PiliPlus/services/video_accelerator/cdn_probe.dart';
import 'package:PiliPlus/services/video_accelerator/local_stream_server.dart';

void main() {
  test(
    'new native-style Range cancels old stream without leaked cancellation',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((r) async {
        try {
          final m = RegExp(r'bytes=(\d+)-(\d+)')
              .firstMatch(r.headers.value('range')!);
          final start = int.parse(m![1]!), end = int.parse(m[2]!);
          final length = end - start + 1;
          r.response.statusCode = 206;
          r.response.contentLength = length;
          r.response.headers.set('content-range', 'bytes $start-$end/8388608');
          r.response.headers.set('etag', '"same"');
          if (length <= 262144)
            await Future<void>.delayed(const Duration(milliseconds: 100));
          r.response.add(List<int>.filled(length, 7));
          await r.response.close();
        } catch (_) {
          /* Intentional downstream cancellation. */
        }
      });
      final relay = LocalStreamServer(
        source: () => Uri.parse('http://127.0.0.1:${origin.port}/video'),
        headers: const {},
        clientFactory: HttpClient.new,
        rangeConcurrency: 8,
      );
      await relay.start();
      final client = HttpClient();
      final q = await client.getUrl(relay.uri);
      q.headers.set('range', 'bytes=0-4194303');
      final first = await q.close();
      final prefix = Completer<void>();
      final drained = first
          .listen((bytes) {
            if (!prefix.isCompleted) prefix.complete();
          }, onError: (Object _) {})
          .asFuture<void>()
          .catchError((Object _) {});
      await prefix.future;
      final next = await client.getUrl(relay.uri);
      next.headers.set('range', 'bytes=524288-786431');
      final second = await next.close();
      expect(await second.fold<int>(0, (n, b) => n + b.length), 262144);
      await drained;
      expect(relay.errors, 0);
      client.close(force: true);
      await relay.close();
      await origin.close(force: true);
    },
  );
  for (final action in ['pause', 'seek', 'close', 'identity']) {
    test('proxy recovery respects $action boundary', () async {
      var time = Duration.zero;
      final a = Uri.parse('https://primary/video'),
          b = Uri.parse('https://backup/video');
      var probes = 0, opens = 0;
      final gate = Completer<ProbeResult>();
      final s = AcceleratorSession(
        config: const AcceleratorConfig(mode: AcceleratorMode.multiRange8),
        tracks: [
          AcceleratorTrack(kind: 'video', original: a, candidates: [a, b]),
        ],
        clock: () => time,
        probe: (uri, config, token) {
          probes++;
          return gate.future;
        },
      );
      await s.startProxy(
        create: (source, failure) => LocalStreamServer(
          source: source,
          headers: const {},
          clientFactory: HttpClient.new,
          onFailure: failure,
          rangeConcurrency: 8,
        ),
      );
      s.onSwitch = (v, a) async {
        opens++;
        return true;
      };
      await s.observe(bufferAheadSeconds: 0, throughputBps: 0, playing: true);
      time = const Duration(seconds: 6);
      if (action == 'pause') {
        await s.observe(
          bufferAheadSeconds: 0,
          throughputBps: 0,
          playing: false,
        );
        expect(probes, 0);
      } else if (action == 'identity') {
        s.proxy!.lastFailureReason = 'etagMismatch';
        await s.recoverPlayback();
        expect(probes, 0);
        expect(s.bypassed, isTrue);
        expect(opens, 1);
      } else {
        final pending = s.observe(
          bufferAheadSeconds: 0,
          throughputBps: 0,
          playing: true,
        );
        expect(probes, 1);
        Future<void>? closing;
        if (action == 'seek') {
          s.invalidate();
        } else {
          closing = s.close();
        }
        gate.complete(
          const ProbeResult(
            bytes: 262144,
            elapsed: Duration(seconds: 1),
            fingerprint: 'same',
            totalBytes: 10000000,
            status: 206,
          ),
        );
        await pending;
        await closing;
        expect(opens, 0);
        expect(s.switches, 0);
      }
      await s.close();
    });
  }
  for (final mode in [AcceleratorMode.multiRange8, AcceleratorMode.rangeAuto]) {
    for (final scenario in [
      'gain',
      'mismatch',
      'failed',
      'noGain',
      'openFailed',
      'missingProof',
      'currentFailed',
    ]) {
      test('$mode stalled proxy recovery $scenario', () async {
        var time = Duration.zero;
        final original = Uri.parse('https://primary.bilivideo.com/video');
        final backup = Uri.parse('https://backup.bilivideo.com/video');
        final video = AcceleratorTrack(
          kind: 'video',
          original: original,
          candidates: [original, backup],
          bitrateBps: 4000000,
        );
        var probes = 0, opens = 0;
        final s = AcceleratorSession(
          config: AcceleratorConfig(mode: mode),
          tracks: [video],
          clock: () => time,
          probe: (uri, config, token) async {
            probes++;
            if (scenario == 'failed' && uri == backup ||
                scenario == 'currentFailed' && uri == original) {
              return const ProbeResult(error: 'transport');
            }
            return ProbeResult(
              bytes: 262144,
              elapsed: Duration(
                milliseconds: uri == original || scenario == 'noGain'
                    ? 1000
                    : 100,
              ),
              totalBytes: 10000000,
              status: 206,
              fingerprint: scenario == 'missingProof'
                  ? null
                  : scenario == 'mismatch' && uri == backup
                  ? 'wrong'
                  : 'same',
            );
          },
        );
        await s.startProxy(
          create: (source, failure) => LocalStreamServer(
            source: source,
            headers: const {},
            clientFactory: HttpClient.new,
            rangeConcurrency: mode == AcceleratorMode.multiRange8 ? 8 : 16,
            onFailure: failure,
          ),
        );
        final relay = s.proxy!;
        s.onSwitch = (v, a) async {
          opens++;
          return scenario != 'openFailed';
        };
        await s.observe(bufferAheadSeconds: 1, throughputBps: 0, playing: true);
        expect(probes, 0);
        time = const Duration(seconds: 6);
        await s.observe(bufferAheadSeconds: 1, throughputBps: 0, playing: true);
        expect(probes, 2);
        if (scenario == 'gain') {
          expect(video.active, backup);
          expect(s.switches, 1);
          expect(s.proxy, isNull);
          expect(s.bypassed, isFalse);
          expect(opens, 1);
          expect(relay.pendingHandlers, 0);
        } else if (scenario == 'openFailed') {
          expect(s.bypassed, isTrue);
          expect(video.active, original);
        } else {
          expect(video.active, original);
          expect(s.proxy, same(relay));
          expect(opens, 0);
        }
        await s.close();
      });
    }
  }
  test(
    'failure recovery freezes demand offset and falls back during cooldown',
    () async {
      var time = Duration.zero;
      final a = Uri.parse('https://primary/video'),
          b = Uri.parse('https://backup/video');
      final offsets = <int>[];
      late AcceleratorSession s;
      s = AcceleratorSession(
        config: const AcceleratorConfig(mode: AcceleratorMode.multiRange8),
        tracks: [
          AcceleratorTrack(
            kind: 'video',
            original: a,
            candidates: [a, b],
            bitrateBps: 1000000,
          ),
        ],
        clock: () => time,
        probe: (uri, config, token) async {
          offsets.add(config.probeOffset);
          s.proxy!.demandOffset = 8 * 1024 * 1024;
          return const ProbeResult(
            bytes: 262144,
            elapsed: Duration(seconds: 1),
            status: 206,
            totalBytes: 16000000,
            fingerprint: 'same',
          );
        },
      );
      await s.startProxy(
        create: (source, failure) => LocalStreamServer(
          source: source,
          headers: const {},
          clientFactory: HttpClient.new,
          onFailure: failure,
          rangeConcurrency: 8,
        ),
      );
      s.proxy!.demandOffset = 4 * 1024 * 1024 + 123;
      var opens = 0;
      s.onSwitch = (v, a) async {
        opens++;
        return true;
      };
      await s.observe(bufferAheadSeconds: 0, throughputBps: 0, playing: true);
      time = const Duration(seconds: 6);
      await s.observe(bufferAheadSeconds: 0, throughputBps: 0, playing: true);
      expect(offsets, [4 * 1024 * 1024, 4 * 1024 * 1024]);
      expect(s.switches, 0);
      await s.recoverPlayback();
      expect(s.bypassed, isTrue);
      expect(opens, 1);
      expect(offsets.length, 2);
      await s.close();
    },
  );
  test(
    'failed transport without verified challenger restores original',
    () async {
      final a = Uri.parse('https://primary/video'),
          b = Uri.parse('https://backup/video');
      final s = AcceleratorSession(
        config: const AcceleratorConfig(mode: AcceleratorMode.multiRange8),
        tracks: [
          AcceleratorTrack(kind: 'video', original: a, candidates: [a, b]),
        ],
        probe: (uri, config, token) async =>
            const ProbeResult(error: 'transport'),
      );
      await s.startProxy(
        create: (source, failure) => LocalStreamServer(
          source: source,
          headers: const {},
          clientFactory: HttpClient.new,
          onFailure: failure,
          rangeConcurrency: 8,
        ),
      );
      var opens = 0;
      s.onSwitch = (v, a) async {
        opens++;
        return true;
      };
      await s.recoverPlayback();
      expect(s.bypassed, isTrue);
      expect(s.switches, 0);
      expect(opens, 1);
      await s.close();
    },
  );
  test(
    'real probe samples nonzero offset and validates final short range',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final ranges = <String>[];
      server.listen((r) async {
        ranges.add(r.headers.value('range')!);
        r.response.statusCode = 206;
        r.response.headers.set('content-range', 'bytes 262144-294911/294912');
        r.response.contentLength = 32768;
        r.response.add(List<int>.filled(32768, 7));
        await r.response.close();
      });
      final result = await CdnProbe(headers: const {}).run(
        Uri.parse('http://127.0.0.1:${server.port}/video'),
        const AcceleratorConfig(probeOffset: 262144),
        ProbeCancellation(),
      );
      expect(result.ok, isTrue);
      expect(result.bytes, 32768);
      expect(ranges, ['bytes=262144-524287']);
      await server.close(force: true);
    },
  );
}
