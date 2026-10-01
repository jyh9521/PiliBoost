# V8 budgets and diagnostic export

## Settings

- Persist one bounded settings map: `cacheMiB` (4/8/16) and
  `concurrencyLimit` (4/8/12/16). Missing, corrupt and unsupported values use
  the prior defaults (8 MiB cache, 16 maximum lanes). OFF remains the default.
- Apply changes to the next source load/quality change, not an active download.
  The cap constrains both manual modes and hysteretic Auto policy.
- Keep 256 KiB chunks, 4 MiB maximum reorder payload and 4 MiB ahead/behind
  retention windows. Cache + reorder budgets total 8/12/20 MiB; these do not
  bound process RSS, socket buffers or consumer-owned bytes. Strong validator,
  pool admission, cancellation and original-source fallback rules are unchanged.
- Storage failures keep the current budget selection and display a save error.

## Export

- Copy current diagnostics as versioned JSON to the clipboard. The export
  boundary allowlists keys, finite numbers, known policy labels and host names.
  Unknown fields/labels, signed URLs, route tokens, ETag values and headers are
  excluded or redacted independently of the live diagnostics producer.
- Record OFF and ON snapshots manually, then copy the pair. Recording checks
  the actual snapshot mode rather than the saved preference. Capture includes
  UTC time and freezes nested data against subsequent source mutation.
- New source ownership clears prior telemetry, including switching to OFF.
  Pairs live only on this diagnostics page and reset when it is closed.
- Pairs explicitly state `sameContentVerified: false` and
  `benefitVerified: false`. They do not identify content or calculate a measured
  acceleration gain. Use the same video/quality/position/network in the final
  device comparison and record sustained playback, not only these snapshots.

Validation covers budget parsing/roundtrips, policy caps, independent widget
settings callbacks, clipboard export, snapshot labeling, mutation isolation and
the existing controlled native playback fixtures. Android long playback,
background/PiP and network transitions remain pending unified device testing.

Next: release preparation (versioning, release build and upstream sync workflow).
