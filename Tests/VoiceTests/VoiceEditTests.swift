import ApplicationServices
import XCTest
@testable import Voice

final class VoiceEditTests: XCTestCase {

    private func snapshot(
        value: String,
        location: Int,
        selectionLength: CaretContext.SelectionLength
    ) -> CaretContext.Snapshot {
        CaretContext.Snapshot(
            value: value,
            location: location,
            selectionLength: selectionLength,
            precedingChar: .startOfField,
            isUnknown: false
        )
    }

    func testRouting_editsReadableNonemptySelectionWhenEnabled() {
        let input = snapshot(value: "make this concise", location: 5, selectionLength: .readable(4))

        XCTAssertEqual(
            VoiceEditRouting.decide(snapshot: input, enabled: true, shiftHeld: false),
            .edit(selection: "this")
        )
    }

    func testRouting_shiftAndDisabledToggleDictateOverSelection() {
        let input = snapshot(value: "selected text", location: 0, selectionLength: .readable(8))

        XCTAssertEqual(VoiceEditRouting.decide(snapshot: input, enabled: false, shiftHeld: false), .dictate)
        XCTAssertEqual(VoiceEditRouting.decide(snapshot: input, enabled: true, shiftHeld: true), .dictate)
    }

    func testRouting_rejectsUnreadableEmptyAndOversizedSelections() {
        XCTAssertEqual(
            VoiceEditRouting.decide(
                snapshot: snapshot(value: "text", location: 0, selectionLength: .unreadable),
                enabled: true,
                shiftHeld: false
            ),
            .dictate
        )
        XCTAssertEqual(
            VoiceEditRouting.decide(
                snapshot: snapshot(value: "text", location: 0, selectionLength: .readable(0)),
                enabled: true,
                shiftHeld: false
            ),
            .dictate
        )
        let longText = String(repeating: "x", count: VoiceEditRouting.maximumSelectionUTF16Length + 1)
        XCTAssertEqual(
            VoiceEditRouting.decide(
                snapshot: snapshot(value: longText, location: 0, selectionLength: .readable(longText.utf16.count)),
                enabled: true,
                shiftHeld: false
            ),
            .selectionTooLong(utf16Count: VoiceEditRouting.maximumSelectionUTF16Length + 1)
        )
    }

    func testRouting_respectsExactUTF16LimitIncludingEmoji() {
        let atLimit = String(repeating: "😀", count: 4_000)
        XCTAssertEqual(atLimit.utf16.count, VoiceEditRouting.maximumSelectionUTF16Length)
        let atLimitDecision = VoiceEditRouting.decide(
            snapshot: snapshot(value: atLimit, location: 0, selectionLength: .readable(atLimit.utf16.count)),
            enabled: true,
            shiftHeld: false
        )
        guard case .edit(let selected) = atLimitDecision else {
            return XCTFail("An exact 8,000 UTF-16 selection should be editable")
        }
        XCTAssertEqual(selected.utf16.count, VoiceEditRouting.maximumSelectionUTF16Length)

        let overLimit = atLimit + "x"
        XCTAssertEqual(
            VoiceEditRouting.decide(
                snapshot: snapshot(value: overLimit, location: 0, selectionLength: .readable(overLimit.utf16.count)),
                enabled: true,
                shiftHeld: false
            ),
            .selectionTooLong(utf16Count: VoiceEditRouting.maximumSelectionUTF16Length + 1)
        )
    }

    func testSelectionExtraction_usesUTF16RangeWithoutSplittingEmoji() {
        let value = "A 👩🏽‍💻 B"
        let nsValue = value as NSString
        let emojiRange = nsValue.range(of: "👩🏽‍💻")
        let input = snapshot(value: value, location: emojiRange.location, selectionLength: .readable(emojiRange.length))

        XCTAssertEqual(VoiceEditRouting.selectedText(in: input), "👩🏽‍💻")
        XCTAssertEqual(
            VoiceEditRouting.selectedText(
                in: snapshot(value: value, location: emojiRange.location + 1, selectionLength: .readable(1))
            ),
            nil
        )
    }

