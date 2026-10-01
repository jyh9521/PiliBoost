# Metadata/playback lifetime isolation — 0.1.4+6

Phone version 0.1.3+5 logged HTTP response timeouts, premature EOF and failed seek.
The user confirmed the same video displays normally with accelerator OFF. This
localizes the regression to the accelerated playback path but does not establish
one sole root cause or exclude slow CDN/audio/rendering effects.

Reproduction before modification: HEAD queries cancel a running GET generation;
initial demand bytes wait behind full parallel chunk completion. Regression tests place a
body behind an explicit gate: the initial demand prefix must reach the player before parallel bodies are released.
A second test queries normal or failed HEAD while a GET is mid-body; the GET must
retain all bytes and no playback recovery/error or cancellation may occur.

HEAD now uses independent clients (at most four), no range scheduler, probes,
cache mutation, playback generation change or failure callback. Metadata errors
return 502 only to that reader. Close aborts metadata sockets and drains handlers.
The GET retains its original single-consumer seek policy. The initial actual demand prefix
is forwarded before conditional verification or full chunk fetch; invalid initial
metadata still returns 502 before headers. Transfer failures after headers close
the stream and follow the existing original-source recovery path.

No changes to decoder settings, Android target, validators or conditional proofs.
The controlled HTTP/native tests establish bounded behavior, not real-device
black-screen or acceleration benefit. Cover-install code 6, enable Multi-Range 8,
reload the same video and verify first frame, uninterrupted play and seek. No
installation or settings changes are performed automatically on the phone.

The initial prefix is ordinary validated single-response payload, not a combined
chunk. No conditional/chunk workers are needed if that prefix completes a small
demand. Replays may receive a small fresh origin prefix before the cached tail;
metrics explicitly distinguish these bytes. Later mismatched chunks abort the
stream and recover; the already valid original prefix is not counted as invalid.
