import 'dart:convert';

import 'package:PiliPlus/services/video_accelerator/accelerator_config.dart';

/// Export is an independent allowlist boundary, not a dump of arbitrary telemetry.
abstract final class DiagnosticExport {
  static const _numeric = {
    'bufferSeconds',
    'requiredBps',
    'aggregateBps',
    'networkReceivedBps',
    'networkForwardedBps',
    'cacheForwardedBps',
    'networkReceivedBytes',
    'networkForwardedBytes',
    'cacheForwardedBytes',
    'observedConcurrency',
    'proxyThroughputBps',
    'proxyUpstreamBytes',
    'proxyForwardedBytes',
    'proxyRequests',
    'proxyErrors',
    'proxyActiveRequests',
    'concurrency',
    'requestedConcurrency',
    'concurrencyLimit',
    'maxMemoryBytes',
    'maxCacheBytes',
    'maxReorderBytes',
    'poolRejectedCandidates',
    'switches',
    'generation',
    'activeRanges',
    'queuedRanges',
    'cacheBytes',
    'cacheHits',
    'reorderBytes',
    'bitrateBps',
    'candidateCount',
    'measuredCandidateCount',
    'throughputBps',
    'ttfbMs',
    'dnsMs',
    'connectMs',
    'rttMs',
    'errors',
    'timeouts',
    'successes',
    'cooldownMs',
    'active',
    'statusCode',
    'totalBytes',
    'length',
    'quoteCount',
    'nonAsciiCount',
    'nonOctetCount',
    'whitespaceCount',
    'controlCount',
    'firstInvalidIndex',
  };
  static const _flags = {
    'probeBusy',
    'refreshRequired',
    'excluded',
    'recoveryProbePending',
    'identityEncoding',
    'parallelEligible',
    'validatorTransportable',
    'present',
    'weakPrefix',
    'lowercaseWeakPrefix',
    'openingQuote',
    'closingQuote',
    'asciiOnly',
    'leadingWhitespace',
    'trailingWhitespace',
    'possibleCombinedValues',
  };
  static const _labels = {
    'state',
    'mode',
    'parallelStatus',
    'validatorStatus',
    'rangeStatus',
    'reason',
    'proxyFailureReason',
    'decisionReason',
    'switchOutcome',
    'probingTrack',
    'kind',
    'recoveryState',
    'autoDecisionThroughputSource',
    'throughputSource',
    'invalidReason',
  };
  static const _values = {
    'off',
    'normal',
    'lowBuffer',
    'probing',
    'accelerating',
    'recovering',
    'bypassed',
    'resourceMismatch',
    'video',
    'audio',
    'ready',
    'cooling',
    'halfOpen',
    'excluded',
    'missing',
    'weak',
    'strong',
    'unsupported',
    'unmeasured',
    'matched',
    'ignored',
    'rejected',
    'mismatched',
    'malformed',
    'unsatisfied',
    'eligible',
    'missingStrongValidator',
    'validatorTransportUnsupported',
    'singleConnection',
    'strongEtagParallel',
    'validatedCdnPool',
    'rangeIgnored',
    'rangeMismatch',
    'invalidContentRange',
    'invalidUnsatisfiedRange',
    'unknownLength',
    'encodedContent',
    'unsatisfiedRange',
    'waitingForTelemetry',
    'proxyStartFailed',
    'manualProbe',
    'paused',
    'proxyObservationOnly',
    'bufferAboveLowThreshold',
    'noAlternative',
    'measuringCandidates',
    'switchingSource',
    'sourceOpened',
    'notSwitched',
    'bufferRecovered',
    'stillLowBuffer',
    'awaitingBufferRecovery',
    'mpvAuxiliary',
    'freshNetworkOrderedVideoWindow',
    'rangeIdentity',
    'etagIdentity',
    'oversizedBody',
    'deadline',
    'truncatedBody',
    'rangeSyntax',
    'transientStatus',
    'poolUnavailable',
    'anchorMismatch',
    'validationBudget',
    'candidateValidationError',
    'healthyBuffer',
    'auxiliaryThroughputSufficient',
    'generationQuietPeriod',
    'lowBufferConfirmation',
    'probeCooldown',
    'switchCooldown',
    'switchLimit',
    'allCandidatesCooling',
    'noSwitchHandler',
    'insufficientProbeGain',
    'challengerFailed',
    'empty',
    'none',
    'missingOpeningQuote',
    'missingClosingQuote',
    'quoteInOpaque',
    'whitespaceInOpaque',
    'controlInOpaque',
    'nonOctetInOpaque',
  };
  static bool _known(String value) =>
      _values.contains(value) ||
      AcceleratorMode.values.any((m) => m.name == value) ||
      RegExp(r'^http\d{3}$').hasMatch(value);

  static Map<String, Object?> sanitize(Map snapshot) {
    final out = <String, Object?>{};
    for (final entry in snapshot.entries) {
      final key = entry.key, value = entry.value;
      if (_numeric.contains(key) &&
          (value == null || value is num && value.isFinite)) {
        out[key as String] = value;
      } else if (_flags.contains(key) && value is bool) {
        out[key as String] = value;
      } else if (_labels.contains(key)) {
        out[key as String] = value == null
            ? null
            : value is String && _known(value)
            ? value
            : 'redacted';
      } else if ((key == 'host' || key == 'activeHost') &&
          value is String &&
          value.length <= 253 &&
          RegExp(r'^[a-zA-Z0-9.-]+$').hasMatch(value)) {
        out[key as String] = value;
      } else if (['tracks', 'cdns', 'pool', 'cdnCapabilities'].contains(key) &&
          value is List) {
        out[key as String] = value
            .take(32)
            .whereType<Map>()
            .map(sanitize)
            .toList();
      } else if (key == 'etagFormat' && value is Map) {
        out['etagFormat'] = sanitize(value);
      } else if (key == 'poolRejectionReasons' && value is Map) {
        out['poolRejectionReasons'] = {
          for (final e in value.entries)
            if (e.key is String && _known(e.key as String) && e.value is int)
              e.key as String: e.value,
        };
      }
    }
    return out;
  }

  static Map<String, Object?> capture(Map snapshot, {DateTime? now}) => {
    'capturedAtUtc': (now ?? DateTime.now()).toUtc().toIso8601String(),
    'snapshot': sanitize(snapshot),
  };
  static String encode(Map snapshot) =>
      const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': 1,
        ...capture(snapshot),
      });
}

/// Manual paired observations, not matched-content or measured benefit claims.
class DiagnosticComparison {
  Map<String, Object?>? off, on;
  bool record(Map snapshot, {required bool enabled, DateTime? now}) {
    final mode = snapshot['mode'];
    final isOff = mode == 'off' || (mode == null && snapshot['state'] == 'off');
    final isOn =
        mode is String &&
        AcceleratorMode.values.any(
          (m) => m != AcceleratorMode.off && m.name == mode,
        );
    if (enabled ? !isOn : !isOff) return false;
    final frozen = DiagnosticExport.capture(snapshot, now: now);
    if (enabled) {
      on = frozen;
    } else {
      off = frozen;
    }
    return true;
  }

  bool get complete => off != null && on != null;
  String encode() => const JsonEncoder.withIndent('  ').convert({
    'schemaVersion': 1,
    'comparisonKind': 'manualSnapshots',
    'sameContentVerified': false,
    'benefitVerified': false,
    'off': off,
    'on': on,
  });
}
