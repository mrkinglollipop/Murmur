# Murmur

**Murmur** is a macOS menu-bar dictation app. Hold a push-to-talk key, speak, and release — Murmur transcribes your speech and inserts it at the cursor.

It is built for people who dictate into real apps all day: local or cloud speech recognition, optional AI cleanup, a learned dictionary, snippets, and history you can search and export.

**Requirements:** macOS 26 or later · Apple Silicon or Intel Mac with a supported CoreML stack for local models.

**License:** [AGPL-3.0](LICENSE) · Copyright © 2026 Matthew Schwartz d/b/a [King Lollipop Studios](https://github.com/mrkinglollipop)

---

## Highlights

- **Push-to-talk** — global activation (fn / Globe or Right Option) via a HID-level event tap
- **Toggle-lock** — double-tap fn for hands-free recording
- **Live HUD** — waveform feedback while you hold the key
- **Local or cloud ASR** — WhisperKit on-device by default; optional BYO cloud keys (xAI, ElevenLabs)
- **Cleanup** — optional grammar / filler cleanup (on-device Apple Intelligence or cloud LLM)
- **Dictionary & snippets** — corrections learned from edits; spoken phrase expansion
- **History & Insights** — searchable dictation log, exports, and usage stats
- **Auto-update** — Sparkle updates from the public [Murmur-updates](https://github.com/mrkinglollipop/Murmur-updates) feed

---

## Install (end users)

Prefer a signed build from the Sparkle feed or a notarized DMG when available. After install:

1. Open **Murmur** from Applications (menu-bar mic icon).
2. Grant **Input Monitoring**, **Microphone**, and **Accessibility** when prompted (see [Permissions](#permissions) below).
3. Hold **fn / Globe** (or your configured key), speak, and release.

Updates install in-app via **Check for Updates…** when enabled.

---

## Build from source

You need **Xcode** (with command-line tools) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
cp Config/Team.xcconfig.example Config/Team.xcconfig   # required by XcodeGen
# Optional: set DEVELOPMENT_TEAM in that file for signed builds
xcodegen generate
xcodebuild -scheme Voice -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

`Voice.xcodeproj` is generated and not tracked — always run `xcodegen generate` after clone or `project.yml` changes.

Unsigned contributor builds should pass `CODE_SIGNING_ALLOWED=NO`. Signed release builds need a stable **Developer ID Application** identity (see the signing comments in [`project.yml`](project.yml)).

### Verify

```bash
xcodebuild test -scheme VoiceTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

This repository has **no CI by design**. Local macOS verification is the gate.

### Maintainer install & release

| Script | Purpose |
|--------|---------|
| `bash scripts/install-local.sh` | Signed Release build → `/Applications/Murmur.app` |
| `bash scripts/make-dmg.sh` | Signed DMG (`NOTARIZE=1` recommended) |
| `bash scripts/publish-sparkle.sh` | Notarize, Sparkle-sign, publish DMG + appcast |

Details: [`scripts/README.md`](scripts/README.md). Do not commit team IDs, Sparkle private keys, or API keys.

---

## Permissions

| Permission | Why |
|------------|-----|
| **Input Monitoring** | Global push-to-talk via `CGEvent` HID tap |
| **Microphone** | Audio capture while recording |
| **Accessibility** | Inject text at the focused field |

Grant under **System Settings → Privacy & Security**. Quit and relaunch Murmur after changing toggles.

**Note:** The fn / Globe key is only visible to a HID-level tap (`.cghidEventTap`). Session-level taps never see it — that is why Input Monitoring is required.

---

## Speech engines

### Local (default)

| Model | Engine | Notes |
|-------|--------|-------|
| Whisper large-v3-turbo | WhisperKit (CoreML) | Default; downloads on first use |
| Whisper large-v3 | WhisperKit | |
| distil-whisper large-v3 | WhisperKit | |
| Whisper base | WhisperKit | Smaller / faster |
| Parakeet TDT 0.6B v3 | Python sidecar | Requires `pip install parakeet-mlx` |

Manage models in **Settings → Local Model**. Model files live under `~/Library/Application Support/Voice/Models/`.

### Cloud (bring your own key)

| Provider | Model | Notes |
|----------|-------|-------|
| xAI | Grok STT | Optional live WebSocket streaming |
| ElevenLabs | Scribe v2 Realtime | Always streams (batch only as fallback) |

Keys are stored in the macOS Keychain (device-only). Without a key for the selected provider, Murmur falls back to the local engine.

---

## Optional AI cleanup

Off by default. When enabled:

- **On-device** — Apple Intelligence / Foundation Models (macOS 26+)
- **Cloud** — OpenAI or xAI (BYO key)
- **Code-aware mode** — preserves identifiers and spoken punctuation
- **Style profiles** — formality hints appended to the cleanup prompt

Configure under **Settings → Cleanup**.

---

## Data on disk

| Location | Contents |
|----------|----------|
| `~/Library/Application Support/Voice/` | History, dictionary, snippets, transforms, style |
| `~/Library/Application Support/Voice/Recordings/` | Short retained captures for retry |
| `~/Library/Application Support/Voice/Models/` | WhisperKit cache |
| Temporary directory | Ephemeral capture files (removed after success) |

Debug logging (`VOICE_DEBUG=1`) writes to a owner-only temp log. **Transcript text is never logged** — only counts and timing.

---

## Parakeet (optional local engine)

```bash
pip install parakeet-mlx
```

Murmur launches the bundled sidecar with a resolved `python3` (Homebrew paths, pyenv, then `/usr/bin/env python3`). Finder-launched apps often have a minimal `PATH`; if setup fails, the error names the interpreter that was tried.

---

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) (CLA / copyright assignment) and [`SECURITY.md`](SECURITY.md) for private vulnerability reporting.

Questions and ideas: GitHub Issues. Security reports: **Security → Report a vulnerability** (not public issues).

---

## Acknowledgements

Bundled components include WhisperKit, Sparkle, FluidAudio, and the EB Garamond / Figtree fonts. License texts ship in the app and under [`Resources/Licenses/`](Resources/Licenses/).
