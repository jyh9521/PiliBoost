# Raw conditional compatibility — 0.1.3+5

The previous phone snapshot reports barePositiveRejected without the exact failed
check. conditionalProbe now exposes quoted/raw negative and positive HTTP status
codes, conditionFormat and positiveFailureReason, not validator/URL/header values.

Only a quoted-positive response of exactly 412 enables raw negative and positive
trials. A same-length, same allowed-character-class token with a guaranteed wrong
first character must return 412. The correct raw token must return 206 with exact
range, total, identity encoding, raw ETag and a complete one-byte body. At most
four probes share a four-second deadline, no retries or redirects. A 200, ignored
negative, or metadata/body mismatch never establishes proof. Subsequent chunks
send the exact verified condition format and check all identity fields.

Proof remains same signed URI/validator/total scoped; no cross-CDN admission or
claim that a nonstandard token is a strong RFC ETag. Standard syntax reference:
https://www.rfc-editor.org/rfc/rfc9110.html#name-if-match
Existing 60-second result lifetime, cancellation, cache budgets and fallback stay.

Failure detail: unexpectedStatus, lengthMismatch, rangeMismatch, etagIdentity,
encodedContent, oversizedBody, truncatedBody, deadline or transport. Raw trial is
not attempted on quoted metadata mismatch or a status other than explicit 412.
Paused snapshots and zero current throughput are not full-session measurements.

Cover-install code 5, reload the affected video in Multi-Range 8, copy diagnostics.
Look for bareConditionalVerified, bareEtagParallel and observedConcurrency above 1.
Real Android CDN outcome/benefit remain separate from controlled HTTP/native tests.
