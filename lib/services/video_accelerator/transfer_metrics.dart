import 'dart:math';

/// Bounded ~3s video payload windows, not socket overhead or unique goodput.
class TransferMetrics {
  TransferMetrics({Duration Function()? now}) {
    final watch = Stopwatch()..start();
    _now = now ?? (() => watch.elapsed);
    _start = _now();
  }
  late final Duration Function() _now;
  late final Duration _start;
  final _upstream = <int, int>{}, _fresh = <int, int>{}, _cached = <int, int>{};
  int upstreamBytes = 0, freshForwardedBytes = 0, cachedForwardedBytes = 0;
  int get _tick => (_now() - _start).inMilliseconds ~/ 100;
  void _prune(Map<int, int> buckets) =>
      buckets.removeWhere((k, _) => k < _tick - 29);
  void _add(Map<int, int> buckets, int bytes) {
    if (bytes < 0) throw ArgumentError('Negative payload');
    _prune(buckets);
    buckets.update(_tick, (n) => n + bytes, ifAbsent: () => bytes);
  }

  void received(int bytes) {
    _add(_upstream, bytes);
    upstreamBytes += bytes;
  }

  void forwarded(int bytes, {required bool cached}) {
    _add(cached ? _cached : _fresh, bytes);
    if (cached) {
      cachedForwardedBytes += bytes;
    } else {
      freshForwardedBytes += bytes;
    }
  }

  double _rate(Map<int, int> buckets) {
    _prune(buckets);
    final micros = min(3000000, (_now() - _start).inMicroseconds);
    return micros <= 0
        ? 0
        : buckets.values.fold<int>(0, (a, b) => a + b) * 8e6 / micros;
  }

  void resetWindow() {
    _upstream.clear();
    _fresh.clear();
    _cached.clear();
  }

  double get upstreamBps => _rate(_upstream);
  double get freshForwardedBps => _rate(_fresh);
  double get cachedForwardedBps => _rate(_cached);
  double get outputBps => freshForwardedBps + cachedForwardedBps;
  int get retainedBuckets {
    _prune(_upstream);
    _prune(_fresh);
    _prune(_cached);
    return _upstream.length + _fresh.length + _cached.length;
  }
}

/// UI status describes observed mechanisms, never claims an OFF/ON speed gain.
abstract final class AcceleratorEffectSummary {
  static String describe(Map<String, Object?> data) {
    if (data['mode'] == 'off' || data['state'] == 'off') {
      return '加速已关闭：使用原始播放链路。';
    }
    if (data['state'] == 'bypassed') {
      return '加速已回退：使用原始播放链路。原因：${data['proxyFailureReason'] ?? '播放源恢复'}';
    }
    if (data['parallelStatus'] == 'missingStrongValidator') {
      return '未启用并发：资源缺少可靠强 ETag，当前为单连接。';
    }
    final observed = data['observedConcurrency'];
    if (observed is num && observed > 1) {
      final active = data['activeRanges'] as num? ?? 0;
      return '已观测到 ${observed.toInt()} 路上游并发；当前 ${active.toInt()} 路。是否改善播放仍需 OFF/ON 对照。';
    }
    if (data['parallelStatus'] == 'strongEtagParallel' ||
        data['parallelStatus'] == 'validatedCdnPool') {
      return '分片模式已启用，尚未观测到多路上游同时传输；缓存命中或小范围请求可能只用单路。';
    }
    if (data['parallelStatus'] == 'singleConnection') return '当前为单连接代理，未启用并发。';
    return '当前为 CDN 优选/等待播放数据；尚未确认加速效果。';
  }

  static String rate(Object? value) => value is num && value.isFinite
      ? '${(value / 1000000).toStringAsFixed(2)} Mbps'
      : '未测量';
}
