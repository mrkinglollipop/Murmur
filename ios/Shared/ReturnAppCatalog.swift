import Foundation

/// Known titles / SF Symbols / URL-scheme fallbacks. The jump-back grid is
/// not limited to this list — any allowed bundle ID can be stored and opened
/// via workspace-open. `scheme` is timeout/reject fallback only.
struct ReturnApp: Equatable, Identifiable {
    var id: String { bundleID }
    let bundleID: String
    let title: String
    let symbol: String
    let scheme: String?
}

enum ReturnAppCatalog {
    static let all: [ReturnApp] = [
        ReturnApp(
            bundleID: HostFingerprint.messagesBundle,
            title: "Messages",
            symbol: "message.fill",
            scheme: "sms:"
        ),
        ReturnApp(
            bundleID: HostFingerprint.notesBundle,
            title: "Notes",
            symbol: "note.text",
            scheme: "mobilenotes://"
        ),
        ReturnApp(
            bundleID: HostFingerprint.mailBundle,
            title: "Mail",
            symbol: "envelope.fill",
            scheme: "message://"
        ),
        ReturnApp(
            bundleID: HostFingerprint.safariBundle,
            title: "Safari",
            symbol: "safari.fill",
            scheme: "x-web-search://"
        ),
        ReturnApp(
            bundleID: "com.apple.reminders",
            title: "Reminders",
            symbol: "checklist",
            scheme: "x-apple-reminderkit://"
        ),
        ReturnApp(
            bundleID: "com.apple.mobilecal",
            title: "Calendar",
            symbol: "calendar",
            scheme: "calshow://"
        ),
        ReturnApp(
            bundleID: "com.apple.DocumentsApp",
            title: "Files",
            symbol: "folder.fill",
            scheme: "shareddocuments://"
        ),
        ReturnApp(
            bundleID: "com.tinyspeck.chatlyio",
            title: "Slack",
            symbol: "number",
            scheme: "slack://"
        ),
        ReturnApp(
            bundleID: "net.whatsapp.WhatsApp",
            title: "WhatsApp",
            symbol: "phone.bubble.fill",
            scheme: "whatsapp://"
        ),
        ReturnApp(
            bundleID: "com.atebits.Tweetie2",
            title: "X",
            symbol: "at",
            scheme: "twitter://"
        ),
        ReturnApp(
            bundleID: "com.hammerandchisel.discord",
            title: "Discord",
            symbol: "bubble.left.and.bubble.right.fill",
            scheme: "discord://"
        ),
        ReturnApp(
            bundleID: "com.facebook.Facebook",
            title: "Facebook",
            symbol: "person.2.fill",
            scheme: "fb://"
        ),
        ReturnApp(
            bundleID: "com.facebook.Messenger",
            title: "Messenger",
            symbol: "message.fill",
            scheme: "fb-messenger://"
        ),
        ReturnApp(
            bundleID: "com.google.Gmail",
            title: "Gmail",
            symbol: "envelope.fill",
            scheme: "googlegmail://"
        ),
        ReturnApp(
            bundleID: "com.burbn.instagram",
            title: "Instagram",
            symbol: "camera.fill",
            scheme: "instagram://"
        ),
        ReturnApp(
            bundleID: "com.google.ios.youtube",
            title: "YouTube",
            symbol: "play.rectangle.fill",
            scheme: "youtube://"
        ),
        ReturnApp(
            bundleID: "com.google.chrome.ios",
            title: "Chrome",
            symbol: "globe",
            scheme: "googlechrome://"
        ),
        ReturnApp(
            bundleID: "com.spotify.client",
            title: "Spotify",
            symbol: "music.note",
            scheme: "spotify://"
        ),
        ReturnApp(
            bundleID: "com.microsoft.Office.Outlook",
            title: "Outlook",
            symbol: "envelope.fill",
            scheme: "ms-outlook://"
        ),
        ReturnApp(
            bundleID: "co.anysphere.sand",
            title: "Grok Bot",
            symbol: "cpu",
            scheme: nil
        ),
        ReturnApp(
            bundleID: "com.anthropic.claude",
            title: "Claude",
            symbol: "bubble.left.fill",
            scheme: nil
        ),
        ReturnApp(
            bundleID: "co.anysphere.cursor",
            title: "Cursor",
            symbol: "chevron.left.forwardslash.chevron.right",
            scheme: nil
        )
    ]

    static let defaultBundleIDs = [
        HostFingerprint.messagesBundle,
        HostFingerprint.notesBundle,
        HostFingerprint.mailBundle,
        HostFingerprint.safariBundle,
        "com.atebits.Tweetie2"
    ]

    static let knownBundleIDs = Set(all.map(\.bundleID))

    /// Drop empty IDs, Murmur itself, and duplicates. Keep third-party IDs
    /// and preserve caller order so the grid can be rearranged.
    static func isAllowed(_ bundleID: String) -> Bool {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return false }
        return !id.lowercased().hasPrefix("com.matt.murmur")
    }

    static func sanitizedIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for raw in ids {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isAllowed(id), seen.insert(id).inserted else { continue }
            ordered.append(id)
        }
        return ordered
    }

    /// Missing store key → factory defaults. Present empty array → none (swipe only).
    static func resolvedIDs(stored: [String]?, keyExists: Bool) -> [String] {
        if !keyExists { return defaultBundleIDs }
        return sanitizedIDs(stored ?? [])
    }

    static func displayTitle(for bundleID: String) -> String {
        if let known = all.first(where: { $0.bundleID == bundleID }) {
            return known.title
        }
        if let last = bundleID.split(separator: ".").last, !last.isEmpty {
            return last.replacingOccurrences(of: "-", with: " ").capitalized
        }
        return bundleID
    }

    static func displaySymbol(for bundleID: String) -> String {
        all.first(where: { $0.bundleID == bundleID })?.symbol ?? "app.fill"
    }

    /// Store order, including IDs that are not in `all`.
    static func apps(enabledIDs: [String]) -> [ReturnApp] {
        sanitizedIDs(enabledIDs).map { id in
            all.first(where: { $0.bundleID == id })
                ?? ReturnApp(
                    bundleID: id,
                    title: displayTitle(for: id),
                    symbol: displaySymbol(for: id),
                    scheme: nil
                )
        }
    }

    static func schemeURL(for bundleID: String) -> URL? {
        guard let value = all.first(where: { $0.bundleID == bundleID })?.scheme else { return nil }
        return URL(string: value)
    }

    /// Move `moving` onto `onto` without SwiftUI's `Collection.move` (that
    /// symbol is unavailable in the keyboard test target).
    static func reorderedIDs(_ ids: [String], moving: String, onto: String) -> [String] {
        var next = sanitizedIDs(ids)
        guard let from = next.firstIndex(of: moving),
              let to = next.firstIndex(of: onto),
              from != to else { return next }
        let item = next.remove(at: from)
        next.insert(item, at: to)
        return next
    }
}
