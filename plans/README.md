# Engineering notes (`plans/`)

This folder holds **historical engineering notes** from internal audits and
implementation passes. It is **not** a product roadmap and is not required
reading for contributors.

Status values below are best-effort snapshots. Prefer [`README.md`](../README.md),
[`CONTRIBUTING.md`](../CONTRIBUTING.md), and [`CLAUDE.md`](../CLAUDE.md) for
current setup and contribution guidance.

## Index

| Plan | Title | Status |
|------|-------|--------|
| 001 | Secure-input boundary | DONE |
| 002 | Fixture-driven stitch replay harness | TODO |
| 003 | CLAUDE.md for agent sessions | DONE |
| 004 | Small-fixes bundle (races, logs, cleanup) | DONE |
| 005 | Docs & deps batch | TODO |
| 006 | Spike: WPM + latency insights | PARTIAL |
| 007 | Spike: retry-from-history with engine picker | PARTIAL |
| 008 | Spike: per-app Snippets / Dictionary / Transforms | TODO |
| 009 | Spike: export / import settings bundle | TODO |
| 010 | Cloud batch WAV transcode | TODO |
| 011 | AssemblyAI `speech_model` param | DEFERRED (engine retired from UI) |
| 012 | ElevenLabs Scribe v2 Realtime | DONE |
| 013 | Retire unused selectable ASR engines | DONE |
| 014 | Scribe RT: `no_verbatim` + dictionary `keyterms` | DONE |
| 015 | Sparkle auto-update | DONE |
| 016 | Secure-input mid-hold | DONE |
| 017 | Streaming race + Parakeet sidecar bounds | DONE |
| 018 | Disk I/O off the dictation hot path | DONE |
| 019 | Docs truth-up | DONE |
| 020 | Polish bundle | DONE |
| 021 | FluidVoice-inspired scope | DRAFT |
| 022 | Speaker-gating spike report | DONE (spike) |
| 023 | Open-source readiness | SHIPPED (Phases 1–5) |
| 024 | Repo audit findings | archival (fix pass 1 landed) |
| 025 | Murmur Pro scope | approved direction; not started |
| 026 | iOS keyboard: Wispr-parity chrome + swipe/autocorrect/GIPHY (swipe bake-off gated) | PARTIAL — P0–P2 in tree; swipe is in the build (Settings toggle, default off), still bake-off gated; P2b Messages bubble is a device spike; **027 wins for look** (mic not Start/waveform; brighter caps + 1pt lip, not leftover UIGlassEffect-on-keys); **P0 space-bar trackpad cancelled by 027** |
| 027 | iOS keyboard: Apple chrome polish + multi-iPhone sizing | SHIPPED (2026-08-13) — visual vs Apple unverified until Messages screenshot; **wins for look** vs 026 (mic not Start/waveform; brighter caps + 1pt lip); **cancels 026 P0 space-bar trackpad**; 026 still owns P0-host / GIF / swipe / dictation bounce |

## Notes for maintainers

- Individual plan files may use informal “operator / executor” language from
  agent-assisted sessions. Treat them as archival context, not public product copy.
- Do not commit secrets, team IDs, or machine-local paths into new plan text.
- Open-source cut rationale lives in [`023-open-source-readiness.md`](023-open-source-readiness.md).

---

# 026 — iOS keyboard: Wispr-parity chrome + swipe/autocorrect/GIPHY (swipe ship-gated)

**Status:** PARTIAL — P0-host, P0-chrome, P1 autocorrect, P2 Giphy REST tray, and swipe-to-type are in the tree. P2b Messages GIF bubble is a device spike. Swipe is bake-off gated (not missing).
**Written against:** `cf13857` (`main`, 2026-08-12).
**Canonical home:** this section in `plans/README.md` until split to `plans/026-ios-keyboard-upgrade.md`.
**Does not authorize App Store submit, Mac target changes, Pro/IAP, or Murmur-server.**

**027 wins for look (and cancels trackpad):** Plan [027](027-ios-keyboard-apple-polish.md) **replaces** this plan’s accessory CTA and key chrome. Implement **027**: mic on the QuickType bar (**not** the 106pt Start/waveform pill); brighter caps + **1pt lip** (**not** leftover `UIGlassEffect`-on-keys as remaining P0-chrome work). 027 also **cancels 026 P0 space-bar trackpad** and the **P0 acceptance “space-drag moves caret.”** Do not implement or revive that pan.

**026 still owns:** P0-host, GIF, swipe (default **off**), dictation bounce, P1 autocorrect, P3 ship-gate. Those stay as written here.

This plan **explicitly pulls in** `ios/README.md` “Continued work” items that were out of scope until asked: **full QWERTY as a real typing keyboard** (keys already insert; this upgrade makes them competitive), plus swipe, autocorrect, and GIPHY. Dictation bounce architecture stays, but **must return to the originating host app** (Matt, 2026-08-12: today it always dumps you in Messages). **Floor is iOS 27** — Liquid Glass with no iOS 26 compatibility path.

## 1. Goal

Ship a **dictation-first iOS keyboard that is also a beautiful daily driver**: Wispr Flow parity on the chrome **we will match** (§3; not magnify callouts, not a hamburger drawer), then **three features Wispr’s keyboard docs do not ship** — swipe-to-type, autocorrect with a candidate bar, and a GIPHY tray launched from a dedicated button on the **existing top accessory row** (left of the **027 mic**; not leftover Start/waveform).

Primary workflow that proves the product: in **Notes** (not Messages), switch to Murmur, type, tap Start, and **not get kidnapped into Messages**. Best case: bounce back to Notes. Honest degrade: stay in Murmur and swipe back; transcript still inserts in Notes. Then GIF + swipe as the rest of the upgrade.

