# Gooby skill coach — requirements (v0, deliberately simple)

Status: approved by product owner 2026-11-11 ("doesn't have to be pretty, just work")

## Goal

When the user asks Claude Code for the same thing in 5 different sessions, even
in different words ("commit and push to my repo" / "commit and push" / "commit
all changes and push"), Gooby offers to turn it into a `/gooby-<name>` skill.

## Requirements

1. **Capture.** An opt-in `UserPromptSubmit` hook (`hooks/gooby-capture-prompt.sh`,
   installed by `scripts/install-hook.sh`) writes each prompt's hook JSON to
   `~/Library/Application Support/Gooby/inbox/`. It prints nothing, always exits 0,
   and skips prompts from Gooby's own Claude calls (`GOOBY_INTERNAL=1`).
2. **Conversation context.** Gooby reads the hook's `transcript_path` (last
   512 KB only) and takes Claude's last main-chat text message written before
   the prompt (last 1500 characters). So "yes go ahead" after "Want me to commit
   and push?" counts as a commit-and-push request. No transcript or no match
   = no context (format is undocumented; failures are silent).
3. **Local filter.** Prompts starting with `/` or `!` are dropped. Dropped prompts never call Claude.
   Revised 2026-11-11 (cheaper short replies):
   - Pure thanks, praise, or no ("thanks", "perfect", "cool, works great", "no, not now"): dropped.
   - Short approvals (≤ 6 words, all agreeing words, e.g. "yes", "sure, go ahead", "ok cool"):
     classified only if Claude's message right before offered or asked something (a `?` or an
     offer phrase such as "want me to", "should I", "if you want" in its last 400 characters).
   - Everything else: classified when ≥ 6 characters, or when there is context (as before).
   Offline estimate on the product owner's 543 logged prompts: Claude calls 536 → 528 (8 saved,
   1.5%); the skipped replies were "proceed", "continue", "go", "confirm", "approve" after
   messages that asked nothing.
4. **Classify.** Every other prompt goes to `claude -p --model opus` (tools off,
   no saved session) with the context and all tracked intents (3 examples each).
   Claude answers `ignore`, `match` (known id + confidence), or `new` (slug +
   summary), plus `request`: the task restated in full. The restated request
   (not "yes") is what gets saved as the example.
   Matches below 0.75 confidence don't count. Unparseable replies count as `ignore`.
5. **Count.** An intent is offered once it has sightings from **5 distinct
   session ids** (raised from 3 by the product owner, 2026-11-11). Repeats inside
   one session count once. Session ids are stored apart from the 8 kept example
   prompts, so many repeats in one chat never push older sessions out of the count.
6. **Context-aware offers** (product owner, 2026-11-11). Skills are always global
   (`~/.claude/skills/gooby-<slug>/`, usable in every project).
   - **Right moment.** The hook also captures Claude Code's `Stop` event (Claude
     finished replying). An offer appears only on a `Stop` in the same session
     where the intent was just asked for, within 30 minutes of that ask. A `Stop`
     in another session never triggers it. Unanswered bubbles close after 120 s;
     that is not a No, and the offer returns at the next repeat.
   - **From what Claude did.** Each sighting stores the session log path and a
     trace of what Claude did (tool calls, ≤ 30 steps; end of its final reply,
     ≤ 400 characters; ≤ 2,500 characters total), captured when that turn ends.
     Traces are taken early because logs are deleted after about 30 days.
     Traces missing after 7 days are given up. The skill draft is based on
     those steps, generalized for use in any project.
   - **Not already covered.** Before offering, Gooby lists installed skills and
     commands (`~/.claude/skills`, `~/.claude/commands`, plugin skills and
     commands, and each sighting folder's `.claude/skills` and
     `.claude/commands`; ≤ 400 entries) and asks Claude once whether one already
     does the task. Covered: marked `covered`, never offered. Unreadable answer:
     no offer now, asked again at the next repeat.
   A speech bubble above Gooby shows the summary, `/gooby-<slug>`, "No thanks" /
   "Make it". One bubble at a time; hidden while Gooby is hidden.
7. **No** marks the intent declined forever. **Yes** asks Claude to draft
   `~/.claude/skills/gooby-<slug>/SKILL.md` (falls back to a template that lists
   the captured steps), never overwrites (uses `-2`, `-3`, …), and marks it created.
8. Declined and created intents still absorb future matches, so they never
   come back as duplicates.

9. **Several Terminal windows** (product owner, 2026-11-11). The hook records the
   chat's tty (first parent process with a terminal, e.g. `ttys002`). A due offer
   waits (up to the 30-minute window) until that tty is the selected tab of
   Terminal's front window, checked every 2 s via `osascript` (Automation
   permission for Terminal). It shows right away, labeled `<folder> · <chat title>`,
   when the tab can't be found (tmux, VS Code, closed tab) or Terminal can't be
   asked (permission denied, error, Terminal not running). An offer that waits
   past the window is dropped quietly (not a No) and returns at the next repeat.
