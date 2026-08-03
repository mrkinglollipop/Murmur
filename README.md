# Murmur — macOS

Menu-bar push-to-talk dictation app. Hold **fn / Globe** (or **Right Option**) → mic records. Release → audio is transcribed, optionally cleaned up, dictionary-corrected, snippet-expanded, and injected at the cursor. A floating HUD pill shows live waveform feedback while recording.

---

## Features

- **Push-to-talk** — global activation via CGEvent tap (HID layer); fn consumption suppresses the emoji picker by default
- **Toggle-lock** — double-tap fn for hands-free recording that continues after key release
- **Recording HUD** — audio-reactive waveform pill with dynamic activation-key label
- **Text injection** — inserts transcribed text at the focused field; falls back to clipboard when injection fails
- **Transcription history** — searchable log of every dictation, with edit-to-learn dictionary corrections and JSON/Markdown export
- **Dictionary** — case-insensitive whole-word variant→term corrections, auto-learned from history edits
- **Snippets** — voice-triggered phrase expansion (longest-match first)
- **Voice commands** — spoken commands applied post-transcript (e.g. discard / clear)
- **Style profiles** — formality instructions appended to the cleanup LLM prompt
- **Transforms** — custom rewrite prompts run on the last dictation (copied to clipboard)
- **Insights** — usage stats over history and dictionary activity
- **Scratchpad** — free-form notes with debounced autosave
- **Settings UI** — engine selection, activation key, cleanup, API keys, model downloads, launch-at-login, dictation sounds
- **Recording retention** — last 5 recordings kept in Application Support for retry on failed transcriptions

---

## ASR Engines

### Local (default path)

| Model | Engine | Notes |
|-------|--------|-------|
| Whisper large-v3-turbo | WhisperKit (CoreML) | Default; downloads on first use |
| Whisper large-v3 | WhisperKit | |
| distil-whisper large-v3 | WhisperKit | |
| Whisper base | WhisperKit | Fast/small |
| Parakeet TDT 0.6B v3 | Python sidecar | Requires `pip install parakeet-mlx` |

Switch between local models in **Settings → Local Model**. Download/delete models from the same panel.

### Cloud (BYO API key)

| Provider | Model | Notes |
|----------|-------|-------|
| xAI | Grok STT (grok-stt) | Selectable; optional live WebSocket streaming |
| ElevenLabs | Scribe v2 Realtime | Selectable; **always streams** (batch only as socket fallback) |

Retired providers (AssemblyAI, Deepgram, OpenAI gpt-4o-transcribe, Groq) remain in code for factory/Keychain compatibility but are **not** shown in the Settings picker.

Enable **Settings → Transcription Engine → Cloud**, pick a cloud model, and paste your API key (stored in Keychain). If no key is stored for the selected provider, dictation falls back to the local engine.

**Streaming**
- Local WhisperKit live streaming is **disabled** (`ASREngineSelector.streamingEnabled = false`) due to a sub-second tail-drop bug; local uses the file-based path.
- **xAI** optional live streaming when enabled in Settings; otherwise batch WAV upload.
- **ElevenLabs** always uses the realtime WebSocket; batch is fallback only when the socket fails.

---

## AI Cleanup

Optional post-transcription pass (off by default) that fixes grammar, punctuation, and filler words.

- **On-device** — Apple Intelligence / Foundation Models (macOS 26+)
- **Cloud** — OpenAI or xAI Grok (BYO key in Keychain)
- **Code-aware mode** — preserves identifiers and spoken punctuation for programming dictation
- **Style** — active Style profile formality instruction is appended to the cleanup prompt

Configure in **Settings → Cleanup**.

---

## Build

