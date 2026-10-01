import 'dart:async';

import 'package:PiliPlus/services/video_accelerator/accelerator_config.dart';
import 'package:PiliPlus/services/video_accelerator/accelerator_diagnostics.dart';
import 'package:PiliPlus/services/video_accelerator/cdn_probe.dart';
import 'package:PiliPlus/services/video_accelerator/cdn_stats.dart';
import 'package:PiliPlus/services/video_accelerator/local_stream_server.dart';
import 'package:PiliPlus/services/video_accelerator/range_concurrency_policy.dart';

class AcceleratorTrack {
  AcceleratorTrack({
    required this.kind,
    required this.original,
    required this.candidates,
    this.bitrateBps,
    this.durationSeconds,
  }) : active = original;
  final String kind;
  final Uri original;
  final List<Uri> candidates;
  double? bitrateBps;
  final double? durationSeconds;
  Uri active;
  final stats = <Uri, CdnStats>{};
  int cursor = 0;
}

typedef SourceSwitch = Future<bool> Function(String video, String? audio);

class AcceleratorSession {
  AcceleratorSession({
    required this.config,
    required this.tracks,
    required this.probe,
    Duration Function()? clock,
  }) : now = clock ?? _clock.elapsedGetter;
  static final _clock = Stopwatch()..start();
  final AcceleratorConfig config;
  final List<AcceleratorTrack> tracks;
  final ProbeTransport probe;
  final Duration Function() now;
  SourceSwitch? onSwitch;
  void Function()? onRefreshRequired;
  ProbeCancellation? _cancellation;
  Duration? _lowSince, _lastProbe, _lastSwitch, _quietUntil;
  bool disposed = false, bypassed = false, _busy = false;
  int generation = 0, switches = 0, _trackCursor = 0;
  double bufferSeconds = 0, aggregateBps = 0;
  String state = 'normal';
  String decisionReason = 'waitingForTelemetry';
  String? probingTrack;
  String switchOutcome = 'notSwitched';
  LocalStreamServer? proxy;
  final _rangePolicy = RangeConcurrencyPolicy();

  Future<void>? _startingProxy, _closing;
  final _observations = <Future<void>>{};

  Future<void> startProxy({
    required LocalStreamServer Function(Uri Function(), void Function()) create,
  }) => _startingProxy ??= _startProxy(create: create);

  Future<void> _startProxy({
    required LocalStreamServer Function(Uri Function(), void Function()) create,
  }) async {
    if (!config.usesProxy || !enabled) return;
    final video = tracks.firstWhere((track) => track.kind == 'video');
    final server = create(() => video.active, () {
      if (enabled) {
        final refresh = proxy?.lastFailureReason == 'http403';
        final callback = onRefreshRequired;
        unawaited(
          restoreOriginal().then((_) {
            if (refresh && !disposed) callback?.call();
          }),
        );
      }
    });
    proxy = server;
    try {
      await server.start();
      if (disposed) await server.close();
    } catch (_) {
      proxy = null;
      await server.close();
      bypassed = true;
      state = 'bypassed';
      decisionReason = 'proxyStartFailed';
      publish();
    }
  }

  bool get enabled =>
      config.mode != AcceleratorMode.off && !disposed && !bypassed;
  double get requiredBps =>
      tracks.any(
        (track) => track.kind == 'video' && (track.bitrateBps ?? 0) <= 0,
      )
      ? 0
      : tracks.fold<double>(0, (sum, track) => sum + (track.bitrateBps ?? 0)) *
            config.safetyFactor;

  void invalidate({bool networkChanged = false}) {
    generation++;
    _cancellation?.cancel();
    proxy?.cancelRequests();
    proxy?.metrics.resetWindow();
    aggregateBps = 0;
    _rangePolicy.reset();
    if (config.mode == AcceleratorMode.rangeAuto ||
        config.mode == AcceleratorMode.multiCdn) {
      proxy?.desiredConcurrency = 4;
    }
    _lowSince = null;
    _quietUntil = now() + config.minimumLowDuration;
    if (networkChanged) {
      proxy?.resetPool();
      _lastProbe = null;
      for (final track in tracks) {
        track.stats.clear();
      }
    }
  }

  Future<void> observe({
    required double bufferAheadSeconds,
    required double throughputBps,
    required bool playing,
    double speed = 1,
  }) {
    late final Future<void> job;
    job = _observe(
      bufferAheadSeconds: bufferAheadSeconds,
      throughputBps: throughputBps,
      playing: playing,
      speed: speed,
    ).whenComplete(() => _observations.remove(job));
    _observations.add(job);
    return job;
  }

