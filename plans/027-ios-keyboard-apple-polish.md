# 027 — iOS keyboard: Apple chrome polish + multi-iPhone sizing

**Status:** SHIPPED (2026-08-13) — code on `main` via this ship. Visual vs Apple in Messages is **unverified** until a device screenshot. Kill the keyboard once after install. **Supersession:** the bottom-row 😊 opens Murmur’s in-app emoji page (search, 9-column grid, category strip, ABC). It is **not** wired to `handleInputModeList`. The system globe in the keyboard well still switches keyboards.
**Written against:** Murmur-ios working tree 2026-08-13 (uncommitted typing-safety + first chrome pass on `main`).
**Canonical home:** this file. Index row in [`plans/README.md`](README.md).
**Does not authorize:** App Store / TestFlight, iOS 26 compatibility, iPad, Mac targets, Pro/IAP, the backend, space-bar trackpad, key popups that draw above the keyboard’s top edge.

Thread intent (2026-08-13): the keyboard still does not look Apple-y after the wide-spacebar pass. Do **all** of the punch-list batches (QuickType bar + mic relocate, geometry/keycaps, Apple gestures). Add **other iPhone** sizing if it is easy. Relocating the microphone is acceptable. Write this plan, then verify it — **do not implement in the verify-plan turn**.

## 1. Goal

Make Murmur’s QWERTY chrome read as an iOS keyboard that happens to have Murmur dictation and GIF, not a Wispr clone with a coral billboard.

Primary workflow that proves it: in **Messages** on an **iPhone 17 Pro Max** (Matt’s device), switch to Murmur, type `hello how are you`, see Apple-like keys + QuickType, tap the **mic** to start dictation (same bounce path as today’s Start). Screenshot next to Apple’s keyboard in the same thread.

Narrow-width (SE-class, 375pt) is **metrics-only** in tests — not a `KeyboardChromeView` layout test. After Batch A, `MurmurKeyboardTests` **will** assert height, gaps, and space vs mode unit ratios with **width as input** at **375 / 402 / 430** on **iPhone 17 Pro / iOS 27** sim (`KeyboardChromeMetrics` is not in the tree yet). That target does **not** include `KeyboardChromeView`. Key **frames** are visual on device. 375pt **visual** is **unverified** on this host (SE 3rd gen sim is iOS 26.5); 375 metrics still run on the 17 Pro / 27.0 sim.

## 2. Current state (code, 2026-08-13)

Verified by reading these files this session:

| Surface | What exists |
|---|---|
| Height | Fixed `KeyboardChromeTokens.portraitHeight = 296`, `landscapeHeight = 188`. `KeyboardViewController.updateKeyboardHeight()` only flips those two constants on compact vertical size class. |
| Device family | `TARGETED_DEVICE_FAMILY: "1"` (iPhone only) in `ios/project.yml`. Floor **iOS 27.0**. |
| Bottom row | `123` · 😊 (Murmur emoji page: search + 9-col + categories + ABC) · unlabeled space · return (`return.left` or blue Go/Search). Comma/period **not** on the letters row. |
| Accessory | `AccessoryBarView`: GIF text chip · 3 suggestion slots with hairlines · coral **Start** + waveform, 106pt wide. |
| Keys | Flat fill + 1pt drop shadow. Letter fill dark `white 0.42`. Pressed state lightens fill. No popup. |
| Globe | System globe lives in the keyboard well, not Murmur’s bottom row. Smiley is **not** `handleInputModeList`. |
| 123 | Tap toggles `page` letters ↔ numbers. No slide-to-type. |
| Long-press | Only keys with `longPressInsert` (comma/period/apostrophe on 123/symbols third row). No vowel diacritics. |
| Swipe | In the build, **default off**. Space-bar trackpad **removed** (wipe vector). Do not revive. |
| Dictation | `root.onMic` → `toggleRecord()` → bounce to Murmur app. Listening overlay unchanged. |

## 3. Non-goals

- iOS 26 / wife’s current OS. Floor stays **27.0**. Sideload to her phone is a later ops note, not this plan.
- iPad (`TARGETED_DEVICE_FAMILY` stays `"1"`).
- Space-bar trackpad.
- Magnify callouts that draw **above** the keyboard window (Apple forbids this for extensions). Top-row (qwerty) popups that would overflow the top edge are skipped; rows 2–4 may popup **inside** the keyboard bounds.
- Changing dictation bounce, Full Access, ElevenLabs, GIF tray existence, swipe algorithm, or autocorrect policy.
- App Store / TestFlight.

