# ETag format evidence — 0.1.1+3

This diagnostic update does not change validator admission, normalize/repair
ETag values or enable parallel playback for unsupported validators.

Replay the affected video using Multi-Range 8. On Diagnostics, select Copy current
diagnostics. Each `cdnCapabilities` entry now includes `etagFormat`:

- Presence and length (UTF-16 code units as supplied by `dart:io` headers).
- Exact uppercase weak prefix, lowercase prefix, opening/closing quotes, quote
  count and possible combined values.
- ASCII/non-ASCII/non-octet, whitespace and control counts; boundary whitespace.
- First invalid opaque-character index (zero-based in the original header) and
  an enumerated invalid reason. Missing boundary quotes have no character index.

Records exclude actual validator contents, hashes, character code values,
signed URLs, cookies and headers. The clipboard allowlist includes these fields
and drops unrelated injected fields. No additional probes or requests are made.
Evidence describes the header value received through `dart:io`, not a packet
capture of the original bytes. HTTP library normalization may already have
occurred; this is why the update does not guess or repair representation identity.

Use `missingOpeningQuote`, `missingClosingQuote`, `quoteInOpaque`,
`whitespaceInOpaque`, `controlInOpaque`, or `nonOctetInOpaque` to identify the next
compatibility investigation. A `none` result can still describe a weak tag or a
strong non-ASCII tag that the transport cannot send in conditional requests.

Android release package and signing identity stay unchanged. Version code 3
allows upgrading the previous code-2 release without uninstalling. Replay after
installation before copying diagnostics; no USB packet capture is required.
