# Gooby Component Requirements Verification and Test Matrix

## Document Information

| Field | Value |
|---|---|
| **Component** | Gooby visual companion |
| **Document Type** | Component RVTM |
| **Related Requirement Spec** | `specs/gooby/requirements.md` |
| **Related Design Spec** | `specs/gooby/design.md` |
| **Related Task List** | `specs/gooby/tasks.md` |
| **Status** | Verified — visual MVP complete 2026-11-10 |
| **Last Updated** | 2026-11-10 |

This is the durable component-level traceability record. The same baseline rows
appear in `tasks.md` §6; future Gooby features append their own rows here.

| Requirement ID | Requirement (Brief) | Verification Method | Test / Evidence ID | Task ID | Status | Date Verified | Notes |
|---|---|---|---|---|---|---|---|
| BSL-GOOBY-001 | One separate native Gooby companion window. | XCTest plus live launch/relaunch review. | T-GOOBY-001; M-GOOBY-001 | TG3-GOOBY-002, TG3-GOOBY-003, TEST-GOOBY-002, VERIFY-GOOBY-003 | Verified | 2026-11-10 | Exactly one character must be hosted. |
| BSL-GOOBY-002 | Required square, eyes, pupils, and prohibited details absent. | Metrics XCTest, inspection, and live visual review. | T-GOOBY-002; M-GOOBY-002 | TG2-GOOBY-001, TG2-GOOBY-002, TG2-GOOBY-004, TEST-GOOBY-001, VERIFY-GOOBY-001, VERIFY-GOOBY-003 | Verified | 2026-11-10 | Code-drawn character only. |
| BSL-GOOBY-003 | Smooth gentle vertical oscillation. | Pure bob-math XCTest plus 10-second review. | T-GOOBY-003; M-GOOBY-003 | TG2-GOOBY-001, TG2-GOOBY-003, TG2-GOOBY-004, TEST-GOOBY-001, VERIFY-GOOBY-003 | Verified | 2026-11-10 | No panel-frame or layout shift. |
| BSL-GOOBY-004 | Occasional blink while normal motion is enabled. | Deterministic state XCTest plus 30-second review. | T-GOOBY-004; M-GOOBY-004 | TG2-GOOBY-001, TG2-GOOBY-003, TG2-GOOBY-004, TEST-GOOBY-001, VERIFY-GOOBY-003 | Verified | 2026-11-10 | Intervals remain bounded and nonuniform. |
| BSL-GOOBY-005 | Honor reduced motion. | State-transition XCTest plus live preference-change review. | T-GOOBY-005; M-GOOBY-005 | TG2-GOOBY-001, TG2-GOOBY-003, TG2-GOOBY-004, TEST-GOOBY-001, VERIFY-GOOBY-003 | Verified | 2026-11-10 | Test preference change while visible. |
| BSL-GOOBY-006 | Preserve the other app’s keyboard focus. | Configuration XCTest plus focused-Terminal review. | T-GOOBY-006; M-GOOBY-006 | TG3-GOOBY-001, TG3-GOOBY-002, TG3-GOOBY-003, TEST-GOOBY-002, VERIFY-GOOBY-003 | Verified | 2026-11-10 | Live typing evidence is decisive. |
| BSL-GOOBY-007 | No user-content collection or privileged desktop/terminal permission. | Source/project audit plus clean-profile first launch. | T-GOOBY-007; M-GOOBY-007 | VERIFY-GOOBY-001, VERIFY-GOOBY-003 | Verified | 2026-11-10 | No prohibited APIs or permissions. |
| BSL-GOOBY-008 | Clean native build without character or animation dependency. | Clean build/test and dependency/bundle inspection. | T-GOOBY-008 | TG1-GOOBY-001, TG1-GOOBY-003, VERIFY-GOOBY-001, VERIFY-GOOBY-002 | Verified | 2026-11-10 | Inspect app bundle and project dependencies. |
| BSL-GOOBY-009 | Hover close control quits Gooby without moving focus. | XCTest plus live hover/click/typing review. | T-GOOBY-009; M-GOOBY-009 | TG4A-GOOBY-001, TEST-GOOBY-003, VERIFY-GOOBY-003 | Verified | 2026-11-10 | Amendment 2026-11-10. |
| BSL-GOOBY-010 | At most one Gooby runs. | XCTest plus repeat-launch review. | T-GOOBY-010; M-GOOBY-010 | TG4A-GOOBY-002, TEST-GOOBY-003, VERIFY-GOOBY-003 | Verified | 2026-11-10 | Amendment 2026-11-10. |

## Summary

| Total | Verified | Pending | Failed | Planned Coverage |
|---:|---:|---:|---:|---:|
| 8 | 0 | 8 | 0 | 100% |

## Design Adversarial Remediation Trace

| Finding ID | Remediation Task | Verification Method | Evidence ID | Status | Notes |
|---|---|---|---|---|---|
| F-5A-001 | TASK-GOOBY-REMEDIATE-F-5A-001 | Inspect the clean-build evidence bundle for Xcode version, SDK version, and `MACOSX_DEPLOYMENT_TARGET`. | E-GOOBY-PROVENANCE-001 | Pending | Medium finding accepted for remediation by the user. |

## Revision History

| Version | Date | Author | Changes |
|---|---|---|---|
| 1.0 | 2026-11-10 | Codex with product-owner input | Initial baseline component RVTM. |
| 1.1 | 2026-11-10 | Codex with product-owner input | Task plan approved; verification remains pending implementation. |
| 1.2 | 2026-11-10 | Codex with product-owner input | Added the approved F-5A-001 remediation trace. |

