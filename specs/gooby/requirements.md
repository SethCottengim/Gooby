# Baseline Component Functional Spec: Gooby

## Document Information

| Field | Value |
|---|---|
| **Spec Type** | Baseline |
| **Document ID** | BSL-UI-GOOBY-001 |
| **Component** | Gooby visual companion |
| **Domain** | ui |
| **Lifecycle Stage** | concept |
| **Status** | Approved |
| **Owner** | Hackathon product owner |
| **Last Updated** | 2026-11-10 |
| **Last Code Audit** | N/A until implemented |
| **AI Consumption Role** | Holistic Context |

## Evidence Anchors

| Evidence Type | Anchor | Notes |
|---|---|---|
| Primary implementation | Planned native macOS app source | Created during implementation |
| Public contract | Separate Gooby companion window | Visible desktop surface for the first milestone |
| Verification | Planned build and manual motion review | Normal-motion and reduced-motion checks |
| Related decisions | `specs/guardrails/gooby-visual-mvp.md` | Approved visual and privacy boundary |

## 1. Component Summary

### 1.1 Purpose

Gooby gives a future AI-use coach a friendly, immediately recognizable desktop
presence. This first baseline establishes the character itself without coupling
it to a terminal, an AI provider, or user conversation content.

### 1.2 Current Responsibility

The component shall present a calm, code-drawn companion character in its own
macOS window and communicate life through only two ambient behaviors: gentle
vertical movement and occasional blinking.

### 1.3 Scope Boundary

**In scope:**

- A native macOS visual companion window.
- A light-blue soft-cornered square character with white eyes and black pupils.
- Normal-motion and reduced-motion character states.

**Out of scope:**

- Terminal tracking, terminal text insertion, or interaction with Claude Code
  or Codex.
- Prompt analysis, emotional inference, conversation storage, and networked AI
  services.
- Speech, a mouth, blush, labels, badges, dashboards, or onboarding UI.

### 1.4 Users, Consumers, and Stakeholders

| Stakeholder / Consumer | Relationship to Component | Need Satisfied |
|---|---|---|
| Hackathon demonstrator | Launches and shows Gooby | A memorable, approachable visual prototype |
| Future AI-tool user | Will later see Gooby beside a terminal | A calm, non-intimidating companion presence |

## 2. Functional Baseline

### 2.1 Current-State Capabilities

| Req ID | Current-State Requirement | Priority | Acceptance Criteria | Verification |
|---|---|---|---|---|
| BSL-GOOBY-001 | The component shall launch as a separate native macOS window displaying exactly one Gooby character. | Must | Launching the app makes one character visible without a terminal, browser, or network connection. | Demonstration |
| BSL-GOOBY-002 | The component shall render Gooby as a light-blue, soft-cornered square with two white eyes and black pupils. | Must | The visible face has no blush, cheeks, mouth, text, status badge, gradient, or raster character asset. | Inspection |
| BSL-GOOBY-003 | The component shall give Gooby a smooth, gentle vertical oscillation while normal motion is enabled. | Must | During a 10-second visual review, the character completes visibly smooth upward and downward movement without a layout jump. | Demonstration |
| BSL-GOOBY-004 | The component shall make Gooby blink occasionally while normal motion is enabled. | Must | During a 30-second visual review, both eyes close and reopen at least once without obscuring the character's pupils when open. | Demonstration |
| BSL-GOOBY-005 | The component shall honor the operating system's reduced-motion preference. | Must | With reduced motion enabled, automatic bobbing and blinking stop while Gooby remains visible with open eyes. | Demonstration |
| BSL-GOOBY-006 | The component shall not take keyboard focus from another application while it is visible. | Must | A user can continue typing into an already focused application while Gooby remains on screen. | Demonstration |
| BSL-GOOBY-007 | The component shall operate without collecting user content or requesting terminal, screen-recording, Automation, or Accessibility permissions. | Must | First launch displays no such permission prompt and requires no prompt or terminal data. | Inspection |
| BSL-GOOBY-002a | (Amends BSL-GOOBY-002, 2026-11-10) The component shall render Gooby per the character v2 reference: soft-shaded light-blue rounded body, glossy black dot eyes, flat face (no cheeks), curled smile, face turned slightly right, stick arms and sitting legs, ground shadow. | Must | Live visual review against the reference image; no raster character asset, text, or badges. | Inspection |
| BSL-GOOBY-008 | The component shall complete a clean native macOS build without external character-image or animation dependencies. | Must | A clean build produces a launchable app without downloading or bundling a character image or third-party animation package. | Build + Inspection |
| BSL-GOOBY-009 | The component shall show a small close control only while the pointer is over Gooby; activating it shall quit Gooby without moving keyboard focus. | Must | Hovering reveals the close circle; moving away hides it; one click quits Gooby; typing in the previously focused app continues uninterrupted. | Demonstration |
| BSL-GOOBY-010 | The component shall run at most one Gooby at a time. | Must | Launching Gooby while it is already running leaves exactly one Gooby visible. | Demonstration |

