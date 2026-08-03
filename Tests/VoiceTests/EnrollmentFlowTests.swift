import XCTest
@testable import Voice

final class EnrollmentFlowTests: XCTestCase {

    func testHappyPathThroughAllSteps() {
        var flow = EnrollmentFlow(totalSteps: 3)

        XCTAssertEqual(flow.phase, .notStarted)

        flow.beginDownload()
        XCTAssertEqual(flow.phase, .downloadingModel)

        flow.modelReady()
        XCTAssertEqual(flow.phase, .recording(step: 0))

        flow.finishedStep()
        XCTAssertEqual(flow.phase, .recording(step: 1))

        flow.finishedStep()
        XCTAssertEqual(flow.phase, .recording(step: 2))

        flow.finishedStep()
        XCTAssertEqual(flow.phase, .computing)

        flow.computingSucceeded()
        XCTAssertEqual(flow.phase, .done)
    }

    func testDownloadFailedPath() {
        var flow = EnrollmentFlow()

        flow.beginDownload()
        flow.downloadFailed("network error")
        XCTAssertEqual(flow.phase, .failed("network error"))
    }

    func testMidRecordingStepFailedPath() {
        var flow = EnrollmentFlow()

        flow.beginDownload()
        flow.modelReady()
        flow.stepFailed("mic denied")
        XCTAssertEqual(flow.phase, .failed("mic denied"))
    }

    func testCancelFromAnyPhaseReturnsNotStarted() {
        var notStarted = EnrollmentFlow()
        notStarted.cancel()
        XCTAssertEqual(notStarted.phase, .notStarted)

        var downloading = EnrollmentFlow()
        downloading.beginDownload()
        downloading.cancel()
        XCTAssertEqual(downloading.phase, .notStarted)

        var recording = EnrollmentFlow()
        recording.beginDownload()
        recording.modelReady()
        recording.cancel()
        XCTAssertEqual(recording.phase, .notStarted)

        var computing = EnrollmentFlow()
        computing.beginDownload()
        computing.modelReady()
        computing.finishedStep()
        computing.finishedStep()
        computing.finishedStep()
        XCTAssertEqual(computing.phase, .computing)
        computing.cancel()
        XCTAssertEqual(computing.phase, .notStarted)

        var done = EnrollmentFlow()
        done.beginDownload()
        done.modelReady()
        done.finishedStep()
        done.finishedStep()
        done.finishedStep()
        done.computingSucceeded()
        done.cancel()
        XCTAssertEqual(done.phase, .notStarted)

        var failed = EnrollmentFlow()
        failed.beginDownload()
        failed.downloadFailed("oops")
        failed.cancel()
        XCTAssertEqual(failed.phase, .notStarted)
    }

    func testUnexpectedTransitionsAreNoOps() {
        var flow = EnrollmentFlow()

        flow.modelReady()
        XCTAssertEqual(flow.phase, .notStarted)

        flow.beginDownload()
        flow.finishedStep()
        XCTAssertEqual(flow.phase, .downloadingModel)

        flow.modelReady()
        flow.computingSucceeded()
        XCTAssertEqual(flow.phase, .recording(step: 0))
    }

    func testBeginDownloadFromFailedRestarts() {
        var flow = EnrollmentFlow()
        flow.beginDownload()
        flow.downloadFailed("previous")
        flow.beginDownload()
        XCTAssertEqual(flow.phase, .downloadingModel)
    }
}
