// Standalone transport comparison; inputs contain private signed URLs.
// ignore_for_file: cascade_invocations
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:PiliPlus/services/video_accelerator/accelerator_session.dart';
import 'package:PiliPlus/services/video_accelerator/accelerator_config.dart';
import 'package:PiliPlus/services/video_accelerator/cdn_probe.dart';
import 'package:PiliPlus/services/video_accelerator/cdn_resolver.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:crypto/crypto.dart';
import 'package:PiliPlus/services/video_accelerator/local_stream_server.dart';
import 'package:PiliPlus/services/video_accelerator/range_protocol.dart';

class DigestSink implements Sink<Digest> {
  Digest? result;
  @override
  void add(Digest d) {
    result = d;
  }

  @override
  void close() {}
}

const headers = {
  'user-agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.2 Safari/605.1.15',
  'referer': 'https://www.bilibili.com/',
};
Future<Map<String, Object?>> measure(
  String label,
  Uri source,
  int offset, {
  bool parallel = false,
}) async {
  const amount = 4 * 1024 * 1024;
  LocalStreamServer? proxy;
  final client = HttpClient()..autoUncompress = false;
  final watch = Stopwatch()..start();
  final digest = DigestSink();
  final hash = sha256.startChunkedConversion(digest);
  var count = 0, firstMs = 0, lastMs = 0, maxGap = 0, status = 0;
  String? failure;
  try {
    var target = source;
    if (parallel) {
      proxy = LocalStreamServer(
        source: () => source,
        headers: headers,
        clientFactory: HttpClient.new,
        rangeConcurrency: 8,
      );
      await proxy.start();
      target = proxy.uri;
    }
    final q = await client.getUrl(target).timeout(const Duration(seconds: 15));
    q.followRedirects = false;
    if (!parallel) headers.forEach(q.headers.set);
    q.headers.set('accept-encoding', 'identity');
    q.headers.set('range', 'bytes=$offset-${offset + amount - 1}');
    final response = await q.close().timeout(const Duration(seconds: 15));
    status = response.statusCode;
    if (status != 206) throw StateError('status');
    final range = ContentRange.parse(
      response.headers.value('content-range') ?? '',
    );
    if (range.start != offset ||
        range.end != offset + amount - 1 ||
        response.contentLength != amount) {
      throw StateError('range');
    }
    await (() async {
      await for (final data in response) {
        final now = watch.elapsedMilliseconds;
        if (count == 0) firstMs = now;
        maxGap = max(maxGap, now - lastMs);
        lastMs = now;
        count += data.length;
        hash.add(data);
        if (count > amount) throw StateError('oversize');
      }
    })().timeout(const Duration(seconds: 30));
    if (count != amount) failure = 'incompleteBody';
  } catch (e) {
    failure = e.runtimeType.toString();
  } finally {
    watch.stop();
    hash.close();
    client.close(force: true);
    await proxy?.close();
  }
  final result = <String, Object?>{
    'label': label,
    'host': source.host,
    'offset': offset,
    'requestedBytes': amount,
    'httpStatus': status,
    'receivedBytes': count,
    'completed': failure == null && count == amount,
    'failure': failure,
    'elapsedMs': watch.elapsedMilliseconds,
    'firstByteMs': firstMs,
    'maxDeliveryGapMs': maxGap,
    'averagePayloadBps': count * 8e6 / max(1, watch.elapsedMicroseconds),
    'sha256': digest.result.toString(),
    if (proxy != null) ...{
      'parallelStatus': proxy.parallelStatus,
      'observedConcurrency': proxy.observedConcurrency,
      'proxyErrors': proxy.errors,
      'proxyFailureReason': proxy.lastFailureReason,
      'transportClientsCreated': proxy.transportClientsCreated,
      'transportClientsReused': proxy.transportClientsReused,
      'capabilities': proxy.cdnCapabilities,
    },
  };
  stdout.writeln(jsonEncode(result));
  return result;
}

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
      'Usage: verify_real_video_recovery.dart PRIVATE_PLAYURL_JSON OUTPUT_JSON',
    );
    exitCode = 2;
    return;
  }
  final data =
      (jsonDecode(await File(args[0]).readAsString()) as Map)['data'] as Map;
  final track = ((data['dash'] as Map)['video'] as List).cast<Map>().firstWhere(
    (t) => t['id'] == 112 && (t['codecs'] as String).startsWith('avc'),
  );
  final source = Uri.parse((track['baseUrl'] ?? track['base_url']) as String);
  final backups = ((track['backupUrl'] ?? track['backup_url']) as List)
      .cast<String>();
  final candidates = CdnResolver.resolve(
    original: source.toString(),
    playUrls: backups,
    mirrorHosts: CDNService.values.map((c) => c.host).whereType<String>(),
  );
  final rows = <Map<String, Object?>>[];
  rows.add(await measure('DIRECT_BEFORE', source, 24 * 1024 * 1024));
  var time = Duration.zero;
  final probeRows = <Map<String, Object?>>[];
  final decisions = <Map<String, Object?>>[];
  final transport = CdnProbe(headers: headers);
  final video = AcceleratorTrack(
    kind: 'video',
    original: source,
    candidates: candidates,
    bitrateBps: (track['bandwidth'] as num).toDouble(),
  );
  final session = AcceleratorSession(
    config: const AcceleratorConfig(mode: AcceleratorMode.multiRange8),
    tracks: [video],
    clock: () => time,
    probe: (uri, config, token) async {
      final r = await transport.run(uri, config, token);
      final row = <String, Object?>{
        'host': uri.host,
        'offset': config.probeOffset,
        'bytes': r.bytes,
        'bps': r.throughputBps,
        'ok': r.ok,
        'failure': r.error,
        'status': r.status,
        'totalBytes': r.totalBytes,
        'fingerprint': r.fingerprint,
      };
      probeRows.add(row);
      stdout.writeln(jsonEncode(row));
      return r;
    },
  );
  await session.startProxy(
    create: (source, failure) => LocalStreamServer(
      source: source,
      headers: headers,
      clientFactory: HttpClient.new,
      rangeConcurrency: 8,
      onFailure: failure,
    ),
  );
  session.proxy!.demandOffset = 24 * 1024 * 1024;
  // Transport acceptance stronger than a successful native open: full exact range.
  session.onSwitch = (v, a) async {
    final r = await measure(
      'SWITCH_VALIDATION',
      Uri.parse(v),
      24 * 1024 * 1024,
    );
    rows.add(r);
    return r['completed'] == true;
  };
  try {
    await session.observe(
      bufferAheadSeconds: 1,
      throughputBps: 0,
      playing: true,
    );
    for (var round = 0; round < min(8, candidates.length - 1); round++) {
      time = Duration(seconds: 6 + round * 46);
      await session.observe(
        bufferAheadSeconds: 1,
        throughputBps: 0,
        playing: true,
      );
      final d = <String, Object?>{
        'round': round,
        'reason': session.decisionReason,
        'host': video.active.host,
        'switches': session.switches,
        'directCdnRecovery': session.directCdnRecovery,
        'bypassed': session.bypassed,
      };
      decisions.add(d);
      stdout.writeln(jsonEncode(d));
      if (session.switches > 0 || session.bypassed) break;
    }
    rows.add(await measure('SELECTED_AFTER', video.active, 24 * 1024 * 1024));
    final report = {
      'bvid': 'BV1uNeX6JEkf',
      'quality': 112,
      'codec': track['codecs'],
      'declaredVideoBitrateBps': track['bandwidth'],
      'rows': rows,
      'probes': probeRows,
      'decisions': decisions,
      'switches': session.switches,
      'directCdnRecovery': session.directCdnRecovery,
      'notes': [
        'Real network byte transport; no media file saved or displayed.',
        'Policy clock advanced between rounds; low-buffer input injected, not measured from a decoder.',
        'This verifies source selection and full-range transfers, not Android playback or universal speedup.',
      ],
    };
    await File(args[1])
        .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    stdout.writeln('REAL_RECOVERY_REPORT_SAVED');
  } finally {
    await session.close();
  }
}