  Future<void> _observe({
    required double bufferAheadSeconds,
    required double throughputBps,
    required bool playing,
    double speed = 1,
  }) async {
    if (!enabled) return;
    if (CdnProbe.manualTesting > 0) {
      if (_cancellation != null) invalidate();
      decisionReason = 'manualProbe';
      return;
    }
    bufferSeconds = bufferAheadSeconds < 0 ? 0 : bufferAheadSeconds;
    aggregateBps = throughputBps.isFinite && throughputBps > 0
        ? throughputBps
        : 0;
    final time = now();
    final target = requiredBps * speed;
    // Foundation stage: fixed single upstream, no probe traffic or deferred
    // host changes on an open-ended native request. Smart CDN remains separate.
    if (config.usesProxy) {
      if (config.mode == AcceleratorMode.rangeAuto ||
          config.mode == AcceleratorMode.multiCdn) {
        _rangePolicy.observe(
          now: time,
          bufferSeconds: bufferSeconds,
          throughputBps: aggregateBps,
          requiredBps: target,
          playing: playing,
        );
        proxy?.desiredConcurrency = _rangePolicy.concurrency;
      }
      state = !playing || bufferSeconds > config.lowBufferSeconds
          ? 'normal'
          : 'lowBuffer';
      if (playing &&
          (config.mode == AcceleratorMode.rangeAuto ||
              config.mode == AcceleratorMode.multiCdn)) {
        if (bufferSeconds >= config.recoveryBufferSeconds &&
            _rangePolicy.concurrency > 4) {
          state = 'recovering';
        } else if (bufferSeconds < config.lowBufferSeconds &&
            _rangePolicy.concurrency > 4) {
          state = 'accelerating';
        }
      }
      decisionReason = !playing ? 'paused' : 'proxyObservationOnly';
      return;
    }
    // A successful open is not proof of sustained playback improvement.
    if (switches > 0) {
      if (bufferSeconds >= config.recoveryBufferSeconds) {
        switchOutcome = 'bufferRecovered';
      } else if (playing &&
          bufferSeconds <= config.lowBufferSeconds &&
          _lastSwitch != null &&
          time - _lastSwitch! >= config.switchInterval) {
        switchOutcome = 'stillLowBuffer';
      }
    }
    if (!playing ||
        bufferSeconds >= config.recoveryBufferSeconds ||
        (target > 0 && aggregateBps >= target)) {
      if (_cancellation != null) invalidate();
      _lowSince = null;
      state = 'normal';
      decisionReason = !playing
          ? 'paused'
          : bufferSeconds >= config.recoveryBufferSeconds
          ? 'healthyBuffer'
          : 'auxiliaryThroughputSufficient';
      return;
    }
    if (bufferSeconds > config.lowBufferSeconds) {
      _lowSince = null;
      decisionReason = 'bufferAboveLowThreshold';
      return;
    }
    _lowSince ??= time;
    // Timer observations must not overwrite the phase of a pending round.
    if (_busy) return;
    state = 'lowBuffer';
    final waitReason = (_quietUntil != null && time < _quietUntil!)
        ? 'generationQuietPeriod'
        : time - _lowSince! < config.minimumLowDuration
        ? 'lowBufferConfirmation'
        : (_lastProbe != null && time - _lastProbe! < config.probeInterval)
        ? 'probeCooldown'
        : (_lastSwitch != null && time - _lastSwitch! < config.switchInterval)
        ? 'switchCooldown'
        : switches >= config.maxSwitches
        ? 'switchLimit'
        : null;
    if (waitReason != null) {
      decisionReason = waitReason;
      return;
    }
    _busy = true;
    _lastProbe = time;
    final epoch = generation;
    final token = ProbeCancellation();
    _cancellation = token;
    try {
      final eligible = tracks
          .where(
            (track) =>
                track.candidates.length > 1 &&
                (proxy == null || track.kind == 'video'),
          )
          .toList();
      if (eligible.isEmpty) {
        decisionReason = 'noAlternative';
        return;
      }
      final track = _nextTrack(eligible);
      final alternatives = track.candidates
          .where(
            (uri) =>
                uri != track.active &&
                (track.stats[uri]?.available(time) ?? true),
          )
          .toList();
      if (alternatives.isEmpty || onSwitch == null) {
        decisionReason = alternatives.isEmpty
            ? 'allCandidatesCooling'
            : 'noSwitchHandler';
        return;
      }
      state = 'probing';
      decisionReason = 'measuringCandidates';
      probingTrack = track.kind;
      final challenger = alternatives[track.cursor++ % alternatives.length];
      // One incumbent and one challenger, sequentially; bounded total traffic.
      final results = <Uri, ProbeResult>{};
      for (final uri in [
        track.active,
        challenger,
      ].take(config.maxProbesPerRound)) {
        final result = await probe(uri, config, token);
        if (!enabled || epoch != generation || token.cancelled) return;
        results[uri] = result;
        final stats = track.stats.putIfAbsent(uri, () => CdnStats(config));
        if (result.ok) {
          stats.success(result.bytes, result.elapsed, result.ttfb, now());
          if ((track.bitrateBps ?? 0) <= 0 &&
              result.totalBytes != null &&
              (track.durationSeconds ?? 0) > 0) {
            track.bitrateBps = result.totalBytes! * 8 / track.durationSeconds!;
          }
        } else if (result.error != 'cancelled') {
          stats.errors++;
          if (result.timeout) stats.timeouts++;
          stats.blockedUntil = now() + config.failureCooldown;
        }
      }
      final current = results[track.active], other = results[challenger];
      if (current?.ok == true &&
          other?.ok == true &&
          ((current!.totalBytes != null &&
                  other!.totalBytes != null &&
                  current.totalBytes != other.totalBytes) ||
              (current.fingerprint != null &&
                  other!.fingerprint != null &&
                  current.fingerprint != other.fingerprint))) {
        final rejected = track.stats[challenger]!;
        rejected.errors++;
        rejected.blockedUntil = now() + config.failureCooldown;
        state = 'resourceMismatch';
        decisionReason = 'resourceMismatch';
        return;
      }
      if (current?.status == 403 && other?.status == 403) {
        await restoreOriginal();
        onRefreshRequired?.call();
        return;
      }
      final currentRate = track.stats[track.active]?.throughputBps ?? 0;
      final challengerStats = track.stats[challenger];
      final rate = challengerStats?.throughputBps ?? 0;
      if (other?.ok == true &&
          challengerStats!.fresh(now(), config.measurementTtl) &&
          (current?.ok != true || rate >= currentRate * config.switchGain)) {
        final previous = track.active;
        decisionReason = 'switchingSource';
        track.active = challenger;
        final ok = await _switchSource();
        if (!enabled || epoch != generation) {
          if (!bypassed) track.active = previous;
          return;
        }
        if (!ok) {
          track.active = previous;
          await restoreOriginal();
        } else {
          switches++;
          _lastSwitch = now();
          _lowSince = null;
          state = 'recovering';
          switchOutcome = 'awaitingBufferRecovery';
          decisionReason = 'sourceOpened';
        }
      } else {
        decisionReason = other?.ok == true
            ? 'insufficientProbeGain'
            : 'challengerFailed';
      }
    } catch (_) {
      if (enabled && epoch == generation) await restoreOriginal();
    } finally {
      _busy = false;
      probingTrack = null;
      if (identical(_cancellation, token)) _cancellation = null;
      publish();
    }
  }

