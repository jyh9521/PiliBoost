<div align="center">
    <img width="200" height="200" src="assets/images/logo/logo.png" alt="PiliPlus logo">
    <h1>PiliBoost</h1>
</div>

## PiliBoost · 0.1.4 conditional compatibility update

A [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) fork with adaptive CDN selection and bounded streaming acceleration.
Development belongs to [jyh9521/PiliBoost](https://github.com/jyh9521/PiliBoost); upstream is a reference and synchronization source.

### Streaming Accelerator

Audio/Video Settings → **Streaming Accelerator**. Default: **OFF**. Changes apply on the next source load or quality change.

| Mode | Implementation |
| --- | --- |
| OFF | Original playback without accelerator requests |
| Auto / Smart CDN | Bounded Range probes during sustained low buffering, EWMA selection, cooldown and source fallback |
| Proxy | Single-connection video Range relay; direct audio |
| Multi-Range 4/8/12/16 | Bounded single-CDN parallel chunks, ordered output and RAM cache |
| Multi-Range Auto | Starts at 4 lanes; adapts to buffering and fresh ordered output within the configured cap |
| Multi-CDN Auto | Experimental pool admission using strong ETag, exact total and matching head/tail samples |

Lane caps: 4/8/12/16. Cache: 4/8/16 MiB; reorder payload: at most 4 MiB. These are not process RSS limits.
Without a standard transportable strong validator or a verified same-URI bare-token conditional proof, playback stays single-connection. Errors attempt original-source recovery.
No disk cache, live acceleration, parallel audio or unvalidated cross-CDN byte splicing.

0.1.4 playback fix: HEAD metadata readers no longer cancel the active GET stream. The first actual demand payload is forwarded before conditional probes/full parallel chunks. Compatibility update: explicit quoted-positive 412 enables an additional raw-token negative/positive trial under the same deadline. `conditionalProbe` records HTTP status codes and exact failure categories. bare ASCII tokens require a mismatched quoted If-Match response of 412 and a matched one-byte response of 206. Only the exact URI may use this proof, never a cross-CDN pool. Diagnostics expose `bareEtagStatus` and `bareEtagParallel`, not raw tags. Nonstandard tags remain `unsupported` RFC validators.

### Verification

Diagnostics separate received network payload, fresh ordered output, cache output, observed concurrency, buffering and CDN capabilities/fallback reasons.
Copy sanitized JSON or manually record OFF/ON snapshots. Pairs do not prove matched content or acceleration benefit.
Final device testing should use identical content, quality, position and network, including sustained playback, seeking, quality changes, background/PiP and network transitions.
Automated tests and controlled native fixtures are validated; real CDN gains and Android long-play acceptance remain pending.

### Release and build

Version: **0.1.4+6**. Android release identity: `com.jyh9521.piliboost`; app label: **PiliBoost**.
A dedicated release key is required. Existing `com.example.piliplus.debug` test builds remain separate; data is not migrated automatically.
Published builds belong in this fork's [Releases](https://github.com/jyh9521/PiliBoost/releases). Release preparation/build output is not stable device acceptance.
[Build/signing](docs/accelerator/RELEASE.md) · [Budgets/export](docs/accelerator/V8SETTINGS.md) · [Validation](docs/accelerator/VALIDATION.md) · [Attribution](NOTICE).

<div align="center">

[中文](README.md) | English

![GitHub repo size](https://img.shields.io/github/repo-size/jyh9521/PiliBoost)
![GitHub Repo stars](https://img.shields.io/github/stars/jyh9521/PiliBoost)
![GitHub all releases](https://img.shields.io/github/downloads/jyh9521/PiliBoost/total)

</div>

<div align="center">
    <p>A third-party Bilibili client built with Flutter</p>

<img src="assets/screenshots/510shots_so.png" width="32%" alt="PiliPlus mobile screenshot" />
<img src="assets/screenshots/174shots_so.png" width="32%" alt="PiliPlus mobile screenshot" />
<img src="assets/screenshots/850shots_so.png" width="32%" alt="PiliPlus mobile screenshot" />
<br/>
<img src="assets/screenshots/main_screen.png" width="96%" alt="PiliPlus desktop screenshot" />
<br/>
</div>

<br/>

## Download

Download a build from [Releases](https://github.com/jyh9521/PiliBoost/releases), or clone the repository and build it locally.

## Disclaimer

PiliBoost is a PiliPlus-based personal project developed for educational purposes, intended only for learning and testing. Please delete it within 24 hours of downloading.
All APIs used were collected from the official website. This project does not provide any cracked content.

Credit to the original project: [guozhigq/pilipala](https://github.com/guozhigq/pilipala).
Credit to the upstream project: [orz12/PiliPalaX](https://github.com/orz12/PiliPalaX).
This repository makes more extensive changes. Thank you to the original authors for sharing their work as open source.

Thank you for using PiliPlus.

## Acknowledgements

- [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)
- [flutter_meedu_videoplayer](https://github.com/zezo357/flutter_meedu_videoplayer)
- [media-kit](https://github.com/media-kit/media-kit)
- [dio](https://pub.dev/packages/dio)
- And others

## Star History

<a href="https://star-history.dera.page/#jyh9521/PiliBoost&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://star-history.dera.page/svg?repos=jyh9521/PiliBoost&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://star-history.dera.page/svg?repos=jyh9521/PiliBoost&type=Date" />
   <img alt="Star History Chart" src="https://star-history.dera.page/svg?repos=jyh9521/PiliBoost&type=Date" />
 </picture>
</a>
