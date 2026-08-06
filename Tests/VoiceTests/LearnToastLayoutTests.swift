import XCTest
@testable import Voice

final class LearnToastLayoutTests: XCTestCase {

    func testToastYStacksAboveRecordingWhenVisible() {
        let frame = CGRect(x: 100, y: 40, width: 260, height: 40)
        let y = LearnToastLayout.toastOriginY(
            recordingVisible: true,
            recordingFrame: frame,
            restingOriginY: 30
        )
        XCTAssertEqual(y, frame.maxY + LearnToastLayout.gapAboveRecording)
    }

    func testToastYUsesRestingOriginWhenRecordingHidden() {
        let frame = CGRect(x: 100, y: 40, width: 260, height: 40)
        let y = LearnToastLayout.toastOriginY(
            recordingVisible: false,
            recordingFrame: frame,
            restingOriginY: 30
        )
        XCTAssertEqual(y, 30)
    }
}
