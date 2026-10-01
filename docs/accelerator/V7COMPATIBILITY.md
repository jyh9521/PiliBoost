# V7 CDN response compatibility

- Demand response headers now produce bounded, session-local `cdnCapabilities`
  evidence (latest record per host, maximum 32 hosts). This adds no probe traffic.
- Records expose status, matched/ignored/malformed/mismatched Range evidence,
  total length, validator category, identity encoding and explicit reasons.
  Signed URLs, paths, query parameters and ETag values are never included.
- `parallelEligible` describes initial metadata admission, not measured
  concurrency, a successful worker transfer or whole-file equivalence. Full 200
  responses leave Range support unmeasured until actual worker requests.
- Strong validator parsing is shared by resource construction and relay
  admission, including opaque octets 0x80–0xFF per
  [RFC 9110 section 8.8.3](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.8.3).
  Current `dart:io` outbound headers accept ASCII only. Valid non-ASCII tags
  are classified as strong but remain single-connection with
  `validatorTransportUnsupported`; they are never altered or escaped.
  Weak, malformed, mixed and non-octet validators remain single-connection.
- Range ignored, malformed/mismatched bounds, encoded content, unknown length,
  redirects and HTTP failures are explicit reasons and retain original-source
  fallback. Valid 416 responses start no workers; overflowing totals are rejected.
- Cross-CDN identity remains strong ETag + total length + head/tail anchors.
  Equal lengths or matching samples alone do not authorize byte splicing.

Validation uses controlled loopback responses and existing native playback
fixtures. Real CDN coverage, Android background playback, network transitions and
OFF/ON benefit remain part of the final unified device test. Default stays OFF.

Next: V8 configurable budgets and sanitized diagnostics export.
