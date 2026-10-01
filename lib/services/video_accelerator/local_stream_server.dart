import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:PiliPlus/services/video_accelerator/range_protocol.dart';
import 'package:PiliPlus/services/video_accelerator/range_downloader.dart';
import 'package:PiliPlus/services/video_accelerator/range_scheduler.dart';
import 'package:PiliPlus/services/video_accelerator/range_memory_cache.dart';
import 'package:PiliPlus/services/video_accelerator/range_cdn_pool.dart';
import 'package:PiliPlus/services/video_accelerator/accelerator_config.dart';
import 'package:PiliPlus/services/video_accelerator/transfer_metrics.dart';

/// Video-only loopback relay; optional validated, bounded parallel windows.
/// Player demand drives streaming; every new request cancels the previous one.
class LocalStreamServer {
  LocalStreamServer({
    required this.source,
    required this.headers,
    required this.clientFactory,
    this.timeout = const Duration(seconds: 15),
    this.onFailure,
    this.rangeConcurrency = 1,
    int? initialConcurrency,
    RangeMemoryCache? cache,
    TransferMetrics? metrics,
    this.candidates = const [],
    this.config = const AcceleratorConfig(),
  }) : metrics = metrics ?? TransferMetrics(),
       cache = cache ?? RangeMemoryCache(),
       desiredConcurrency = initialConcurrency ?? rangeConcurrency,
       assert(
         (initialConcurrency ?? rangeConcurrency) >= 1 &&
             (initialConcurrency ?? rangeConcurrency) <= rangeConcurrency,
       ),
       assert(rangeConcurrency >= 1 && rangeConcurrency <= 16);
  final Uri Function() source;
  final Map<String, String> headers;
  final HttpClient Function() clientFactory;
  final Duration timeout;
  final AcceleratorConfig config;
  final List<Uri> candidates;
  RangePoolDownloader? _pool;
  RangeCancellation? _poolToken;
  int _poolCreatedMs = 0;
  List<Map<String, Object?>> get poolStats => _pool?.diagnostics ?? [];
  final TransferMetrics metrics;
  int observedConcurrency = 0;
  double get networkThroughputBps => metrics.freshForwardedBps;
  final RangeMemoryCache cache;
  final int rangeConcurrency;
  int desiredConcurrency;
  OrderedRangeScheduler? _scheduler;
  Future<void> _parallelDrain = Future<void>.value();
  int get queuedRanges =>
      max(0, (_scheduler?.pendingRanges ?? 0) - activeRanges);
  int get activeRanges => _scheduler?.downloader.activeRequests ?? 0;
  int get reservedBytes => _scheduler?.reservedBytes ?? 0;
  int actualConcurrency = 1;
  String parallelStatus = 'singleConnection';
  String validatorStatus = 'unmeasured';
  int get rejectedPoolCandidates => _pool?.rejectedCandidates ?? 0;
  Map<String, int> get poolRejectionReasons =>
      _pool?.rejectionReasons ?? const {};
  final void Function()? onFailure;
  HttpServer? _server;
  HttpClient? _client;
  final _clock = Stopwatch()..start();
  final _token = List.generate(
    24,
    (_) => Random.secure().nextInt(256),
  ).map((n) => n.toRadixString(16).padLeft(2, '0')).join();
  int _epoch = 0, upstreamBytes = 0, forwardedBytes = 0, errors = 0;
  int activeRequests = 0, requests = 0, cancellations = 0;
  String? lastFailureReason;
  bool _closed = false;
  Future<void>? _closing;
  Uri get uri => Uri.parse('http://127.0.0.1:${_server!.port}/$_token/video');

  double get throughputBps => metrics.outputBps;

