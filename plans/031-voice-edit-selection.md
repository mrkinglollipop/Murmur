# 031 — Voice-edit the selection ("tell it what to change")

**Status:** APPROVED 2026-10-10 (Matt). Decisions: on by default, hold ⇧ dictates over a selection; edits go to History as "Edit" with the instruction stored. Build after 033 and 032.
**Origin:** 030 peer comparison, gap 1 (Wispr Command Mode, Aqua Edit Mode, Typeless Ask Anything, VoiceInk all ship it).

## Goal

Select text in any app, hold the dictation key, say what to do with it
("make this shorter", "turn this into a bulleted list", "fix the grammar"),
release. The selection is replaced with the result. The spoken words are the
instruction, not dictation.

## What exists

- ⌃⌥⌘T already runs a *fixed* Transform over the selected text
  (`HotkeyController.swift` → `TransformRunner.run`), copying the result to
  the clipboard. The backend-selection and privacy rules (on-device never
  falls back to cloud, 030 R-01) are already there and are reused as is.
- `CaretContext.snapshot` reads the focused field's value and selection
  range at hold start, so "is there a selection" is already known at the
  moment the key goes down.
- `TextInjector` can replace a selection today: injecting over a selection
  replaces it in every host that honours standard editing (this is how
  "dictation overwrote my selection" bug #91 happened; here it is the point).

## Behaviour

1. Hold with a non-empty selection → the HUD shows "Editing selection"
   instead of "Listening", so the user knows the words are an instruction.
2. Release → transcript becomes the instruction; the selected text is the
   input; `TransformRunner` runs instruction-over-text with the user's
   cleanup backend and credentials.
3. Result replaces the selection through the normal inject path (same
   secure-input, app-switch and clipboard-fallback guards as dictation).
4. Undo: the previous text is kept for one step; "undo that" on the next
   hold, or ⌘Z in the host, restores it. Minimum: the host's own ⌘Z works
   because the replacement is a single inject.
5. Ambiguity: if the model returns nothing usable (empty, or the sanity gate
   rejects it), the selection is left untouched and the HUD says "Try
   rephrasing" (Aqua's behaviour). Never type the instruction itself.
6. Opt-out: a Settings toggle "Edit selected text by voice" (default on),
   and a modifier (hold ⇧ with the key) to dictate *over* a selection
   instead of editing it.

## Non-goals

- Multi-step conversations, "stack" edits, screen context beyond the
  selection, selection longer than ~8k characters (refuse with a HUD message).
- Changing which backends exist or how keys are stored.

## Open decisions (yours)

- Default on or off? (Recommendation: on, since a selection + hold is a
  deliberate act; the ⇧ escape hatch covers dictating over a selection.)
- Does the result also go to History? (Recommendation: yes, labelled
  "Edit", with the instruction stored, not the selected text.)

## Verification

- Unit: instruction/selection routing as a pure decision (selection present,
  toggle, ⇧ held, length cap); sanity-gate rejection leaves the selection.
- Product: select text in TextEdit and in a browser field, hold, say "make
  this one sentence", release; then ⌘Z restores. Secure Input field: nothing
  happens and the HUD says why.

## Effort

M–L. Single-session slices: (A) routing + HUD state + Transform call,
(B) replace-selection inject + undo, (C) Settings toggle + History row.
