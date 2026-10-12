# Transport reuse and rolling scheduling — 0.1.5+7

The user reports sustained stutter after 0.1.4. Inspection found each 256 KiB
chunk created and force-closed its own HttpClient, preventing reuse, and the
ordered scheduler waited for an entire window before starting any new request.
Dart's persistent-client behavior is documented here:
https://api.dart.dev/dart-io/HttpClient-class.html

A downloader now leases separate clients to simultaneous requests. Only a fully
read, exact status/range/total/encoding/validator/body validated response returns
its client to the bounded idle set (default 16 per downloader/lane). URI identity includes the signed
query. Each client allows one live connection per host, idle network timeout 15s.
Errors, partial bodies, deadlines and cancellation destroy only that lease; later
requests create a clean client. Cancellation never aborts an independently owned
lease. Relay completion and discarded CDN validation lanes release idle clients.
No retries, admission checks, source switches or decoder settings are relaxed.

The scheduler retains at most the configured width of chunk reservations and
refills only after the consumer resumes from yield. Slow tails do not impose an
extra whole-window barrier. This does not eliminate waiting for the next required
chunk. Identity failures anywhere in the queue promptly cancel siblings and
preserve the original error. Seek/close cancellation still drains all handled
futures. Configured memory/parallelism budgets and pause backpressure remain.

Diagnostics transportClientsCreated and transportClientsReused describe the
current/latest downloader (admitted pool lanes for pooled mode), not session byte
counts, unique sockets, successful TLS reuse or OFF/ON speed benefit. A remote
server can close a keep-alive socket; reusing the client can still open a new one.

Controlled benchmark: 16 MiB, 64 x 256 KiB chunks, 4/8 lanes. A new origin socket
pays an artificial 30ms setup delay; each request pays 5ms. Server remote ports
measure actual loopback socket counts, client factory records allocations, and
wall clock includes copying/JIT/validation/consumer time. The same legacy-API
fixture runs on original and modified sources. Expected baseline reuse assertions
fail, while byte count and validation complete. This is HTTP fixture evidence,
not real CDN/TLS/video playback or a universal improvement factor.

Cover-install code 7, choose Multi-Range 8 and reload the same video/quality/point.
Evaluate uninterrupted play, first frame and seek before copying diagnostics.
Track fresh ordered output and buffer, not just concurrency or reuse counters.
Fallback and OFF remain available. Device acceptance and sustained benefit are
pending; no device installation or application-data changes occur automatically.
