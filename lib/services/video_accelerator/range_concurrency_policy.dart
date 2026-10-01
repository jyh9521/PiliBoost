/// Hysteretic window changes; no resolution rules or per-connection rate sum.
class RangeConcurrencyPolicy {
  RangeConcurrencyPolicy({
    this.lowBufferSeconds = 8,
    this.recoveryBufferSeconds = 20,
    this.interval = const Duration(seconds: 5),
    this.maxConcurrency = 16,
  }) : assert(maxConcurrency >= 4 && maxConcurrency <= 16);
  final int maxConcurrency;
  final double lowBufferSeconds, recoveryBufferSeconds;
  final Duration interval;
  int concurrency = 4;
  Duration? _lastChange, _lowSince;
  void reset() {
    concurrency = 4;
    _lastChange = _lowSince = null;
  }

  void observe({
    required Duration now,
    required double bufferSeconds,
    required double throughputBps,
    required double requiredBps,
    required bool playing,
  }) {
    if (!playing) {
      _lowSince = null;
      return;
    }
    if (_lastChange != null && now - _lastChange! < interval) return;
    if (bufferSeconds >= recoveryBufferSeconds) {
      _lowSince = null;
      if (concurrency > 4) {
        concurrency -= 4;
        _lastChange = now;
      }
    } else if (requiredBps > 0 &&
        bufferSeconds < lowBufferSeconds &&
        throughputBps < requiredBps) {
      _lowSince ??= now;
      if (now - _lowSince! >= interval && concurrency < maxConcurrency) {
        concurrency = (concurrency + 4).clamp(4, maxConcurrency);
        _lastChange = now;
        _lowSince = now;
      }
    } else {
      _lowSince = null;
    }
  }
}
