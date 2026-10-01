// ignore_for_file: cascade_invocations
import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/services/video_accelerator/source_transition_queue.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:PiliPlus/services/video_accelerator/accelerator_config.dart';
import 'package:PiliPlus/services/video_accelerator/accelerator_session.dart';
import 'package:PiliPlus/services/video_accelerator/cdn_probe.dart';
import 'package:PiliPlus/services/video_accelerator/local_stream_server.dart';
import 'package:PiliPlus/services/video_accelerator/playback_source_adapter.dart';
import 'package:PiliPlus/services/video_accelerator/range_concurrency_policy.dart';
import 'package:PiliPlus/services/video_accelerator/transfer_metrics.dart';

class _DelayedRelay extends LocalStreamServer {
  _DelayedRelay(this.gate)
    : super(
        source: () => Uri.parse('https://fixture/v'),
        headers: const {},
        clientFactory: HttpClient.new,
      );
  final Completer<void> gate;
  @override
  Future<void> start() async {
    await gate.future;
    await super.start();
  }
}

AcceleratorSession session({
  AcceleratorMode mode = AcceleratorMode.rangeAuto,
  Duration Function()? clock,
  ProbeTransport? probe,
}) => AcceleratorSession(
  config: AcceleratorConfig(mode: mode),
  clock: clock,
  tracks: [
    AcceleratorTrack(
      kind: 'video',
      original: Uri.parse('https://fixture/v'),
      candidates: [
        Uri.parse('https://fixture/v'),
        Uri.parse('https://backup/v'),
      ],
      bitrateBps: 1000000,
    ),
  ],
  probe: probe ?? (a, b, c) async => const ProbeResult(),
);
void main() {
  test('direct relay close joins pending bind and rejects restart', () async {
    final relay = LocalStreamServer(
      source: () => Uri.parse('https://fixture/v'),
      headers: const {},
      clientFactory: HttpClient.new,
    );
    final starting = relay.start();
    await relay.close();
    await starting;
    expect(relay.pendingHandlers, 0);
    await expectLater(relay.start(), throwsStateError);
  });
  test(
    'queued source transitions wait and only the latest queued load is current',
    () async {
      final q = SourceTransitionQueue();
      final first = q.enqueue();
      await first.ready;
      final middle = q.enqueue(), last = q.enqueue();
      var entered = false;
      final entering = middle.ready.then((_) => entered = true);
      await Future<void>.delayed(Duration.zero);
      expect(entered, isFalse);
      first.finish();
      await entering;
      expect(middle.isCurrent, isFalse);
      expect(last.isCurrent, isTrue);
      middle.finish();
      await last.ready;
      last.finish();
      last.finish();
    },
  );
  test('exit invalidates pending source ownership and cleanup releases next ticket', () async {
    final q = SourceTransitionQueue();
    final a = q.enqueue(), b = q.enqueue();
    q.invalidate();
    expect(a.isCurrent, isFalse);
    expect(b.isCurrent, isFalse);
    a.finish();
    await b.ready;
    b.finish();
    final c = q.enqueue();
    await c.ready;
    expect(c.isCurrent, isTrue);
    c.finish();
  });
  test(
    'session startup is single-flight; awaited close is idempotent',
    () async {
      final s = session();
      var factories = 0;
      LocalStreamServer create(Uri Function() source, void Function() failure) {
        factories++;
        return LocalStreamServer(
          source: source,
          headers: const {},
          clientFactory: HttpClient.new,
          onFailure: failure,
        );
      }

      await Future.wait([
        s.startProxy(create: create),
        s.startProxy(create: create),
      ]);
      expect(factories, 1);
      final server = s.proxy!;
      final first = s.close(), second = s.close();
      expect(identical(first, second), isTrue);
      await first;
      expect(s.disposed, isTrue);
      expect(s.proxy, isNull);
      expect(server.pendingHandlers, 0);
      final generation = s.generation;
      s.dispose();
      expect(s.generation, generation);
    },
  );
  test('close waits pending startup and does not resurrect relay', () async {
    final gate = Completer<void>();
    final s = session();
    late _DelayedRelay relay;
    final start = s.startProxy(create: (a, b) => relay = _DelayedRelay(gate));
    var complete = false;
    final close = s.close().then((_) => complete = true);
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(complete, isFalse);
    gate.complete();
    await start;
    await close;
    expect(s.proxy, isNull);
    expect(relay.pendingHandlers, 0);
  });
  test('awaited close drains an in-flight Smart CDN observation', () async {
    var now = Duration.zero;
    final response = Completer<ProbeResult>();
    ProbeCancellation? token;
    final s = session(
      mode: AcceleratorMode.smartCdn,
      clock: () => now,
      probe: (a, b, c) {
        token = c;
        return response.future;
      },
    );
    s.onSwitch = (v, a) async => false;
    await s.observe(bufferAheadSeconds: 0, throughputBps: 0, playing: true);
    now = const Duration(seconds: 6);
    final round = s.observe(
      bufferAheadSeconds: 0,
      throughputBps: 0,
      playing: true,
    );
    expect(token, isNotNull);
    var closed = false;
    final closing = s.close().then((_) => closed = true);
    expect(token!.cancelled, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(closed, isFalse);
    response.complete(const ProbeResult(error: 'cancelled'));
    await round;
    await closing;
    expect(s.disposed, isTrue);
  });
  test(
    'network snapshots deduplicate set/order and stop after close',
    () async {
      final changes = StreamController<List<ConnectivityResult>>();
      final s = session();
      final binding = AcceleratorBinding(
        s,
        () {},
        networkChanges: changes.stream,
      );
      changes.add([ConnectivityResult.wifi, ConnectivityResult.vpn]);
      await Future<void>.delayed(Duration.zero);
      expect(s.generation, 0);
      changes.add([
        ConnectivityResult.vpn,
        ConnectivityResult.wifi,
        ConnectivityResult.wifi,
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(s.generation, 0);
      changes.add([ConnectivityResult.mobile]);
      await Future<void>.delayed(Duration.zero);
      expect(s.generation, 1);
      changes.addError(StateError('fixture'));
      await Future<void>.delayed(Duration.zero);
      expect(s.generation, 2);
      await binding.close();
      final generation = s.generation;
      changes.add([ConnectivityResult.wifi]);
      await Future<void>.delayed(Duration.zero);
      expect(s.generation, generation);
      await changes.close();
    },
  );
  test(
    'binding close stops telemetry immediately and returns same future',
    () async {
      final changes = StreamController<List<ConnectivityResult>>();
      final s = session();
      var ticks = 0;
      final binding = AcceleratorBinding(
        s,
        () => ticks++,
        networkChanges: changes.stream,
        observationInterval: const Duration(milliseconds: 2),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ticks, greaterThan(0));
      final a = binding.close(), b = binding.close();
      expect(identical(a, b), isTrue);
      await a;
      final last = ticks;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ticks, last);
      await changes.close();
    },
  );
  test('seek/network invalidation resets Auto width and stale window, not cumulative payload', () async {
    var now = Duration.zero;
    final s = session(clock: () => now);
    await s.startProxy(
      create: (a, b) => LocalStreamServer(
        source: a,
        headers: const {},
        clientFactory: HttpClient.new,
        rangeConcurrency: 16,
        initialConcurrency: 4,
      ),
    );
    final server = s.proxy!;
    await s.observe(bufferAheadSeconds: 0, throughputBps: 0, playing: true);
    now = const Duration(seconds: 6);
    await s.observe(bufferAheadSeconds: 0, throughputBps: 0, playing: true);
    expect(server.desiredConcurrency, 8);
    server.metrics.received(1024);
    server.metrics.forwarded(1024, cached: false);
    s.invalidate(networkChanged: true);
    expect(server.desiredConcurrency, 4);
    expect(server.metrics.outputBps, 0);
    expect(server.metrics.upstreamBytes, 1024);
    expect(s.aggregateBps, 0);
    await s.close();
  });
  test('window and hysteresis reset start a new confirmation period', () {
    var now = Duration.zero;
    final metrics = TransferMetrics(now: () => now);
    metrics.received(100);
    now = const Duration(seconds: 1);
    expect(metrics.upstreamBps, 800);
    metrics.resetWindow();
    expect(metrics.upstreamBps, 0);
    expect(metrics.upstreamBytes, 100);
    final p = RangeConcurrencyPolicy();
    void observe(int time) => p.observe(
      now: Duration(seconds: time),
      bufferSeconds: 0,
      throughputBps: 0,
      requiredBps: 100,
      playing: true,
    );
    observe(0);
    observe(6);
    expect(p.concurrency, 8);
    p.reset();
    observe(7);
    observe(8);
    expect(p.concurrency, 4);
  });
  test('relay close drains a live request before resolving', () async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final arrived = Completer<void>();
    final gate = Completer<void>();
    origin.listen((r) async {
      if (!arrived.isCompleted) arrived.complete();
      await gate.future;
      try {
        r.response.statusCode = 206;
        r.response.headers.set('content-range', 'bytes 0-1023/1024');
        r.response.contentLength = 1024;
        r.response.add(List.filled(1024, 0));
        await r.response.close();
      } catch (_) {}
    });
    final relay = LocalStreamServer(
      source: () => Uri.parse('http://127.0.0.1:${origin.port}/v'),
      headers: const {},
      clientFactory: HttpClient.new,
    );
    await relay.start();
    final consumer = HttpClient();
    final reading = (() async {
      final r = await consumer.getUrl(relay.uri);
      r.headers.set('range', 'bytes=0-1023');
      await (await r.close()).drain<void>();
    })();
    final settled = reading.then<void>((_) {}, onError: (Object _) {});
    await arrived.future;
    expect(relay.pendingHandlers, 1);
    await relay.close();
    expect(relay.pendingHandlers, 0);
    expect(relay.activeRequests, 0);
    expect(relay.errors, 0);
    gate.complete();
    await settled;
    consumer.close(force: true);
    await origin.close(force: true);
  });
}
