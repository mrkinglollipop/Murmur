# Cloud protocols (Android)

Transcribed from Swift headers. Drift is caught by golden fixtures in `:cloud:test`, not shared code.

## ElevenLabs batch (PR 2)

Source: `ios/Shared/ElevenLabsBatch.swift`.

- `POST https://api.elevenlabs.io/v1/speech-to-text`
- Header: `xi-api-key` (not Bearer, not query)
- Multipart fields: `model_id=scribe_v2`, `language_code`, `no_verbatim` (`true`/`false`), repeated `keyterms` (never comma-joined)
- File part: name `file`, filename `audio.wav`, `Content-Type: audio/wav`
- Body: 16 kHz / 16-bit / mono PCM WAV (`WavWriter`, contract of `WAVTranscoder`)
- Response JSON: `{ "text": "..." }` (top-level `"text"` only)

## ElevenLabs Scribe v2 Realtime (PR 5)

Source: `Sources/Voice/ElevenLabsRealtimeTranscriber.swift`.

- `wss://api.elevenlabs.io/v1/speech-to-text/realtime?model_id=scribe_v2_realtime&audio_format=pcm_16000&language_code=<lang>&no_verbatim=<true|false>` plus `commit_strategy`, optional `filter_background_audio`, VAD fields when commit is VAD, repeated `keyterms`
- Header: `xi-api-key` (not Bearer, not query)
- Audio: **text JSON** frames, not binary. All four fields required:
  `{"message_type":"input_audio_chunk","audio_base_64":"...","commit":bool,"sample_rate":16000}`
- Ready gate: `session_started`. Partials: `partial_transcript`. Finals: `committed_transcript` (sequential, no stitch)
- `keyterms` are repeated query params, never comma-joined. `+` is `%2B`. Cap 50 terms / 20 UTF-8 bytes
- Discriminator is `message_type`, not `type`

## Gemini 3.5 Transcribe Live (PR 5)

Source: `Sources/Voice/GeminiLiveTranscriber.swift`, `GeminiLiveOptions.swift`.

- `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=<key>`
- First client frame: camelCase `setup` (`models/gemini-3.5-transcribe-live`, `inputAudioTranscription`, `realtimeInputConfig.automaticActivityDetection`)
- Audio: JSON `realtimeInput.audio` with `mimeType=audio/pcm;rate=16000` and base64 PCM16
- Ready gate: `setupComplete` / `setup_complete`. Server may send **binary** UTF-8 JSON
- Partials: `serverContent.interimInputTranscription.text`. Finals: `serverContent.inputTranscription.text` (snake_case aliases accepted)
- Session cap 580 s: stop sending; preserve accumulated text
- Live handshake is device-gated: a failed `setupComplete` skips live on later takes and uses batch

## Gemini batch (PR 5)

Source: `ios/Shared/GeminiBatch.swift`.

- `POST https://generativelanguage.googleapis.com/v1beta/interactions`
- Header: `x-goog-api-key`
- JSON body from `GeminiLiveOptions.makeBatchRequestBody` (WAV base64, `gemini-3.5-transcribe`)
- Transcript: top-level `output_text`, else `output`, else `steps[].content[].text`