  AcceleratorTrack _nextTrack(List<AcceleratorTrack> eligible) {
    final round = _trackCursor++;
    // High-bitrate DASH video dominated the observed stall (29 Mbps vs 83 kbps).
    // Give it three of four rounds, but retain an audio round to avoid starvation.
    if (eligible.length == 2) {
      final video = eligible
          .where((track) => track.kind == 'video')
          .firstOrNull;
      final audio = eligible
          .where((track) => track.kind == 'audio')
          .firstOrNull;
      if (video != null &&
          audio != null &&
          (audio.bitrateBps ?? 0) > 0 &&
          (video.bitrateBps ?? 0) >= audio.bitrateBps! * 4) {
        return round % 4 == 3 ? audio : video;
      }
    }
    return eligible[round % eligible.length];
  }

  Future<bool> _switchSource() async {
    final video = tracks.firstWhere((track) => track.kind == 'video');
    final audio = tracks.where((track) => track.kind == 'audio').firstOrNull;
    return await onSwitch
            ?.call(
              video.active.toString(),
              audio?.active.toString(),
            )
            .timeout(config.sourceSwitchTimeout * 3) ??
        false;
  }

  Future<void> restoreOriginal() async {
    if (disposed || bypassed) return;
    bypassed = true;
    invalidate();
    for (final track in tracks) {
      track.active = track.original;
    }
    state = 'bypassed';
    try {
      await _switchSource();
    } catch (_) {
      /* Original player handles errors. */
    }
    await proxy?.close();
    publish();
  }

