enum AcceleratorMode {
  off,
  auto,
  smartCdn,
  rangeProxy,
  multiRange4,
  multiRange8,
  multiRange12,
  multiRange16,
  rangeAuto,
}

/// Playback policy and bounded session RAM budgets; opt-in parallel modes.
class AcceleratorConfig {
  const AcceleratorConfig({
    this.mode = AcceleratorMode.off,
    this.safetyFactor = 1.5,
    this.switchGain = 1.5,
    this.lowBufferSeconds = 8,
    this.recoveryBufferSeconds = 20,
    this.minimumLowDuration = const Duration(seconds: 5),
    this.probeInterval = const Duration(seconds: 30),
    this.switchInterval = const Duration(seconds: 45),
    this.failureCooldown = const Duration(seconds: 30),
    this.measurementTtl = const Duration(seconds: 90),
    this.probeTimeout = const Duration(seconds: 4),
    this.sourceSwitchTimeout = const Duration(seconds: 10),
    this.probeBytes = 256 * 1024,
    this.maxProbesPerRound = 2,
    this.minimumSampleBytes = 16 * 1024,
    this.maxSwitches = 4,
    this.maxMemoryBytes = 12 * 1024 * 1024,
    this.maxAheadBytes = 4 * 1024 * 1024,
    this.maxBehindBytes = 4 * 1024 * 1024,
    this.ewmaFastHalfLifeSeconds = 2,
    this.ewmaSlowHalfLifeSeconds = 5,
  }) : assert(safetyFactor > 0),
       assert(switchGain > 1),
       assert(probeBytes > 0),
       assert(maxProbesPerRound >= 2);

  bool get usesProxy => mode == AcceleratorMode.rangeProxy || parallelism > 1;
  int get parallelism => switch (mode) {
    AcceleratorMode.multiRange4 => 4,
    AcceleratorMode.multiRange8 => 8,
    AcceleratorMode.multiRange12 => 12,
    AcceleratorMode.multiRange16 => 16,
    AcceleratorMode.rangeAuto => 16,
    _ => 1,
  };
  final int maxMemoryBytes, maxAheadBytes, maxBehindBytes;
  final AcceleratorMode mode;
  final double safetyFactor, switchGain;
  final double lowBufferSeconds, recoveryBufferSeconds;
  final Duration minimumLowDuration, probeInterval, switchInterval;
  final Duration failureCooldown, measurementTtl, probeTimeout;
  final Duration sourceSwitchTimeout;
  final int probeBytes, maxProbesPerRound, minimumSampleBytes, maxSwitches;
  final double ewmaFastHalfLifeSeconds, ewmaSlowHalfLifeSeconds;

  static AcceleratorMode parseMode(Object? value) =>
      AcceleratorMode.values.firstWhere(
        (mode) => mode.name == value,
        orElse: () => AcceleratorMode.off,
      );
}