### 2.2 Modes, States, or Variants

| Mode / State / Variant | Behavior | Entry Condition | Exit / Completion Condition |
|---|---|---|---|
| Normal motion | Gooby gently bobs and may blink. | The operating system permits normal motion. | The operating system requests reduced motion or the app closes. |
| Reduced motion | Gooby remains visible and still with open eyes. | The operating system requests reduced motion. | The operating system permits normal motion or the app closes. |

### 2.3 Baseline Exclusions

| Exclusion ID | Not Included In Current Baseline | Rationale / Disposition |
|---|---|---|
| EXC-001 | Following or attaching to a terminal window | Deferred to the desktop-integration feature |
| EXC-002 | Reading Claude Code or Codex prompts and outputs | Deferred to CLI-specific adapters |
| EXC-003 | Pasting suggested text into a terminal | Deferred until reliable, user-controlled session integration exists |
| EXC-004 | Character speech, prompt advice, reactions, or personalization | Deferred until the companion has approved conversation context |

## 3. Contract Baseline

### 3.1 Inputs

| Input | Source | Required? | Contract Reference | Notes |
|---|---|---|---|---|
| App launch | User or macOS | Yes | Native app lifecycle | Begins the visual experience |
| Motion preference | macOS accessibility setting | Yes | System motion preference | Selects normal-motion or reduced-motion state |

### 3.2 Outputs

| Output | Consumer / Destination | Contract Reference | Notes |
|---|---|---|---|
| Rendered Gooby window | User's desktop | Separate companion window | The sole visible product surface in this milestone |
| Motion state | User | Rendered character behavior | Ambient behavior changes with the system preference |

### 3.3 External Interfaces

| Interface | Direction | Purpose | Verification |
|---|---|---|---|
| macOS window system | Outbound | Shows Gooby without becoming the typing target | Manual focus review |
| macOS motion preference | Inbound | Selects the accessible visual state | Reduced-motion review |

### 3.4 Error And Recovery Behavior

| Condition | Required Component Response | User / Consumer Visible Result | Verification |
|---|---|---|---|
| Motion preference changes while Gooby is open | Settle into the applicable state without a visual jump. | Gooby becomes still or resumes calm movement. | Manual state-change review |
| App window closes | End the visual session cleanly. | No lingering animation or input capture remains. | Manual close/relaunch review |

## 4. Quality And Constraint Baseline

### 4.1 Non-Functional Requirements

| Category | Requirement | Target / Threshold | Verification |
|---|---|---|---|
| Reliability | Character motion shall remain visually continuous while the app is open. | No visible snap or window-layout shift during the 10-second normal-motion review. | Demonstration |
| Security / Access Control | The visual MVP shall not require privileged desktop or terminal access. | No system permission prompt for the excluded capabilities. | Inspection |
| Usability / Accessibility | Motion shall respect the operating system preference. | Reduced-motion state is visible and stable. | Demonstration |
| Maintainability | The character shall be code-drawn and have no external character-asset dependency. | Build succeeds without downloading a character image or animation package. | Inspection |

### 4.2 Operating Constraints

| Constraint ID | Constraint | Source |
|---|---|---|
| CON-GOOBY-001 | Use a native macOS SwiftUI/AppKit implementation for the visual MVP. | `specs/guardrails/gooby-visual-mvp.md` |
| CON-GOOBY-002 | Keep the visual layer self-contained so later terminal and CLI work does not replace it. | `specs/guardrails/gooby-visual-mvp.md` |
| CON-GOOBY-003 | Avoid external image and animation dependencies. | `specs/guardrails/gooby-visual-mvp.md` |

### 4.3 Assumptions

| Assumption ID | Assumption | Impact If False |
|---|---|---|
| ASM-GOOBY-001 | The demo runs on a macOS environment capable of running native SwiftUI apps. | The visual MVP requires a different host implementation. |
| ASM-GOOBY-002 | A separate companion window is sufficient for the first demonstration. | Window-following behavior becomes part of this baseline. |

## 5. Traceability And Verification

### 5.1 Standards, Guardrails, And Decisions

| Source | Relationship To Baseline |
|---|---|
| `specs/guardrails/gooby-visual-mvp.md` | Defines the visual, privacy, and accessibility constraints for every requirement in this baseline. |
| User-approved Gooby concept | Establishes the friendly visual companion purpose and staged product boundary. |

