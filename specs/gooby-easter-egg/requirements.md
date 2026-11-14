# Feature Spec: Rain easter egg

| Field | Value |
|---|---|
| **Document ID** | FR-UI-GOOBY-RAIN-001 |
| **Status** | Implemented; awaiting product-owner live test |
| **Branch** | `easter-egg` |
| **Process** | Condensed SDD pass at product-owner request |

## Product-owner choices (2026-11-11)
- Trigger: 9 clicks on Gooby in a row, each within 0.6 s of the previous one.
- Light drizzle over the whole screen (the screen Gooby is on, incl. menu bar and Dock); the laptop stays usable.
- Water rises from the bottom and covers the screen over 4.5 minutes; the area under the water can't be clicked.
- When full: hold 10 s, then drain over 10 s.
- Gooby floats on the water surface.
- Trolling (recommendation accepted): close ✕ hidden during the storm; each click bails a useless 2 pt;
  a second 9-click streak is a fake-out (rain stops and water drains for 3 s, then the storm returns 1.25× faster).
- A fail-safe must stop everything and return to normal immediately.

## Requirements
| ID | Requirement | Verification |
|---|---|---|
| FR-RAIN-001 | 9 clicks on Gooby's body (not the ✕), each ≤ 0.6 s apart, start the storm. | XCTest + live |
| FR-RAIN-002 | Rain is a light but clearly visible drizzle (75 drops/s, ~100 on screen; blue-gray 1.6 pt streaks, 14–22 pt long, 55–75% opacity) that lands on the water surface with small splashes, and never blocks clicks. Revised 2026-11-11: the original 38 drops/s, 42%-alpha streaks were invisible on light backgrounds. | XCTest (DrizzleModel) + live |
| FR-RAIN-003 | Water (99% opaque, so what's behind it is practically invisible) rises linearly to full screen in 270 s; it blocks mouse clicks/scrolls beneath it. Keyboard input can't be blocked without the Accessibility permission, so typing still reaches the focused app. | XCTest + live |
| FR-RAIN-004 | Full screen holds 10 s, then drains in 10 s; the storm then ends by itself. | XCTest |
| FR-RAIN-005 | Gooby stays visible above the water and floats on the waterline. | XCTest + live |
| FR-RAIN-006 | Trolling: ✕ hidden; bail −2 pt per click; second streak fakes out (3 s) then rises 1.25× faster. | XCTest |
| FR-RAIN-007 | **Fail-safe:** ⌃⌥⌘ Esc ends everything immediately from any app (Carbon global hotkey, no permission, registered only during a storm). Backups: `pkill -x Gooby`; draining always starts by 290 s so every storm ends within 300 s. | XCTest + live |
| FR-RAIN-008 | No new permissions, network, or data collection. | Source scan |

## Window levels
Water = status bar + 1 (26), Gooby = status bar + 2 (27), rain = status bar + 3 (28). Live check
(2026-11-11, 1728 × 1117 screen): levels 26/27/28 as designed; water rose 35 → 60 pt in 6 s
(expected 4.137 pt/s).

## Code
`Sources/EasterEgg/`: `ClickStreakDetector`, `StormModel` (pure timeline), `FailSafeHotKey`,
`DrizzleModel` (pure rain simulation), `StormOverlays` (panels, `RainView`, `WaterView`), `StormController`.
Tests: `GoobyTests/StormTests.swift`. Debug-only: `GOOBY_DEBUG_STORM=1` starts a storm at launch.

## Known limits
- Covers only the screen Gooby is on (other monitors stay dry).
- Reduce motion freezes the wave but the drizzle still falls.
- If another app already owns ⌃⌥⌘ Esc, registration fails silently; `pkill` and the 300 s cap still apply.

## Amendment: tilt to slosh — continuous water (2026-11-11, branch `accelerometer`)

History: v1 tilted one rigid surface around the screen centre (product owner: not freeform);
v2 used a CPU particle fluid (product owner: particles too big and bouncy, wanted a continuous
look). v3, current: a continuous shallow-water surface.

| ID | Requirement | Verification |
|---|---|---|
| FR-RAIN-009 | Water is a continuous surface: 1D shallow-water equations on a staggered grid (8 pt columns, 216 on 1728 pt). Height differences drive flow, so waves travel, reflect off the screen edges, and slosh. Gravity on screen follows the laptop's roll (sideways component drives the water downhill), so tilting pours it to the low side and it settles at the real-world level slope. It does not bounce: velocity damping 0.9 /s plus light smoothing. | XCTest (ShallowWaterSim: conservation, settling, slope, dry corner) + live |
| FR-RAIN-010 | Sudden movement adds a short sideways kick (9,000 pt/s² per g), sending a wave across; sensor noise below 0.03 g is ignored. | XCTest (TiltInput) + live |
| FR-RAIN-011 | Fill is controlled by exact water volume (vol/target 0.999 offline at 100 s), so the 4.5-minute schedule holds. Rain feeds the bucket: each landing drop adds a small bump where it hits, which spreads as ripples. Draining/bailing removes water evenly. Gooby floats on the surface under him; rain lands on the surface. | XCTest + live |
| FR-RAIN-012 | Rendering: one smooth vector shape (99% opaque gradient, deep at the bottom, lighter toward the surface) with a light surface line. Above the surface it is fully transparent and the water window is trimmed to the water's highest point. | XCTest + live |
| FR-RAIN-013 | The motion sensor runs only during a storm and is switched off at stop, on graceful quit (SIGTERM/SIGINT handled, so `pkill` cleans up), and at every launch. Macs without the sensor get plain downward gravity. | Live (`pkill` left 0 windows and 0 sensor reports) |

**Bench (1728 × 1117 pt, -O):** water drift 0.0002% over a slosh; roughness 195 → 11.6 pt in 6 s
after a hard shove; tilted 25° slope 0.459 vs tan 25° = 0.466; with 8% water at a 34° tilt the high
side runs dry; 0.014 ms per 60 Hz frame at 90% full. The Debug build no longer needs `-O`.
Limitation: a height field cannot overturn or pour in a stream (no breaking waves).

**Sensor:** Apple-silicon MacBook motion sensor on the AppleSPU hub, IOKit HID vendor page 0xFF00 /
usage 3. 22-byte reports at 100 Hz; Int32 little-endian x/y/z at offsets 6/10/14 in 1/65536 g.
Reporting is enabled through private `SensorPropertyReportingState` / `SensorPropertyPowerState` /
`ReportInterval` properties. Verified on Mac16,7 (M4 Pro), macOS 26.7.1, inside Gooby with no admin
rights and no permission prompt. Roll direction confirmed live (positive = right side lower).
**Risk:** undocumented interface; a future macOS may change it.
**Open:** confirm live that clicks pass through the transparent area above a tilted surface inside
the water window.

Debug-only switches: `GOOBY_DEBUG_STORM=1` (start at launch), `GOOBY_DEBUG_STORM_SPEED=10`
(faster storm), `GOOBY_DEBUG_TILT=1` (log sensor roll).
