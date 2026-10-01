/// RFC 9110 section 8.8.3: opaque octets, not a quoted-string to unescape.
class EntityTag {
  static String status(String? value) {
    if (value == null) return 'missing';
    final weak = value.startsWith('W/');
    final tag = weak ? value.substring(2) : value;
    if (tag.length < 2 || !tag.startsWith('"') || !tag.endsWith('"')) {
      return 'unsupported';
    }
    for (final c in tag.substring(1, tag.length - 1).codeUnits) {
      if (!(c == 0x21 ||
          (c >= 0x23 && c <= 0x7e) ||
          (c >= 0x80 && c <= 0xff))) {
        return 'unsupported';
      }
    }
    return weak ? 'weak' : 'strong';
  }

  static bool isStrong(String? value) => status(value) == 'strong';

  // dart:io outgoing header validation only accepts ASCII field values.
  static bool isTransportableStrong(String? value) =>
      isStrong(value) && value!.codeUnits.every((c) => c < 0x80);
}

/// A single HTTP byte range. Multipart requests are deliberately not supported.
class ByteRange {
  const ByteRange(this.start, this.end, this.suffix);
  final int? start, end, suffix;

  static ByteRange parse(String value) {
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value);
    if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) {
      throw const FormatException('Invalid single byte range');
    }
    final start = int.tryParse(match[1]!);
    final end = int.tryParse(match[2]!);
    if ((match[1]!.isNotEmpty && start == null) ||
        (match[2]!.isNotEmpty && end == null) ||
        (start == null && (end ?? 0) <= 0) ||
        (start != null && end != null && end < start)) {
      throw const FormatException('Invalid byte range bounds');
    }
    return ByteRange(
      start,
      start == null ? null : end,
      start == null ? end : null,
    );
  }

  (int, int)? resolve(int total) {
    if (total <= 0 || (start != null && start! >= total)) return null;
    final first = start ?? (total > suffix! ? total - suffix! : 0);
    final last = end == null || end! >= total ? total - 1 : end!;
    return (first, last);
  }
}

class ContentRange {
  const ContentRange(this.start, this.end, this.total);
  final int start, end, total;
  int get length => end - start + 1;

  static ContentRange parse(String value) {
    final m = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(value);
    if (m == null) throw const FormatException('Invalid content range');
    final a = int.parse(m[1]!), b = int.parse(m[2]!), n = int.parse(m[3]!);
    if (a > b || b >= n) throw const FormatException('Invalid content bounds');
    return ContentRange(a, b, n);
  }

  bool matches(ByteRange request) => request.resolve(total) == (start, end);
}
