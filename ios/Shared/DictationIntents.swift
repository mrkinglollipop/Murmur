import AppIntents
import Foundation

struct ToggleMicIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Toggle Microphone"
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        DictationBridge.post(.toggle)
        return .result()
    }
}

struct StopDictationIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Dictation"
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        DictationBridge.post(.stop)
        return .result()
    }
}
