// ignore_for_file: cascade_invocations
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:PiliPlus/services/video_accelerator/transfer_metrics.dart';
import 'package:PiliPlus/services/video_accelerator/accelerator_diagnostics.dart';
import 'package:PiliPlus/pages/setting/pages/streaming_accelerator.dart';

void main() {
  test('network ingress, fresh output and cached output stay separate', () {
    var now = Duration.zero;
    final m = TransferMetrics(now: () => now);
    m.received(2000);
    m.forwarded(1000, cached: false);
    m.forwarded(3000, cached: true);
    expect(m.outputBps, 0);
    now = const Duration(seconds: 1);
    expect(m.upstreamBps, 16000);
    expect(m.freshForwardedBps, 8000);
    expect(m.cachedForwardedBps, 24000);
    expect(m.outputBps, 32000);
    expect(m.upstreamBytes, 2000);
    expect(m.freshForwardedBytes, 1000);
    expect(m.cachedForwardedBytes, 3000);
  });
  test('expired rate windows decay while cumulative bytes remain', () {
    var now = Duration.zero;
    final m = TransferMetrics(now: () => now);
    m.received(100);
    m.forwarded(100, cached: false);
    now = const Duration(milliseconds: 3100);
    expect(m.upstreamBps, 0);
    expect(m.outputBps, 0);
    expect(m.upstreamBytes, 100);
    m.forwarded(9000, cached: true);
    expect(m.cachedForwardedBps, 24000);
    expect(m.freshForwardedBps, 0);
  });
  test('rolling metric memory is bounded across a long session', () {
    var now = Duration.zero;
    final m = TransferMetrics(now: () => now);
    for (var i = 0; i < 10000; i++) {
      now = Duration(milliseconds: i * 100);
      m.received(1);
      m.forwarded(1, cached: i.isEven);
    }
    expect(m.retainedBuckets, lessThanOrEqualTo(90));
    expect(m.upstreamBytes, 10000);
  });
  test('negative counters cannot corrupt metrics', () {
    final m = TransferMetrics();
    expect(() => m.received(-1), throwsArgumentError);
    expect(() => m.forwarded(-1, cached: true), throwsArgumentError);
    expect(m.upstreamBytes, 0);
    expect(m.cachedForwardedBytes, 0);
  });
  final cases = <Map<String, Object?>, String>{
    {'mode': 'off'}: '加速已关闭',
    {'state': 'bypassed', 'proxyFailureReason': 'http403'}: 'http403',
    {'mode': 'multiRange4', 'parallelStatus': 'missingStrongValidator'}:
        '未启用并发',
    {
      'mode': 'multiRange4',
      'parallelStatus': 'strongEtagParallel',
      'observedConcurrency': 0,
    }: '尚未观测到多路',
    {
      'mode': 'multiCdn',
      'parallelStatus': 'validatedCdnPool',
      'observedConcurrency': 8,
      'activeRanges': 0,
    }: '已观测到 8 路',
    {'mode': 'rangeProxy', 'parallelStatus': 'singleConnection'}: '单连接代理',
    {'mode': 'smartCdn'}: '尚未确认加速效果',
  };
  for (final c in cases.entries) {
    test('effect summary ${c.value}', () {
      expect(AcceleratorEffectSummary.describe(c.key), contains(c.value));
    });
  }
  test(
    'rate formatting never presents missing or invalid data as measured zero',
    () {
      expect(AcceleratorEffectSummary.rate(null), '未测量');
      expect(AcceleratorEffectSummary.rate(double.nan), '未测量');
      expect(AcceleratorEffectSummary.rate(16000000), '16.00 Mbps');
      expect(AcceleratorEffectSummary.rate(0), '0.00 Mbps');
    },
  );
  testWidgets('diagnostics renders fallback and separates network from cache', (
    tester,
  ) async {
    final previous = AcceleratorDiagnostics.latest;
    AcceleratorDiagnostics.publish({
      'state': 'normal',
      'mode': 'multiRange4',
      'parallelStatus': 'missingStrongValidator',
      'networkReceivedBps': 1000000.0,
      'networkForwardedBps': 800000.0,
      'cacheForwardedBps': 20000000.0,
      'bufferSeconds': 4.25,
      'requiredBps': 2000000.0,
    });
    await tester.pumpWidget(
      const MaterialApp(home: AcceleratorDiagnosticsPage()),
    );
    expect(find.textContaining('未启用并发：'), findsOneWidget);
    expect(find.textContaining('网络顺序输出：0.80 Mbps'), findsOneWidget);
    expect(find.textContaining('缓存输出：20.00 Mbps'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    AcceleratorDiagnostics.publish(previous);
  });
}
