// Opt-in live-network acceptance. Private signed input stays outside the repository.
// ignore_for_file: cascade_invocations, avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:PiliPlus/services/video_accelerator/accelerator_config.dart';
import 'package:PiliPlus/services/video_accelerator/accelerator_session.dart';
import 'package:PiliPlus/services/video_accelerator/cdn_probe.dart';
import 'package:PiliPlus/services/video_accelerator/cdn_resolver.dart';
import 'package:PiliPlus/services/video_accelerator/local_stream_server.dart';
import 'package:PiliPlus/services/video_accelerator/media_source_rewriter.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';

void main() {
  final input = Platform.environment['PILIBOOST_REAL_INPUT'];
  final output = Platform.environment['PILIBOOST_REAL_OUTPUT'];
  test(
    'real 1080P native playback OFF and recovery-enabled eight lanes',
    () async {
      MediaKit.ensureInitialized(
        libmpv: Platform.environment['PILIBOOST_LIBMPV'],
      );
      final data =
          (jsonDecode(await File(input!).readAsString()) as Map)['data'] as Map;
      final dash = data['dash'] as Map;
      final video = (dash['video'] as List).cast<Map>().firstWhere(
        (t) => t['id'] == 112 && (t['codecs'] as String).startsWith('avc'),
      );
      final audio = (dash['audio'] as List).cast<Map>().first;
      final v = (video['baseUrl'] ?? video['base_url']) as String;
      final a = (audio['baseUrl'] ?? audio['base_url']) as String;
      const headers = {
        'user-agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.2 Safari/605.1.15',
        'referer': 'https://www.bilibili.com/',
      };
      final rows = <Map<String, Object?>>[];
      for (final enabled in [false, true]) {
        final player = await Player.create(
          configuration: const PlayerConfiguration(
            options: {
              'vo': 'null',
              'ao': 'null',
              'config': 'no',
              'vid': 'auto',
              'hwdec': 'no',
            },
          ),
        );
        AcceleratorSession? session;
        var selected = v;
        var switching = false;
        var nativeErrors = 0;
        var readErrors = 0;
        final errors = player.stream.error.listen((event) {
          nativeErrors++;
          if (AcceleratorSession.isReadFailure(event)) readErrors++;
          if (!switching &&
              session?.proxy != null &&
              AcceleratorSession.isReadFailure(event)) {
            unawaited(session!.recoverPlayback());
          }
        });
        final watch = Stopwatch()..start();
        try {
          if (enabled) {
            session = AcceleratorSession(
              config: const AcceleratorConfig(
                mode: AcceleratorMode.multiRange8,
              ),
              tracks: [
                AcceleratorTrack(
                  kind: 'video',
                  original: Uri.parse(v),
                  bitrateBps: (video['bandwidth'] as num).toDouble(),
                  candidates: CdnResolver.resolve(
                    original: v,
                    playUrls:
                        ((video['backupUrl'] ?? video['backup_url']) as List)
                            .cast<String>(),
                    mirrorHosts: CDNService.values
                        .map((c) => c.host)
                        .whereType<String>(),
                  ),
                ),
              ],
              probe: CdnProbe(headers: headers).run,
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
            selected = session.proxy!.uri.toString();
          }
          String edl(String source) =>
              'edl://!no_chapters;%${source.length}%$source;!new_stream;!no_chapters;%${a.length}%$a';
          player.setMediaHeader(
            userAgent: headers['user-agent']!,
            referer: headers['referer']!,
          );
          await player.open(
            Media(
              edl(selected),
              start: const Duration(seconds: 120),
            ),
            play: true,
          );
          session?.onSwitch = (next, audio) async {
            switching = true;
            try {
              final media = player.current.last;
              final rewritten = rewriteMediaSource(
                media.uri,
                selected,
                a,
                next,
                a,
              );
              await player.open(
                media.copyWith(uri: rewritten, start: player.state.position),
                play: true,
              );
              selected = next;
              return true;
            } catch (_) {
              return false;
            } finally {
              switching = false;
            }
          };
          final samples = <Map<String, Object?>>[];
          var maxNoProgress = 0, noProgress = 0;
          double? firstPosition;
          double? lastPosition;
          for (var i = 0; i < 60; i++) {
            await Future<void>.delayed(const Duration(seconds: 1));
            final p = player.state.position.inMicroseconds / 1e6;
            final buffer =
                (player.state.buffer - player.state.position).inMicroseconds /
                1e6;
            if (p >= 120.1) {
              firstPosition ??= p;
              if (lastPosition != null && p - lastPosition < 0.1) {
                noProgress++;
              } else {
                noProgress = 0;
              }
              if (noProgress > maxNoProgress) maxNoProgress = noProgress;
              lastPosition = p;
            }
            samples.add({
              'wallMs': watch.elapsedMilliseconds,
              'positionSeconds': p,
              'bufferSeconds': buffer,
            });
            if (!switching && session?.enabled == true) {
              unawaited(
                session!.observe(
                  bufferAheadSeconds: buffer,
                  throughputBps: session.proxy?.networkThroughputBps ?? 0,
                  playing: true,
                ),
              );
            }
          }
          final row = <String, Object?>{
            'mode': enabled ? 'multiRange8' : 'off',
            'elapsedMs': watch.elapsedMilliseconds,
            'firstPosition': firstPosition,
            'lastPosition': lastPosition,
            'maxNoProgressSeconds': maxNoProgress,
            'videoWidth': player.state.videoParams.w,
            'nativeErrors': nativeErrors,
            'readErrors': readErrors,
            'switches': session?.switches ?? 0,
            'directCdnRecovery': session?.directCdnRecovery ?? false,
            'bypassed': session?.bypassed ?? false,
            'observedConcurrency': session?.proxy?.observedConcurrency ?? 0,
            'proxyErrors': session?.proxy?.errors ?? 0,
            'proxyFailureReason': session?.proxy?.lastFailureReason,
            'reason': session?.decisionReason,
            'samples': samples,
          };
          rows.add(row);
          print(
            'REAL_NATIVE mode=${row['mode']} first=$firstPosition last=$lastPosition stall=$maxNoProgress errors=$nativeErrors switches=${row['switches']} recovery=${row['directCdnRecovery']}',
          );
        } finally {
          await errors.cancel();
          await player.dispose();
          await session?.close();
          await Future<void>.delayed(const Duration(seconds: 6));
        }
      }
      await File(output!).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'bvid': 'BV1uNeX6JEkf',
          'quality': 112,
          'codec': video['codecs'],
          'rows': rows,
          'notes': [
            'Native desktop decoder with null video/audio outputs; not Android visual acceptance.',
            'Sequential OFF then ON; CDN warm state uncontrolled; do not attribute warm-up to code.',
          ],
        }),
      );
      final on = rows.last;
      expect(on['videoWidth'], 1920);
      expect(on['firstPosition'], isNotNull);
      expect(
        (on['lastPosition'] as double) - (on['firstPosition'] as double),
        greaterThan(45),
      );
      expect(on['maxNoProgressSeconds'] as int, lessThanOrEqualTo(3));
      expect(
        on['bypassed'],
        false,
        reason: 'Original-source fallback alone does not accept acceleration.',
      );
      expect(
        on['directCdnRecovery'] == true ||
            (on['observedConcurrency'] as int) >= 8,
        isTrue,
      );
    },
    skip: input == null || output == null,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
