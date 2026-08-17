import AppIntents
import Foundation

struct ToggleMicIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Toggle Microphone"
    static var openAppWhenRun = false
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult {
        DictationBridge.post(.toggle)
        return .result()
    }
}

struct StopDictationIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Dictation"
    static var openAppWhenRun = false
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult {
        DictationBridge.post(.stop)
        return .result()
    }
}

/// Power button on the Dynamic Island — kills the keepalive without opening Murmur.
struct EndSessionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Turn Murmur Off"
    static var openAppWhenRun = false
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult {
        DictationBridge.post(.cancel)
        return .result()
    }
}

/// Pencil button — opens Murmur, matching Wispr’s compose control.
struct OpenMurmurIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Open Murmur"
    static var openAppWhenRun = true
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult {
        return .result()
    }
}
