import 'package:PiliPlus/services/video_accelerator/range_protocol.dart';
import 'package:PiliPlus/services/video_accelerator/range_downloader.dart';

/// Evidence from one demand response's headers, not a whole-file identity proof.
/// Values are enums/numbers only; validators and signed URLs stay private.
class CdnCapability {
  CdnCapability.inspect({
    required this.statusCode,
    required int contentLength,
    ByteRange? requestedRange,
    String? contentRange,
    String? etag,
    String? encoding,
  }) : validatorStatus = EntityTag.status(etag),
       etagFormat = EntityTag.format(etag),
       validatorTransportable = EntityTag.isTransportableStrong(etag) {
    if (statusCode == 416) {
      rangeStatus = 'unsatisfied';
      final match = RegExp(r'^bytes \*/(\d+)$').firstMatch(contentRange ?? '');
      totalBytes = match == null ? null : int.tryParse(match[1]!);
      if (totalBytes == null) failureReason = 'invalidUnsatisfiedRange';
      return;
    }
    if (requestedRange != null) {
      if (statusCode != 206) {
        rangeStatus = statusCode == 200 ? 'ignored' : 'rejected';
        failureReason = statusCode == 200 ? 'rangeIgnored' : 'http$statusCode';
        return;
      }
      try {
        final cr = ContentRange.parse(contentRange ?? '');
        totalBytes = cr.total;
        if (!cr.matches(requestedRange) || contentLength != cr.length) {
          rangeStatus = 'mismatched';
          failureReason = 'rangeMismatch';
          return;
        }
        rangeStatus = 'matched';
      } on FormatException {
        rangeStatus = 'malformed';
        failureReason = 'invalidContentRange';
        return;
      }
    } else {
      if (statusCode != 200) {
        failureReason = 'http$statusCode';
        return;
      }
      if (contentLength < 0) {
        failureReason = 'unknownLength';
        return;
      }
      totalBytes = contentLength;
    }
    identityEncoding = (encoding ?? 'identity').toLowerCase() == 'identity';
    if (!identityEncoding) failureReason = 'encodedContent';
  }

  final int statusCode;
  final String validatorStatus;
  final bool validatorTransportable;
  final Map<String, Object?> etagFormat;
  BareEtagResult? bareResult;
  String rangeStatus = 'unmeasured';
  int? totalBytes;
  bool identityEncoding = false;
  String? failureReason;
  bool get parallelEligible =>
      failureReason == null &&
      statusCode != 416 &&
      (totalBytes ?? 0) > 0 &&
      (validatorTransportable || bareResult?.proof != null);
  Map<String, Object?> toJson() => {
    'statusCode': statusCode,
    'rangeStatus': rangeStatus,
    'validatorStatus': validatorStatus,
    'validatorTransportable': validatorTransportable,
    'bareEtagStatus': bareResult?.status ?? 'notAttempted',
    'conditionalProbe': bareResult?.evidence ?? const <String, Object?>{},
    'etagFormat': etagFormat,
    'identityEncoding': identityEncoding,
    'totalBytes': totalBytes,
    'parallelEligible': parallelEligible,
    'reason':
        failureReason ??
        (statusCode == 416
            ? 'unsatisfiedRange'
            : parallelEligible
            ? 'eligible'
            : bareResult != null
            ? bareResult!.status
            : validatorStatus == 'strong' && !validatorTransportable
            ? 'validatorTransportUnsupported'
            : 'missingStrongValidator'),
  };
}
