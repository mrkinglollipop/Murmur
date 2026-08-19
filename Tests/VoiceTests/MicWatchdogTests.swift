import XCTest
import AudioToolbox
import CoreAudio
@testable import Voice

/// Decision logic for the mic zero-buffer watchdog and dead-format probe —
/// the guards behind the post-route-change wedge fix (a dictation hold whose
/// engine "started" but whose tap delivered zero buffers, observed 2026-08-09
/// as `max RMS 0.0000 … buffers=0` after another app's voice session).
final class MicWatchdogTests: XCTestCase {

    // MARK: - Dead-mic reporting
    //
    // A wedged input device (another app taking Sound input — observed
    // 2026-08-11 with Jump Desktop) delivers zero buffers while the engine and
    // socket both report success. The RMS silence guard cannot tell that from
    // a quiet room, so the hold used to be discarded with no visible sign.

    func testReportsDeadMicWhenNoBuffersOverARealHold() {
        XCTAssertTrue(AudioRecorder.shouldReportDeadMic(buffersSeen: 0, holdDuration: 3.0))
    }

    func testDeadMicBoundaryIsInclusive() {
        XCTAssertTrue(AudioRecorder.shouldReportDeadMic(buffersSeen: 0, holdDuration: 1.0))
    }

    /// 0.1.32 shipped a floor so an accidental split-second tap is ignored
    /// rather than erroring. A dead-mic report must not undo that.
    func testAccidentalTapStaysSilent() {
        XCTAssertFalse(AudioRecorder.shouldReportDeadMic(buffersSeen: 0, holdDuration: 0.2))
        XCTAssertFalse(AudioRecorder.shouldReportDeadMic(buffersSeen: 0, holdDuration: 0.9))
    }

    /// Buffers arrived and were merely quiet — that is the silence guard's
    /// job, and it must stay silent.
    func testQuietRoomIsNotReportedAsDeadMic() {
        XCTAssertFalse(AudioRecorder.shouldReportDeadMic(buffersSeen: 42, holdDuration: 3.0))
    }

    func testRestartsWhenTakeLiveAndNoBuffers() {
        XCTAssertTrue(
            AudioRecorder.watchdogShouldRestartCapture(
                generationMatches: true,
                stillWanted: true,
                tapInstalled: true,
                buffersSeen: 0,
                alreadyRetried: false
            )
        )
    }

    func testNoRestartOnceBuffersFlow() {
        XCTAssertFalse(
            AudioRecorder.watchdogShouldRestartCapture(
                generationMatches: true,
                stillWanted: true,
                tapInstalled: true,
                buffersSeen: 5,
                alreadyRetried: false
            )
        )
    }

    func testNoRestartForStaleGeneration() {
        XCTAssertFalse(
            AudioRecorder.watchdogShouldRestartCapture(
                generationMatches: false,
                stillWanted: true,
                tapInstalled: true,
                buffersSeen: 0,
                alreadyRetried: false
            )
        )
    }

    func testNoRestartAfterHoldReleased() {
        XCTAssertFalse(
            AudioRecorder.watchdogShouldRestartCapture(
                generationMatches: true,
                stillWanted: false,
                tapInstalled: true,
                buffersSeen: 0,
                alreadyRetried: false
            )
        )
    }

    func testNoRestartWithTapAlreadyTornDown() {
        XCTAssertFalse(
            AudioRecorder.watchdogShouldRestartCapture(
                generationMatches: true,
                stillWanted: true,
                tapInstalled: false,
                buffersSeen: 0,
                alreadyRetried: false
            )
        )
    }

    func testSingleRetryPerHold() {
        XCTAssertFalse(
            AudioRecorder.watchdogShouldRestartCapture(
                generationMatches: true,
                stillWanted: true,
                tapInstalled: true,
                buffersSeen: 0,
                alreadyRetried: true
            )
        )
    }

    // MARK: - Mid-hold configuration-change restart

    func testConfigChangeRestartsMidHold() {
        XCTAssertTrue(
            AudioRecorder.shouldRestartCaptureOnConfigChange(
                stillWanted: true, tapInstalled: true, alreadyRetried: false, startInFlight: false
            )
        )
    }