  void publish() {
    if (disposed) return;
    AcceleratorDiagnostics.publish({
      'state': state,
      'mode': config.mode.name,
      'bufferSeconds': bufferSeconds,
      'requiredBps': requiredBps,
      'aggregateBps': aggregateBps,
      'throughputSource': proxy == null || bypassed
          ? 'mpvAuxiliary'
          : 'freshNetworkOrderedVideoWindow',
      'networkReceivedBps': proxy?.metrics.upstreamBps,
      'networkForwardedBps': proxy?.metrics.freshForwardedBps,
      'cacheForwardedBps': proxy?.metrics.cachedForwardedBps,
      'networkReceivedBytes': proxy?.metrics.upstreamBytes ?? 0,
      'networkForwardedBytes': proxy?.metrics.freshForwardedBytes ?? 0,
      'cacheForwardedBytes': proxy?.metrics.cachedForwardedBytes ?? 0,
      'observedConcurrency': proxy?.observedConcurrency ?? 0,
      'autoDecisionThroughputSource': config.usesProxy
          ? 'freshNetworkOrderedVideoWindow'
          : 'mpvAuxiliary',
      'proxyThroughputBps': proxy?.throughputBps,
      'proxyUpstreamBytes': proxy?.upstreamBytes ?? 0,
      'proxyForwardedBytes': proxy?.forwardedBytes ?? 0,
      'proxyRequests': proxy?.requests ?? 0,
      'proxyErrors': proxy?.errors ?? 0,
      'proxyFailureReason': proxy?.lastFailureReason,
      'proxyActiveRequests': proxy?.activeRequests ?? 0,
      'concurrency': proxy?.actualConcurrency ?? 1,
      'requestedConcurrency': config.parallelism,
      'parallelStatus': proxy?.parallelStatus,
      'validatorStatus': proxy?.validatorStatus,
      'poolRejectedCandidates': proxy?.rejectedPoolCandidates ?? 0,
      'poolRejectionReasons': proxy?.poolRejectionReasons ?? const {},
      'pool': proxy?.poolStats ?? [],
      'refreshRequired': proxy?.lastFailureReason == 'http403',
      'switches': switches,
      'generation': generation,
      'probeBusy': _busy,
      'probingTrack': probingTrack,
      'decisionReason': decisionReason,
      'switchOutcome': switchOutcome,
      'activeRanges': proxy?.activeRanges ?? 0,
      'queuedRanges': proxy?.queuedRanges ?? 0,
      'cacheBytes': proxy?.cache.bytes ?? 0,
      'cacheHits': proxy?.cache.hits ?? 0,
      'reorderBytes': proxy?.reservedBytes ?? 0,
      'tracks': tracks
          .map(
            (track) => {
              'kind': track.kind,
              'bitrateBps': track.bitrateBps,
              'activeHost': track.active.host,
              'candidateCount': track.candidates.length,
              'measuredCandidateCount': track.stats.length,
              'cdns': track.stats.entries
                  .map(
                    (entry) => {
                      'host': entry.key.host,
                      'throughputBps': entry.value.throughputBps,
                      'ttfbMs': entry.value.ttfb?.inMilliseconds,
                      'dnsMs': null,
                      'connectMs': null,
                      'rttMs': null,
                      'errors': entry.value.errors,
                      'timeouts': entry.value.timeouts,
                      'successes': entry.value.successes,
                      'cooldownMs': entry.value.available(now())
                          ? 0
                          : (entry.value.blockedUntil! - now()).inMilliseconds,
                    },
                  )
                  .toList(),
            },
          )
          .toList(),
    });
  }

  void dispose() {
    unawaited(close());
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    disposed = true;
    invalidate();
    final server = proxy;
    proxy = null;
    onSwitch = null;
    onRefreshRequired = null;
    await Future.wait<void>([
      if (server != null) server.close(),
      ?_startingProxy,
      ..._observations,
    ]);
  }
}

extension on Stopwatch {
  Duration Function() get elapsedGetter =>
      () => elapsed;
}
