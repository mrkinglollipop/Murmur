# Murmur iOS keyboard

Separate XcodeGen project. Do not add these targets to the Mac `project.yml`.

```bash
# from repo root
[ -f Config/Team.xcconfig ] || cp Config/Team.xcconfig.example Config/Team.xcconfig
cd ios
xcodegen generate
# Compile gate (verified 2026-08-11): generic iPhoneOS, unsigned
xcodebuild -project MurmurIOS.xcodeproj -scheme MurmurIOS \
  -destination 'generic/platform=iOS' -configuration Debug \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

**Signing (2026-08-11):** App IDs `com.matt.murmur.ios` + `com.matt.murmur.ios.keyboard` are registered on team `XGLHMG3629`. Manual profiles: `Murmur iOS Development` / `Murmur Keyboard Development`.

**Signed compile (verified 2026-08-11):** App Group `group.com.matt.murmur.ios` is on both App IDs; profiles regenerated. `xcodegen` + signed `xcodebuild` **BUILD SUCCEEDED**.

```bash
cd ios
xcodegen generate
xcodebuild -project MurmurIOS.xcodeproj -scheme MurmurIOS \
  -destination 'generic/platform=iOS' -configuration Debug \
  DEVELOPMENT_TEAM=XGLHMG3629 -derivedDataPath build build

# Autocorrect unit tests (iOS 27 simulator)
xcodebuild test -project MurmurIOS.xcodeproj -scheme MurmurKeyboardTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0' \
  CODE_SIGNING_ALLOWED=NO
```

Keyboard mic opens Murmur (`extensionContext.open`) so the host can record.
If this take’s host ID is known (Messages usually), Murmur bounces back
automatically. Otherwise it stays on the swipe interstitial — swipe right
across the **bottom edge**, then speak. Tap the keyboard mic again to send.
Do not dictate inside Murmur.

Typing uses `UITextChecker` plus a bundled frequency list. `teh` + space
becomes `the`; the original stays in the candidate bar as undo. Autocorrect
runs with Full Access off. It does not run in secure fields, and the first
space after a dictation insert does not respell the transcript.

Chrome is Apple-like QWERTY (QuickType bar, coral mic instead of a Start
pill, width-bucket heights for compact / regular / Max iPhones). Floor is
iOS 27.0; iPhone only. Visual vs stock Apple is device-screenshot gated.

GIF tray (Full Access + Giphy key in Murmur Settings): trending/search via
Giphy REST, not the iOS SDK. Search grows the input view so results sit
above full-size keys (not a compressed key strip). Tap inserts the GIF URL
(`insertText`). A pasteboard GIF copy is attempted for Messages; that
bubble path is a spike.

The containing app is a Wispr-style shell (Home, Dictionary, Snippets, Style,
Scratchpad, Settings). Dictionary terms go to Scribe as `keyterms` and are
applied again after STT. Snippets expand after Style. Style is local caps /
punctuation (not an LLM). `no_verbatim` strips fillers. Action Button is the
App Shortcut “Start Dictation” (clipboard on stop). Host-return interstitial
still covers the app during a gated keyboard take. Settings → Return apps is
a 4-column grid: add any installed app, drag to rearrange, minus to remove.

> Distribution note: the keyboard launch/return handoff currently relies on responder-chain and private system APIs. This build is for private sideload testing and is not App Store-ready.

Install needs the iPhone unlocked and trusted.

## Shipped (PR #35)

Private sideload spike is on GitHub `main`. Batch STT is ElevenLabs
(`scribe_v2`) via 16-bit / 16 kHz mono WAV. The original “record inside the
appex / host never backgrounds” P0 is **not** what shipped — do not silently
revert the bounce path without an explicit new decision.

Linux cloud agents cannot compile, sign, or device-test this. Do not install a
Swift toolchain or fake a build; use a Mac with Xcode.

## Continued work

This README is the in-repo worksheet. Next slice is whatever the continuing
thread asks for. Out of scope until explicitly pulled in: Pro/subscription,
Murmur-server, IAP, local Whisper on iOS, Mac target changes, App
Store submit. Swipe-to-type is in this build (`SwipeTypingEngine`, Settings
toggle, default off). It is still ship-gated pending a device bake-off — not
absent from the keyboard.