## 4. “Other iPhones” — what “easy” means

**In scope:** portrait/landscape height and key metrics that **scale with keyboard width** so SE (375), standard (390–402), and Max (430) do not share one 296pt Pro Max slab.

**How (easy):** the key grid is already unit-based (`layoutKeys` divides `grid.bounds.width`). The bug is the **fixed input-view height** and **fixed gaps**. Replace constants with a pure `KeyboardChromeMetrics` value type:

```text
input: width, isLandscape
output: keyboardHeight, accessoryHeight, sideInset, rowGap, keyGap,
        letterFont, specialFont, bottomInset, spaceUnits, modeUnits, returnUnits
```

Width buckets (portrait, points):

| Bucket | Width | Portrait keyboard height (incl. accessory) |
|---|---|---|
| compact | `< 390` | 271 |
| regular | `390 ..< 430` | 302 |
| max | `≥ 430` | 340 |

Landscape buckets (starting guesses — **unverified** until a screenshot; same width cuts as portrait):

| Bucket | Width | Landscape keyboard height (incl. accessory) |
|---|---|---|
| compact | `< 390` | 162 |
| regular | `390 ..< 430` | 176 |
| max | `≥ 430` | 188 |

After Batch A, `MurmurKeyboardTests` **will** assert these portrait and landscape heights (and gap / space-unit ratios) at 375 / 402 / 430 (`KeyboardChromeMetrics` / `KeyboardChromeMetricsTests` are not in the tree yet). Landscape values are **unverified starting guesses**; the metrics-test row still locks the numbers so they cannot drift silently. Tune from screenshot, not by adding a fourth bucket.

**Verify without owning every phone:** After Batch A, `MurmurKeyboardTests` **will** instantiate **`KeyboardChromeMetrics` only** — do **not** add `KeyboardChromeView` to that target (manual file list; Giphy tray, swipe, listening overlay). Pass widths **375 / 402 / 430** (portrait and landscape) on **iPhone 17 Pro / iOS 27** sim; **will** assert `keyboardHeight`, gaps, and space vs mode unit ratios. Key **frames**, overlap, and accessory mic/GIF on-screen are **visual on device** (Pro Max). 375pt visual remains **unverified** on this host (SE 3rd gen sim is iOS 26.5).

**Out of scope for “easy”:** iOS 26 `#available` chrome, iPad split keyboard, Mac Catalyst.

## 5. Batches (implementation order)

Do in this order. Each batch is separately screenshot-able. Do not mix C into A.

### B — QuickType bar + mic relocate (first)

Files: `ios/Keyboard/AccessoryBarView.swift`, `ios/Keyboard/KeyboardChromeView.swift` (wiring only if needed), `ios/Keyboard/KeyboardViewController.swift` (keep `onMic` → `toggleRecord()`).

- Left: compact **GIF** control. SF Symbol `gift` is wrong; use `square.stack` or the existing "GIF" letters at 12pt, **no chip fill** unless the tray is open.
- Center: three suggestions, equal width, hairline separators, SF 17 regular. Highlight **only** the middle slot when it is a correction (non-empty and ≠ left slot), not a pill on every slot.
- Right: **mic** button ~36×36, SF `mic.fill`, coral tint. Accessibility label stays **Start dictation**. Identifier `murmur.keyboard.start` stays so nothing else breaks.
- Remove the 106pt coral "Start" + waveform pill.
- Listening / error / waiting chrome stays the full-keyboard overlay. Mic on the bar still calls `onMic`.
- Caption (status text) still replaces suggestions when set.

Acceptance: Messages screenshot shows a QuickType-like bar; tapping mic still opens Murmur dictation (same bounce). GIF still opens the tray.

### A — Geometry + keycaps + emoji/globe (second)

Files: `ios/Shared/KeyboardChromeTokens.swift` (or new `KeyboardChromeMetrics.swift` in Shared + KeyboardTests), `ios/Keyboard/KeyboardChromeView.swift`, `ios/Keyboard/KeyboardViewController.swift` (`updateKeyboardHeight` uses metrics for current width).

