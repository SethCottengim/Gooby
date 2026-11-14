# Design and Tasks: Gooby follows Terminal (FR-UI-GOOBY-FOLLOW-001)

## Design
- `TerminalWindowLocator` + `CGWindowInfoSource`: `CGWindowListCopyWindowInfo` (on-screen, front to back) → owner pid, layer, bounds, alpha only. Picks the first layer-0, visible, ≥ 200 × 100 pt window owned by the frontmost app when its bundle ID is `com.apple.Terminal`.
- `TerminalRelativePlacement` (pure): converts Core Graphics bounds (top-left origin) to AppKit (bottom-left origin) using the primary screen height; chooses the screen with the most overlap; right → left → inside-corner rule; clamps to the visible frame.
- `TerminalFollower`: 30 Hz `Timer` in `.common` run-loop mode. Skips the window query entirely when Terminal isn't frontmost. Ignores < 0.5 pt jitter.
- `GoobyWindowHost` conforms to `GoobyPresenter`: `prepare()` creates the panel hidden; `present(at:)` moves + fades in; `conceal()` fades out then `orderOut` (a present during the fade wins).
- Panel `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` so it follows Terminal across desktops / full screen.
- Feasibility probe (2026-11-10): bounds readable with Screen Recording denied; titles hidden; 200 queries: median 0.322 ms, p95 0.831 ms, max 23.422 ms.

## Tasks
| Task ID | Task | Requirement(s) | Status |
|---|---|---|---|
| FOLLOW-001 | Locator + live window source | FR-FOLLOW-001, 005 | ✅ |
| FOLLOW-002 | Pure placement + coordinate conversion | FR-FOLLOW-001, 003 | ✅ |
| FOLLOW-003 | Follower polling + hide/show | FR-FOLLOW-002, 004 | ✅ |
| FOLLOW-004 | Host present/conceal, panel Spaces behavior, delegate wiring | FR-FOLLOW-004, 006 | ✅ |
| FOLLOW-TEST-001 | XCTest: placement, conversion, locator, follower, presenter, source scan (`GoobyTests/TerminalFollowTests.swift`) | FR-FOLLOW-001..005 | ✅ (47/47 suite) |
| FOLLOW-VERIFY-001 | In-app live position check | FR-FOLLOW-001, 005 | ✅ Gooby x 1391 = Terminal right edge 1391; bottoms both 957 (CG coords) |
| FOLLOW-VERIFY-002 | Product-owner live test (drag, resize, app switch, screen edge, full screen, typing) | FR-FOLLOW-002..006 | ✅ 2026-11-10 — all 6 checks passed (product owner) |
