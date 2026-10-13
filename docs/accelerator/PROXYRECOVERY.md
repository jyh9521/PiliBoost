# Proxy slow-route recovery — 0.1.6+8 test build

Fixed-width and adaptive proxy modes previously returned from observation before
the Smart CDN selection policy. Relay errors immediately restored the same slow
original source. Eight observed connections did not establish useful throughput.

Proxy modes now enter bounded selection after five seconds of low buffering.
Each round samples one incumbent and one challenger sequentially, at the frozen
current ordered byte position rounded down to 256 KiB. Each sample is at most
256 KiB with a four-second deadline. Complete matching SHA256 samples and total
lengths are mandatory, with a fresh measured 1.5x gain. Mismatches and failures
are rejected and cooled down. Probe rounds remain 30 seconds apart, source
changes 45 seconds apart, with at most four successful changes per session.

The player reopens the entire source at the current playback position, retaining
rate, paused state, audio and subtitle selections. Successful recovery stops
the proxy and uses direct candidate playback for the remainder of this session.
`directCdnRecovery` distinguishes this from parallel playback. No cross-source
byte splicing or relaxed ETag admission occurs. Audio remains separate.

Relay and native read failures share one recovery owner. Transient failures may
use one bounded selection round; unavailable proof, cooldown, expired signatures
or failed source opens restore original playback. Identity failures do not retry
candidate selection. Closing the old loopback reader during a whole-source open
does not independently request another fallback. Seek/network/exit invalidation
cancels stale observations. OFF retains its original behavior.

Routine superseded Range cancellation is consumed before the HTTP response
stream writer. Non-cancellation transfer failures still propagate and trigger
the bounded recovery path; resource validators and response length checks remain.

## Reproducible computer checks

Use the pinned SDK and existing package configuration:

```powershell
& "$FlutterRoot/bin/flutter.bat" test --no-pub test/services/video_accelerator --reporter expanded
& "$FlutterRoot/bin/dart.bat" --packages=.dart_tool/package_config.json tool/phase1/verify_real_video_recovery.dart $PrivatePlayurlJson $OutputJson
```

The standalone harness loads private browser-issued DASH JSON (quality 112,
H.264), measures exact 4 MiB ranges, and runs real probe/selection code. Its
policy clock and low-buffer input are explicitly simulated; output is transport
evidence, not native playback. Signed URLs and account credentials are excluded
from reports. Payload is hashed and discarded, not saved as video files.

The opt-in native test uses the pinned media_kit/libmpv with null audio/video
outputs. Supply `PILIBOOST_REAL_INPUT`, `PILIBOOST_REAL_OUTPUT`, and
`PILIBOOST_LIBMPV`, then run `real_playback_test.dart`. It plays the real 1080P
video with separate audio for 60 seconds in OFF and ON at position 120 seconds,
records progress and stalls, and requires 1920-wide decoder parameters, over
45 seconds of ON progress and no consecutive post-start stall over three seconds.
It does not display or persist video frames. Missing private input skips this
live check in the normal deterministic suite.

Real CDN performance fluctuates. Sequential runs warm caches; do not attribute
warm-up to code, permanently prefer one host, or infer Android device acceptance
from desktop decoder/transport results. This release is a regression test APK,
not a claim that every cold video is now smooth.