    func testConfigChangeOnlyFlagsWhenIdle() {
        XCTAssertFalse(
            AudioRecorder.shouldRestartCaptureOnConfigChange(
                stillWanted: false, tapInstalled: false, alreadyRetried: false, startInFlight: false
            )
        )
    }

    func testConfigChangeRespectsSharedRetryBudget() {
        XCTAssertFalse(
            AudioRecorder.shouldRestartCaptureOnConfigChange(
                stillWanted: true, tapInstalled: true, alreadyRetried: true, startInFlight: false
            )
        )
    }

    func testConfigChangeDoesNotRestartAfterTeardown() {
        XCTAssertFalse(
            AudioRecorder.shouldRestartCaptureOnConfigChange(
                stillWanted: true, tapInstalled: false, alreadyRetried: false, startInFlight: false
            )
        )
    }

    /// Tap is installed (`isSetUp`) before off-main `engine.start()` returns.
    /// Config-change must not teardown+restart while that start is pending.
    func testConfigChangeDoesNotRestartWhileStartInFlight() {
        XCTAssertFalse(
            AudioRecorder.shouldRestartCaptureOnConfigChange(
                stillWanted: true, tapInstalled: true, alreadyRetried: false, startInFlight: true
            )
        )
    }

    // MARK: - Model-load deadline

    func testDeadlineReturnsValueWhenOperationFinishesFirst() async throws {
        let value = try await WhisperKitEngine.withDeadline(
            5,
            timeoutError: { WhisperKitEngineError.modelLoadTimedOut("test", 5) },
            operation: { "loaded" }
        )
        XCTAssertEqual(value, "loaded")
    }

    func testDeadlineThrowsWhenOperationParksForever() async {
        do {
            _ = try await WhisperKitEngine.withDeadline(
                0.1,
                timeoutError: { WhisperKitEngineError.modelLoadTimedOut("test-model", 0.1) },
                operation: { () -> String in
                    // Parked await that honors cancellation, standing in for a
                    // model load that never returns.
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    return "never"
                }
            )
            XCTFail("expected modelLoadTimedOut")
        } catch let error as WhisperKitEngineError {
            guard case .modelLoadTimedOut(let name, _) = error else {
                XCTFail("wrong case: \(error)")
                return
            }
            XCTAssertEqual(name, "test-model")
            XCTAssertTrue(error.localizedDescription.contains("retry"), "user-facing message must mention retry")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testDeadFormatDetection() {
        XCTAssertTrue(AudioRecorder.inputFormatLooksDead(sampleRate: 0, channelCount: 1))
        XCTAssertTrue(AudioRecorder.inputFormatLooksDead(sampleRate: 48_000, channelCount: 0))
        XCTAssertTrue(AudioRecorder.inputFormatLooksDead(sampleRate: 0, channelCount: 0))
        XCTAssertFalse(AudioRecorder.inputFormatLooksDead(sampleRate: 48_000, channelCount: 1))
        XCTAssertFalse(AudioRecorder.inputFormatLooksDead(sampleRate: 16_000, channelCount: 2))
    }

    func testGhostInputStatusIsNopeAndBadObject() {
        XCTAssertTrue(AudioRecorder.isGhostInputStartStatus(kAudioHardwareBadDeviceError))
        XCTAssertTrue(AudioRecorder.isGhostInputStartStatus(kAudioHardwareBadObjectError))
        XCTAssertFalse(AudioRecorder.isGhostInputStartStatus(noErr))
        XCTAssertFalse(AudioRecorder.isGhostInputStartStatus(kAudioUnitErr_FormatNotSupported))
    }

    func testGhostInputErrorReadsOSStatusAndUnderlying() {
        let nope = NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(kAudioHardwareBadDeviceError)
        )
        XCTAssertTrue(AudioRecorder.isGhostInputStartError(nope))
        let wrapped = NSError(
            domain: "test",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: nope]
        )
        XCTAssertTrue(AudioRecorder.isGhostInputStartError(wrapped))
        XCTAssertFalse(
            AudioRecorder.isGhostInputStartError(
                NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
            )
        )
    }