    func testSelectionExtraction_allowsAComposedGraphemeToBeSplitAtScalarBoundary() {
        let value = "e\u{301}"
        XCTAssertEqual(
            VoiceEditRouting.selectedText(
                in: snapshot(value: value, location: 1, selectionLength: .readable(1))
            ),
            "\u{301}"
        )
    }

    func testSelectionExtraction_rejectsUnreadableEmptyUnknownAndInvalidRanges() {
        XCTAssertNil(
            VoiceEditRouting.selectedText(
                in: snapshot(value: "text", location: 0, selectionLength: .unreadable)
            )
        )
        XCTAssertNil(
            VoiceEditRouting.selectedText(
                in: snapshot(value: "text", location: 0, selectionLength: .readable(0))
            )
        )
        XCTAssertNil(
            VoiceEditRouting.selectedText(
                in: snapshot(value: "text", location: -1, selectionLength: .readable(1))
            )
        )
        XCTAssertNil(
            VoiceEditRouting.selectedText(
                in: snapshot(value: "text", location: 3, selectionLength: .readable(2))
            )
        )
        XCTAssertNil(VoiceEditRouting.selectedText(in: .unknown))
    }

    func testShiftDetectionReadsExistingActivationFlags() {
        XCTAssertTrue(ActivationController.isShiftHeld([.maskShift, .maskSecondaryFn]))
        XCTAssertFalse(ActivationController.isShiftHeld([.maskSecondaryFn]))
    }

    func testHUDState_preservesEditingSelectionAnnouncement() {
        XCTAssertEqual(RecordingHUD.State.editingSelection.accessibilityAnnouncement, "Editing selection")
        XCTAssertEqual(RecordingHUD.State.editingSelection.visibleLabel, "Editing selection")
        XCTAssertEqual(RecordingHUD.State.listening.accessibilityAnnouncement, "Listening")
        XCTAssertEqual(RecordingHUD.State.processing.accessibilityAnnouncement, "Transcribing")
    }

    @MainActor
    func testVoiceEditReleaseFailsClosedBeforeDictationOrInjection() {
        let pipeline = TranscriptionPipeline()
        let token = pipeline.test_holdVoiceEditSnapshot(
            snapshot(value: "selected text", location: 0, selectionLength: .readable(8))
        )
        let failure = expectation(description: "voice edit fails closed")
        pipeline.runVoiceEditTransform = { instruction, selected, credentials in
            XCTAssertEqual(instruction, "make it shorter")
            XCTAssertEqual(selected, "selected")
            XCTAssertEqual(credentials.backend, .onDevice)
            throw TransformRunnerError.emptyResponse
        }
        pipeline.onTranscription = { _, _ in
            XCTFail("An edit instruction must not enter ordinary dictation")
            return ("", [])
        }
        pipeline.onFailure = { reason in
            XCTAssertEqual(reason, .voiceEditFailed)
            failure.fulfill()
        }

        pipeline.finishTranscription(
            text: "make it shorter",
            hadExplicitTrailingNewline: false,
            engineID: "fixture",
            audioPath: nil,
            replaceHistoryEntryID: nil,
            sessionHeldToken: token,
            sessionHeldSnapshot: pipeline.test_heldCaretSnapshot,
            sessionHeldFrontmostPID: nil,
            completion: { result in XCTAssertEqual(result, .failed) }
        )
        wait(for: [failure], timeout: 1)
    }

    @MainActor
    func testVoiceEditSettingDefaultsOnAndUsesInjectedDefaults() throws {
        let suite = "murmur.voice-edit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SettingsStore(defaults: defaults, profileDirectory: directory, apiKeyLookup: { _ in nil })
        XCTAssertTrue(store.voiceEditSelectedText)
        store.voiceEditSelectedText = false
        XCTAssertFalse(defaults.bool(forKey: "voice.settings.voiceEditSelectedText"))
    }
}
