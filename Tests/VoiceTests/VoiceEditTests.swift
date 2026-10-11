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
        let reloaded = SettingsStore(defaults: defaults, profileDirectory: directory, apiKeyLookup: { _ in nil })
        XCTAssertFalse(reloaded.voiceEditSelectedText)
    }
    func testSelectionExtraction_rejectsBothSurrogateBoundariesAndOverflowingLengths() {
        for (location, length) in [(0, 1), (1, 1), (1, 2), (0, -1), (0, Int.max), (Int.max, 1)] {
            let input = snapshot(value: "😀a", location: location, selectionLength: .readable(length))
            XCTAssertNil(VoiceEditRouting.selectedText(in: input))
            XCTAssertEqual(VoiceEditRouting.decide(snapshot: input, enabled: true, shiftHeld: false), .dictate)
        }
    }

    func testResultSanityChecksLengthAndSymbolsWithoutPreservingWords() {
        let selection = "Do not ship 4 units."
        let rewrite = "Deliver five crates."
        XCTAssertTrue(VoiceEditRouting.resultLooksUsable(rewrite, over: selection))
        XCTAssertFalse(TranscriptionPipeline.cleanupLooksSane(input: selection, output: rewrite))
        for invalid in ["", "  \n", "…😀!!!", "x", String(repeating: "x", count: selection.count * 2 + 1)] {
            XCTAssertFalse(VoiceEditRouting.resultLooksUsable(invalid, over: selection))
        }
        XCTAssertTrue(VoiceEditRouting.resultLooksUsable("12345", over: "abcdefghij"))
        XCTAssertTrue(VoiceEditRouting.resultLooksUsable("abcd", over: "abcdefghij"))
        XCTAssertTrue(VoiceEditRouting.resultLooksUsable(String(repeating: "x", count: 20), over: "abcdefghij"))
        XCTAssertFalse(VoiceEditRouting.resultLooksUsable("abc", over: "abcdefghij"))
    }

    func testSelectionRecheckRequiresReadableUnchangedValueAndExactRange() {
        let held = snapshot(value: "same same", location: 0, selectionLength: .readable(4))
        XCTAssertTrue(VoiceEditRouting.selectionMatches(held: held, fresh: held))
        for fresh in [
            CaretContext.Snapshot.unknown,
            snapshot(value: "same same", location: 0, selectionLength: .unreadable),
            snapshot(value: "same same", location: 0, selectionLength: .readable(0)),
            snapshot(value: "same same", location: 5, selectionLength: .readable(4)),
            snapshot(value: "same changed", location: 0, selectionLength: .readable(4)),
            snapshot(value: "else same", location: 0, selectionLength: .readable(4))
        ] {
            XCTAssertFalse(VoiceEditRouting.selectionMatches(held: held, fresh: fresh))
        }
        XCTAssertFalse(VoiceEditRouting.selectionMatches(held: nil, fresh: held))
    }

    @MainActor
    private func assertEditDelivery(
        result: String = "New words here.",
        fresh: CaretContext.Snapshot? = nil,
        currentPID: pid_t? = 42,
        secureInput: Bool = false,
        insertResult: TextInjector.InsertResult = .inserted(deliveredText: "New words here."),
        expectedOutcome: TranscriptionPipeline.InjectPipelineResult,
        expectedFailure: DictationFailure? = nil,
        expectedClipboard: String? = nil,
        expectedInsert: String? = nil,
        startNewHold: Bool = false
    ) {
        let pipeline = TranscriptionPipeline()
        let held = snapshot(value: "Old words here.", location: 0, selectionLength: .readable(15))
        let token = pipeline.test_holdVoiceEditSnapshot(held, frontmostPID: 42)
        var clipboard: String?
        var inserted: String?
        var failure: DictationFailure?
        var history: [HistoryEntry] = []
        pipeline.onTranscriptionLogged = { _, _, _, _, _, _ in XCTFail("An edit must not be logged as dictation") }
        pipeline.onVoiceEditLogged = { text, instruction, engine, injected, savedWithoutInsertion in
            history.append(HistoryEntry(text: text, engine: engine, injected: injected,
                savedWithoutInsertion: savedWithoutInsertion, kind: .edit, instruction: instruction))
        }
        pipeline.voiceEditInjectionHooks = .init(
            target: { .init(secureInput: secureInput, pid: currentPID, bundleIdentifier: "fixture") },
            snapshot: { fresh ?? held },
            insert: { text in inserted = text; return insertResult },
            leaveOnClipboard: { clipboard = $0 }
        )
        pipeline.runVoiceEditTransform = { instruction, selection, _ in
            XCTAssertEqual(instruction, "rewrite this")
            XCTAssertEqual(selection, "Old words here.")
            if startNewHold {
                await MainActor.run { _ = pipeline.test_holdSnapshot(held, frontmostPID: 42) }
            }
            return result
        }
        pipeline.onTranscription = { _, _ in XCTFail("Edit must bypass dictionary correction"); return ("", []) }
        pipeline.onSnippetExpand = { _ in XCTFail("Edit must bypass snippet expansion"); return "" }
        pipeline.onFailure = { failure = $0 }
        let completed = expectation(description: "edit delivery completed")
        pipeline.finishTranscription(
            text: "rewrite this",
            hadExplicitTrailingNewline: false,
            engineID: "fixture",
            audioPath: nil,
            replaceHistoryEntryID: nil,
            sessionHeldToken: token,
            sessionHeldSnapshot: held,
            sessionHeldFrontmostPID: 42,
            completion: { outcome in
                XCTAssertEqual(outcome, expectedOutcome)
                completed.fulfill()
            }
        )
        wait(for: [completed], timeout: 5)
        XCTAssertEqual(failure, expectedFailure)
        XCTAssertEqual(clipboard, expectedClipboard)
        XCTAssertEqual(inserted, expectedInsert)
        // Clipboard recovery still logs history when a newer hold suppresses notification.
        if expectedOutcome == .inserted || expectedClipboard != nil {
            XCTAssertEqual(history.count, 1)
            XCTAssertEqual(history.first?.text, result.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertEqual(history.first?.instruction, "rewrite this")
            XCTAssertEqual(history.first?.kind, .edit)
            XCTAssertEqual(history.first?.injected, expectedOutcome == .inserted)
            XCTAssertNil(history.first?.audioPath)
            let encoded = try? JSONEncoder().encode(history)
            XCTAssertFalse(encoded.flatMap { String(data: $0, encoding: .utf8) }?.contains("Old words here.") ?? true)
        } else {
            XCTAssertTrue(history.isEmpty)
        }
        if startNewHold { XCTAssertEqual(pipeline.test_heldCaretSnapshot, held) }
        else { XCTAssertNil(pipeline.test_heldCaretSnapshot) }
    }

    @MainActor
    func testEditDeliveryUnchangedSelectionUsesOneInjectAndPreservesRewrite() {
        assertEditDelivery(expectedOutcome: .inserted, expectedInsert: "New words here.")
    }

    @MainActor
    func testEditDeliveryChangedOrGoneSelectionLeavesResultOnClipboard() {
        for fresh in [
            snapshot(value: "Old words here.", location: 0, selectionLength: .readable(0)),
            snapshot(value: "New field text.", location: 0, selectionLength: .readable(15)),
            CaretContext.Snapshot.unknown
        ] {
            assertEditDelivery(fresh: fresh, expectedOutcome: .failed,
                expectedFailure: .injectionFailed, expectedClipboard: "New words here.")
        }
    }

    @MainActor
    func testEditDeliveryAppSwitchOrMissingPIDUsesClipboard() {
        for pid: pid_t? in [99, nil] {
            assertEditDelivery(currentPID: pid, expectedOutcome: .failed,
                expectedFailure: .injectionFailed, expectedClipboard: "New words here.")
        }
    }

    @MainActor
    func testEditDeliverySecureInputBlocksBothInjectAndClipboard() {
        assertEditDelivery(currentPID: 99, secureInput: true, expectedOutcome: .failed,
            expectedFailure: .secureInputBlocked)
    }

    @MainActor
    func testEditDeliveryEmptyOrRejectedResultLeavesSelectionUntouched() {
        for result in ["", "  \n", "!!!…😀", "x", String(repeating: "x", count: 31)] {
            assertEditDelivery(result: result, expectedOutcome: .failed, expectedFailure: .voiceEditFailed)
        }
        XCTAssertEqual(DictationFailure.voiceEditFailed.message, "Try rephrasing")
    }

    @MainActor
    func testEditDeliveryDedupeDoesNotReportASecondInsert() {
        assertEditDelivery(insertResult: .deduped, expectedOutcome: .deduped, expectedInsert: "New words here.")
    }

    @MainActor
    func testOlderEditCannotInjectOrNotifyOverANewerHold() {
        assertEditDelivery(expectedOutcome: .failed, expectedFailure: nil,
            expectedClipboard: "New words here.", startNewHold: true)
    }

    @MainActor
    func testOversizedSelectionRefusesWithoutTypingTheInstruction() {
        let pipeline = TranscriptionPipeline()
        let text = String(repeating: "x", count: 8_001)
        let held = snapshot(value: text, location: 0, selectionLength: .readable(8_001))
        let token = pipeline.test_holdVoiceEditSnapshot(held, frontmostPID: 42)
        pipeline.runVoiceEditTransform = { _, _, _ in XCTFail("Oversized selection must not reach a backend"); return "" }
        pipeline.onTranscription = { _, _ in XCTFail("Refusal must not become dictation"); return ("", []) }
        pipeline.onTranscriptionLogged = { _, _, _, _, _, _ in XCTFail("Refusal must not log the instruction") }
        pipeline.onFailure = { XCTAssertEqual($0, .voiceEditSelectionTooLong) }
        let completed = expectation(description: "oversized edit refused")
        pipeline.finishTranscription(text: "rewrite this", hadExplicitTrailingNewline: false,
            engineID: "fixture", audioPath: nil, replaceHistoryEntryID: nil,
            sessionHeldToken: token, sessionHeldSnapshot: held, sessionHeldFrontmostPID: 42,
            completion: { XCTAssertEqual($0, .failed); completed.fulfill() })
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(DictationFailure.voiceEditSelectionTooLong.message, "Selection too long")
    }

    private struct UnexpectedCleanup: TranscriptCleanupService {
        func cleanup(_ text: String, codeAware: Bool, styleInstruction: String?) async throws -> String {
            XCTFail("A spoken edit instruction must not pass through dictation cleanup")
            return text
        }
    }

    @MainActor
    func testStreamingEditPreservesInstructionAndUsesConfiguredCredentialsOnce() {
        let selector = ASREngineSelector()
        let pipeline = selector.pipeline
        pipeline.cleanupEnabled = true
        pipeline.codeAware = true
        pipeline.cleanupService = UnexpectedCleanup()
        selector.autoRunTransform = Transform(name: "Unexpected", prompt: "Do not run for an edit")
        var credentialReads = 0
        selector.transformCredentialsProvider = {
            credentialReads += 1
            return TransformCredentials(backend: .onDevice, openAIKey: "fixture-openai", xaiKey: "fixture-xai")
        }
        let held = snapshot(value: "Old words here.", location: 0, selectionLength: .readable(15))
        let token = pipeline.test_holdVoiceEditSnapshot(held, frontmostPID: 42)
        pipeline.runVoiceEditTransform = { instruction, selection, credentials in
            XCTAssertEqual(instruction, "put dot and new line into this text")
            XCTAssertEqual(selection, "Old words here.")
            XCTAssertEqual(credentials.backend, .onDevice)
            XCTAssertEqual(credentials.openAIKey, "fixture-openai")
            XCTAssertEqual(credentials.xaiKey, "fixture-xai")
            return ""
        }
        let completed = expectation(description: "streamed edit completed")
        pipeline.onFailure = { XCTAssertEqual($0, .voiceEditFailed) }
        pipeline.logStreamedTranscription(text: "put dot and new line into this text", engineID: "fixture",
            sessionHeldToken: token, sessionHeldSnapshot: held, sessionHeldFrontmostPID: 42,
            completion: { XCTAssertEqual($0, .failed); completed.fulfill() })
        wait(for: [completed], timeout: 5)
        XCTAssertEqual(credentialReads, 1)
        XCTAssertEqual(TransformRunner.orderedBackends(preferring: .onDevice), [.onDevice])
    }

    func testInjectorRejectsTargetSwitchAfterSelectionRecheckWithoutPostingEvents() {
        let pasteboard = NSPasteboard(name: .init("murmur.voice-edit.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let injector = TextInjector(hooks: .init(
            pasteboard: pasteboard,
            target: { .init(secureInput: false, pid: 99, bundleIdentifier: "fixture") },
            createObserver: { XCTFail("Target mismatch must not create an event tap"); return nil },
            postUnicode: { _ in XCTFail("Target mismatch must not type"); return 0 },
            postPasteChord: { XCTFail("Target mismatch must not paste"); return false },
            postCanary: { XCTFail("Target mismatch must not probe"); return false },
            waitForConfirmation: { _, _ in XCTFail("Target mismatch has no delivery to confirm"); return 0 }
        ))
        XCTAssertEqual(injector.insert("New words here.", expectedTargetPID: 42), .failed)
        XCTAssertEqual(pasteboard.string(forType: .string), "New words here.")
    }

    func testEditHistoryRoundTripStoresResultInstructionAndKind() throws {
        let entry = HistoryEntry(date: Date(timeIntervalSince1970: 12_345), text: "Rewritten result.",
            engine: "fixture", injected: true, kind: .edit, instruction: "Make this shorter")
        let data = try JSONEncoder().encode(entry)
        XCTAssertEqual(try JSONDecoder().decode(HistoryEntry.self, from: data), entry)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "Edit")
        XCTAssertEqual(object["text"] as? String, "Rewritten result.")
        XCTAssertEqual(object["instruction"] as? String, "Make this shorter")
    }

    func testLegacyHistoryDecodesWithoutInstructionOrKind() throws {
        let entry = HistoryEntry(date: Date(timeIntervalSince1970: 12_345), text: "Old dictation.",
            engine: "fixture", injected: true)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        object.removeValue(forKey: "instruction")
        object.removeValue(forKey: "kind")
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.instruction)
        XCTAssertEqual(decoded.kind, .dictation)
        XCTAssertEqual(try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(decoded)), decoded)
    }

    @MainActor
    func testEditHistoryPersistsInInjectedDirectoryAndCountsAsADictation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.json")
        let store = HistoryStore(fileURL: fileURL)
        store.append(text: "Dictated text", engine: "fixture", injected: true)
        store.append(text: "New edited result", engine: "fixture", injected: false,
            kind: .edit, instruction: "Rewrite this")
        store.flush()
        let reloaded = HistoryStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.entries.count, 2)
        XCTAssertEqual(reloaded.entries.first?.kind, .edit)
        XCTAssertEqual(reloaded.entries.first?.instruction, "Rewrite this")
        XCTAssertEqual(reloaded.entries.first?.text, "New edited result")
        XCTAssertNil(reloaded.entries.first?.audioPath)
        XCTAssertEqual(reloaded.entries.reduce(0) { $0 + InsightsView.metricsWordCount($1.text) }, 5)
    }

    @MainActor
    func testAbandonedEditSavesOnlyItsResultAndInstructionWithoutInjection() {
        let pipeline = TranscriptionPipeline()
        let held = snapshot(value: "Old words here.", location: 0, selectionLength: .readable(15))
        let token = pipeline.test_holdVoiceEditSnapshot(held, frontmostPID: 42)
        pipeline.markHoldAbandoned(token)
        pipeline.runVoiceEditTransform = { _, _, _ in "New words here." }
        pipeline.voiceEditInjectionHooks = .init(
            target: { XCTFail("Abandoned edit must not sample an injection target"); return .init(secureInput: false, pid: 42, bundleIdentifier: "fixture") },
            snapshot: { XCTFail("Abandoned edit must not re-read AX"); return held },
            insert: { _ in XCTFail("Abandoned edit must not type"); return .failed },
            leaveOnClipboard: { _ in XCTFail("Abandoned edit must not overwrite clipboard") }
        )
        pipeline.onTranscriptionLogged = { _, _, _, _, _, _ in XCTFail("Edit must not log as dictation") }
        pipeline.onAbandonedHoldSaved = { _, _, _ in XCTFail("Edit must use its typed history hook") }
        let logged = expectation(description: "abandoned edit logged")
        pipeline.onVoiceEditLogged = { result, instruction, engine, injected, savedWithoutInsertion in
            XCTAssertEqual(result, "New words here.")
            XCTAssertEqual(instruction, "rewrite this")
            XCTAssertEqual(engine, "fixture")
            XCTAssertFalse(injected)
            XCTAssertTrue(savedWithoutInsertion)
            logged.fulfill()
        }
        let completed = expectation(description: "abandoned edit completed")
        pipeline.finishTranscription(text: "rewrite this", hadExplicitTrailingNewline: false,
            engineID: "fixture", audioPath: nil, replaceHistoryEntryID: nil,
            sessionHeldToken: token, sessionHeldSnapshot: held, sessionHeldFrontmostPID: 42,
            completion: { XCTAssertEqual($0, .savedToHistory); completed.fulfill() })
        wait(for: [logged, completed], timeout: 5)
        XCTAssertNil(pipeline.test_heldCaretSnapshot)
        XCTAssertFalse(pipeline.test_abandonedHoldTokens.contains(token))
    }

    @MainActor
    func testEmptyEditInstructionDoesNotTransformInjectOrLog() {
        let pipeline = TranscriptionPipeline()
        let held = snapshot(value: "Old words here.", location: 0, selectionLength: .readable(15))
        let token = pipeline.test_holdVoiceEditSnapshot(held, frontmostPID: 42)
        pipeline.runVoiceEditTransform = { _, _, _ in XCTFail("Empty instruction must not reach a backend"); return "" }
        pipeline.onTranscriptionLogged = { _, _, _, _, _, _ in XCTFail("Empty instruction must not enter History") }
        pipeline.onVoiceEditLogged = { _, _, _, _, _ in XCTFail("Empty instruction has no edit result to store") }
        pipeline.onFailure = { XCTAssertEqual($0, .voiceEditFailed) }
        let completed = expectation(description: "empty edit completed")
        pipeline.finishTranscription(text: "  \n", hadExplicitTrailingNewline: false,
            engineID: "fixture", audioPath: nil, replaceHistoryEntryID: nil,
            sessionHeldToken: token, sessionHeldSnapshot: held, sessionHeldFrontmostPID: 42,
            completion: { XCTAssertEqual($0, .failed); completed.fulfill() })
        wait(for: [completed], timeout: 2)
    }

}
