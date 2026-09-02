# Cloud protocols (Android)

Transcribed from Swift headers. Drift is caught by golden fixtures in `:cloud:test`, not shared code.

## ElevenLabs batch (PR 2)

Source: `ios/Shared/ElevenLabsBatch.swift`.

- `POST https://api.elevenlabs.io/v1/speech-to-text`
- Header: `xi-api-key` (not Bearer, not query)
- Multipart fields: `model_id=scribe_v2`, `language_code`, `no_verbatim` (`true`/`false`), repeated `keyterms` (never comma-joined)
- File part: name `file`, filename `audio.wav`, `Content-Type: audio/wav`
- Body: 16 kHz / 16-bit / mono PCM WAV (`WavWriter`, contract of `WAVTranscoder`)
- Response JSON: `{ "text": "..." }`