- Drive height/gaps/fonts from `KeyboardChromeMetrics` (section 4).
- Side inset ~3–4pt on max, slightly more on compact so keys are not edge-clipped.
- Letter caps: brighter dark fill (~0.48–0.52 white), specials darker. **Bottom lip** (1pt darker rect or a second shadow path), not a blurry drop shadow.
- SF letters: 22 compact / 24 regular / 25 max, weight regular. Special glyphs 15–17, medium.
- ASDF inset: increase A-row spacers so A sits in the Q–W gutter (optical Apple alignment). Shift/delete ~1.5–1.75 letter-widths.
- Bottom row: `123` · **😊** · space · return. The smiley opens Murmur’s **in-app emoji page** (search, 9-col grid, categories, ABC back to letters). Do **not** wire that key to `handleInputModeList`. The system globe in the keyboard well still switches keyboards. Emoji is always on the bottom row (not gated on `needsInputModeSwitchKey`).
- Return: keep `return.left` for `.default`; blue prominent for go/search/send/continue.
- Pressed letter: lighten fill; **no** `CGAffineTransform` shrink.

Acceptance: overlay-compare screenshot vs Apple on Pro Max (spacebar width, 123 size, row rhythm). `MurmurKeyboardTests` **metrics** asserts pass at 375 / 402 / 430 (portrait + landscape) on iPhone 17 Pro / iOS 27 — **not** `KeyboardChromeView` layout tests. After A lands, **re-screenshot the QuickType/mic bar in Messages**; Batch B’s shot at 296pt is stale once height changes.

### C — Gestures Apple has (third)

Files: `ios/Keyboard/KeyboardChromeView.swift` (and a small helper if the popup/diacritic overlay deserves its own type in the same file or `KeyPreviewView.swift`).

**C1 — 123 slide-to-type**
- Short tap 123: still switch to numbers page (today).
- Press-and-drag from 123 onto a numbers-page key: temporarily show numbers, highlight the key under the finger, on release insert that character and **return to letters**. If the finger never leaves 123, treat as a normal tap.
- Disable letter-swipe while this drag is active.
- Same pattern for `#+=` while already on numbers? **No** — only 123 from letters. YAGNI.

**C2 — In-bounds key popup**
- On touch-down of a letter key in rows 1–2 (asdf / zxcv) and digits on the numbers page, show a popup **above** the key, clipped to the keyboard bounds.
- Row 0 (qwerty): **no** popup that would cross the top edge; pressed fill only.
- Popup dies on touch-up / cancel. Reduce-motion: skip popup.

**C3 — Long-press diacritics**
- Vowels `a e i o u` plus `n c s y z` (Apple-ish Latin set). Long-press (≥0.4s) shows a horizontal strip of alternates; slide to select; release inserts.
- Must not fire if a swipe has already begun.
- Apostrophe/comma/period long-press on the **123 page** stays as today.

Acceptance: unit-test the diacritic map (input letter → alternatives). Slide-to-type and popups are device/sim visual; document “unverified on SE hardware” if only Pro Max is installed.

## 6. Files

| File | Role |
|---|---|
| `ios/Shared/KeyboardChromeMetrics.swift` | Pure metrics from width + landscape. Testable without the appex. |
| `ios/Shared/KeyboardChromeTokens.swift` | Colors, corner radius, lip color. Height constants become wrappers around metrics or die. |
| `ios/Keyboard/AccessoryBarView.swift` | Batch B layout. |
| `ios/Keyboard/KeyboardChromeView.swift` | Bottom row, key drawing, 123 slide, popups, diacritics, emoji key. Popup/diacritic overlay may stay in this file. |
| `ios/Keyboard/KeyPreviewView.swift` | **Optional.** Same-file-or-new: popup/diacritic overlay may live in `KeyboardChromeView.swift` **or** this new type. Not required as a separate file. |
| `ios/Keyboard/KeyboardViewController.swift` | Height from metrics. Bottom-row 😊 is Murmur’s emoji page, not `handleInputModeListFromView:withEvent:`. System globe stays in the well. |
| `ios/KeyboardTests/KeyboardChromeMetricsTests.swift` | Bucket heights and space-unit math. Add this file **and** `Shared/KeyboardChromeMetrics.swift` to the `MurmurKeyboardTests` source list in `ios/project.yml` (that target is a **manual file list**, not a folder glob — chrome views are not in it). |
| `ios/project.yml` | Append the new metrics source + test file to `MurmurKeyboardTests`. Do not add `KeyboardChromeView.swift` to the test target (Giphy tray, swipe, listening overlay). |
| `ios/README.md` | One paragraph: Apple-like chrome, mic on QuickType, iPhone width buckets, iOS 27 floor. |