  Future<void> start() async {
    if (_closed) throw StateError('Closed relay');
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_closed) {
      await _server!.close(force: true);
      return;
    }
    _server!.listen((request) => unawaited(_handle(request)));
  }

  Future<void> _empty(HttpRequest r, int status) async {
    r.response.statusCode = status;
    r.response.contentLength = 0;
    await r.response.close();
  }

  Future<void> _handle(HttpRequest r) async {
    HttpClient? client;
    var committed = false;
    var consumerGone = false;
    var upstreamFailed = false;
    var upstreamCompleted = false;
    var epoch = -1;
    try {
      if (_closed || r.uri.path != '/$_token/video' || r.uri.hasQuery) {
        await _empty(r, 404);
        return;
      }
      if (r.method != 'GET' && r.method != 'HEAD') {
        r.response.headers.set('allow', 'GET, HEAD');
        await _empty(r, 405);
        return;
      }
      final rawRange = r.headers.value('range');
      ByteRange? range;
      try {
        range = rawRange == null ? null : ByteRange.parse(rawRange);
      } on FormatException {
        await _empty(r, 400);
        return;
      }
      final remote = source();
      if (!['http', 'https'].contains(remote.scheme) || remote.host.isEmpty) {
        throw const FormatException('Invalid media source');
      }
      cancelRequests();
      epoch = _epoch;
      requests++;
      activeRequests = 1;
      client = clientFactory()..autoUncompress = false;
      _client = client;
      final localClient = client;
      unawaited(
        r.response.done.then<void>(
          (_) => localClient.close(force: true),
          onError: (Object _) {
            consumerGone = true;
            localClient.close(force: true);
          },
        ),
      );
      final request = await client.openUrl(r.method, remote).timeout(timeout);
      // Signed remote URI is supplied internally; local clients cannot choose it.
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      request.headers.set('accept-encoding', 'identity');
      if (rawRange != null) request.headers.set('range', rawRange);
      final response = await request.close().timeout(timeout);
      if (_closed || epoch != _epoch) throw StateError('Cancelled relay');
      final status = response.statusCode;
      if (status == 403) throw const RangeTransferException('http403');
      if (status == 416) {
        final cr = response.headers.value('content-range');
        if (cr == null || !RegExp(r'^bytes \*/\d+$').hasMatch(cr)) {
          throw const FormatException('Invalid unsatisfied range');
        }
        r.response.headers.set('content-range', cr);
        await _empty(r, 416);
        return;
      }
      if (range != null) {
        if (status != 206) throw const FormatException('Range not supported');
        final cr = ContentRange.parse(
          response.headers.value('content-range') ?? '',
        );
        if (!cr.matches(range) || response.contentLength != cr.length) {
          throw const FormatException('Mismatched upstream range');
        }
      } else if (status != 200 || response.contentLength < 0) {
        throw const FormatException('Invalid upstream response');
      }
      if ((response.headers.value('content-encoding') ?? 'identity') !=
          'identity') {
        throw const FormatException('Encoded upstream content');
      }
      r.response.statusCode = status;
      r.response.contentLength = response.contentLength;
      for (final name in ['content-range', 'content-type', 'accept-ranges']) {
        final value = response.headers.value(name);
        if (value != null) r.response.headers.set(name, value);
      }
      r.response.headers.set('cache-control', 'no-store');
      if (rangeConcurrency > 1 && r.method == 'GET') {
        final etag = response.headers.value('etag');
        validatorStatus = etag == null
            ? 'missing'
            : etag.startsWith('W/')
            ? 'weak'
            : RegExp(r'^"[\x21\x23-\x7e]*"$').hasMatch(etag)
            ? 'strong'
            : 'unsupported';
        // A strong validator is required before combining separate responses.
        if (etag != null && RegExp(r'^"[\x21\x23-\x7e]*"$').hasMatch(etag)) {
          final cr = status == 206
              ? ContentRange.parse(response.headers.value('content-range')!)
              : null;
          final total = cr?.total ?? response.contentLength;
          if (total > 0) {
            final first = cr?.start ?? 0;
            final last = cr?.end ?? total - 1;
            client.close(force: true);
            final previous = _parallelDrain;
            final completion = Completer<void>();
            _parallelDrain = completion.future;
            OrderedRangeScheduler? scheduler;
            RangeDownloader? downloader;
            var upstreamBefore = 0;
            var chunkCached = false;
            try {
              await previous;
              if (_closed || epoch != _epoch) throw const RangeCancelled();
              final resource = RangeResource(
                uri: remote,
                totalBytes: total,
                etag: etag,
              );
              if (candidates.isNotEmpty) {
                if (_pool == null ||
                    !_pool!.matches(resource) ||
                    _clock.elapsedMilliseconds - _poolCreatedMs >
                        config.poolLifetime.inMilliseconds) {
                  _pool = RangePoolDownloader(
                    headers: headers,
                    clientFactory: clientFactory,
                    onBytesReceived: metrics.received,
                    cache: cache,
                    primary: resource,
                    candidates: candidates,
                    sampleBytes: config.poolSampleBytes,
                    probeTimeout: config.poolProbeTimeout,
                    prepareTimeout: config.poolPrepareTimeout,
                    cooldown: config.poolCooldown,
                  );
                  _poolCreatedMs = _clock.elapsedMilliseconds;
                }
                downloader = _pool!;
                upstreamBefore = downloader.upstreamBytes;
                final token = RangeCancellation();
                _poolToken = token;
                try {
                  await _pool!.prepare(token);
                } catch (_) {
                  if (identical(_pool, downloader)) _pool = null;
                  rethrow;
                } finally {
                  if (identical(_poolToken, token)) _poolToken = null;
                }
                if (_closed || epoch != _epoch) throw const RangeCancelled();
              } else {
                downloader = CachedRangeDownloader(
                  cache: cache,
                  headers: headers,
                  clientFactory: clientFactory,
                  onBytesReceived: metrics.received,
                );
              }
              scheduler = OrderedRangeScheduler(
                downloader: downloader,
                concurrency: rangeConcurrency,
                onChunkReady: (chunk) {
                  chunkCached = chunk.attempts == 0;
                  observedConcurrency = max(
                    observedConcurrency,
                    downloader!.peakActiveRequests,
                  );
                },
                windowConcurrency: () {
                  actualConcurrency = desiredConcurrency;
                  return desiredConcurrency;
                },
              );
              _scheduler = scheduler;
              actualConcurrency = desiredConcurrency;
              parallelStatus = _pool != null
                  ? 'validatedCdnPool'
                  : 'strongEtagParallel';
              unawaited(
                r.response.done.then<void>(
                  (_) => scheduler?.invalidate(),
                  onError: (Object _) {
                    consumerGone = true;
                    scheduler?.invalidate();
                  },
                ),
              );
              committed = true;
              await r.response.addStream(
                scheduler
                    .read(resource, first, last)
                    .handleError((Object error) {
                      if (error is! RangeCancelled) upstreamFailed = true;
                      throw error;
                    })
                    .map((chunk) {
                      if (_closed || epoch != _epoch) {
                        throw const RangeCancelled();
                      }
                      _recordForwarded(chunk.length, cached: chunkCached);
                      return chunk;
                    }),
              );
              if (scheduler.deliveredBytes != last - first + 1) {
                cancellations++;
              }
              await r.response.close();
              return;
            } finally {
              scheduler?.invalidate();
              // addStream cancels its subscription and waits for async* finally.
              upstreamBytes +=
                  (downloader?.upstreamBytes ?? 0) - upstreamBefore;
              if (identical(_scheduler, scheduler)) _scheduler = null;
              completion.complete();
            }
          }
        }
        actualConcurrency = 1;
        parallelStatus = 'missingStrongValidator';
      }
      committed = true;
      if (r.method != 'HEAD') {
        var received = 0;
        await r.response.addStream(
          response
              .timeout(timeout)
              .handleError((Object error) {
                upstreamFailed = true;
                throw error;
              })
              .transform(
                StreamTransformer<List<int>, List<int>>.fromHandlers(
                  handleDone: (sink) {
                    upstreamCompleted = true;
                    sink.close();
                  },
                ),
              )
              .map((chunk) {
                if (_closed || epoch != _epoch) {
                  throw StateError('Cancelled relay');
                }
                received += chunk.length;
                upstreamBytes += chunk.length;
                metrics.received(chunk.length);
                observedConcurrency = max(observedConcurrency, 1);
                if (received > response.contentLength) {
                  upstreamFailed = true;
                  throw const FormatException('Oversized upstream');
                }
                // Bytes handed to the downstream stream, not unique cached goodput.
                _recordForwarded(chunk.length);
                return chunk;
              }),
        );
        if (received != response.contentLength) {
          // addStream can complete early when mpv closes a demux/seek reader.
          // Only an actual upstream EOF proves a truncated representation.
          if (!upstreamCompleted) {
            cancellations++;
            return;
          }
          upstreamFailed = true;
          throw const FormatException('Truncated upstream');
        }
      }
      await r.response.close();
    } catch (error) {
      // Cancellation from seek/close is not a CDN failure.
      if (!_closed &&
          !consumerGone &&
          (!committed || upstreamFailed) &&
          epoch == _epoch &&
          epoch >= 0) {
        errors++;
        lastFailureReason = error is RangeTransferException
            ? error.reason
            : error is FormatException
            ? error.message
            : error.runtimeType.toString();
        onFailure?.call();
      }
      try {
        if (!committed) {
          await _empty(r, 502);
        } else {
          final socket = await r.response.detachSocket();
          socket.destroy();
        }
      } catch (_) {
        /* Consumer already disconnected. */
      }
    } finally {
      client?.close(force: true);
      if (identical(_client, client)) {
        _client = null;
        activeRequests = 0;
      }
    }
  }

  void _recordForwarded(int count, {bool cached = false}) {
    forwardedBytes += count;
    metrics.forwarded(count, cached: cached);
  }

  void resetPool() {
    _pool = null;
    cache.clear();
  }

  void cancelRequests() {
    _poolToken?.cancel();
    _scheduler?.invalidate();
    _epoch++;
    if (_client != null) cancellations++;
    _client?.close(force: true);
    _client = null;
    activeRequests = 0;
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    cancelRequests();
    await _server?.close(force: true);
    await _parallelDrain;
    cache.clear();
    _pool = null;
  }
}
