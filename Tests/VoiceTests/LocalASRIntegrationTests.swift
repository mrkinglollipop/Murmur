import AVFoundation
import XCTest
@testable import Voice

/// End-to-end check that the **local** transcription path actually produces
/// text — the path shipped to users who never configure a cloud key.
///
/// Skipped unless the sentinel file `/tmp/.murmur-run-local-asr` exists, because
/// it loads a real multi-gigabyte CoreML model from
/// `Application Support/Voice/Models` and decodes audio — far too slow for the
/// normal suite:
///
///     touch /tmp/.murmur-run-local-asr
///     xcodebuild test -scheme VoiceTests -destination 'platform=macOS' \
///       CODE_SIGNING_ALLOWED=NO -only-testing:VoiceTests/LocalASRIntegrationTests
///     rm /tmp/.murmur-run-local-asr
///
/// A sentinel file rather than an environment variable on purpose: `xcodebuild`
/// does not forward the invoking shell's environment to the test runner process,
/// and the `TEST_RUNNER_`-prefixed form did not reach it either, so an env gate
/// silently skips instead of running.
///
/// The fixture is synthesised with macOS `say`, so the test never touches the
/// user's retained dictation audio and the expected transcript is known up
/// front. Model files are read, never written.
final class LocalASRIntegrationTests: XCTestCase {

    static let sentinelPath = "/tmp/.murmur-run-local-asr"

    private static let spokenText =
        "The quick brown fox jumps over the lazy dog near the riverbank."

    private var fixtureURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.sentinelPath),
            "Create \(Self.sentinelPath) to run the local ASR integration check."
        )
        fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-local-asr-\(UUID().uuidString).caf")
        try Self.synthesizeSpeech(Self.spokenText, to: fixtureURL)
    }

    override func tearDown() {
        if let fixtureURL {
            try? FileManager.default.removeItem(at: fixtureURL)
        }
        super.tearDown()
    }

    /// The default local model must be present, loadable from Application
    /// Support, and produce a transcript matching known input.
    func testDefaultLocalModelTranscribesKnownSpeech() async throws {
        let model = LocalModel.default
        let folder = try XCTUnwrap(
            ModelManager.modelFolderURL(for: model),
            "default local model has no WhisperKit folder mapping"
        )
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: folder.path),
            "\(model.displayName) is not downloaded — nothing to verify."
        )

        let engine = WhisperKitEngine(
            modelID: try XCTUnwrap(model.whisperKitModelID),
            displayName: model.displayName,
            localModel: model,
            language: "en"
        )

        let transcript = try await engine.transcribe(audioURL: fixtureURL)
        let lowered = transcript.lowercased()

        XCTAssertFalse(
            transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "local engine returned an empty transcript"
        )
        // Loose containment, not equality: Whisper punctuates and capitalises
        // on its own, and asserting an exact string would make this a flake.
        for phrase in ["quick brown fox", "lazy dog"] {
            XCTAssertTrue(
                lowered.contains(phrase),
                "expected \(phrase.debugDescription) in local transcript (got \(transcript.count) chars)"
            )
        }
    }

    /// Every *other* downloaded WhisperKit model must also transcribe
    /// correctly — users pick any of them in Settings, and "local works" has
    /// to mean the model they chose, not just the default. Models not on disk
    /// are skipped, so coverage automatically tracks what is downloaded.
    func testOtherDownloadedWhisperKitModelsTranscribeKnownSpeech() async throws {
        let others = LocalModel.allCases.filter {
            $0 != LocalModel.default && $0.whisperKitModelID != nil
        }
        var exercised: [String] = []
        for model in others {
            guard let folder = ModelManager.modelFolderURL(for: model),
                  FileManager.default.fileExists(atPath: folder.path) else { continue }

            let engine = WhisperKitEngine(
                modelID: try XCTUnwrap(model.whisperKitModelID),
                displayName: model.displayName,
                localModel: model,
                language: "en"
            )
            let transcript = try await engine.transcribe(audioURL: fixtureURL)
            let lowered = transcript.lowercased()
            for phrase in ["quick brown fox", "lazy dog"] {
                XCTAssertTrue(
                    lowered.contains(phrase),
                    "\(model.displayName): expected \(phrase.debugDescription) in transcript (got \(transcript.count) chars)"
                )
            }
            exercised.append(model.displayName)
        }
        try XCTSkipIf(
            exercised.isEmpty,
            "no non-default WhisperKit models downloaded — nothing further to verify"
        )
    }

    /// Whisper emits subtitle-style sound captions on ambiguous audio;
    /// `stripSoundAnnotations` is what keeps them out of the injected text, and
    /// it runs on every local transcription.
    func testSoundAnnotationStrippingLeavesRealSpeechIntact() {
        XCTAssertEqual(
            WhisperKitEngine.stripSoundAnnotations("[Music] hello there"),
            "hello there"
        )
        XCTAssertEqual(
            WhisperKitEngine.stripSoundAnnotations("*sighs* fix the parser"),
            "fix the parser"
        )
        XCTAssertEqual(
            WhisperKitEngine.stripSoundAnnotations("no annotations here"),
            "no annotations here"
        )
    }

    // MARK: - Fixture

    /// Renders `text` to a CAF via macOS `say`. 16 kHz mono matches what the
    /// ASR path consumes and keeps the fixture small.
    private static func synthesizeSpeech(_ text: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-o", url.path,
            "--data-format=LEF32@16000",
            text,
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("`say` could not produce a fixture (exit \(process.terminationStatus)).")
        }
    }
}