## 2. Current state (code, 2026-08-12)

Verified by reading `ios/Keyboard/` this session. Do **not** trust the memory topic `murmur-ios-keyboard.md` for architecture — it still describes an in-appex `AVAudioEngine` path and “no `extensionContext.open`.” Shipped code is the opposite (PR #35 bounce path). `ios/README.md` is the worksheet SSOT.

| Surface | What exists |
|---|---|
| Entry | `KeyboardViewController` (`UIInputViewController`), height **296pt** (`KeyboardChromeTokens.portraitHeight`) |
| Chrome | `KeyboardChromeView` — UIKit only, “Wispr-shaped QWERTY” |
| Top bar | 48pt: `statusLabel` + **Start** (waveform) on the right. `menuButton` exists but is **hidden, disabled, `frame = .zero`** |
| Keys | Real `textDocumentProxy.insertText` / `deleteBackward`. Letters / 123 / #+= . Shift once/locked. Space labeled **“Murmur”**. Return title from `returnKeyType` |
| Already shipped typing niceties | Sentence/word/all-caps from `autocapitalizationType`; double-space → `. `; input clicks; candidate bar; `UITextChecker` |
| Swipe | In the build (`SwipeTypingEngine`, Settings toggle, **default off**). Still bake-off gated — not missing. |
| GIF | Giphy REST tray from the accessory row (3-column thumbs). Messages pasteboard bubble is a device spike. |
| Missing | Key callouts; haptics beyond clicks. **Space-bar cursor / trackpad cancelled by 027** — not remaining work. |
| Dictation | Mic does **not** record in the appex. `murmur://dictate` via `extensionContext.open`, fallback responder-chain `UIApplication.open` (sideload). Host records + ElevenLabs `scribe_v2`. Poll `handoff.json` 80ms → `insertText` |
| Listening overlay | Replaces grid; **Format** disabled; palette is **light gray even in dark mode** |
| Full Access | `RequestsOpenAccess: true`. No Full Access / no API key → `.setup`, mic dead, **keys still type** |
| Packaging | `ios/project.yml` — **iOS 27.0** floor (SDK `iphoneos27.0` on this machine, Xcode-beta). iPhone only, **zero SPM**. App Group `group.com.matt.murmur.ios`. Test target `MurmurKeyboardTests` |
| Host return (bug) | `KeyboardViewController.startHandoff` **defaults an empty probe to `com.apple.MobileSMS`**, then `HostAppProbe.remember` persists it. `HostReturn.resolvedHost` defaults empty → Messages again. Scheme fallback only knows Messages / Notes / Mail. Matt’s report (always returns to Messages) matches this path. |
| Visual tokens | No shared iOS design-token file. Coral `#D85A30` duplicated in onboarding / Live Activity. Mac `Sources/Voice/UI/Theme.swift` is **AppKit** — do not import it into the appex |

## 3. Wispr Flow — what “parity but better” means

Research gather 2026-08-12 (official help + App Store + Wispr changelog). Wispr keyboard: [Set up the Flow keyboard on iPhone](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone) (updated ~2026-08-07); App Store `id6497229487`; [What’s new](https://wisprflow.ai/whats-new).

**Wispr ships (parity we will match):** full QWERTY (sometimes behind “Show full QWERTY”), autocap, autocorrect, double-space period, haptics, **top bar** (status / style pill / spinner), globe, Full Access required for transcription, mic bounce into the containing app, cloud dictation. **Space-bar trackpad:** Wispr has it; **027 cancels matching it** (do not implement).

**Wispr ships (we will not match):**
- **Magnify / pop-above-keyboard callouts** — Wispr has them; we will not. Apple forbids drawing key previews above the keyboard’s top edge (same constraint as §5.10).
- **Hamburger drawer** — Wispr has a hamburger; we **replace that slot** with GIF + candidates + **027 mic** (not leftover Start/waveform). This upgrade does not build a drawer. P0 does not keep a dead hamburger.

**Wispr does not document (our extras, not parity):** swipe/glide/QuickPath, GIF/sticker tray, Apple-style three-slot QuickType bar.

**Platform constraints we will not “fix”:** Apple forbids drawing key previews **above the keyboard’s top edge**. Wispr’s iOS 26 Liquid Glass **gap** and iOS 26.4 swipe-back notes are **out of this build’s compatibility budget** — floor is iOS 27; do not spend P0 on 26.x workarounds. If a gap still exists on 27, record it on device (do not promise it is gone). Wispr [What’s new](https://wisprflow.ai/whats-new) (fetched 2026-08-12) remains citation-only.

**Better than Wispr, on public APIs:**

1. Typing + swipe + autocorrect **work with Full Access off** (GIF + dictation still require it). App Store Review 4.4.1 would demand this anyway; we do it because it is the right keyboard.
2. Candidate bar is **visible**, not silent replace.
3. GIF button on the accessory row.
4. Swipe with always-visible alternatives (see P3 honesty bar).
5. Murmur visual identity (coral + **iOS 27 Liquid Glass**), not generic dark gray.

**Not in this plan:** beating Wispr’s cloud dictation quality; Voice Edit / Format; **killing** the bounce (we **fix** where it returns); App Store submission; iOS 26 compatibility.

## 4. Constraints (do not fight these)

| Constraint | Fact | Plan consequence |
|---|---|---|
| No QuickPath API | Apple ExtensibilityPG: expected typing features have **no dedicated API**. KeyboardKit Gestures = press/long-press/space-drag, **not** glide ([KeyboardKit](https://github.com/KeyboardKit/KeyboardKit) 10.7.3, 2026-07-19) | P3 is a **custom path matcher**, not an SDK checkbox |
| Memory | Apple: appex process cap **varies by device**, jetsam on exceed. KeyboardKit cites **~60–70 MB** on device (Simulator does not enforce) | No Giphy iOS SDK (default `GPHCache` **300 MB** memory). Tiny `URLCache`. Compact wordlist |
| Text API | `insertText` / `deleteBackward` / context strings only. **No insertGIF** | GIF: REST thumbnails in-keyboard; insert = pasteboard spike + URL fallback |
| Network | Only with Full Access | GIF **disabled** (stays in layout; a11y explains why), not removed, when `!hasFullAccess` |
| Height | Auto Layout on the keyboard view. Cannot draw above top edge | Reuse the **existing 48pt top bar**; bump total height only if the GIF tray needs a second sheet |
| App Store | 2.5.1 public APIs; 4.4.1 must work without Full Access / without network; must not launch apps besides Settings | **Stay sideload.** Existing `LSApplicationWorkspace` + responder-chain open stay. This build may add `suspend` for host return. Still not App Store. |
| iOS floor | This machine has **iPhoneOS 27.0 SDK** (`iphoneos27.0`, Xcode-beta). Project **is** `IPHONEOS_DEPLOYMENT_TARGET: "27.0"` in `ios/project.yml` (both `deploymentTarget` keys). | Floor stays **27.0**. No iOS 26 `#available` chrome. Do not plan a 26.0 → 27.0 bump — that already landed. |
| Tenor | API sunset **2026-06-30**; new keys closed 2026-01-13 | **Not a fallback** |
| KeyboardKit 10 | `master` LICENSE is closed-source / license key; 9.9.0 was MIT. Pro autocomplete is **$50/mo** (1 language) as of research 2026-08-12 ([KeyboardKit Pro](https://keyboardkit.com/pro)) | **Do not take KK 10.** DIY `UITextChecker` + `UILexicon` |
| Tests | `ios/` has **`MurmurKeyboardTests`** (exists; matcher / spell / swipe tests) | Keep using `MurmurKeyboardTests` for matcher/spell logic; device remains the UI oracle. Do not add a second host as if none exists. |

Apple docs (fetched 2026-08-12): [Creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard), [UITextChecker](https://developer.apple.com/documentation/uikit/uitextchecker), [requestSupplementaryLexicon](https://developer.apple.com/documentation/uikit/uiinputviewcontroller/requestsupplementarylexicon(completion:)), [App Store Review Guidelines 4.4.1](https://developer.apple.com/app-store/review/guidelines/).

Giphy (fetched 2026-08-12): [REST API](https://developers.giphy.com/docs/api/) — beta **100 calls/hour**, mandatory **Powered By GIPHY**, `fixed_height` 100px called out as “good for mobile keyboards”; [iOS SDK](https://developers.giphy.com/docs/sdk/) — `GiphyViewController` / `GiphyGridController`, 300 MB default cache — **rejected for appex**.

## 4.1 Feasibility (checked 2026-08-12 — do not skip)

Verdicts: **SHIP** = public API or empirically already happening on device. **SPIKE** = try on device first hour; ship-gate. **BLOCKED** = do not plan as if it works. **Degrade** = honest fallback if the spike fails.

| Bet | Verdict | Evidence |
|---|---|---|
| Bump floor to iOS 27 / compile `UIGlassEffect` | **SHIP** | This machine: SDK `iphoneos27.0`. `UIGlassEffect.h` in that SDK (`API_AVAILABLE(ios(26.0))`). |
| `UIGlassEffect` in the **keyboard appex** samples Messages/Notes behind it | **BLOCKED as a claim** | Apple: glass blurs content **in the window that hosts** the effect ([UIVisualEffectView](https://developer.apple.com/documentation/uikit/uivisualeffectview), WWDC25 284). Keyboard is a separate `keyboard-service` process. No Apple/KeyboardKit doc that glass samples the host app. |
| Glass **look** on keys/chips (samples the keyboard’s own backdrop) | **SPIKE → degrade** | API will compile. KeyboardKit iOS 26 work was a **restyle** (fills/insets), not `UIGlassEffect` in the appex ([KK blog 2025-07-28](https://keyboardkit.com/blog/2025/07/28/custom-ios-keyboard-extensions-and-liquid-glass)). If glass looks like mud/jetsam in the appex, ship tinted fills + highlights. Do not promise a see-through keyboard over the thread. |
| Wispr Liquid Glass **gap** above the keyboard | **Do not fight** | Wispr: iOS reserves theme safe-area; Flow cannot remove it ([help](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone)). Not a Murmur chrome bug. iOS 27: **unverified** whether the gap remains — screenshot, don’t spend a week on it. |
| Public API for “which app is showing this keyboard” | **BLOCKED** | `UIInputViewController` / `UITextDocumentProxy` have no host bundle ID (iPhoneOS27.0.sdk headers, 2026-08-12). KeyboardKit: `_hostBundleID` KVC **nil since iOS 16** ([issue 545](https://github.com/KeyboardKit/KeyboardKit/issues/545)). iOS 26/27 release notes add nothing. |
| `sourceApplication` as the host (Notes/Messages) | **BLOCKED** | [UIScene.OpenURLOptions.sourceApplication](https://developer.apple.com/documentation/uikit/uiscene/openurloptions/sourceapplication): non-nil only if **same team**. Keyboard → containing app is same team → you get **Murmur** (or nil), not Notes. Different-team host → **nil**. SwiftUI `.onOpenURL` does not even vended this today (`MurmurApp.swift`). |
| Stop defaulting empty probe to Messages | **SHIP** | Pure logic bug. `startHandoff` L294–295 + `HostReturn.resolvedHost`. Removing the default cannot make host detection worse. |
| Stop `remember`ing a guessed Messages ID | **SHIP** | Poisoned `lastHostBundleID` is why later takes stay wrong. |
| `LSApplicationWorkspace.openApplicationWithBundleIdentifier` | **SHIP (sideload, empirically)** | Matt’s bug **is** this SPI succeeding — it really opens Messages. So on his phone the SPI works. Wrong bundle ID is the bug, not a dead SPI. App Store: **BLOCKED** (2.5.1; Dictus 2026 says KK was rejected for it). |
| Open the **correct** app via workspace | **SPIKE** | Only if probe returns a real ID this take. If probe is nil (likely), workspace has nothing honest to open. |
| `UIApplication.suspend` restores the previous app | **SPIKE** | Private; **no iOS 26/27 Apple citation**. Wispr auto-return **broke on iOS 26.4** — users swipe back ([Adapting to iOS 26.4](https://docs.wisprflow.ai/articles/6269634092-adapting-to-ios-26-4)). May be a no-op. Do not write the plan as if suspend is the product. |
| Honest degrade if auto-return fails | **SHIP** | Stay in Murmur; copy: swipe back to the app you were in. Dictation keeps running (`UIBackgroundModes: audio`). Better than kidnapping to Messages. Wispr already shipped this degrade. |
| Suspend/return **before** the input graph is armed | **Don’t** | Wispr: swipe-back too early on cold start failed to start dictation. Arm `AVAudioEngine` in Murmur foreground first. The lease path already fails `recorder.start()` from background (`app.lease.startNeedsForeground`). |
| Delay **speech capture** until the keyboard is back in the host | **SPIKE → product attempt** | Matt 2026-08-12: do not start dictation until he is back in Notes/Safari. Arm the graph with no segment file (buffers already discarded in `MicRecorder.consume` when `segmentFile == nil`). Keyboard `viewWillAppear` pings App Group → open/unpause the file → then “Listening…”. If unpause-from-background fails on device, degrade to today’s order (file starts in Murmur) and say so in chrome. |
| P1 `UITextChecker` + lexicon | **SHIP** | Public APIs in the 27 SDK. |
| P2 Giphy REST in appex | **SHIP** (key + Full Access); insert GIF bubble **SPIKE** | REST + tiny renditions. `insertText` cannot place an animated GIF. |
| P3 swipe matcher | **SPIKE** with Matt ship-gate | Unchanged. |

**P0-host feasible product (what we actually promise):**

1. **Never actively launch Messages** unless this take’s probe (or the user) really was Messages. That is the bug Matt hit. **SHIP.**
2. If we have a probed host ID, workspace-open it (SPI already works on device). **SHIP when probe hits.**
3. Try suspend after the input graph is armed (not after “Listening…”). **SPIKE.** Log success/fail.
4. If still sitting in Murmur: **degrade** — don’t open Messages; tell him to swipe right. Capture still waits for keyboard `viewWillAppear` unless the listen-gate spike failed. **SHIP.**
5. **Listen-gate:** “Listening…” only after the originating keyboard is on screen again. **SPIKE** (see table). Host-only SessionView takes stay immediate.

Do not promise “always returns to Notes/Safari” until the device spike says suspend or probe works on iOS 27.

## 5. Product decisions (defaults — change only if Matt overrides)

1. **Sideload / private** distribution. No App Store work in this upgrade.
2. **English-first.** `PrimaryLanguage` stays `en-US`.
3. **Top accessory row layout** (Matt’s 026 request; **027 Batch B replaces the CTA**): `[ GIF ] [ candidate ×3 ] ………… [ mic ]`. GIF = top-left. **027:** coral `mic.fill` ~36×36 on the right — **not** leftover Start/waveform-pill AC. Candidates occupy the middle. During dictation, listening overlay still replaces the whole chrome (unchanged bounce UX).
4. **GIPHY REST** in the appex, not the official SDK, not Tenor, not a host-app bounce for search.
5. **Autocorrect engine:** `UITextChecker` + `requestSupplementaryLexicon` + a small bundled frequency list. No cloud LM. **No next-word model in P1** (KeyboardKit claims Apple dropped next-word APIs in iOS 16 — single-source; we do not promise QuickType-quality prediction).
6. **Swipe honesty bar:** beat Apple on **UX** (visible alternatives, whole-word undo, no silent wrong-commit). Do **not** claim neural QuickPath accuracy. P3 is a **spike with ship/no-ship gate**.
7. **Visual:** coral `#D85A30` / `#F0997B`. Duplicate tokens into `ios/Shared/KeyboardChromeTokens.swift` — do not import Mac `Theme.swift`. **027 wins for key look:** brighter caps + **1pt lip**. Do **not** treat leftover 026 `UIGlassEffect` / `UIGlassContainerEffect` on keys as remaining P0-chrome work (historical spike notes stay in §4.1 for archive).
8. **Do not regress dictation.** Bounce, lease, App Group IPC, ElevenLabs batch, Live Activity stay. Do not silently revert to in-appex mic. **Do not default the host to Messages.** Auto-return to Notes/Safari is a **device spike**, not a guarantee (§4.1). Keyboard-initiated takes **gate “Listening…”** on keyboard `viewWillAppear` (listen-gate spike).
9. **Sideload private APIs:** keep `LSApplicationWorkspace` (empirically works). `suspend` is a **spike**, not the product. Still not App Store.
10. **Key haptics** are P0 Wispr-parity chrome (small, public API). **Space-bar trackpad is cancelled by 027** — do not implement the local space pan or the P0 AC “space-drag moves caret.” Key *pop-above-keyboard* callouts are **out** — Wispr has magnify callouts; we will not match them (Apple forbids drawing above the top edge; top-row QWERTY would look broken). See §3.

## 6. Architecture (where new code lives)

All new typing/GIF/swipe code stays in the **keyboard target** except: Giphy API key storage (App Group, set from host onboarding) and optional GIF binary fetch cache directory in the App Group container.

```
ios/Keyboard/
  KeyboardViewController.swift      — proxy, height, Full Access gates, lexicon; **stop defaulting host to MobileSMS**
  KeyboardChromeView.swift          — layout; **027 key look** (brighter caps + 1pt lip). Not leftover UIGlassEffect-on-keys work
  AccessoryBarView.swift            — GIF button + CandidateStrip; **027 CTA is mic**, not Start/waveform
  AutocorrectController.swift       — UITextChecker + word-span replace (in tree)
  SwipeTypingEngine.swift           — pan → path → candidates (in tree; Settings toggle, default off)
  GifTrayController.swift           — REST search/trending + grid sheet (in tree)
  KeyGeometry.swift                 — key-center map for swipe + hit tests
ios/Shared/
  HostAppProbe.swift                — probe only; never remember a guessed Messages default
  KeyboardChromeTokens.swift        — colors, radii, heights (UIKit)
  AppGroupStore.swift               — add giphyAPIKey (and maybe gifCacheEnabled)
  GiphyClient.swift                 — URLSession, tiny cache, attribution
ios/MurmurIOS/
  HostReturn.swift                  — never open Messages unless probe said Messages; suspend is a spike; swipe-back degrade
  OnboardingView.swift              — Giphy key step; GIF works only with Full Access
ios/Resources/                      — NEW: en-US frequency wordlist (license-clean)
ios/project.yml                     — iOS 27.0 floor (landed), `MurmurKeyboardTests` exists, no Giphy SPM
```

**Touch handling (P0 vs P3 — load-bearing):** today’s keys are discrete `UIButton` `.touchUpInside` (`private final class KeyView: UIButton` in `KeyboardChromeView.swift`).

- **P0:** keep that existing `KeyView` subclass. **Space-bar trackpad is cancelled by 027** — no local pan on the space key. Do not introduce a grid-wide gesture owner in P0.
- **P3:** introduce a single `UIGestureRecognizer` owner on `grid` that dispatches tap vs swipe vs delete-hold. **Do not absorb a P0 space-key pan** (cancelled by 027; never shipped). Letter keys may then become non-`UIButton` layers under that owner so `UIButton` highlights and the pan recognizer do not fight. Translation under about 16pt → tap (preserve current key behavior); translation across **2 or more letter keys** → swipe path; cancel the tap. Swipe **never** starts on delete / shift / 123 / return / space (space types space, not swipe).
- **Do not add a second type named `KeyView`.** If P3 replaces the UIButton subclass, rename or convert the existing type in place — never two `KeyView`s.

**Height:** idle typing is **296pt** (`KeyboardChromeTokens.portraitHeight`). GIF search tray shares that height with a compressed key row; it is not a taller keyboard.

**Jetsam budget (P2/P3), on top of the current keyboard baseline:**

MurmurKeyboard already compiles all of `ios/Shared/` except `DictationAttributes.swift` / `DictationIntents.swift` (`ios/project.yml`). That includes **MicRecorder**, **ElevenLabsBatch**, and **WAVTranscoder**, which are unused in the appex (host-only). P0 plans excluding those three from the keyboard target — **plan only; do not implement in this doc pass**. GIF/wordlist caps below are additional, not a substitute for that exclude.

- `URLCache` memory ≤ **4 MB**, disk ≤ **16 MB** in App Group
- Decode only `fixed_height_small` / `fixed_width_small` for the grid; fetch `downsized` only on send
- Wordlist: compact UTF-8 list, target **≤ 1.5 MB** bundled; load lazily
- On `viewWillDisappear`, cancel downloads and drop decoded images

## 7. Phases

Implementation order is **P0-host → P0-chrome → P1 → P2 → P3**. Host-return is in **this build** (Matt 2026-08-12). Do not start P3 until P1 candidate bar exists. Implementation of every phase is **blocked on Matt** (`approved — build`).

### P0-host — Return to the app that started dictation (must-fix)

**Matt’s report (2026-08-12):** after Start, Murmur always brings him back to **Messages**, regardless of which app he was typing in.

**Root cause (verified in code this session, not a guess):**

1. `KeyboardViewController.startHandoff` (L294–295): `detectedHost.isEmpty ? "com.apple.MobileSMS" : detectedHost`. Empty probe **becomes Messages**.
2. `HostAppProbe.remember(host)` then persists that guess in `AppGroupStore.lastHostBundleID`. Later probes that fail return the **stale Messages** ID (`HostAppProbe.bundleID` L19–20). One bad take poisons every later take.
3. `HostReturn.resolvedHost` (L16–19): empty → last → **Messages again**.
4. `HostReturn.openScheme` only knows Messages / Notes / Mail. `LSApplicationWorkspace.openApplicationWithBundleIdentifier` of the **wrong** ID actively launches Messages instead of restoring the previous foreground app.

`HostAppProbe` is best-effort KVC on undocumented selectors. iOS exposes **no public** keyboard-host identity API (comment in `HostAppProbe.swift`). So “open this bundle ID” is the wrong primitive when the ID is a guess.

**Fix (this build — feasibility in §4.1, not vibes):**

1. **SHIP — never default to Messages.** Empty probe stays empty. Do **not** `remember` a default. Do **not** write Messages into `lastHostBundleID` unless the probe **this take** returned `com.apple.MobileSMS`.
2. **SHIP when probe hits — workspace-open that ID.** The SPI already opens Messages on Matt’s phone; the bug is the ID. If probe is nil (likely; KVC dead since iOS 16), skip workspace.
3. **SPIKE — `suspend` after the input graph is armed**, before the take is “Listening…”. Log whether the previous app returns. If it is a no-op (Wispr 26.4 pattern), do not keep calling it.
4. **SHIP degrade — do not open Messages as a consolation prize.** If still in Murmur: SessionView tells him to swipe right. Listening has **not** started yet (listen-gate).
5. **SPIKE — listen-gate.** Keyboard-initiated takes: no WAV segment / no “Listening…” until `KeyboardViewController.viewWillAppear` with a pending payload. Timeout if he never returns. If opening the segment from background fails, degrade to file-starts-in-Murmur and log it. SessionView-only takes (`bounce: false`) still start immediately.
6. Diagnostics: log `probed=` vs `empty=` vs `workspace=` vs `suspend=` vs `hostReady=` vs `listenGated=`. Device AC **fails** if a Notes take **opens** Messages. Device AC **does not fail** if a Notes take stays in Murmur with swipe-right copy (degrade). Listen-gate AC **fails** if chrome says Listening while Murmur is still frontmost (unless degrade was logged). “Always returns to Notes” is **unverified** until the spike.

**Acceptance:**

- Dictate from **Notes**: must **not** land in Messages. Either Notes (spike success) or Murmur with swipe-right copy (degrade). **Listening starts only after the keyboard is back** (unless listen-gate degrade was logged). Transcript still inserts when he is back in Notes.
- Dictate from **Safari** (or Mail): same — not Messages.
- Dictate from **Messages**: may return to Messages (probe or he was already there).
- After a Notes take, a later Messages take must not be poisoned by a guessed lastHost.
- Compile gate. No in-appex mic rewrite. No “suspend always works” claim without a device log.

### P0 — Chrome: iOS 27 Liquid Glass daily-driver + accessory row slots

**Why after P0-host:** Matt’s GIF button has nowhere to live until the top row is a real accessory bar. Visual work is wasted if we restyle a dead hamburger — **remove/replace** `menuButton`; P0 does not keep a hidden hamburger. Host-return lands first so chrome work does not regress a still-broken bounce.

**Work:**

1. Extract `AccessoryBarView`: left GIF control **visible but disabled** (placeholder slot Matt asked for; a11y explains “GIFs need Full Access and a Giphy key”), middle three candidate slots (empty/idle), right CTA. **027 Batch B:** that CTA is **mic**, not Start/waveform — do not implement leftover Start-pill AC.
2. `KeyboardChromeTokens` — light/dark fills, coral CTA, key corner radius ~8–10pt (today 5.5), row gap, font sizes. Listening overlay **follows dark/light**. **027 Batch A wins for key look** (brighter caps + 1pt lip). Do **not** treat leftover `UIVisualEffectView` + `UIGlassEffect` on keys as remaining P0-chrome work. Historical spike: glass samples the **keyboard’s own** backdrop only; do not claim the keyboard frosts the Messages thread.
3. Haptics: `UIImpactFeedbackGenerator` on key down (respect Reduce Motion / system keyboard haptic setting if readable; otherwise follow `UIAccessibility.isReduceMotionEnabled`).
4. **Cancelled by 027 — space-bar trackpad:** do **not** add a local pan on the space key / `adjustTextPosition`. P3 must not absorb a P0 space-key pan that was never shipped.
5. Keep globe, shift, 123/#+=, delete-repeat, double-space period, capitalization.
6. Idle status: do not show a blank status forever; empty candidates + **027 mic** is the rest state. Setup/secure copy can use a single-line caption or replace candidates temporarily.
7. **offline degrade** visual pass (no better-design MCP): no purple SaaS gradient, contrast AA on key glyphs, one primary (**027 mic**, not Start pill), no glow soup.
8. **Keyboard target jetsam baseline:** exclude `MicRecorder.swift`, `ElevenLabsBatch.swift`, and `WAVTranscoder.swift` from the MurmurKeyboard target (`project.yml` Shared excludes; host-only).
9. `ios/project.yml` `deploymentTarget.iOS` and `IPHONEOS_DEPLOYMENT_TARGET` are **already 27.0** — not remaining work.

**Acceptance:**

- Unsigned `xcodebuild` Debug generic iOS **BUILD SUCCEEDED** (command in §9).
- Device: light + dark in Notes; **mic (027)** still starts dictation (same bounce as 026 Start); keys still insert; **space-drag / trackpad AC cancelled by 027** (space key types space only); GIF control **visible but disabled** top-left; three candidate slots visible.
- No purple SaaS gradient; key glyphs readable in light and dark (offline degrade).
- Listening overlay readable in dark mode.
- No hamburger / dead `menuButton` in the accessory row.
- Dictation bounce + insert still works (**Notes and Messages**, one take each) **and** P0-host AC (Notes/Safari do not dump into Messages).
- Keys/accessory look: **027 wins** — brighter caps + 1pt lip (Batch A); mic not Start/waveform (Batch B). Do **not** treat leftover 026 `UIGlassEffect`-on-keys as remaining P0-chrome work. Screenshot on device after 027.

### P1 — Autocorrect + candidate bar

**Status:** implemented in PR #37 (2026-08-12). Device AC (10 typos in Notes) still needs Matt.

**Work:**

1. `requestSupplementaryLexicon` on appear; keep `UILexicon` in memory.
2. On each insert/delete, parse `documentContextBeforeInput` for the **current word span** (letters + apostrophes; stop at whitespace).
3. `UITextChecker.completions` / `guesses` for that span + lexicon hits + frequency-list prefix. Show up to **3** in the accessory bar.
4. On **space** or **punctuation**, if the word is flagged misspelled and a high-confidence guess exists, replace the span (delete N, insert correction) and keep the old word as candidate **#2** so a tap undoes.
5. Skip: digits, all-caps acronyms (len≥2), URLs, the word after an explicit “don’t correct” tap this session (Wispr behavior).
6. Never autocorrect in `isSecureTextEntry`. Never touch text that was just inserted by dictation in the same turn: after `.done` insert, set `suppressAutocorrectUntilNextWhitespace` so the **first space after a transcript does not respell dictated words**.
7. Unit tests (new `MurmurKeyboardTests`): word-span extraction, skip rules, replace math on sample strings — **no device**.

**Acceptance:**

- Type `teh` + space → `the`; candidate bar shows `teh` as undo.
- Type a correct word → completions for the prefix while typing, no aggressive replace.
- Secure field: no replace.
- Full Access off: autocorrect still runs (no network).
- Compile gate + device: 10 common typos in Notes.

**Honesty:** this is **Wispr-class / system-spellcheck class**, not “better than Apple’s QuickType LM.” The visible bar + undo is the “better” vs silent Apple/Wispr replace.

### P2 — GIPHY (REST + accessory button)

**Blocked on Matt before coding the client:** a Giphy **iOS** API key in the dashboard, stored like the ElevenLabs key (App Group). Beta keys are **100 req/h**. Production limits need Giphy’s application/pricing email — **blocked on Matt** if we outgrow beta.

**Work:**

1. Onboarding step: paste Giphy key → `AppGroupStore`. Empty key → GIF button disabled with a11y “Add a Giphy key in Murmur.”
2. `GiphyClient`: `trending` + `search` over `https://api.giphy.com/v1/gifs/…`. Attribution view **“Powered By GIPHY”** (ToS). Renditions: grid = `fixed_height_small` / `fixed_width_small`; send = `downsized` or `original` only after tap.
3. GIF button top-left toggles **tray sheet** (replaces key grid, keeps accessory bar). Search field + 2-column collection. Close returns to QWERTY.
4. `!hasFullAccess` or no network: button stays in layout but **disabled**, copy “Turn on Full Access for GIFs.” Keyboard typing still works.
5. **Insert path (two-tier):**
   - **P2a (ship):** `insertText` of the Giphy URL (works in every `UITextField`). User sees a link. Honest, not magical.
   - **P2b (spike, same phase, ship/no-ship):** `UIPasteboard` with `UTType.gif` data + `public.url`. Device-test in **Messages**: if an animated bubble appears without leaving the keyboard, keep it and prefer it when `hasFullAccess`. If not, **keep P2a** and document “paste from clipboard” as a manual extra — do not fake a bubble with private APIs.
6. Sticker-guideline hygiene: no off-platform stolen packs; Giphy attribution visible in-tray.
7. Cache/jetsam limits in §6.

**Acceptance:**

- Full Access + key: tap GIF → trending loads; search “nope”; tap a GIF → host field receives **at least** a URL (P2a).
- Messages P2b: recorded as **verified / failed** in the device log — either outcome is a valid ship as long as P2a works.
- Full Access off: no crash, no hang, typing OK.
- Attribution visible.
- Compile gate. Network failures show an in-tray error, not a frozen grid.

### P3 — Swipe-to-type (spike → ship gate)

**Work:**

1. `KeyGeometry` from laid-out letter key frames (rebuild on layout / rotation / 123 page — swipe **letters page only**).
2. Pan recognizer per §6. Sample points; map to nearest key center; collapse runs.
3. Score a license-clean **en-US frequency list** (default corpus: MIT `first20hours/google-10000-english` or equivalent public-domain/MIT/Apache — **no GPL**, AnySoftKeyboard is Apache 2.0 and may be **studied**, not copied if provenance is messy). Combine with `UILexicon` names.
4. Algorithm (ShapeWriter-style spatial model, not a neural net): expected polyline through letter centers vs sampled path; channel distance + length ratio + unigram frequency. Beam of top 20 → show top **3** in the candidate bar. Finger-up commits **#1**.
5. UX vs Apple (the actual “better” bar):
   - Alternatives stay visible until the next word starts.
   - Tap #2/#3 replaces the committed word.
   - One extra delete after a swipe deletes the **whole swipe word**, not one letter.
   - Short pan = tap. Swipe never starts on modifiers.
   - Swipe does not run during dictation overlay.
6. Unit tests: path → expected word on a fake 10-key geometry fixture (e.g. path across h-e-l-l-o centers prefers `hello`).
7. **Ship gate (device, Matt taste — no numeric top-1 threshold):** 20-word list (common + a few proper nouns from Contacts lexicon), side-by-side vs Apple QuickPath on the same list. **Matt calls ship/no-ship.** Orchestrator must not invent a percentage cutoff. If Matt judges top-1 worse than Apple’s QuickPath, **do not ship swipe** — leave the recognizer behind a compile flag / hidden setting. Shipping a worse glide is a product failure; shipping without glide is fine (Wispr doesn’t have it).

**Acceptance (if gate passes):**

- Swipe `hello`, `the`, `and` commits correctly more often than not; #2/#3 catch misses.
- Tap still works on every letter.
- 123 page unaffected.
- Jetsam: no keyboard death after 50 swipes (device).
- Compile gate + tests.

**Honesty:** Gboard-class neural swipe is **out of scope**. “Better than Apple’s shitty implementation” is **UX + undo + candidates**, with a quality gate so we don’t ship a worse matcher.

## 8. Out of scope

- App Store submit, removing private bounce APIs, in-appex microphone
- KeyboardKit / Fleksy / Giphy SPM SDK / Tenor
- Next-word LLM, Voice Edit / Format, Mac dictionary sync, Pro/IAP, Murmur-server
- iPad (`TARGETED_DEVICE_FAMILY` stays `1`), other languages, emoji search page (unless it falls out of Giphy)
- Drawing above the keyboard top edge
- iOS 26 compatibility / dual chrome paths / promising to close Wispr’s iOS 26 Liquid Glass gap
- Wispr hamburger drawer / magnify callouts (see §3 — we will not match those)
- Changing Mac `project.yml` / WhisperKit / Sparkle
- Rewriting dictation IPC (P0-host is a surgical `HostReturn` / probe / default-Messages fix, not a new handoff design)

## 9. Verification

**Compile (unsigned)** — same snippet as `ios/README.md` (from **repo root**, then `cd ios`):

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

Expect: `** BUILD SUCCEEDED **`. Re-run after this work. Do not treat a from-`ios/` `../Config` variant as a second SSOT.

**Signed device:** team and profiles as documented in `ios/README.md`. Keyboard Full Access + GIF/dictation **cannot** be honestly verified in Simulator (jetsam + Full Access + Messages paste).

**Per-phase oracles:**

| Phase | Oracle |
|---|---|
| P0-host | Notes take must not open Messages. Return-to-Notes **or** swipe-right degrade. Listening only after keyboard is back (or logged listen-gate degrade). Log probed/empty/suspend/hostReady. Safari or Mail once. |
| P0–P3 | Unsigned compile (iOS 27 SDK) |
| P1, P3 | `MurmurKeyboardTests` (new) |
| P0–P3 UI | Physical iPhone **on iOS 27**: Notes + Messages, light/dark; **027 look** screenshot (mic + lip), not leftover UIGlassEffect-on-keys |
| P2 | Failed GIF search must surface in-tray |
| Dictation regression | One Notes take + one Messages take after every phase that touches `KeyboardViewController` or `HostReturn` |

**Visual:** `ios-oracle` / xc-mcp screenshots if a sim keyboard is even present; **device screenshots are the real visual oracle**. Label sim-only as **unverified** for Full Access features.

## 10. Blocked on Matt

| Item | Why it blocks |
|---|---|
| `approved — build` | Build gate. This file is a plan, not authorization |
| Giphy dashboard API key (iOS) | P2 cannot call `api.giphy.com` without it |
| Giphy production quota | Only if beta 100 req/h is too small; otherwise ship on beta |
| P3 ship/no-ship after the 20-word device list | Matt taste; no numeric top-1 threshold; side-by-side vs Apple QuickPath; orchestrator must not silently ship a worse swipe |
| App Store later | Separate decision; private APIs still block |

Not blocked: P0-host **Messages default removal** (in-repo), P1 autocorrect, iOS 27 compile, swipe spike, REST client. Auto-return to Notes and host-sampled glass are **not** promised.

## 11. Risks

| Risk | Mitigation |
|---|---|
| Jetsam when decoding GIFs | Rendition + cache caps; SDK forbidden |
| Pan vs tap fights | P0: no space-key pan (trackpad cancelled by 027). P3: single gesture owner; 16pt slop; modifiers excluded |
| Autocorrect mangles dictation | After `.done`, `suppressAutocorrectUntilNextWhitespace`; skip secure |
| Messages ignores pasteboard GIF | P2a URL always; P2b optional |
| Wordlist license | MIT/Apache/public domain only |
| Stale memory topic | This plan + `ios/README.md` win over `murmur-ios-keyboard.md` until that page is updated post-ship |
| Always-Messages bounce | SHIP: never default/remember MobileSMS. SPIKE: suspend. SHIP degrade: swipe-back, never open Messages as consolation |
| Glass samples the host thread | BLOCKED as a claim; spike glass on keyboard backdrop only; degrade to fills |
| `sourceApplication` as Notes/Messages | BLOCKED — same-team or nil |

## 12. README / docs when this ships

Same PR as the phase that lands (not now):

- `ios/README.md` — remove “full QWERTY” from the out-of-scope list; document GIF Full Access + Giphy key; keep App Store / private-API warning.
- `plans/README.md` — this row: Status DRAFT until ship, then SHIPPED/PARTIAL by phase. Split §026 to `026-ios-keyboard-upgrade.md` when the novel-file write gate allows.
- Memory topic `murmur-ios-keyboard.md` — rewrite bounce + typing features (stale in-appex mic claim).

## 13. Effort sketch (planning only, not a schedule promise)

| Phase | Shape |
|---|---|
| P0-host | Surgical `HostReturn` / probe / kill Messages default; device Notes+Safari+Messages |
| P0-chrome | Accessory bar + iOS 27 floor (landed). **Look:** 027 (mic + lip), not leftover UIGlassEffect-on-keys |
| P1 | Spell engine + tests + bar wiring |
| P2 | REST client + tray + onboarding; P2b is a device afternoon |
| P3 | Matcher + tests + device gate; largest unknown |

No phase is “done” without the §9 oracle for that phase.
