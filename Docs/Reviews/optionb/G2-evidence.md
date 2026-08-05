# G2 — Scroll feasibility — evidence

**Date:** 2026-08-05T11:50:37.257Z
**Build:** TranscriptSpike WP-0 2026-08-05
**Machine:** Openclaw's Mac mini, macOS 26.5.1, arm64
**Operator:** Q
**Verifier:** Adam

## Pre-registered criteria (verbatim)

- Streaming append: **5 fps for 10 s = 50 messages**, distance-from-bottom ≤ 4 px after each
- Late images: **10 local fixtures** (one every 500 ms), pin remains ≤ 4 px
- Window resize: continuous for 10 s at 4 Hz cycling 5 sizes, pin remains ≤ 4 px
- Pin state: `true` throughout (asserted via repeated `bc.pinToBottom` + state poll)
- Tolerance: **4 px** (sub-frame, allows sub-pixel rounding)
- Image fixtures: deterministic local PNGs written to `outDir/fixtures/`

## Assertions (sample)

| Time | Label | OK | Detail |
|---|---|---|---|
| 2026-08-05 11:50:24 +0000 | stream_append[0] | ✅ | dfb=0px |
| 2026-08-05 11:50:24 +0000 | resize[0] | ✅ | dfb=0px size=760x720 |
| 2026-08-05 11:50:25 +0000 | stream_append[1] | ✅ | dfb=0px |
| 2026-08-05 11:50:25 +0000 | resize[1] | ✅ | dfb=0px size=900x600 |
| 2026-08-05 11:50:25 +0000 | image_inject[0] | ✅ | dfb=0px url=g2-img-0.png |
| 2026-08-05 11:50:25 +0000 | stream_append[2] | ✅ | dfb=0px |
| 2026-08-05 11:50:25 +0000 | resize[2] | ✅ | dfb=0px size=600x800 |
| 2026-08-05 11:50:25 +0000 | stream_append[3] | ✅ | dfb=0px |
| 2026-08-05 11:50:25 +0000 | resize[3] | ✅ | dfb=0px size=1100x700 |
| 2026-08-05 11:50:25 +0000 | stream_append[4] | ✅ | dfb=0px |
| 2026-08-05 11:50:25 +0000 | image_inject[1] | ✅ | dfb=0px url=g2-img-1.png |
| 2026-08-05 11:50:26 +0000 | stream_append[5] | ✅ | dfb=0px |
| 2026-08-05 11:50:26 +0000 | resize[4] | ✅ | dfb=0px size=500x900 |
| 2026-08-05 11:50:26 +0000 | stream_append[6] | ✅ | dfb=0px |
| 2026-08-05 11:50:26 +0000 | resize[5] | ✅ | dfb=0px size=760x720 |
| 2026-08-05 11:50:26 +0000 | image_inject[2] | ✅ | dfb=0px url=g2-img-2.png |
| 2026-08-05 11:50:26 +0000 | stream_append[7] | ✅ | dfb=0px |
| 2026-08-05 11:50:26 +0000 | resize[6] | ✅ | dfb=0px size=900x600 |
| 2026-08-05 11:50:26 +0000 | stream_append[8] | ✅ | dfb=0px |
| 2026-08-05 11:50:26 +0000 | resize[7] | ✅ | dfb=0px size=600x800 |
| 2026-08-05 11:50:26 +0000 | stream_append[9] | ✅ | dfb=0px |
| 2026-08-05 11:50:26 +0000 | image_inject[3] | ✅ | dfb=0px url=g2-img-3.png |
| 2026-08-05 11:50:27 +0000 | stream_append[10] | ✅ | dfb=0px |
| 2026-08-05 11:50:27 +0000 | resize[8] | ✅ | dfb=0px size=1100x700 |
| 2026-08-05 11:50:27 +0000 | stream_append[11] | ✅ | dfb=0px |
| 2026-08-05 11:50:27 +0000 | resize[9] | ✅ | dfb=0px size=500x900 |
| 2026-08-05 11:50:27 +0000 | image_inject[4] | ✅ | dfb=0px url=g2-img-4.png |
| 2026-08-05 11:50:27 +0000 | stream_append[12] | ✅ | dfb=0px |
| 2026-08-05 11:50:27 +0000 | resize[10] | ✅ | dfb=0px size=760x720 |
| 2026-08-05 11:50:27 +0000 | stream_append[13] | ✅ | dfb=0px |
| 2026-08-05 11:50:27 +0000 | resize[11] | ✅ | dfb=0px size=900x600 |
| 2026-08-05 11:50:27 +0000 | stream_append[14] | ✅ | dfb=0px |
| 2026-08-05 11:50:27 +0000 | image_inject[5] | ✅ | dfb=0px url=g2-img-5.png |
| 2026-08-05 11:50:28 +0000 | stream_append[15] | ✅ | dfb=0px |
| 2026-08-05 11:50:28 +0000 | resize[12] | ✅ | dfb=0px size=600x800 |
| 2026-08-05 11:50:28 +0000 | stream_append[16] | ✅ | dfb=0px |
| 2026-08-05 11:50:28 +0000 | resize[13] | ✅ | dfb=0px size=1100x700 |
| 2026-08-05 11:50:28 +0000 | stream_append[17] | ✅ | dfb=0px |
| 2026-08-05 11:50:28 +0000 | image_inject[6] | ✅ | dfb=0px url=g2-img-6.png |
| 2026-08-05 11:50:28 +0000 | resize[14] | ✅ | dfb=0px size=500x900 |
| 2026-08-05 11:50:28 +0000 | stream_append[18] | ✅ | dfb=0px |
| 2026-08-05 11:50:28 +0000 | resize[15] | ✅ | dfb=0px size=760x720 |
| 2026-08-05 11:50:28 +0000 | stream_append[19] | ✅ | dfb=0px |
| 2026-08-05 11:50:28 +0000 | image_inject[7] | ✅ | dfb=0px url=g2-img-7.png |
| 2026-08-05 11:50:29 +0000 | stream_append[20] | ✅ | dfb=0px |
| 2026-08-05 11:50:29 +0000 | resize[16] | ✅ | dfb=0px size=900x600 |
| 2026-08-05 11:50:29 +0000 | stream_append[21] | ✅ | dfb=0px |
| 2026-08-05 11:50:29 +0000 | resize[17] | ✅ | dfb=0px size=600x800 |
| 2026-08-05 11:50:29 +0000 | stream_append[22] | ✅ | dfb=0px |
| 2026-08-05 11:50:29 +0000 | image_inject[8] | ✅ | dfb=0px url=g2-img-8.png |
| 2026-08-05 11:50:29 +0000 | resize[18] | ✅ | dfb=0px size=1100x700 |
| 2026-08-05 11:50:29 +0000 | stream_append[23] | ✅ | dfb=0px |
| 2026-08-05 11:50:29 +0000 | resize[19] | ✅ | dfb=0px size=500x900 |
| 2026-08-05 11:50:29 +0000 | stream_append[24] | ✅ | dfb=0px |
| 2026-08-05 11:50:30 +0000 | stream_append[25] | ✅ | dfb=0px |
| 2026-08-05 11:50:30 +0000 | image_inject[9] | ✅ | dfb=0px url=g2-img-9.png |
| 2026-08-05 11:50:30 +0000 | resize[20] | ✅ | dfb=0px size=760x720 |
| 2026-08-05 11:50:30 +0000 | stream_append[26] | ✅ | dfb=0px |
| 2026-08-05 11:50:30 +0000 | resize[21] | ✅ | dfb=0px size=900x600 |
| 2026-08-05 11:50:30 +0000 | stream_append[27] | ✅ | dfb=0px |

_(truncated; full list in `spike-run.log`)_

## Verdict

**PASS**


## Recording

If `--record` was passed, `recording.mp4` is alongside this file. Frame-level review by Adam.