No new SPM. No iPad family.

## 7. Verification

| Check | Oracle |
|---|---|
| Metrics buckets | `xcodebuild test` scheme `MurmurKeyboardTests`, iPhone 17 Pro / iOS 27 sim. Assert portrait **and** landscape heights (271/302/340 and 162/176/188) plus gaps / space-unit ratios at widths 375 / 402 / 430. Do **not** add `KeyboardChromeView` to this target. |
| Metrics at 375/402/430 | **Not** `KeyboardChromeView` in unit tests (appex chrome is not in `MurmurKeyboardTests`). **Will** assert **metrics** (height, gaps, space vs mode unit ratios) at those widths. Frame overlap on device/sim is visual. |
| C3 diacritic map | `MurmurKeyboardTests`: unit-test input letter → alternatives (vowels `a e i o u` plus `n c s y z`). Slide-to-select and popup visuals stay device/sim. |
| Autocorrect/swipe tests still green | same; do not regress typing-safety tests |
| Device build | `xcodebuild` MurmurIOS → Matt’s iPhone 17 Pro Max; `devicectl device install app` |
| Visual Pro Max | Matt screenshot vs Apple in Messages (dark). Agent cannot see the appex until that shot. |
| Visual narrow (375pt) | **Unverified** on this host: SE 3rd gen sim is iOS **26.5**. 375 **metrics** run on **iPhone 17 Pro / iOS 27.0** sim with width as input. Device screenshot only if a 375pt device is present. |
| Post-A QuickType reshot | After Batch A height change, **re-screenshot** the QuickType/mic bar in Messages. Batch B’s 296pt shot is stale. |
| `ios/README.md` chrome paragraph | Same PR as implementation: one paragraph matching §6 (Apple-like chrome, mic on QuickType, iPhone width buckets, iOS 27 floor). |
| Mic still dictates | Device: tap mic → Murmur bounce (same as Start today) |
| GIF still opens | Device tap |

Oracle cap: same `xcodebuild test` / device build as today. Keyboard appex visual is **unverified** until a screenshot. Do not claim “looks like Apple” from a green compile.

After install: kill Murmur keyboard once (switch away, switch back).

## 8. Sequencing vs 026

Plan **026** remains the dictation/swipe/GIF upgrade (PARTIAL). **027 wins for look.** This plan **replaces** 026’s accessory CTA and key chrome — leftover 026 Start/waveform and `UIGlassEffect`-on-keys lines are **not remaining work**.

- **Accessory CTA:** Batch B mic (~36×36 `mic.fill`, coral), **not** 026’s 106pt coral Start + waveform pill. Do not implement leftover 026 Start/waveform accessory AC.
- **Key look:** Batch A brighter letter caps (~0.48–0.52 white) + **1pt bottom lip**. Do **not** treat remaining 026 `UIGlassEffect`-on-keys (P0-chrome glass spike / “glass or restyle fills”) as remaining work.

**Cancelled (do not implement):** 026 P0 space-bar trackpad, including the P0 acceptance that space-drag moves the caret.

**026 still owns (not superseded):** P0-host, GIF tray, swipe (default **off**), dictation bounce, P1 autocorrect, P3 ship-gate. Swipe default stays **off**. Space-bar trackpad stays **gone**.

## 9. Risks

| Risk | Mitigation |
|---|---|
| Mic harder to find than “Start” | Keep accessibility name; coral tint; 36pt hit target |
| `handleInputModeList` on the smiley | **Superseded.** Bottom-row 😊 opens the in-app emoji page. System globe in the well switches keyboards. Do not wire `handleInputModeList` to the smiley. |
| 123 slide fights swipe | Exclude mode key from `LetterSwipeRecognizer`; cancel swipe when slide-to-type begins |
| Popup clipped ugly on row 1 | Skip popup on row 0 rather than drawing above the keyboard |
| Height 312 too tall on some hosts | Device shots 2026-08-13: Apple pane **339pt**; Murmur at 340 rendered **422pt** because the ~80pt globe/mic well was inside our view *and* in the system chrome. Max input height is **260** (accessory + 43pt keys). Visual still screenshot-gated. |

## 10. Approval

Implementation starts only after Matt says **`approved — build`** (or equivalent). Verify-plan green is not that approval.
