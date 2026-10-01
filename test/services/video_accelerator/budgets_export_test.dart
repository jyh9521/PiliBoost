// ignore_for_file: curly_braces_in_flow_control_structures
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:PiliPlus/services/video_accelerator/accelerator_config.dart';
import 'package:PiliPlus/services/video_accelerator/accelerator_diagnostics.dart';
import 'package:PiliPlus/services/video_accelerator/diagnostic_export.dart';
import 'package:PiliPlus/services/video_accelerator/range_concurrency_policy.dart';
import 'package:PiliPlus/pages/setting/pages/streaming_accelerator.dart';

void main() {
  test('corrupt budgets preserve defaults and OFF creates no proxy', () {
    for (final value in [
      null,
      'broken',
      [],
      {'cacheMiB': -1, 'concurrencyLimit': 99},
      {'cacheMiB': '16', 'concurrencyLimit': 8.0},
    ]) {
      final b = AcceleratorBudgets.parse(value);
      expect(b.cacheMiB, 8);
      expect(b.concurrencyLimit, 16);
    }
    expect(
      const AcceleratorBudgets().config(AcceleratorMode.off).usesProxy,
      isFalse,
    );
  });
  for (final cache in [4, 8, 16]) {
    for (final cap in [4, 8, 12, 16]) {
      test('budget roundtrip $cache MiB / $cap lanes', () {
        final b = AcceleratorBudgets.parse(
          jsonDecode(
            jsonEncode(
              AcceleratorBudgets(
                cacheMiB: cache,
                concurrencyLimit: cap,
              ).toJson(),
            ),
          ),
        );
        expect(b.cacheMiB, cache);
        expect(b.concurrencyLimit, cap);
        for (final mode in AcceleratorMode.values) {
          final config = b.config(mode);
          expect(config.parallelism, lessThanOrEqualTo(cap));
          expect(config.maxAheadBytes, 4 * 1024 * 1024);
          expect(
            config.maxMemoryBytes - config.maxAheadBytes,
            cache * 1024 * 1024,
          );
        }
      });
    }
  }
  for (final cap in [4, 8, 12, 16]) {
    test('Auto pressure obeys cap $cap', () {
      final policy = RangeConcurrencyPolicy(maxConcurrency: cap);
      for (var t = 0; t < 200; t += 5) {
        policy.observe(
          now: Duration(seconds: t),
          bufferSeconds: 0,
          throughputBps: 1,
          requiredBps: 100,
          playing: true,
        );
        expect(policy.concurrency, lessThanOrEqualTo(cap));
      }
      expect(policy.concurrency, cap);
      policy.reset();
      expect(policy.concurrency, 4);
    });
  }
  test(
    'export drops signed URLs, tokens, arbitrary labels and invalid numbers',
    () {
      final output = DiagnosticExport.encode({
        'mode': 'rangeAuto',
        'state': 'normal',
        'bufferSeconds': double.nan,
        'networkForwardedBps': double.infinity,
        'cacheBytes': 12,
        'uri': 'https://cdn.test/v?signature=SECRET',
        'token': 'SECRET',
        'decisionReason': 'SECRET',
        'host': 'https://cdn.test/?SECRET',
        'tracks': [
          {
            'kind': 'video',
            'activeHost': 'cdn.test',
            'etag': 'SECRET',
            'cdns': [
              {'host': 'cdn.test', 'throughputBps': 123},
            ],
          },
        ],
        'poolRejectionReasons': {'validationBudget': 2, 'SECRET': 10},
      });
      expect(output, isNot(contains('SECRET')));
      expect(output, isNot(contains('signature')));
      final s = (jsonDecode(output) as Map)['snapshot'] as Map;
      expect(s['cacheBytes'], 12);
      expect(s.containsKey('bufferSeconds'), isFalse);
      expect(s['decisionReason'], 'redacted');
      expect(s['poolRejectionReasons'], {'validationBudget': 2});
    },
  );
  test('comparison freezes snapshots and rejects mislabeled modes', () {
    final pair = DiagnosticComparison();
    final source = {'mode': 'off', 'state': 'off', 'cacheBytes': 0};
    expect(pair.record(source, enabled: true), isFalse);
    expect(pair.record(source, enabled: false), isTrue);
    source['cacheBytes'] = 999;
    expect(
      pair.record({'mode': 'rangeAuto', 'cacheBytes': 12}, enabled: true),
      isTrue,
    );
    expect(pair.complete, isTrue);
    final data = jsonDecode(pair.encode()) as Map;
    expect(data['off']['snapshot']['cacheBytes'], 0);
    expect(data['benefitVerified'], isFalse);
    expect(data['sameContentVerified'], isFalse);
    expect(pair.record({'mode': 'unknown'}, enabled: true), isFalse);
  });
  testWidgets('settings saves independent budgets through callback', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var saved = const AcceleratorBudgets();
    await tester.pumpWidget(
      MaterialApp(
        home: StreamingAcceleratorPage(
          mode: AcceleratorMode.off,
          onChanged: (_) async {},
          onBudgetsChanged: (b) async {
            saved = b;
          },
        ),
      ),
    );
    await tester.ensureVisible(find.text('并发上限'));
    await tester.tap(find.text('16 路'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('8 路').last);
    await tester.pumpAndSettle();
    expect(saved.concurrencyLimit, 8);
    await tester.ensureVisible(find.text('RAM 缓存预算'));
    await tester.tap(find.text('8 MiB'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4 MiB').last);
    await tester.pumpAndSettle();
    expect(saved.cacheMiB, 4);
    expect(saved.concurrencyLimit, 8);
  });
  testWidgets('clipboard exports sanitized current and paired snapshots', (
    tester,
  ) async {
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData')
          clipboard = (call.arguments as Map)['text'] as String;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    AcceleratorDiagnostics.publish({
      'state': 'off',
      'mode': 'off',
      'token': 'SECRET',
    });
    await tester.pumpWidget(
      const MaterialApp(home: AcceleratorDiagnosticsPage()),
    );
    await tester.tap(find.text('复制当前诊断'));
    await tester.pump();
    expect(clipboard, isNot(contains('SECRET')));
    expect(jsonDecode(clipboard!)['snapshot']['mode'], 'off');
    await tester.tap(find.text('记录 OFF'));
    await tester.pump();
    AcceleratorDiagnostics.publish({'state': 'normal', 'mode': 'rangeAuto'});
    await tester.pump();
    await tester.tap(find.text('记录 ON'));
    await tester.pump();
    await tester.tap(find.text('复制 OFF/ON 对照'));
    await tester.pump();
    expect(jsonDecode(clipboard!)['benefitVerified'], isFalse);
  });
}
