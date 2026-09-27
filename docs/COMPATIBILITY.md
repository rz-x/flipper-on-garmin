# Compatibility

**Generated 2026-09-18** from the Connect IQ device definitions for the 118 products in `watchapp/manifest.xml`.
Regenerate with the snippet in `tools/build-all-devices.sh`'s neighbour, or by hand from `~/.Garmin/ConnectIQ/Devices/*/simulator.json`.

Only the **Descent Mk2** has run the app. Every other row is a build that succeeded and a layout computed from the device's
screen, not an observation. Rows are grouped by screen; the image column is the mirrored 128×64 Flipper screen after
`Framebuffer.fit()`, which on round screens bounds the scale by the circle so no corner of the image is cut.

| Screen | Shape | Input | Scale | Mirror image | Watchdog budget | Models |
|---|---|---|---|---|---|---|
| 240×240 | rectangle | touch | 1.88 | 240×120 | 240,000 | Venu Sq. Music Edition |
| 240×320 | rectangle | 5 buttons | 1.88 | 240×120 | 2,500,000 | Edge MTB |
| 240×400 | rectangle | touch | 1.88 | 240×120 | 250,000 | eTrex Touch |
| 240×400 | rectangle | touch | 1.88 | 240×120 | 2,500,000 | Edge Explore 2 |
| 240×400 | rectangle | 5 buttons | 1.88 | 240×120 | 250,000 | GPSMAP 67 / 67i |
| 246×322 | rectangle | 5 buttons | 1.92 | 246×123 | 2,500,000 | Edge 530, Edge 540 / 540 Solar |
| 246×322 | rectangle | touch | 1.92 | 246×123 | 2,500,000 | Edge 830, Edge 840 / 840 Solar |
| 282×470 | rectangle | touch | 2.2 | 282×141 | 2,500,000 | Edge 1030, Edge 1030 / Bontrager, Edge 1030 Plus, Edge 1040 / 1040 Solar |
| 282×470 | rectangle | touch | 2.2 | 282×141 | 250,000 | GPSMAP H1 / H1i Plus |
| 320×360 | rectangle | touch | 2.5 | 320×160 | 240,000 | Venu Sq 2, Venu Sq 2 Music |
| 420×600 | rectangle | 5 buttons | 3.28 | 420×210 | 2,500,000 | Edge 550 |
| 420×600 | rectangle | touch | 3.28 | 420×210 | 2,500,000 | Edge 850 |
| 448×486 | rectangle | touch | 3.5 | 448×224 | 240,000 | Venu X1 |
| 480×800 | rectangle | touch | 3.75 | 480×240 | 250,000 | Montana 7 Series |
| 480×800 | rectangle | touch | 3.75 | 480×240 | 2,500,000 | Edge 1050 |
| 218×218 | round | touch + 2 buttons | 1.47 | 187×93 | 240,000 | Captain Marvel, Rey, vívoactive 4S |
| 218×218 | round | 5 buttons | 1.47 | 187×93 | 120,000  half | Forerunner 255s |
| 218×218 | round | 5 buttons | 1.47 | 187×93 | 240,000 | Forerunner 255s Music |
| 240×240 | round | 5 buttons | 1.62 | 207×103 | 240,000 | Descent Mk2 S, Forerunner 245 Music, Forerunner 645 Music, Forerunner 745, Forerunner 945, Forerunner 945 LTE ...(+12) |
| 240×240 | round | touch + 2 buttons | 1.62 | 207×103 | 240,000 | fēnix 7S, fēnix 7S Pro, vívoactive 3 Music |
| 260×260 | round | 5 buttons | 1.76 | 225×112 | 240,000 | Forerunner 255 Music, fēnix 6 Pro / 6 Sapphire / 6 Pro Solar / 6 Pro Dual Power / quatix 6 |
| 260×260 | round | touch + 2 buttons | 1.76 | 225×112 | 240,000 | Darth Vader, First Avenger, Forerunner 955 / Solar, fēnix 7 / quatix 7, fēnix 7 Pro, fēnix 7 Pro - Solar Edition (no Wi-Fi) ...(+3) |
| 260×260 | round | 5 buttons | 1.76 | 225×112 | 120,000  half | Forerunner 255 |
| 280×280 | round | 5 buttons | 1.9 | 243×121 | 240,000 | Descent Mk2 / Mk2i, fēnix 6X Pro / 6X Sapphire / 6X Pro Solar / tactix Delta Sapphire / Delta Solar / Delta Solar - Ballistics Edition / quatix 6X / 6X Solar / 6X Dual Power |
| 280×280 | round | touch + 2 buttons | 1.9 | 243×121 | 240,000 | Enduro 3, fēnix 7X / tactix 7 / quatix 7X Solar / Enduro 2, fēnix 7X Pro, fēnix 7X Pro - Solar Edition (no Wi-Fi), fēnix 8 Solar 51mm / tactix 8 Solar 51mm, fēnix 9 Pro Solar 51mm |
| 360×360 | round | touch + 2 buttons | 2.46 | 314×157 | 240,000 | Forerunner 265s, Venu 2S |
| 390×390 | round | touch + 2 buttons | 2.67 | 341×170 | 240,000 | Approach S50, Approach S70 42mm, D2 Air, Descent G2, Descent Mk3 43mm / Mk3i 43mm, Forerunner 165 ...(+14) |
| 390×390 | round | 5 buttons | 2.67 | 341×170 | 240,000 | Instinct 3 AMOLED 45mm, Instinct Crossover AMOLED |
| 416×416 | round | touch + 2 buttons | 2.85 | 364×182 | 240,000 | D2 Air X10, D2 Mach 1, Forerunner 265, Venu 2, Venu 2 Plus, epix (Gen 2) / quatix 7 Sapphire ...(+5) |
| 416×416 | round | 5 buttons | 2.85 | 364×182 | 240,000 | Instinct 3 AMOLED 50mm |
| 454×454 | round | touch + 2 buttons | 3.0 | 384×192 | 240,000 | Approach S70 47mm, D2 Mach 2, D2 Mach 2 Pro, Descent Mk3i 51mm, Forerunner 570 47mm, Forerunner 965 ...(+8) |
| 466×466 | round | touch + 2 buttons | 3.2 | 409×204 | 240,000 | fēnix 9 Pro 51mm |

## Notes

- **Excluded on purpose:** fenix 6 / 6S (non-Pro), Instinct Crossover, Instinct E, Venu Sq - 128 KB watch-app memory limit; the app is ~140 KB and would die on launch.
- **Watchdog budget** is the per-`onUpdate` work limit from `simulator.json`. The render is sliced into 8 passes of ≤300 rectangles, tuned so the Forerunner 255 family (120 000, half the usual) stays inside it. Unverified on that hardware.
- **Touch devices:** swipe = direction, tap = OK; START and BACK keep their button meaning. Edge bike computers and handhelds build and are listed, but a Flipper remote on a bike computer is untested territory.
- **Launcher icon:** one 40×40 asset, scaled by the device (icon sizes range 26-70 px). Per-size assets are a to-do.
- **Fractional scaling:** e.g. 1.76 on a 260 px round screen gives 225×112 with nothing cut, where the old integer fit gave 256×128 with 15 px cut from each side - and the Flipper keeps its status bar in those corners.