### 5.2 Feature History

| Date | Feature Spec / Issue | Baseline Impact |
|---|---|---|
| 2026-11-10 | Initial visual Gooby milestone | Establishes the first externally visible Gooby capability. |

### 5.3 Verification Coverage

| Requirement ID | Verification Evidence | Status |
|---|---|---|
| BSL-GOOBY-001 | Launch demonstration | Planned |
| BSL-GOOBY-002 | Visual inspection | Planned |
| BSL-GOOBY-003 | Normal-motion demonstration | Planned |
| BSL-GOOBY-004 | Blink demonstration | Planned |
| BSL-GOOBY-005 | Reduced-motion demonstration | Planned |
| BSL-GOOBY-006 | Keyboard-focus demonstration | Planned |
| BSL-GOOBY-007 | Permission and data-boundary inspection | Planned |
| BSL-GOOBY-008 | Clean-build output and dependency inspection | Planned |
| BSL-GOOBY-009 | Hover close demonstration plus XCTest | Planned |
| BSL-GOOBY-010 | Repeat-launch demonstration plus XCTest | Planned |

### 5.4 Known Verification Gaps

| Gap ID | Gap | Impact | Planned Resolution |
|---|---|---|---|
| GAP-GOOBY-001 | No implementation or automated visual checks exist yet. | All requirements remain unverified. | Add build and manual verification tasks after the design is approved. |

## Appendix A: Glossary

| Term | Definition |
|---|---|
| Gooby | The friendly square desktop companion character. |
| Normal motion | The default ambient character behavior: vertical bobbing and occasional blinking. |
| Reduced motion | The stable character behavior used when the operating system asks for less animation. |

## Appendix B: Revision History

| Version | Date | Author | Changes |
|---|---|---|---|
| 1.0 | 2026-11-10 | Codex with product-owner input | Initial functional baseline created from the approved visual scope. |
| 1.1 | 2026-11-10 | Codex with product-owner input | Approved the adversarial-analysis amendments and design constraints. |

## Appendix C: Requirement Analysis Dispositions

### C.1 Summary

The requirement-level analysis found one high and three medium risks. All are
resolved through one requirement amendment and five design constraints below.

### C.2 Requirement Amendments

| Finding | Amendment | Target |
|---|---|---|
| F-3A-004 | Require a clean native macOS build with no external character or animation dependency. | BSL-GOOBY-008 |

### C.3 Design Constraints

| ID | Design Constraint | Source Finding |
|---|---|---|
| DC-GOOBY-001 | The design shall use and manually verify a macOS window configuration that leaves the previously active application as the keyboard target. If the selected deployment target cannot provide that behavior, the build shall not claim BSL-GOOBY-006 as satisfied. | F-3A-001 |
| DC-GOOBY-002 | The design shall declare a supported macOS deployment target and verify that its chosen SwiftUI/AppKit APIs can implement both normal-motion and reduced-motion states. | F-3A-002 |
| DC-GOOBY-003 | The design shall separate character rendering and animation state from the native window-hosting layer so later window-tracking work can extend placement without replacing Gooby's visual component. | F-3A-003 |
| DC-GOOBY-004 | The design shall use focused SwiftUI/AppKit types with semantic names for the character, eyes, animation state, and floating-window behavior. | F-3A-005 |
| DC-GOOBY-005 | The design shall use bounded, nonuniform blink intervals while normal motion is enabled. | F-3A-006 |

### C.4 Accepted Risks

None. Every identified risk is resolved by a requirement amendment or design
constraint.

### C.5 Findings Record

| ID | Sev | Category | Title | Resolution | Status |
|---|---|---|---|---|---|
| F-3A-001 | High | assumption-fragility | Focus-preserving window behavior is unvalidated. | DC-GOOBY-001 | Resolved |
| F-3A-002 | Medium | assumption-fragility | Minimum supported macOS capability is unspecified. | DC-GOOBY-002 | Resolved |
| F-3A-003 | Medium | assumption-fragility | Future window tracking could force a visual-layer rewrite. | DC-GOOBY-003 | Resolved |
| F-3A-004 | Medium | guardrail-coverage | Clean-build verification is not a baseline requirement. | BSL-GOOBY-008 | Resolved |
| F-3A-005 | Low | guardrail-coverage | Semantic naming is not a concrete design constraint. | DC-GOOBY-004 | Resolved |
| F-3A-006 | Low | guardrail-coverage | Natural blink timing is underspecified. | DC-GOOBY-005 | Resolved |
