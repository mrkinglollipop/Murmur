import Foundation
import Carbon
import os.log

/// Post-ASR pipeline: cleanup → dictionary-correct → snippet-expand → inject → history.
/// `ASREngineSelector` owns engine cache/factory and delegates transcription
/// completion work here so the selector stays focused on engine selection.
final class TranscriptionPipeline {

    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "transcription-pipeline")

    /// Resolves engines and cloud settings from the owning selector.
    weak var engineSelector: ASREngineSelector?

    /// Master on/off for the AI cleanup pass.
    var cleanupEnabled: Bool = false

    /// Whether cleanup should use the code-aware prompt variant.
    var codeAware: Bool = false

    /// When true, prepends a leading space before injection when the caret
    /// context warrants it (sentence continuation after alphanumeric/punctuation).
    var smartLeadingSpaceEnabled: Bool = true

    /// Active Style profile formality instruction for cleanup.
    var styleInstruction: String?

    /// Active cleanup backend, or `nil` if cleanup can't run right now.
    var cleanupService: TranscriptCleanupService?

    /// Dictionary-correction hook — applied BEFORE injection and history.
    var onTranscription: ((String, String) -> (String, [CorrectionRecord]))?

    /// Snippet-expansion hook — applied after dictionary correction.
    var onSnippetExpand: ((String) -> String)?

    /// History-logging hook with the final expanded text.
    /// Sixth arg is optional history entry ID to replace (retry path).
    var onTranscriptionLogged: ((String, String, Bool, String?, Bool, UUID?) -> Void)?

    /// Fired on the main thread after a confirmed insert with the delivered text
    /// (for inline correction watching). Not called for dedupe or failed inserts.
    var onTextInserted: ((String) -> Void)?

    /// Invoked on the main thread when dictionary/phonetic corrections fire.
    var onCorrectionsRecorded: (([CorrectionRecord]) -> Void)?

    /// Terminal failure hook (transcription, injection, audio capture).
    var onFailure: ((DictationFailure) -> Void)?

    /// Transcribes the audio file with the selected engine, applies dictionary
    /// correction, injects, and logs to history — the full pipeline for one
    /// completed dictation.
    /// - Parameter replaceHistoryEntryID: when set, history updates that row
    ///   instead of appending (failed-entry retry); concurrent live dictation
    ///   leaves this nil so retries never steal a live append.
    func transcribeAndLog(
        audioURL: URL,
        replaceHistoryEntryID: UUID? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard let selector = engineSelector else {
            completion?(false)
            return
        }

        let audioPath = audioURL.path
        let replaceID = replaceHistoryEntryID
        if let cloudModel = selector.cloudModel,
           let key = selector.apiKeyProvider?(cloudModel.provider),
           !key.isEmpty {
            let engineTag = "cloud:\(cloudModel.provider.rawValue)"
            logger.info("Transcribing \(audioURL.lastPathComponent) with cloud engine '\(engineTag)'")

            Task {
                do {
                    let service = CloudTranscriberFactory.service(for: cloudModel)
                    let text = try await service.transcribe(
                        audioURL: audioURL,
                        apiKey: key,
                        model: cloudModel,
                        language: selector.selectedLanguage
                    )
                    let cleaned = await self.applyCleanup(text)
                    let transformed = await self.applyAutoTransform(cleaned)
                    self.finishTranscription(
                        text: transformed,
                        engineID: engineTag,
                        audioPath: audioPath,
                        replaceHistoryEntryID: replaceID,
                        completion: completion
                    )
                } catch {
                    self.logger.error("Cloud transcription failed [\(engineTag)]: \(error.localizedDescription)")
                    vlog("cloud transcription error [\(engineTag)]: \(error.localizedDescription) — falling back to local")
                    self.transcribeLocally(
                        audioURL: audioURL,
                        audioPath: audioPath,
                        replaceHistoryEntryID: replaceID,
                        completion: completion
                    )
                }
            }
            return
        }

        transcribeLocally(
            audioURL: audioURL,
            audioPath: audioPath,
            replaceHistoryEntryID: replaceID,
            completion: completion
        )
    }

    /// Streaming entry point: takes text already produced by a live session.
    func logStreamedTranscription(text: String, engineID: String, completion: ((Bool) -> Void)? = nil) {
        Task {
            let cleaned = await self.applyCleanup(text)
            let transformed = await self.applyAutoTransform(cleaned)
            self.finishTranscription(
                text: transformed,
                engineID: engineID,
                audioPath: nil,
                replaceHistoryEntryID: nil,
                completion: completion
            )
        }
    }

    private func transcribeLocally(
        audioURL: URL,
        audioPath: String,
        replaceHistoryEntryID: UUID?,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard let selector = engineSelector else {
            completion?(false)
            return
        }

        let engine = selector.makeEngine()
        logger.info("Transcribing \(audioURL.lastPathComponent) with engine '\(engine.id)'")

        Task {
            do {
                let text = try await engine.transcribe(audioURL: audioURL)
                let cleaned = await self.applyCleanup(text)
                let transformed = await self.applyAutoTransform(cleaned)
                self.finishTranscription(
                    text: transformed,
                    engineID: engine.id,
                    audioPath: audioPath,
                    replaceHistoryEntryID: replaceHistoryEntryID,
                    completion: completion
                )
            } catch {
                self.logger.error("Transcription failed [\(engine.id)]: \(error.localizedDescription)")
                vlog("transcription error [\(engine.id)]: \(error.localizedDescription)")
                self.reportTranscriptionFailure(
                    engineID: engine.id,
                    audioPath: audioPath,
                    replaceHistoryEntryID: replaceHistoryEntryID,
                    completion: completion
                )
            }
        }
    }

    private func reportTranscriptionFailure(
        engineID: String,
        audioPath: String,
        replaceHistoryEntryID: UUID?,
        completion: ((Bool) -> Void)?
    ) {
        DispatchQueue.main.async {
            self.onFailure?(.transcriptionFailed)
            self.onTranscriptionLogged?("", engineID, false, audioPath, true, replaceHistoryEntryID)
            completion?(false)
        }
    }

    /// Caps always, then SpokenPunctuation (codeAware), then DotCompound.
    /// Package-visible for pipeline-gate unit tests. Caps is not gated on
    /// codeAware or cleanup.
    static func preprocessBeforeCleanup(_ text: String, codeAware: Bool) -> String {
        let capped = SpokenCapitalization.apply(text)
        return DotCompoundNumberNormalizer.apply(
            codeAware ? SpokenPunctuation.apply(capped) : capped
        )
    }

    private func applyCleanup(_ text: String) async -> String {
        let preprocessed = Self.preprocessBeforeCleanup(text, codeAware: codeAware)
        guard cleanupEnabled, let svc = cleanupService, !preprocessed.isEmpty else { return preprocessed }

        let wordCount = preprocessed.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
        guard wordCount > 3 else {
            vlog("cleanup skipped — short input (\(wordCount) words)")
            return preprocessed
        }

        let cleanupStart = Date()
        do {
            let cleaned = try await svc.cleanup(preprocessed, codeAware: codeAware, styleInstruction: styleInstruction)
            vlog("cleanup \(String(format: "%.2f", Date().timeIntervalSince(cleanupStart)))s")
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return preprocessed }
            guard Self.cleanupLooksSane(input: preprocessed, output: trimmed) else {
                vlog("cleanup rejected — output diverged from input (likely answered); using raw")
                return preprocessed
            }
            // Cleanup sometimes re-expands joined identifiers (`conduct.mdc` →
            // `conduct dot mdc`) and cleanupLooksSane accepts that. Re-run the
            // deterministic pass so spoken punctuation wins last.
            // Post-SP only on successful cleanup; Caps does not re-run here.
            return codeAware ? SpokenPunctuation.apply(trimmed) : trimmed
        } catch {
            vlog("cleanup failed: \(error.localizedDescription) — using raw")
            return preprocessed
        }
    }

    private func applyAutoTransform(_ text: String) async -> String {
        guard let transform = engineSelector?.autoRunTransform else { return text }
        do {
            let result = try await TransformRunner.run(
                prompt: transform.prompt,
                over: text,
                openAIKey: engineSelector?.openAIKeyProvider?()
            )
            return result.isEmpty ? text : result
        } catch {
            vlog("auto-run transform failed: \(error.localizedDescription) — using pre-transform text")
            return text
        }
    }

    static func cleanupLooksSane(input: String, output: String) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { !$0.isEmpty }
        }
        let inWords = Set(words(input))
        let outWords = words(output)
        guard !outWords.isEmpty, !inWords.isEmpty else { return true }

        let ratio = Double(output.count) / Double(max(input.count, 1))
        if ratio > 2.0 || ratio < 0.4 { return false }

        let newWords = outWords.filter { !inWords.contains($0) }
        return Double(newWords.count) / Double(outWords.count) <= 0.4
    }

    private func finishTranscription(
        text: String,
        engineID: String,
        audioPath: String?,
        replaceHistoryEntryID: UUID?,
        completion: ((Bool) -> Void)?
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.logger.info("Transcribed \(trimmed.count) chars with engine '\(engineID)'")
        vlog("transcribed \(trimmed.count) chars [\(engineID)]")

        guard !trimmed.isEmpty else {
            DispatchQueue.main.async {
                self.onFailure?(.transcriptionFailed)
                if let audioPath {
                    self.onTranscriptionLogged?("", engineID, false, audioPath, true, replaceHistoryEntryID)
                }
                completion?(false)
            }
            return
        }

        DispatchQueue.main.async {
            let (corrected, records) = self.onTranscription?(trimmed, engineID) ?? (trimmed, [])
            if !records.isEmpty { self.onCorrectionsRecorded?(records) }
            let expanded = self.onSnippetExpand?(corrected) ?? corrected
            let secureInput = IsSecureEventInputEnabled()

            // Insert blocks up to ~1s (event delivery + confirmation waits) —
            // run it off-main so HUD animations don't stall. Only the
            // completion (which drives finishHUDAfterPipeline) hops back to
            // main; correction/snippet steps above stay on main as before.
            DispatchQueue.global(qos: .utility).async {
                let textToInject: String
                if !secureInput && self.smartLeadingSpaceEnabled {
                    let precedingChar = CaretContext.precedingCharacter()
                    let shouldPrepend = CaretContext.shouldPrependSpace(
                        precedingChar: precedingChar,
                        transcriptFirstChar: expanded.first
                    )
                    textToInject = shouldPrepend ? " " + expanded : expanded
                } else {
                    textToInject = expanded
                }
                let insertResult = secureInput ? TextInjector.InsertResult.failed : TextInjector().insert(textToInject)
                let injected = insertResult.wasInjectedForHistory
                if case .inserted(let delivered) = insertResult {
                    let notify = self.onTextInserted
                    DispatchQueue.main.async {
                        notify?(delivered)
                    }
                }
                DispatchQueue.main.async {
                    let outcome = Self.secureInputOutcome(secureInput: secureInput, injected: injected)
                    if outcome.shouldLog {
                        // Keep retained file path on success when present so history
                        // retry remains possible (same path as failure retention).
                        self.onTranscriptionLogged?(expanded, engineID, injected, audioPath, false, replaceHistoryEntryID)
                    }
                    if let failure = outcome.failure {
                        self.onFailure?(failure)
                    }

                    completion?(injected)
                }
            }
        }
    }

    /// Pure decision seam for the secure-input / history-logging outcome at
    /// finish time — extracted so it can be exercised in unit tests, since
    /// `IsSecureEventInputEnabled` (Carbon) cannot be forced on in a test.
    ///
    /// - `secureInput == true`: never log (transcript may contain a
    ///   password), always surface `.secureInputBlocked`.
    /// - `secureInput == false, injected == false`: log (nothing secret was
    ///   suppressed), surface `.injectionFailed`.
    /// - `secureInput == false, injected == true`: log, no failure.
    static func secureInputOutcome(secureInput: Bool, injected: Bool)
        -> (shouldLog: Bool, failure: DictationFailure?)
    {
        if secureInput {
            return (false, .secureInputBlocked)
        }
        return (true, injected ? nil : .injectionFailed)
    }
}
