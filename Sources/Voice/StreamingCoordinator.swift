import AVFoundation
#if os(macOS)
import os.log
#endif

/// Owns xAI / WhisperKit streaming session state and the start/stop decision
/// logic extracted from `AudioRecorder`. File-based capture stays in the
/// recorder; this type decides whether to open a streaming session and
/// handles finalize-at-release for both streaming backends.
///
/// iOS compiles this file for the static finalize-recovery helpers only.
/// Session types (`StreamingTranscriber`, `XAIStreamingTranscriber`,
/// `ASREngineSelector`) are Mac-target sources and must not be referenced
/// on iOS.
final class StreamingCoordinator {

#if os(macOS)
    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "streaming")

    /// Non-nil while a WhisperKit streaming session owns transcription.
    private(set) var whisperSession: StreamingTranscriber?

    /// Non-nil while an xAI Grok streaming session is active. Read from the
    /// audio-tap thread to fork per-buffer sends; set/cleared on main.
    private(set) var xaiSession: XAIStreamingTranscriber?

    /// Non-nil while an ElevenLabs Scribe v2 Realtime streaming session is
    /// active. Read from the audio-tap thread to fork per-buffer sends;
    /// set/cleared on main. Mutually exclusive with `xaiSession` (both are
    /// gated on the same `cloudModel` selection, which is a single value).
    private(set) var elevenLabsSession: ElevenLabsRealtimeTranscriber?

    /// Non-nil while a Gemini 3.5 Transcribe Live streaming session is
    /// active. Mutually exclusive with the other cloud streaming sessions.
    private(set) var geminiSession: GeminiLiveTranscriber?

    /// Non-nil while a Meta Muse Voice Transcribe streaming session is active.
    private(set) var museSession: MuseLiveTranscriber?

    /// Coordinator-wide latch: any non-empty `onInterim` during the current
    /// hold. Survives async start-failure clearing the session reference so
    /// file-based fallthrough can still know stream text existed.
    private(set) var coordinatorEverHadStreamText = false

    init(
        xaiSession: XAIStreamingTranscriber? = nil,
        elevenLabsSession: ElevenLabsRealtimeTranscriber? = nil,
        geminiSession: GeminiLiveTranscriber? = nil,
        museSession: MuseLiveTranscriber? = nil
    ) {
        self.xaiSession = xaiSession
        self.elevenLabsSession = elevenLabsSession
        self.geminiSession = geminiSession
        self.museSession = museSession
    }
#else
    init() {}
