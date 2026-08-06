import Foundation
import CoreGraphics

/// Pure stacking math for LearnToastHUD vs RecordingHUD (unit-testable).
enum LearnToastLayout {
    static let gapAboveRecording: CGFloat = 12

    /// Toast panel origin Y (AppKit bottom-left). When recording HUD is visible,
    /// stack above its frame; otherwise use RecordingHUD's resting origin Y.
    static func toastOriginY(
        recordingVisible: Bool,
        recordingFrame: CGRect,
        restingOriginY: CGFloat
    ) -> CGFloat {
        if recordingVisible {
            return recordingFrame.maxY + gapAboveRecording
        }
        return restingOriginY
    }
}
