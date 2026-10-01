# Conditional bare ETag compatibility — 0.1.2+4

RFC 9110 requires quoted entity tags and strong comparison for If-Match:
https://www.rfc-editor.org/rfc/rfc9110.html#name-if-match
A received unquoted token stays validatorStatus=unsupported. It is not renamed
strong or assumed to be a content hash. Shape alone does not establish identity.

For Multi-Range GET demand only, a 16–128 character ASCII alphanumeric/underscore/
hyphen token can attempt a same-URI compatibility challenge. A random quoted
negative If-Match must return 412. A quoted positive If-Match must return 206,
exact Content-Range bytes 0-0/total, length 1, identity encoding, exact original
raw ETag, and exactly one body byte. No redirects or retries; both probes share
a four-second deadline and seek/close cancellation. Error bodies are abandoned.

Only the verifier can mint proof. Scope is exact signed URI, raw token, total
length. Results are retained at most 60 seconds, including failed probes, to
avoid repeated challenges on seeks. Fresh demand renews expired proof. An active
stream retains its established identity and every new chunk still uses quoted
If-Match and verifies exact raw ETag, range, total, encoding and complete length.
The existing failure path cancels sibling ranges; no unchecked concatenation.

This path is single-CDN only, even in Multi-CDN mode. Standard strong validators
keep their old admission path. Proof cannot be supplied to cross-CDN pool
preparation. Byte samples and conditional behavior are evidence, not a whole-file
cryptographic proof; a misbehaving origin can still lie about identity.

Diagnostics: bareEtagStatus (bareConditionalVerified, bareConditionIgnored,
barePositiveRejected, bareProbeFailed); parallelStatus=bareEtagParallel after
admission. Existing validatorStatus remains unsupported; transportable=false
refers to the original RFC validator, not the separately verified compatibility
path. Actual observedConcurrency and fresh network ordered output prove traffic
activity, not benefit. ETag and signed URL contents are never exported.

Install the code-4 APK over code 3, replay the affected video in Multi-Range 8,
then copy diagnostics. If probes are ignored/rejected, playback stays single
connection with the specific reason. Android real-CDN outcome remains to be tested.