10. **Traces when logs are gone** (product owner, 2026-11-11). On Stop the hook
    also saves the last 512 KB of the session log next to the event; Gooby
    reads traces from that copy when the real log is gone, then deletes it.
    Unclaimed copies are deleted after 24 hours. Sightings still missing a trace
    are retried at launch and every 10 minutes. Log retention stays at Claude
    Code's default (30 days).

11. **Retry when Claude fails** (product owner, 2026-11-11). If the Claude call fails
    (offline, login expired, timeout, `claude` missing), the prompt and its context go into
    `~/Library/Application Support/Gooby/retry.json` and are retried after 1 min, 5 min, and
    30 min; a 4th failure drops it. At most 50 waiting prompts, none older than 24 h. After a
    failure, new prompts are queued without calling Claude until the next retry time, so a broken
    Claude never costs a full timeout per prompt. A late retry keeps its original ask time and
    never replaces a newer ask in the same chat (offer timing).

12. **What counts as a task** (from the 2026-11-12 evaluation). A reusable task is
    something the assistant does: a repeatable series of steps that changes, runs,
    or verifies something. Questions that only want an answer (explanations,
    interpreting a message or screenshot, opinions, simple lookups like "give me
    the link to the MR") are ignored even when asked often.
13. **Context sent to Claude** (from the 2026-11-12 evaluation): Claude's previous
    reply, not the chat title. The title is used only to label offers.

## Evaluation (2026-11-12)

Offline replay of 2,706 real prompts (10 most recent `~/Gitlab/` projects, 328
sessions) through Gooby's own classifier, 4 context setups × 3 runs, Opus.
Scripts in `eval/`; data stays in `~/Library/Application Support/Gooby/eval/`.

| Setup | Truly-same pairs caught | Wrong "same" | Offers/run (at 5) | 3 runs agree |
|---|---|---|---|---|
| prompt only | 1 of 2 | 0 | 26–32 | 239/240 |
| + previous reply (chosen) | 2 of 2 | 0 | 34–39 | 232/240 |
| + chat title | 1 of 2 | 0 | 28–33 | 230/240 |
| + both | 2 of 2 | 0 | 32–37 | 231/240 |

- Of 24 pairs labeled "same" from Claude's actions, only 2 were truly the same
  task (19 shared nothing but `glab api`), so recall needs human labels
  (`eval/label.py`).
- The previous reply caught a pair only context could explain ("it is merged" /
  "track to green" = watch the deploy). The title added nothing.
- Median call 16.43–16.58 s for every setup.
- Several offers were questions, not procedures (e.g. `explain-unfamiliar-tool`,
  `interpret-coworker-message`, `get-merge-request-link`), which led to rule 12.
- Rule 12 re-check (`eval/offer_check.py`): the 443 prompts behind the 34 offers
  of the chosen setup, re-asked one at a time with the new rule. **25 offers
  kept, 9 dropped.** Dropped: `get-merge-request-link` (21 of 21 prompts now
  ignored), `explain-tool-or-term` (15 of 15), `interpret-coworker-message`,
  `explain-expected-ui-behavior`, `mvp-generation-cli-command`,
  `get-feature-deployment-url`, `command-to-try-change`, `find-worktree-for-mr`,
  `draft-brief-comment-reply`. Kept workflows lost almost nothing (e.g.
  `push-to-remote` 28 of 28, `comment-on-merge-request` 20 of 20). Limits: each
  prompt was judged with no known intents, and only offered intents were checked.

## Known limits (accepted for v0)

- Claude Code only (no Codex, no plain shell commands).
- Each classified prompt costs one Opus call (switched from Haiku 2026-11-11 by
  product owner for accuracy). Live test: 6 Opus calls in about 66.6 s (whole
  96-test run took 66.646 s) vs 6 Haiku calls in 66.437 s. Opus costs more per call. Short approvals
  ("yes", "ok") cost a call only when Claude's message before them offered or asked something.
- Saying yes to an action Claude offered counts the same as asking for it.
- If Claude keeps failing for about 36 minutes (4 tries), that prompt is dropped.
- All tracked intents are sent each call; fine up to the 200-intent cap.
- Prompts are kept only for intents (≤ 8 each, ≤ 300 chars); inbox files are
  deleted as soon as they are read. Traces (commands Claude ran, file paths)
  are stored alongside those examples.
- Requests made before Gooby was installed are never seen, so they add no
  sightings or traces (importing history would need a Claude call per prompt).
- If one turn writes more than 512 KB of log after the prompt, the log copy
  no longer holds that prompt and its trace comes only from the real log.
- Offers depend on the Stop hook. Re-run `scripts/install-hook.sh` after
  updating; an older install (prompt hook only) never offers.
