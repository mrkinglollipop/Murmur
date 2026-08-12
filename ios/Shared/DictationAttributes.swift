import ActivityKit
import Foundation

struct DictationAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var isRecording: Bool
        var startedAt: Date
        var label: String
    }

    var requestID: String
}