```bash
cp Config/Team.xcconfig.example Config/Team.xcconfig   # xcodegen hard-requires this file
xcodegen generate
xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

The compiled app lands in:
```
~/Library/Developer/Xcode/DerivedData/Voice-*/Build/Products/Debug/Murmur.app
```

Or open `Voice.xcodeproj` in Xcode and hit **⌘B** (after `xcodegen generate` if the project file is not present).

Contributors can build and test without a Developer ID team: pass
`CODE_SIGNING_ALLOWED=NO` to `xcodebuild` (shown above). Signed release builds need a
stable Developer ID identity — see the signing rationale comment above
`CODE_SIGN_STYLE` in [`project.yml`](project.yml). Set your team via
`Config/Team.xcconfig` (from `Config/Team.xcconfig.example`) or export
`DEVELOPMENT_TEAM` before running release scripts.

---

## Release

- **`bash scripts/install-local.sh`** — Release build with Developer ID signing, installs to `/Applications/Murmur.app`, and launches it. Fast path for dogfooding on this Mac.
- **`bash scripts/make-dmg.sh`** — Signed distributable DMG (drag-to-Applications layout). Set `NOTARIZE=1` to notarize; without it the DMG is signed but other Macs may need right-click → Open.
- **`bash scripts/publish-sparkle.sh`** — Builds/notarizes via `make-dmg.sh`, signs the update for Sparkle, and publishes the DMG + appcast to the public `Murmur-updates` feed. Prefer `NOTARIZE=1`. Requires a Sparkle EdDSA private key (path or Keychain account) — do not commit key material.
- The app auto-updates via Sparkle from that public feed.

See [`scripts/README.md`](scripts/README.md) for the full script index. Current release path is **make-dmg → publish-sparkle**; `scripts/release.sh` is legacy.

King Lollipop Studios (Matthew Schwartz) maintains Murmur. See [`LICENSE`](LICENSE) (AGPL-3.0) and [`CONTRIBUTING.md`](CONTRIBUTING.md).

---

## Grant permissions (one-time)

### 1. Input Monitoring

The app uses a `CGEvent.tapCreate` at the HID level (`.cghidEventTap`) to detect the push-to-talk key globally.

1. Run Murmur.app once — if Input Monitoring is not granted, the app shows an alert with an "Open System Settings" button.
2. Go to **System Settings → Privacy & Security → Input Monitoring**.
3. Enable the toggle next to **Murmur**.
4. Quit and relaunch.

### 2. Globe key (only if fn-consumption is disabled)

By default the app consumes standalone fn presses so the emoji/dictation picker never fires. If you set `consumeFnEvents = false` in `ActivationController.swift`:

> **System Settings → Keyboard → "Press 🌐 (Globe) key to:"** → **Do Nothing**

### 3. Microphone

On first hold of the activation key, macOS prompts for microphone access. If previously denied: **System Settings → Privacy & Security → Microphone → enable Murmur**.

### 4. Accessibility (for text injection)

Text injection uses Accessibility APIs. Grant **Murmur** under **System Settings → Privacy & Security → Accessibility** if prompted.

---

## Run & test

1. Launch `Murmur.app` — a microphone icon appears in the menu bar.
2. Hold **fn / Globe** (or your configured key).
3. Speak for 1–5 seconds.
4. Release.
5. Text should appear at the cursor (or on the clipboard if injection failed).
6. Open the main window (**Open Murmur** from the menu bar) to see history, dictionary, snippets, and settings.

### Debug logging

Set `VOICE_DEBUG=1` when launching to enable diagnostic output to `NSTemporaryDirectory()/voice-debug.log` (typically `$(getconf DARWIN_USER_TEMP_DIR)voice-debug.log`, mode `0o600`) and Console (subsystem `com.matt.voice-dictation`). Transcript text is never logged — only counts and timing.

```bash
VOICE_DEBUG=1 /path/to/Murmur.app/Contents/MacOS/Murmur
```

---

## API keys (Keychain)

Cloud transcription and cleanup keys are stored in the macOS Keychain under service `com.matt.voice-dictation.apikeys` with data-protection attributes (device-only, no iCloud sync). Manage keys in **Settings → Cloud Model** and **Settings → Cleanup**.

---

## Data locations

| Path | Contents |
|------|----------|
| `~/Library/Application Support/Voice/` | History, dictionary, snippets, scratchpad, transforms, style JSON |
| `~/Library/Application Support/Voice/Recordings/` | Retained `.caf` recordings (count + size budget in Settings → Storage) |
| `~/Library/Application Support/Voice/Models/` | WhisperKit model cache (migrated from Documents if needed) |
| `/tmp/voice-*.caf` | Ephemeral capture (deleted after successful transcription) |

---

## Parakeet sidecar setup

```bash
pip install parakeet-mlx
```

The Swift `ParakeetEngine` spawns the bundled `parakeet_transcribe.py` sidecar with a
resolved `python3` (Homebrew `/opt/homebrew/bin/python3` or `/usr/local/bin/python3`,
pyenv shim, then `/usr/bin/env python3`). Finder-launched apps inherit a minimal PATH, so
a Homebrew-only install needs one of those absolute interpreters. If `parakeet-mlx` is
missing or Python cannot be found, the sidecar fails with an error that names the
interpreter tried; the app stays running.

---

## Technical note — why `.cghidEventTap` works for fn

The fn / Globe key is consumed by the system at the event-coalescing layer, so a standard `.cgSessionEventTap` tap never sees it. `.cghidEventTap` fires at the HID layer before coalescing — fn arrives as a `.flagsChanged` event with `.maskSecondaryFn`. Requires Input Monitoring permission.
