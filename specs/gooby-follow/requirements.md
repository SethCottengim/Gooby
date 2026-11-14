# Feature Spec: Gooby follows Terminal

| Field | Value |
|---|---|
| **Document ID** | FR-UI-GOOBY-FOLLOW-001 |
| **Status** | Verified (product owner, 2026-11-10) |
| **Process** | Condensed SDD pass (no separate adversarial phase), at product-owner request for hackathon speed |
| **Parent** | `specs/gooby/requirements.md` (BSL-GOOBY-001..010) |

## Product-owner choices (2026-11-10)
- Follow **macOS Terminal only** (`com.apple.Terminal`). VS Code and iTerm2 are out of scope.
- Sit **just outside the window's bottom-right edge**; flip to the left edge if there is no room.
- **Hide when Terminal is not the frontmost app**; reappear when it returns.

## Requirements

| ID | Requirement | Acceptance | Verification |
|---|---|---|---|
| FR-FOLLOW-001 | While Terminal is frontmost, Gooby shall sit just outside its front window's right edge, bottom-aligned. | Gooby's canvas left edge equals the window's right edge; bottoms align. | XCTest + live |
| FR-FOLLOW-002 | When the window moves or resizes, Gooby shall follow within 1 poll interval (1/30 s). | Dragging Terminal keeps Gooby attached with at most slight lag. | XCTest + live |
| FR-FOLLOW-003 | If there is no room to the right, Gooby shall sit outside the left edge; if neither fits, inside the bottom-right corner. Gooby stays within the screen's visible frame. | Placement rules hold for right-edge, full-width and off-screen-bottom windows. | XCTest + live |
| FR-FOLLOW-004 | When Terminal is not frontmost, or has no usable on-screen window, Gooby shall hide (0.15 s fade; instant with reduce motion) and reappear on return. | Switching apps hides/shows Gooby. | XCTest + live |
| FR-FOLLOW-005 | Following shall need no permission and read no window titles, pixels or content. | No permission prompt; source has no `kCGWindowName`, capture or Accessibility APIs. | XCTest source scan + live |
| FR-FOLLOW-006 | Following shall not move keyboard focus. | Typing in Terminal continues while Gooby moves, hides and reappears. | Live |

## Supersedes
- BSL-GOOBY-001 acceptance "visible without a terminal": Gooby now launches hidden unless Terminal is frontmost.
- The static bottom-right placement (design §2.5) remains only as the panel's initial frame before first placement.

## Known limits
- Only the frontmost Terminal window is followed; titles are unreadable, so Gooby cannot pick "the tab running Claude".
- Polling, not events: at most 1/30 s (33.3 ms) lag, may look slightly trailing during fast drags.
- Gooby floats above other windows (`.floating`), so on the left-flip side it can cover another app's window.