    func testGhostInputErrorWalksNestedUnderlyingChain() {
        let nope = NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(kAudioHardwareBadDeviceError)
        )
        var wrapped: NSError = nope
        for _ in 0..<5 {
            wrapped = NSError(
                domain: "test",
                code: 1,
                userInfo: [NSUnderlyingErrorKey: wrapped]
            )
        }
        XCTAssertTrue(AudioRecorder.isGhostInputStartError(wrapped))
    }

    func testPicksLiveDefaultInputWhenAlive() {
        let picked = AudioRecorder.pickAliveInputDevice(
            defaultID: 261,
            defaultIsAlive: true,
            defaultFormatLooksDead: false,
            candidates: [(id: 86, isAlive: true, isBuiltIn: true, formatLooksDead: false)]
        )
        XCTAssertEqual(picked, 261)
    }

    func testPicksBuiltInWhenDefaultIsAliveButFormatDead() {
        let picked = AudioRecorder.pickAliveInputDevice(
            defaultID: 261,
            defaultIsAlive: true,
            defaultFormatLooksDead: true,
            candidates: [
                (id: 261, isAlive: true, isBuiltIn: false, formatLooksDead: true),
                (id: 86, isAlive: true, isBuiltIn: true, formatLooksDead: false),
            ]
        )
        XCTAssertEqual(picked, 86)
    }

    func testPicksBuiltInWhenExcludingGhostDefault() {
        let picked = AudioRecorder.pickAliveInputDevice(
            defaultID: 261,
            defaultIsAlive: true,
            defaultFormatLooksDead: false,
            candidates: [
                (id: 261, isAlive: true, isBuiltIn: false, formatLooksDead: false),
                (id: 86, isAlive: true, isBuiltIn: true, formatLooksDead: false),
            ],
            excluding: [261]
        )
        XCTAssertEqual(picked, 86)
    }

    func testPicksRemainingWhenMultipleExcluded() {
        let picked = AudioRecorder.pickAliveInputDevice(
            defaultID: 261,
            defaultIsAlive: true,
            defaultFormatLooksDead: false,
            candidates: [
                (id: 261, isAlive: true, isBuiltIn: false, formatLooksDead: false),
                (id: 99, isAlive: true, isBuiltIn: false, formatLooksDead: false),
                (id: 86, isAlive: true, isBuiltIn: true, formatLooksDead: false),
            ],
            excluding: [261, 99]
        )
        XCTAssertEqual(picked, 86)
    }

    func testSkipsContinuityFallbackWhenBuiltInExists() {
        let picked = AudioRecorder.pickAliveInputDevice(
            defaultID: 81,
            defaultIsAlive: false,
            defaultFormatLooksDead: true,
            candidates: [
                (id: 93, isAlive: true, isBuiltIn: false, formatLooksDead: false),
                (id: 81, isAlive: true, isBuiltIn: true, formatLooksDead: false),
            ],
            lastResortIDs: [93]
        )
        XCTAssertEqual(picked, 81)
    }

    func testPrefersFormatDeadBuiltInOverContinuity() {
        let picked = AudioRecorder.pickAliveInputDevice(
            defaultID: 81,
            defaultIsAlive: true,
            defaultFormatLooksDead: true,
            candidates: [
                (id: 93, isAlive: true, isBuiltIn: false, formatLooksDead: false),
                (id: 81, isAlive: true, isBuiltIn: true, formatLooksDead: true),
            ],
            lastResortIDs: [93]
        )
        XCTAssertEqual(picked, 81)
    }

    func testPrefersFormatDeadUnaliveBuiltInOverContinuity() {
        let picked = AudioRecorder.pickAliveInputDevice(
            defaultID: 81,
            defaultIsAlive: false,
            defaultFormatLooksDead: true,
            candidates: [
                (id: 93, isAlive: true, isBuiltIn: false, formatLooksDead: false),
                (id: 81, isAlive: false, isBuiltIn: true, formatLooksDead: true),
            ],
            lastResortIDs: [93]
        )
        XCTAssertEqual(picked, 81)
    }

    func testUnaliveBuiltInDefaultBeatsAliveNonLastResortNonBuiltIn() {
        let picked = AudioRecorder.pickAliveInputDevice(
            defaultID: 81,
            defaultIsAlive: false,
            defaultFormatLooksDead: true,
            candidates: [
                (id: 145, isAlive: true, isBuiltIn: false, formatLooksDead: false),
                (id: 81, isAlive: false, isBuiltIn: true, formatLooksDead: true),
            ]
        )
        XCTAssertEqual(picked, 81)
    }

    func testUnaliveBuiltInBeatsNonBuiltInInLastBuiltInPass() {
        let picked = AudioRecorder.pickAliveInputDevice(
            defaultID: nil,
            defaultIsAlive: false,
            candidates: [
                (id: 93, isAlive: true, isBuiltIn: false, formatLooksDead: false),
                (id: 81, isAlive: false, isBuiltIn: true, formatLooksDead: true),
            ],
            lastResortIDs: [93]
        )
        XCTAssertEqual(picked, 81)
    }

    func testDoesNotPreferDeadNonBuiltInOverContinuity() {
        let picked = AudioRecorder.pickAliveInputDevice(
            defaultID: nil,
            defaultIsAlive: false,
            candidates: [
                (id: 99, isAlive: false, isBuiltIn: false, formatLooksDead: true),
                (id: 93, isAlive: true, isBuiltIn: false, formatLooksDead: false),
            ],
            lastResortIDs: [93]
        )
        XCTAssertEqual(picked, 93)
    }

    func testHonorsContinuityWhenItIsLiveDefault() {
        let picked = AudioRecorder.pickAliveInputDevice(
            defaultID: 93,
            defaultIsAlive: true,
            defaultFormatLooksDead: false,
            candidates: [
                (id: 93, isAlive: true, isBuiltIn: false, formatLooksDead: false),
                (id: 81, isAlive: true, isBuiltIn: true, formatLooksDead: false),
            ],
            lastResortIDs: [93]
        )
        XCTAssertEqual(picked, 93)
    }

    func testLastResortOnlyWhenNothingElseAlive() {
        let picked = AudioRecorder.pickAliveInputDevice(
            defaultID: nil,
            defaultIsAlive: false,
            candidates: [
                (id: 93, isAlive: true, isBuiltIn: false, formatLooksDead: false),
            ],
            lastResortIDs: [93]
        )
        XCTAssertEqual(picked, 93)
    }

    func testContinuityAndVirtualAreLastResortTransports() {
        XCTAssertTrue(
            AudioRecorder.isLastResortInputTransport(
                kAudioDeviceTransportTypeContinuityCaptureWireless
            )
        )
        XCTAssertTrue(
            AudioRecorder.isLastResortInputTransport(
                kAudioDeviceTransportTypeContinuityCaptureWired
            )
        )
        XCTAssertTrue(
            AudioRecorder.isLastResortInputTransport(kAudioDeviceTransportTypeVirtual)
        )
        XCTAssertFalse(
            AudioRecorder.isLastResortInputTransport(kAudioDeviceTransportTypeBuiltIn)
        )
        XCTAssertFalse(
            AudioRecorder.isLastResortInputTransport(kAudioDeviceTransportTypeUSB)
        )
    }

    func testReplacesEngineAfterFailedBindNotAfterSuccess() {
        XCTAssertTrue(AudioRecorder.shouldReplaceEngineAfterFailedBind(false))
        XCTAssertFalse(AudioRecorder.shouldReplaceEngineAfterFailedBind(true))
    }

    func testDoesNotFlagRebuildWhileEngineStartInFlight() {
        XCTAssertFalse(AudioRecorder.shouldFlagRebuildOnConfigChange(startInFlight: true))
        XCTAssertTrue(AudioRecorder.shouldFlagRebuildOnConfigChange(startInFlight: false))
    }

    func testObjCExceptionDomainCountsAsGhostStartError() {
        XCTAssertTrue(
            AudioRecorder.isGhostInputStartError(
                NSError(domain: ObjCExceptionCatcher.errorDomain, code: 1)
            )
        )
    }

    func testPicksBuiltInWhenDefaultIsGhost() {
        let picked = AudioRecorder.pickAliveInputDevice(
            defaultID: 261,
            defaultIsAlive: false,
            defaultFormatLooksDead: true,
            candidates: [
                (id: 261, isAlive: false, isBuiltIn: false, formatLooksDead: true),
                (id: 86, isAlive: true, isBuiltIn: true, formatLooksDead: false),
            ]
        )
        XCTAssertEqual(picked, 86)
    }

    func testPicksAnyAliveInputWhenNoBuiltIn() {
        let picked = AudioRecorder.pickAliveInputDevice(
            defaultID: nil,
            defaultIsAlive: false,
            candidates: [
                (id: 99, isAlive: false, isBuiltIn: true, formatLooksDead: true),
                (id: 42, isAlive: true, isBuiltIn: false, formatLooksDead: false),
            ]
        )
        XCTAssertEqual(picked, 42)
    }

    func testSkipsFormatDeadWhenPickingAnyAlive() {
        let picked = AudioRecorder.pickAliveInputDevice(
            defaultID: nil,
            defaultIsAlive: false,
            candidates: [
                (id: 41, isAlive: true, isBuiltIn: false, formatLooksDead: true),
                (id: 42, isAlive: true, isBuiltIn: false, formatLooksDead: false),
            ]
        )
        XCTAssertEqual(picked, 42)
    }

    func testPicksNilWhenNothingAlive() {
        XCTAssertNil(
            AudioRecorder.pickAliveInputDevice(
                defaultID: 261,
                defaultIsAlive: false,
                candidates: [(id: 261, isAlive: false, isBuiltIn: false, formatLooksDead: true)]
            )
        )
    }

    func testPicksFormatDeadBuiltInInsteadOfFailingClosed() {
        let picked = AudioRecorder.pickAliveInputDevice(
            defaultID: 261,
            defaultIsAlive: true,
            defaultFormatLooksDead: true,
            candidates: [
                (id: 261, isAlive: true, isBuiltIn: false, formatLooksDead: true),
                (id: 86, isAlive: true, isBuiltIn: true, formatLooksDead: true),
            ]
        )
        XCTAssertEqual(picked, 86)
    }

    func testFailClosedWhenBindReturnsNil() {
        XCTAssertTrue(AudioRecorder.shouldFailClosedWithoutBoundInput(nil))
        XCTAssertFalse(AudioRecorder.shouldFailClosedWithoutBoundInput(86))
    }

    func testFailClosedAfterDeadFormatFallback() {
        XCTAssertTrue(AudioRecorder.shouldFailClosedAfterDeadFormatFallback(formatStillDead: true))
        XCTAssertFalse(AudioRecorder.shouldFailClosedAfterDeadFormatFallback(formatStillDead: false))
    }

    // MARK: - Next-start exclude (timeout persist)

    /// Hold 2's `doStart` calls `startMicCapture()` with nil exclude; the
    /// persisted timeout ID must still reach bind/rebuild.
    func testNextStartExcludeUsesPersistedWhenExplicitNil() {
        XCTAssertEqual(
            AudioRecorder.excludeOnNextMicStart(explicit: nil, persistedFailedID: 261),
            261
        )
    }

    func testNextStartExcludeExplicitWinsOverPersisted() {
        XCTAssertEqual(
            AudioRecorder.excludeOnNextMicStart(explicit: 86, persistedFailedID: 261),
            86
        )
    }

    func testNextStartExcludeNilWhenNothingPersisted() {
        XCTAssertNil(AudioRecorder.excludeOnNextMicStart(explicit: nil, persistedFailedID: nil))
    }

    func testPersistedExcludeClearsWhenBindLandsOnDifferentDevice() {
        XCTAssertNil(
            AudioRecorder.persistedExcludeAfterBind(boundID: 86, persistedExclude: 261)
        )
    }

    func testPersistedExcludeKeptWhenBindStillMatches() {
        XCTAssertEqual(
            AudioRecorder.persistedExcludeAfterBind(boundID: 261, persistedExclude: 261),
            261
        )
    }

    func testPersistedExcludeStaysNilWhenNothingPersisted() {
        XCTAssertNil(
            AudioRecorder.persistedExcludeAfterBind(boundID: 86, persistedExclude: nil)
        )
    }

    /// Fail-closed persist: a known ghost ID must survive to the next hold.
    /// Nil candidate must not wipe an existing persist; rebuild can nil
    /// `lastBoundInputDeviceID` before fail (format-dead path).
    func testFailClosedPersistKeepsCandidate() {
        XCTAssertEqual(
            AudioRecorder.persistedExcludeOnFailClosed(candidate: 261, existing: nil),
            261
        )
    }

    func testFailClosedPersistDoesNotClobberWithNil() {
        XCTAssertEqual(
            AudioRecorder.persistedExcludeOnFailClosed(candidate: nil, existing: 261),
            261
        )
    }

    func testFailClosedPersistNilWhenNothingKnown() {
        XCTAssertNil(
            AudioRecorder.persistedExcludeOnFailClosed(candidate: nil, existing: nil)
        )
    }

    func testFailClosedPersistCandidateWinsOverExisting() {
        XCTAssertEqual(
            AudioRecorder.persistedExcludeOnFailClosed(candidate: 86, existing: 261),
            86
        )
    }

    // MARK: - Stale doStop vs in-flight start

    func testDoStopDoesNotSkipWhileStartInFlightEvenIfReArmed() {
        XCTAssertFalse(
            AudioRecorder.shouldSkipStaleDoStop(
                wantsRecording: true,
                capturedGeneration: 1,
                currentGeneration: 1,
                startInFlight: true
            )
        )
    }

    func testDoStopDoesNotSkipStaleGenerationWhileStartInFlight() {
        XCTAssertFalse(
            AudioRecorder.shouldSkipStaleDoStop(
                wantsRecording: false,
                capturedGeneration: 1,
                currentGeneration: 2,
                startInFlight: true
            )
        )
    }

    func testDoStopStillSkipsReArmedHoldWhenStartNotInFlight() {
        XCTAssertTrue(
            AudioRecorder.shouldSkipStaleDoStop(
                wantsRecording: true,
                capturedGeneration: 1,
                currentGeneration: 1,
                startInFlight: false
            )
        )
    }

    func testDoStopProceedsWhenReleasedAndStartNotInFlight() {
        XCTAssertFalse(
            AudioRecorder.shouldSkipStaleDoStop(
                wantsRecording: false,
                capturedGeneration: 2,
                currentGeneration: 2,
                startInFlight: false
            )
        )
    }

    /// Re-press during an in-flight start: teardown the attempt, but do not
    /// run the stop pipeline (that would clear the newer hold's caret).
    func testInFlightDoStopReturnsWithoutPipelineWhenReArmed() {
        XCTAssertTrue(
            AudioRecorder.shouldReturnAfterInFlightDoStopTeardown(wantsRecording: true)
        )
        XCTAssertFalse(
            AudioRecorder.shouldReturnAfterInFlightDoStopTeardown(wantsRecording: false)
        )
    }

    // MARK: - Start-success + pending rebuild

    func testStartSuccessRestartsWhenRebuildPendingAndNotRetried() {
        XCTAssertTrue(
            AudioRecorder.shouldRestartCaptureAfterStartSuccess(
                engineNeedsRebuild: true,
                alreadyRetried: false
            )
        )
    }

    func testStartSuccessDoesNotRestartWhenNoRebuildPending() {
        XCTAssertFalse(
            AudioRecorder.shouldRestartCaptureAfterStartSuccess(
                engineNeedsRebuild: false,
                alreadyRetried: false
            )
        )
    }

    func testStartSuccessDoesNotRestartWhenRetryBudgetUsed() {
        XCTAssertFalse(
            AudioRecorder.shouldRestartCaptureAfterStartSuccess(
                engineNeedsRebuild: true,
                alreadyRetried: true
            )
        )
    }

    func testStartSuccessFailsClosedWhenRebuildPendingAfterRetry() {
        XCTAssertTrue(
            AudioRecorder.shouldFailClosedAfterStartSuccessWithPendingRebuild(
                engineNeedsRebuild: true,
                alreadyRetried: true
            )
        )
        XCTAssertFalse(
            AudioRecorder.shouldFailClosedAfterStartSuccessWithPendingRebuild(
                engineNeedsRebuild: true,
                alreadyRetried: false
            )
        )
        XCTAssertFalse(
            AudioRecorder.shouldFailClosedAfterStartSuccessWithPendingRebuild(
                engineNeedsRebuild: false,
                alreadyRetried: true
            )
        )
    }
}