#endif

    /// Soft floor for "looks truncated" — only force batch fallback when text
    /// is extremely short relative to hold length (false positives at 8 cps
    /// discarded good streams). Empty text already falls back separately.
    static let streamMinCharsPerSecond: Double = 2.0
    static let streamTruncationCheckMinDuration: TimeInterval = 8.0

    /// Long holds where a large snapshot-vs-finalize gap without prefix
    /// extension means the live stream diverged — batch re-decode is safer.
    /// Floor is intentionally below "long dictation" (15s+) so a rewritten
    /// last clause on a normal hold still triggers batch when the gap is big.
    static let lengthMismatchBatchMinDuration: TimeInterval = 8.0
    static let lengthMismatchMinCharGap: Int = 25
    /// Minimum extension beyond finalize before treating snapshot as real tail.
    static let snapshotTailRecoveryMinChars: Int = 3

    /// Below this much captured audio (inclusive), a hold with no stream text
    /// is discarded as silence instead of entering the batch→local fallback
    /// chain. Evidence (2026-08-10 log): a 0.33 s dead-silent tap cascaded
    /// through batch "No transcript" into a cold WhisperKit load and a 120 s
    /// timeout error, while a 1.93 s *quiet* hold (also under the RMS
    /// threshold) was legitimately rescued by the same fallback (14 injected
    /// chars). Duration separates those two; loudness does not — do NOT gate
    /// this on `hadSpeech`.
    ///
    /// Inclusive (`<=`): a 0.5 s CAF at exactly the floor (48 kHz × 24_000
    /// frames) previously bypassed silence-cancel (`bufferedSeconds < 0.5`),
    /// ran empty Gemini finalize → WhisperKit batch, and flashed
    /// "Transcription failed" beside a later successful Gemini hold
    /// (2026-08-31 history).
    static let silenceCancelMaxBufferedSeconds: TimeInterval = 0.5

    /// Silence cancel only when there was never stream text and the captured
    /// audio is absent or at most `silenceCancelMaxBufferedSeconds`.
    /// Longer buffers bypass local RMS `hadSpeech` — quiet real speech below
    /// the RMS threshold has been rescued by the batch fallback in the field.
    static func shouldTakeSilenceCancel(
        everHadStreamText: Bool,
        bufferedSeconds: TimeInterval
    ) -> Bool {
        !everHadStreamText && bufferedSeconds <= silenceCancelMaxBufferedSeconds
    }

    /// Total captured seconds across PCM buffers (frames ÷ sample rate).
    static func bufferedSeconds(_ buffers: [AVAudioPCMBuffer]) -> TimeInterval {
        buffers.reduce(0) { total, buf in
            let rate = buf.format.sampleRate
            guard rate > 0 else { return total }
            return total + Double(buf.frameLength) / rate
        }
    }

    /// True when the HUD snapshot at release strictly extends finalize with
    /// meaningful tail text — finalize dropped words the stream had in-flight.
    static func snapshotExtendsFinalize(finalize: String, snapshot: String) -> Bool {
        let finalTrim = finalize.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapTrim = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard snapTrim.count > finalTrim.count, !finalTrim.isEmpty else { return false }

        if snapTrim.hasPrefix(finalTrim) {
            return snapshotTailIsMeaningful(finalTrim: finalTrim, snapTrim: snapTrim)
        }

        let finalLower = finalTrim.lowercased()
        let snapLower = snapTrim.lowercased()
        if snapLower.hasPrefix(finalLower) {
            return snapshotTailIsMeaningful(finalTrim: finalTrim, snapTrim: snapTrim)
        }

        // Finalize often reapplies punctuation the HUD snapshot never had.
        return snapshotWordPrefixExtends(finalTrim: finalTrim, snapTrim: snapTrim)
    }

    /// True when snapshot words contain finalize words as a contiguous
    /// subsequence with meaningful leading content — head-loss where finalize
    /// is a tail fragment. Punctuation-stripped like Class B prefix checks.
    static func snapshotSupersetContainsFinalize(finalize: String, snapshot: String) -> Bool {
        let finalTrim = finalize.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapTrim = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard snapTrim.count > finalTrim.count + snapshotTailRecoveryMinChars else { return false }
        guard !finalTrim.isEmpty else { return false }

        let finalWords = tokenizeForPrefix(finalTrim)
        let snapWords = tokenizeForPrefix(snapTrim)
        guard !finalWords.isEmpty else { return false }
        guard let index = findWordSubsequenceIndex(needle: finalWords, in: snapWords) else {
            return false
        }
        // Prefix extension is Class B, not superset.
        if index == 0, snapWords.count > finalWords.count { return false }
        guard index > 0 else { return false }

        let head = snapWords.prefix(index).joined(separator: " ")
        guard head.count >= snapshotTailRecoveryMinChars else { return false }
        return head.contains(where: { $0.isLetter || $0.isNumber })
    }

    /// Prefer finalize punctuation/cleanup and append only missing snapshot
    /// tail, or prepend missing snapshot head — avoids re-injecting HUD filler.
    static func recoveredTextMergingSnapshot(finalize: String, snapshot: String) -> String? {
        let finalTrim = finalize.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapTrim = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalTrim.isEmpty, !snapTrim.isEmpty else { return nil }

        if snapshotExtendsFinalize(finalize: finalize, snapshot: snapshot) {
            if snapTrim.hasPrefix(finalTrim) {
                let tail = String(snapTrim.dropFirst(finalTrim.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tail.isEmpty else { return finalTrim }
                return appendTail(to: finalTrim, tail: tail)
            }
            let finalLower = finalTrim.lowercased()
            let snapLower = snapTrim.lowercased()
            if snapLower.hasPrefix(finalLower) {
                let tail = String(snapTrim.dropFirst(finalTrim.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tail.isEmpty else { return finalTrim }
                return appendTail(to: finalTrim, tail: tail)
            }
            let finalWords = tokenizeForPrefix(finalTrim)
            let snapWords = tokenizeForPrefix(snapTrim)
            guard snapWords.count > finalWords.count,
                  Array(snapWords.prefix(finalWords.count)) == finalWords else {
                return nil
            }
            let tailWords = Array(snapWords.dropFirst(finalWords.count))
            guard !tailWords.isEmpty else { return nil }
            if let last = finalTrim.last, ".!?".contains(last), tailWords.count < 3 {
                return nil
            }
            guard let tail = snapshotSubstringFromWordIndex(
                snapTrim,
                wordIndex: finalWords.count
            ) else {
                return nil
            }
            guard tail.count >= snapshotTailRecoveryMinChars else { return nil }
            return appendTail(to: finalTrim, tail: tail)
        }

        if snapshotSupersetContainsFinalize(finalize: finalize, snapshot: snapshot) {
            let finalWords = tokenizeForPrefix(finalTrim)
            let snapWords = tokenizeForPrefix(snapTrim)
            guard let index = findWordSubsequenceIndex(needle: finalWords, in: snapWords),
                  index > 0,
                  let head = snapshotSubstringBeforeWordIndex(snapTrim, wordIndex: index),
                  !head.isEmpty else {
                return nil
            }
            let headEndsSentence = head.last.map { ".!?".contains($0) } ?? false
            let sep = headEndsSentence ? " " : ". "
            return head + sep + finalTrim
        }

        return nil
    }

    /// Long hold with a large snapshot lead that is not a simple extension —
    /// live stream and finalize diverged; prefer batch over either string.
    static func shouldBatchFallbackForLengthMismatch(
        finalize: String,
        snapshot: String,
        duration: TimeInterval
    ) -> Bool {
        let finalTrim = finalize.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapTrim = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        if snapshotHasCompetingLongerTail(finalize: finalTrim, snapshot: snapTrim) {
            return true
        }
        guard duration >= lengthMismatchBatchMinDuration else { return false }
        guard snapTrim.count > finalTrim.count + lengthMismatchMinCharGap else { return false }
        return !snapshotExtendsFinalize(finalize: finalTrim, snapshot: snapTrim)
    }

    /// A speculative snapshot and authoritative final share a substantial
    /// prefix but disagree on the ending, with the snapshot carrying more
    /// words. Neither string can safely win by character count; re-decode the
    /// retained audio. This is structural evidence and needs no duration gate.
    static func snapshotHasCompetingLongerTail(finalize: String, snapshot: String) -> Bool {
        let finalTrim = finalize.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapTrim = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard snapTrim.count >= finalTrim.count + snapshotTailRecoveryMinChars else { return false }

        let finalWords = tokenizeForPrefix(finalTrim)
        let snapWords = tokenizeForPrefix(snapTrim)
        guard finalWords.count >= 3, snapWords.count > finalWords.count else { return false }

        var commonPrefix = 0
        while commonPrefix < min(finalWords.count, snapWords.count),
              finalWords[commonPrefix] == snapWords[commonPrefix] {
            commonPrefix += 1
        }
        guard commonPrefix >= 2, commonPrefix < finalWords.count else { return false }
        return commonPrefix * 2 >= finalWords.count
    }

    /// After streaming finalize: prefer non-empty finalize text unless truncated.
    /// If finalize is empty, recover a non-empty pre-finalize snapshot (Class A
    /// residual — silence was bypassed for stream text, then finalize cleared /
    /// returned empty). When finalize is non-empty but shorter than the release-
    /// time snapshot that extends it (Class B tail loss), prefer the snapshot.
    /// Returns success-path text, or `nil` for batch fallback.
    static func streamSuccessTextOrBatchFallback(
        finalizeText: String,
        preFinalizeSnapshot: String,
        duration: TimeInterval = 0,
        truncated: Bool
    ) -> String? {
        let finalTrim = finalizeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapTrim = preFinalizeSnapshot.trimmingCharacters(in: .whitespacesAndNewlines)

        if truncated {
            if snapTrim.count > finalTrim.count,
               snapshotExtendsFinalize(finalize: finalizeText, snapshot: preFinalizeSnapshot),
               !streamResultLooksTruncated(text: preFinalizeSnapshot, duration: duration),
               let merged = recoveredTextMergingSnapshot(
                   finalize: finalizeText,
                   snapshot: preFinalizeSnapshot
               ) {
                return merged
            }
            if finalTrim.isEmpty, !snapTrim.isEmpty {
                return preFinalizeSnapshot
            }
            return nil
        }

        if finalTrim.isEmpty {
            return snapTrim.isEmpty ? nil : preFinalizeSnapshot
        }

        if snapTrim.count > finalTrim.count + snapshotTailRecoveryMinChars,
           snapshotExtendsFinalize(finalize: finalizeText, snapshot: preFinalizeSnapshot)
            || snapshotSupersetContainsFinalize(finalize: finalizeText, snapshot: preFinalizeSnapshot),
           let merged = recoveredTextMergingSnapshot(
               finalize: finalizeText,
               snapshot: preFinalizeSnapshot
           ) {
            return merged
        }

        if shouldBatchFallbackForLengthMismatch(
            finalize: finalTrim,
            snapshot: snapTrim,
            duration: duration
        ) {
            return nil
        }

        return finalizeText
    }

    private static func snapshotTailIsMeaningful(finalTrim: String, snapTrim: String) -> Bool {
        let tailStart = snapTrim.index(
            snapTrim.startIndex,
            offsetBy: min(finalTrim.count, snapTrim.count),
            limitedBy: snapTrim.endIndex
        ) ?? snapTrim.endIndex
        let tail = String(snapTrim[tailStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard tail.count >= snapshotTailRecoveryMinChars else { return false }
        return tail.contains(where: { $0.isLetter || $0.isNumber })
    }

    /// True when snapshot words (punctuation-stripped) strictly extend finalize
    /// words with a meaningful tail — covers finalize inserting a trailing
    /// period the live HUD never showed.
    private static func snapshotWordPrefixExtends(finalTrim: String, snapTrim: String) -> Bool {
        let finalWords = tokenizeForPrefix(finalTrim)
        let snapWords = tokenizeForPrefix(snapTrim)
        guard !finalWords.isEmpty, snapWords.count > finalWords.count else { return false }
        guard Array(snapWords.prefix(finalWords.count)) == finalWords else { return false }
        let tailWords = Array(snapWords.dropFirst(finalWords.count))
        if let last = finalTrim.last, ".!?".contains(last), tailWords.count < 3 {
            return false
        }
        let tail = tailWords.joined(separator: " ")
        guard tail.count >= snapshotTailRecoveryMinChars else { return false }
        return tail.contains(where: { $0.isLetter || $0.isNumber })
    }

    private static func tokenizeForPrefix(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { token -> String? in
            let folded = token.trimmingCharacters(in: .punctuationCharacters).lowercased()
            return folded.isEmpty ? nil : folded
        }
    }

    private static func findWordSubsequenceIndex(needle: [String], in haystack: [String]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let limit = haystack.count - needle.count
        for start in 0...limit {
            if Array(haystack[start..<(start + needle.count)]) == needle {
                return start
            }
        }
        return nil
    }

    private static func appendTail(to finalize: String, tail: String) -> String {
        let tailTrim = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tailTrim.isEmpty else { return finalize }
        var tailOut = tailTrim
        if let last = finalize.last, ".!?".contains(last), let first = tailOut.first {
            tailOut = first.uppercased() + tailOut.dropFirst()
        }
        return finalize + " " + tailOut
    }

    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            if index >= text.endIndex { break }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
            ranges.append(start..<index)
        }
        return ranges
    }

    private static func snapshotSubstringFromWordIndex(_ snapshot: String, wordIndex: Int) -> String? {
        let ranges = wordRanges(in: snapshot)
        guard wordIndex < ranges.count else { return nil }
        let start = ranges[wordIndex].lowerBound
        return String(snapshot[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func snapshotSubstringBeforeWordIndex(_ snapshot: String, wordIndex: Int) -> String? {
        let ranges = wordRanges(in: snapshot)
        guard wordIndex > 0, wordIndex <= ranges.count else { return nil }
        let end = ranges[wordIndex].lowerBound
        return String(snapshot[snapshot.startIndex..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

#if os(macOS)
    /// Clears per-hold stream-text latch. Call at the start of each new capture.
    func resetStreamTextLatch() {
        coordinatorEverHadStreamText = false
    }

    private func noteInterimText(_ text: String) {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            coordinatorEverHadStreamText = true
        }
    }

    // MARK: - Start

    /// Attempts xAI Grok streaming. Returns `true` when a session was opened
    /// (caller should start mic capture). On start failure the session is
    /// cleared and `false` is returned so the caller falls through to file mode.
    func tryStartXAI(
        asrSelector: ASREngineSelector,
        startMicCapture: @escaping () -> Void
    ) -> Bool {
        guard let session = asrSelector.makeXAIStreamingSession() else { return false }

        session.onInterim = { [weak self] text in
            self?.noteInterimText(text)
            asrSelector.onInterimTranscript?(text)
        }
        xaiSession = session
        vlog("doStart — attempting xAI streaming transcription")
        Task {
            do {
                try await session.start()
            } catch {
                vlog("xai streaming: start failed (\(error.localizedDescription)) — continuing in file-buffer mode")
                session.cancel()
                DispatchQueue.main.async {
                    if self.xaiSession === session {
                        self.xaiSession = nil
                    }
                }
            }
        }
        startMicCapture()
        return true
    }

    /// Attempts ElevenLabs Scribe v2 Realtime streaming. Returns `true` when
    /// a session was opened. On start failure the session is cleared and
    /// file-buffer capture continues (mic already running).
    func tryStartElevenLabs(
        asrSelector: ASREngineSelector,
        startMicCapture: @escaping () -> Void
    ) -> Bool {
        guard let session = asrSelector.makeElevenLabsStreamingSession() else { return false }

        session.onInterim = { [weak self] text in
            self?.noteInterimText(text)
            asrSelector.onInterimTranscript?(text)
        }
        elevenLabsSession = session
        vlog("doStart — attempting ElevenLabs Scribe RT streaming transcription")
        Task {
            do {
                try await session.start()
            } catch {
                vlog("elevenlabs streaming: start failed (\(error.localizedDescription)) — continuing in file-buffer mode")
                session.cancel()
                DispatchQueue.main.async {
                    if self.elevenLabsSession === session {
                        self.elevenLabsSession = nil
                    }
                }
            }
        }
        startMicCapture()
        return true
    }

    /// Attempts Gemini 3.5 Transcribe Live streaming. Returns `true` when
    /// a session was opened. Mirrors `tryStartElevenLabs`.
    func tryStartGemini(
        asrSelector: ASREngineSelector,
        startMicCapture: @escaping () -> Void
    ) -> Bool {
        guard let session = asrSelector.makeGeminiStreamingSession() else { return false }

        session.onInterim = { [weak self] text in
            self?.noteInterimText(text)
            asrSelector.onInterimTranscript?(text)
        }
        geminiSession = session
        vlog("doStart — attempting Gemini Live streaming transcription")
        Task {
            do {
                try await session.start()
            } catch {
                vlog("gemini streaming: start failed (\(error.localizedDescription)) — continuing in file-buffer mode")
                session.cancel()
                DispatchQueue.main.async {
                    if self.geminiSession === session {
                        self.geminiSession = nil
                    }
                }
            }
        }
        startMicCapture()
        return true
    }

    /// Attempts Meta Muse Voice Transcribe streaming. Returns `true` when
    /// a session was opened. Mirrors `tryStartGemini`.
    func tryStartMuse(
        asrSelector: ASREngineSelector,
        startMicCapture: @escaping () -> Void
    ) -> Bool {
        guard let session = asrSelector.makeMuseStreamingSession() else { return false }

        session.onInterim = { [weak self] text in
            self?.noteInterimText(text)
            asrSelector.onInterimTranscript?(text)
        }
        museSession = session
        vlog("doStart — attempting Meta Muse streaming transcription")
        Task {
            do {
                try await session.start()
            } catch {
                vlog("muse streaming: start failed (\(error.localizedDescription)) — continuing in file-buffer mode")
                session.cancel()
                DispatchQueue.main.async {
                    if self.museSession === session {
                        self.museSession = nil
                    }
                }
            }
        }
        startMicCapture()
        return true
    }

    /// Attempts WhisperKit streaming. Returns `true` when a session was
    /// opened (mic capture is NOT started here — streaming owns the mic).
    /// On failure, calls `fallbackToFileBased` on main if recording is still wanted.
    func tryStartWhisperKit(
        asrSelector: ASREngineSelector,
        wantsRecording: @escaping () -> Bool,
        levelCallback: @escaping (Float) -> Void,
        fallbackToFileBased: @escaping () -> Void
    ) -> Bool {
        guard asrSelector.streamingEligible,
              let wkEngine = asrSelector.makeWhisperKitEngineForStreaming() else {
            return false
        }

        let session = StreamingTranscriber()
        session.levelCallback = levelCallback
        whisperSession = session
        vlog("doStart — attempting streaming transcription")
        Task {
            do {
                try await session.start(engine: wkEngine)
            } catch {
                vlog("streaming: start failed (\(error.localizedDescription)) — falling back to file-based path")
                self.whisperSession = nil
                DispatchQueue.main.async {
                    guard wantsRecording() else { return }
                    fallbackToFileBased()
                }
            }
        }
        return true
    }

    /// Sends a captured buffer to the active xAI session, if any.
    func sendToXAI(_ buffer: AVAudioPCMBuffer) {
        xaiSession?.send(buffer)
    }

    /// Sends a captured buffer to the active ElevenLabs session, if any.
    func sendToElevenLabs(_ buffer: AVAudioPCMBuffer) {
        elevenLabsSession?.send(buffer)
    }

    /// Sends a captured buffer to the active Gemini session, if any.
    func sendToGemini(_ buffer: AVAudioPCMBuffer) {
        geminiSession?.send(buffer)
    }

    /// Sends a captured buffer to the active Meta Muse session, if any.
    func sendToMuse(_ buffer: AVAudioPCMBuffer) {
        museSession?.send(buffer)
    }

    /// Aborts any in-flight streaming session and drops the reference without
    /// waiting for a final transcript — used when the capture is abandoned
    /// (secure input activated mid-hold) and the audio must not be used.
    func cancelAll() {
        xaiSession?.cancel()
        xaiSession = nil
        elevenLabsSession?.cancel()
        elevenLabsSession = nil
        geminiSession?.cancel()
        geminiSession = nil
        museSession?.cancel()
        museSession = nil
    }

    // MARK: - Stop (xAI)

    struct XAIStopContext {
        let duration: TimeInterval
        let hadSpeech: Bool
        let bufferedAudio: [AVAudioPCMBuffer]
        /// Optional pre-sampled latch from the recorder; OR'd with session/coordinator.
        let streamTextEver: Bool
    }

    /// Handles xAI streaming stop. Returns `true` when this path consumed the stop.
    func handleStopXAI(
        context: XAIStopContext,
        onSilence: @escaping () -> Void,
        onStreamSuccess: @escaping (String) -> Void,
        onBatchFallback: @escaping ([AVAudioPCMBuffer], TimeInterval) -> Void
    ) -> Bool {
        guard let session = xaiSession else { return false }

        // Read latch + transcript snapshot before tear-down / finalize clears state.
        let everHad = context.streamTextEver
            || session.hasEverHadNonEmptyStreamText
            || coordinatorEverHadStreamText
        let bufferedSecs = Self.bufferedSeconds(context.bufferedAudio)
        let preFinalizeSnapshot = session.joinedTranscriptSnapshot()
        xaiSession = nil

        if Self.shouldTakeSilenceCancel(everHadStreamText: everHad, bufferedSeconds: bufferedSecs) {
            vlog("xai streaming: no speech — skipping (silence guard) everHad=\(everHad) buffers=\(context.bufferedAudio.count) bufferedSecs=\(String(format: "%.2f", bufferedSecs)) hadSpeech=\(context.hadSpeech)")
            session.cancel()
            onSilence()
            return true
        }

        if !context.hadSpeech {
            vlog("xai streaming: silence bypass — everHad=\(everHad) buffers=\(context.bufferedAudio.count)")
        }

        let releaseAt = Date()
        Task {
            let text = await session.finalize(recordingDuration: context.duration)
            vlog("xai streaming: finalize-at-release \(String(format: "%.3f", Date().timeIntervalSince(releaseAt)))s")
            if session.requiresBufferedAudioRecovery {
                self.logger.warning("xAI streaming integrity failed — falling back to buffered audio.")
                DispatchQueue.main.async {
                    onBatchFallback(context.bufferedAudio, context.duration)
                }
                return
            }
            let truncated = Self.streamResultLooksTruncated(text: text, duration: context.duration)
                || Self.streamTextLooksAbruptlyCut(text)
            if truncated {
                vlog("xai streaming: truncated (\(text.count) chars / \(String(format: "%.1f", context.duration))s) — batch fallback")
            }
            if let success = Self.streamSuccessTextOrBatchFallback(
                finalizeText: text,
                preFinalizeSnapshot: preFinalizeSnapshot,
                duration: context.duration,
                truncated: truncated
            ) {
                if text.isEmpty || success.count > text.count {
                    vlog("xai streaming: recovered pre-finalize snapshot (\(success.count) chars)")
                }
                onStreamSuccess(success)
            } else {
                if text.isEmpty {
                    self.logger.warning("xAI streaming produced no text — falling back to buffered audio.")
                } else {
                    self.logger.warning("xAI streaming looks truncated — falling back to buffered audio.")
                }
                vlog("xai streaming: fallback to buffered audio (\(context.bufferedAudio.count) buffers)")
                DispatchQueue.main.async {
                    onBatchFallback(context.bufferedAudio, context.duration)
                }
            }
        }
        return true
    }

    // MARK: - Stop (ElevenLabs)

    struct ElevenLabsStopContext {
        let duration: TimeInterval
        let hadSpeech: Bool
        let bufferedAudio: [AVAudioPCMBuffer]
        let streamTextEver: Bool
    }

    /// Handles ElevenLabs Scribe RT streaming stop. Returns `true` when this
    /// path consumed the stop. Mirrors `handleStopXAI`.
    func handleStopElevenLabs(
        context: ElevenLabsStopContext,
        onSilence: @escaping () -> Void,
        onStreamSuccess: @escaping (String) -> Void,
        onBatchFallback: @escaping ([AVAudioPCMBuffer], TimeInterval) -> Void
    ) -> Bool {
        guard let session = elevenLabsSession else { return false }

        let everHad = context.streamTextEver
            || session.hasEverHadNonEmptyStreamText
            || coordinatorEverHadStreamText
        let bufferedSecs = Self.bufferedSeconds(context.bufferedAudio)
        let preFinalizeSnapshot = session.joinedTranscriptSnapshot()
        elevenLabsSession = nil

        if Self.shouldTakeSilenceCancel(everHadStreamText: everHad, bufferedSeconds: bufferedSecs) {
            vlog("elevenlabs streaming: no speech — skipping (silence guard) everHad=\(everHad) buffers=\(context.bufferedAudio.count) bufferedSecs=\(String(format: "%.2f", bufferedSecs)) hadSpeech=\(context.hadSpeech)")
            session.cancel()
            onSilence()
            return true
        }

        if !context.hadSpeech {
            vlog("elevenlabs streaming: silence bypass — everHad=\(everHad) buffers=\(context.bufferedAudio.count)")
        }

        let releaseAt = Date()
        Task {
            let text = await session.finalize(recordingDuration: context.duration)
            vlog("elevenlabs streaming: finalize-at-release \(String(format: "%.3f", Date().timeIntervalSince(releaseAt)))s")
            if session.requiresBufferedAudioRecovery {
                self.logger.warning("ElevenLabs stream coverage was not established — falling back to buffered audio.")
                vlog("elevenlabs streaming: integrity or finality failure — buffered-audio fallback")
                DispatchQueue.main.async {
                    onBatchFallback(context.bufferedAudio, context.duration)
                }
                return
            }
            let truncated = Self.streamResultLooksTruncated(text: text, duration: context.duration)
                || Self.streamTextLooksAbruptlyCut(text)
            if truncated {
                vlog("elevenlabs streaming: truncated (\(text.count) chars / \(String(format: "%.1f", context.duration))s) — batch fallback")
            }
            if let success = Self.streamSuccessTextOrBatchFallback(
                finalizeText: text,
                preFinalizeSnapshot: preFinalizeSnapshot,
                duration: context.duration,
                truncated: truncated
            ) {
                if text.isEmpty || success.count > text.count {
                    vlog("elevenlabs streaming: recovered pre-finalize snapshot (\(success.count) chars)")
                }
                onStreamSuccess(success)
            } else {
                if text.isEmpty {
                    self.logger.warning("ElevenLabs streaming produced no text — falling back to buffered audio.")
                } else {
                    self.logger.warning("ElevenLabs streaming looks truncated — falling back to buffered audio.")
                }
                vlog("elevenlabs streaming: fallback to buffered audio (\(context.bufferedAudio.count) buffers)")
                DispatchQueue.main.async {
                    onBatchFallback(context.bufferedAudio, context.duration)
                }
            }
        }
        return true
    }

    // MARK: - Stop (Gemini)

    struct GeminiStopContext {
        let duration: TimeInterval
        let hadSpeech: Bool
        let bufferedAudio: [AVAudioPCMBuffer]
        let streamTextEver: Bool
    }

    /// Handles Gemini Live streaming stop. Returns `true` when this path
    /// consumed the stop. Mirrors `handleStopElevenLabs`.
    func handleStopGemini(
        context: GeminiStopContext,
        onSilence: @escaping () -> Void,
        onStreamSuccess: @escaping (String) -> Void,
        onBatchFallback: @escaping ([AVAudioPCMBuffer], TimeInterval) -> Void
    ) -> Bool {
        guard let session = geminiSession else { return false }

        let everHad = context.streamTextEver
            || session.hasEverHadNonEmptyStreamText
            || coordinatorEverHadStreamText
        let bufferedSecs = Self.bufferedSeconds(context.bufferedAudio)
        let preFinalizeSnapshot = session.joinedTranscriptSnapshot()
        geminiSession = nil

        if Self.shouldTakeSilenceCancel(everHadStreamText: everHad, bufferedSeconds: bufferedSecs) {
            vlog("gemini streaming: no speech — skipping (silence guard) everHad=\(everHad) buffers=\(context.bufferedAudio.count) bufferedSecs=\(String(format: "%.2f", bufferedSecs)) hadSpeech=\(context.hadSpeech)")
            session.cancel()
            onSilence()
            return true
        }

        if !context.hadSpeech {
            vlog("gemini streaming: silence bypass — everHad=\(everHad) buffers=\(context.bufferedAudio.count)")
        }

        let releaseAt = Date()
        Task {
            let text = await session.finalize(recordingDuration: context.duration)
            vlog("gemini streaming: finalize-at-release \(String(format: "%.3f", Date().timeIntervalSince(releaseAt)))s")
            if session.requiresBufferedAudioRecovery {
                self.logger.warning("Gemini streaming integrity failed or reached its cap — falling back to buffered audio.")
                DispatchQueue.main.async {
                    onBatchFallback(context.bufferedAudio, context.duration)
                }
                return
            }
            let truncated = Self.streamResultLooksTruncated(text: text, duration: context.duration)
                || Self.streamTextLooksAbruptlyCut(text)
            if truncated {
                vlog("gemini streaming: truncated (\(text.count) chars / \(String(format: "%.1f", context.duration))s) — batch fallback")
            }
            if let success = Self.streamSuccessTextOrBatchFallback(
                finalizeText: text,
                preFinalizeSnapshot: preFinalizeSnapshot,
                duration: context.duration,
                truncated: truncated
            ) {
                if text.isEmpty || success.count > text.count {
                    vlog("gemini streaming: recovered pre-finalize snapshot (\(success.count) chars)")
                }
                onStreamSuccess(success)
            } else {
                if text.isEmpty {
                    self.logger.warning("Gemini streaming produced no text — falling back to buffered audio.")
                } else {
                    self.logger.warning("Gemini streaming looks truncated — falling back to buffered audio.")
                }
                vlog("gemini streaming: fallback to buffered audio (\(context.bufferedAudio.count) buffers)")
                DispatchQueue.main.async {
                    onBatchFallback(context.bufferedAudio, context.duration)
                }
            }
        }
        return true
    }

    // MARK: - Stop (Muse)

    struct MuseStopContext {
        let duration: TimeInterval
        let hadSpeech: Bool
        let bufferedAudio: [AVAudioPCMBuffer]
        let streamTextEver: Bool
    }

    /// Handles Meta Muse streaming stop. Returns `true` when this path
    /// consumed the stop. Mirrors `handleStopGemini`.
    func handleStopMuse(
        context: MuseStopContext,
        onSilence: @escaping () -> Void,
        onStreamSuccess: @escaping (String) -> Void,
        onBatchFallback: @escaping ([AVAudioPCMBuffer], TimeInterval) -> Void
    ) -> Bool {
        guard let session = museSession else { return false }

        let everHad = context.streamTextEver
            || session.hasEverHadNonEmptyStreamText
            || coordinatorEverHadStreamText
        let bufferedSecs = Self.bufferedSeconds(context.bufferedAudio)
        let preFinalizeSnapshot = session.joinedTranscriptSnapshot()
        museSession = nil

        if Self.shouldTakeSilenceCancel(everHadStreamText: everHad, bufferedSeconds: bufferedSecs) {
            vlog("muse streaming: no speech — skipping (silence guard) everHad=\(everHad) buffers=\(context.bufferedAudio.count) bufferedSecs=\(String(format: "%.2f", bufferedSecs)) hadSpeech=\(context.hadSpeech)")
            session.cancel()
            onSilence()
            return true
        }

        if !context.hadSpeech {
            vlog("muse streaming: silence bypass — everHad=\(everHad) buffers=\(context.bufferedAudio.count)")
        }

        let releaseAt = Date()
        Task {
            let text = await session.finalize(recordingDuration: context.duration)
            vlog("muse streaming: finalize-at-release \(String(format: "%.3f", Date().timeIntervalSince(releaseAt)))s")
            if session.requiresBufferedAudioRecovery {
                self.logger.warning("Meta Muse streaming integrity failed — falling back to buffered audio.")
                DispatchQueue.main.async {
                    onBatchFallback(context.bufferedAudio, context.duration)
                }
                return
            }
            let truncated = Self.streamResultLooksTruncated(text: text, duration: context.duration)
                || Self.streamTextLooksAbruptlyCut(text)
            if truncated {
                vlog("muse streaming: truncated (\(text.count) chars / \(String(format: "%.1f", context.duration))s) — batch fallback")
            }
            if let success = Self.streamSuccessTextOrBatchFallback(
                finalizeText: text,
                preFinalizeSnapshot: preFinalizeSnapshot,
                duration: context.duration,
                truncated: truncated
            ) {
                if text.isEmpty || success.count > text.count {
                    vlog("muse streaming: recovered pre-finalize snapshot (\(success.count) chars)")
                }
                onStreamSuccess(success)
            } else {
                if text.isEmpty {
                    self.logger.warning("Meta Muse streaming produced no text — falling back to buffered audio.")
                } else {
                    self.logger.warning("Meta Muse streaming looks truncated — falling back to buffered audio.")
                }
                vlog("muse streaming: fallback to buffered audio (\(context.bufferedAudio.count) buffers)")
                DispatchQueue.main.async {
                    onBatchFallback(context.bufferedAudio, context.duration)
                }
            }
        }
        return true
    }

    // MARK: - Stop (WhisperKit)

    /// Handles WhisperKit streaming stop. Returns `true` when this path consumed the stop.
    func handleStopWhisperKit(
        onEmpty: @escaping () -> Void,
        onSuccess: @escaping (String) -> Void
    ) -> Bool {
        guard let session = whisperSession else { return false }

        whisperSession = nil
        let releaseAt = Date()
        Task {
            let text = await session.finalize()
            vlog("streaming: finalize-at-release total \(String(format: "%.3f", Date().timeIntervalSince(releaseAt)))s")
            guard !text.isEmpty else {
                self.logger.warning("Streaming session produced no text.")
                DispatchQueue.main.async { onEmpty() }
                return
            }
            onSuccess(text)
        }
        return true
    }
#endif

    static func streamResultLooksTruncated(text: String, duration: TimeInterval) -> Bool {
        guard duration >= streamTruncationCheckMinDuration else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return Double(trimmed.count) < duration * streamMinCharsPerSecond
    }

    /// True when live/finalize text has an incomplete ending (e.g.
    /// `…language that-` or `unfinished thought...`). These endings request
    /// buffered recovery even when transcript density appears normal.
    static func streamTextLooksAbruptlyCut(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }

        if trimmed.last == "-" {
            let hyphenIndex = trimmed.index(before: trimmed.endIndex)
            let beforeHyphen = trimmed[trimmed.index(before: hyphenIndex)]
            return beforeHyphen.isLetter || beforeHyphen.isNumber
        }

        // Closing quotes can follow punctuation emitted by the provider. Keep
        // this deliberately narrow: only quotes are skipped, so internal
        // ellipses and ordinary sentence punctuation remain successful text.
        let closingQuotes: Set<Character> = ["\"", "'", "”", "’"]
        var ending = trimmed[...]
        while let last = ending.last, closingQuotes.contains(last) {
            ending.removeLast()
        }
        guard ending.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        return ending.last == "…" || ending.hasSuffix("...")
    }
}
