# Gooby visual MVP — application guardrails

Status: approved

## Scope

Build a native macOS visual prototype of Gooby: a small, separate floating
character window. This milestone proves the character's presence and motion;
it does not yet read Claude Code or Codex conversations or insert text into a
terminal. Amendment 2026-11-10: Gooby follows the front macOS Terminal window
using window position only (no titles, pixels or permissions); see
`specs/gooby-follow/requirements.md`.

## Product boundaries

- Gooby is a code-drawn character, not a raster image asset.
- The app must not request Accessibility, Automation, screen-recording, or
  terminal permissions in this milestone.
  > **Amendment 2026-11-11 (product owner, several Terminal windows):** Gooby may
  > request macOS **Automation permission for Terminal only**, used solely to ask
  > which window/tab owns a chat's tty (`tty of tabs`, `selected tab of front
  > window`) so a skill offer appears beside the right window. It never reads
  > tab contents or sends keystrokes. If permission is denied, Gooby keeps
  > working and labels the offer with the chat instead. Accessibility and
  > screen-recording remain prohibited.
- The character window must not take keyboard focus away from another app.
- No prompt, terminal, or user-content data is collected or stored.
  > **Amendment 2026-11-11 (product owner, skill coach):** when the user installs
  > the opt-in Claude Code hook (`scripts/install-hook.sh`), Gooby reads submitted
  > Claude Code prompts from a local inbox, deletes each file after reading, keeps
  > up to 8 example prompts per repeated request (max 300 characters each) in
  > `~/Library/Application Support/Gooby/intents.json`, and sends prompts to Claude
  > via the user's own `claude -p` to group them. Without the hook, nothing changes.
  > Gooby may show a small speech bubble (text + Yes/No) offering a
  > `/gooby-<name>` skill; clicking it must not take keyboard focus. See
  > `specs/gooby-skill-coach/requirements.md`.
  > Amendment 2026-11-11 (product owner, context-aware offers): the hook also
  > captures Claude Code's Stop event, and Gooby stores, per kept example, the
  > session log path, the folder, and a capped trace of what Claude did (tool
  > calls incl. command text and file paths, end of its final reply). Gooby reads
  > installed skill and command files (names and descriptions) to avoid duplicates.
- Amendment 2026-11-10 (product owner): the only interaction control is a tiny
  close circle that appears on hover and quits Gooby. Clicking Gooby or the
  circle must still leave keyboard focus in the other app. Only one Gooby may
  run at a time.

## Visual direction

> **Superseded 2026-11-10 (character v2, product owner):** Gooby now follows the
> product owner's 3D reference image: a puffy, soft-shaded light-blue rounded
> body, small glossy black dot eyes, a flat face (no cheeks), a shallow curled smile,
> thin stick arms, and sitting stick legs, with a soft ground shadow. Gradients,
> a mouth and a shadow are now allowed; cheeks are not. Still required: fully
> code-drawn (no raster character asset), no text or badges, one character only.
> The original v1 direction below is kept for history.


- Form: one friendly, soft-cornered square with a restrained dark outline.
- Body: a calm, light blue solid color; no gradients or decorative UI chrome.
- Face: two white eyes with black pupils.
- Prohibited facial detail: blush, cheeks, mouth, text labels, or status
  badges.
- The character is the sole focal point. Do not surround it with cards,
  dashboards, onboarding copy, or ornamental effects.

## Motion and accessibility

- The square gently oscillates vertically at rest with an unhurried,
  continuous motion.
- It blinks at irregular, natural-looking intervals while otherwise remaining
  calm.
- When the operating system requests reduced motion, disable automatic bobbing
  and blinking while keeping the character visible and expressive.
- Motion must not cause layout shifts or steal interaction from another app.

## Technology and quality guardrails

- Use a native macOS SwiftUI/AppKit implementation.
- Keep the character implementation small and self-contained so later terminal
  tracking and CLI adapters can be added without replacing the visual layer.
- Use semantic, maintainable names; avoid external animation or image
  dependencies for this milestone.
- Verify a clean build and manually verify normal-motion and reduced-motion
  behavior before handoff.

## Acceptance boundary for this milestone

The milestone is complete when a user can launch the macOS app and see a cute
blue square Gooby with white eyes and black pupils, smoothly bobbing and
occasionally blinking, with an accessible reduced-motion fallback.
