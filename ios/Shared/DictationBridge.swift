import Foundation

enum DictationBridge {
    static let toggleName = "com.matt.murmur.ios.dictation.toggle" as CFString
    static let stopName = "com.matt.murmur.ios.dictation.stop" as CFString
    static let startName = "com.matt.murmur.ios.dictation.start" as CFString
    static let cancelName = "com.matt.murmur.ios.dictation.cancel" as CFString
    private static let commandKey = "dictationCommand"

    enum Command: String {
        case toggle
        case stop
        case start
        case cancel
    }

    static func post(_ command: Command) {
        UserDefaults(suiteName: AppGroupStore.suiteName)?.set(command.rawValue, forKey: commandKey)
        let name: CFString = switch command {
        case .toggle: toggleName
        case .stop: stopName
        case .start: startName
        case .cancel: cancelName
        }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name),
            nil,
            nil,
            true
        )
    }

    static func take() -> Command? {
        let suite = UserDefaults(suiteName: AppGroupStore.suiteName)
        let raw = suite?.string(forKey: commandKey) ?? ""
        suite?.removeObject(forKey: commandKey)
        return Command(rawValue: raw)
    }
}
