import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/services/video_accelerator/range_protocol.dart';
import 'package:PiliPlus/services/video_accelerator/cdn_capability.dart';
import 'package:PiliPlus/services/video_accelerator/diagnostic_export.dart';

void main() {
  for (final entry in <String?, String>{
    null: 'missing',
    '': 'empty',
    'SECRET': 'missingOpeningQuote',
    '"SECRET': 'missingClosingQuote',
    '"SECRET"': 'none',
    'W/"SECRET"': 'none',
    'w/"SECRET"': 'missingOpeningQuote',
    '"SEC RET"': 'whitespaceInOpaque',
    '"SEC\nRET"': 'controlInOpaque',
    '"SEC\u0100RET"': 'nonOctetInOpaque',
    '"SEC\u0080RET"': 'none',
    '"SECRET", "OTHER"': 'quoteInOpaque',
  }.entries) {
    test('ETag shape ${entry.value} without validator contents', () {
      final before = EntityTag.status(entry.key);
      final shape = EntityTag.format(entry.key);
      expect(shape['invalidReason'], entry.value);
      expect(shape['length'], entry.key?.length ?? 0);
      expect(jsonEncode(shape), isNot(contains('SECRET')));
      expect(jsonEncode(shape), isNot(contains('OTHER')));
      expect(EntityTag.status(entry.key), before);
      expect(() => shape['length'] = 999, throwsUnsupportedError);
    });
  }
  test('shape positions classify characters without publishing them', () {
    final space = EntityTag.format('W/"SEC RET"');
    expect(space['weakPrefix'], isTrue);
    expect(space['firstInvalidIndex'], 6);
    expect(space['whitespaceCount'], 1);
    final combined = EntityTag.format('"SECRET", W/"OTHER"');
    expect(combined['possibleCombinedValues'], isTrue);
    expect(combined['quoteCount'], 4);
    final opaque = EntityTag.format('"\u0080\u00ff"');
    expect(opaque['asciiOnly'], isFalse);
    expect(opaque['nonAsciiCount'], 2);
    expect(opaque['nonOctetCount'], 0);
  });
  test(
    'actual capability export retains shape and removes injected secrets',
    () {
      final c = CdnCapability.inspect(
        statusCode: 206,
        contentLength: 10,
        requestedRange: ByteRange.parse('bytes=0-9'),
        contentRange: 'bytes 0-9/20',
        etag: 'SECRET',
      );
      final output = DiagnosticExport.encode({
        'cdnCapabilities': [
          {
            'host': 'cdn.test',
            ...c.toJson(),
            'etag': 'SECRET',
            'etagFormat': {...c.etagFormat, 'raw': 'SECRET', 'value': 'SECRET'},
          },
        ],
      });
      expect(output, isNot(contains('SECRET')));
      final capability =
          jsonDecode(output)['snapshot']['cdnCapabilities'][0] as Map;
      expect(capability['etagFormat']['invalidReason'], 'missingOpeningQuote');
      expect(capability['etagFormat']['length'], 6);
      expect(capability['parallelEligible'], isFalse);
      expect(capability['validatorStatus'], 'unsupported');
      expect(capability['rangeStatus'], 'matched');
    },
  );
}
