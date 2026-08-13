import Foundation

/// Maps keyboard-side class names and process paths to a host bundle ID.
/// ChatKit (`CKMessage*`) is Messages; CloudKit (`CKRecord`) is not.
enum HostFingerprint {
    static let messagesBundle = "com.apple.MobileSMS"
    static let notesBundle = "com.apple.mobilenotes"
    static let mailBundle = "com.apple.mobilemail"
    static let safariBundle = "com.apple.mobilesafari"

    /// Apps we will PID-match for bounce. Unknown hosts stay on the interstitial.
    static let dictationHostBundleIDs = [
        messagesBundle,
        notesBundle,
        mailBundle,
        safariBundle,
        "com.apple.reminders",
        "com.apple.mobilecal",
        "com.apple.DocumentsApp",
        "com.apple.Preferences",
        "com.apple.shortcuts",
        "com.apple.VoiceMemos"
    ]

    static func bundleID(fromClassNames names: [String]) -> String? {
        for name in names where isMessagesClass(name) {
            return messagesBundle
        }
        for name in names {
            if isNotesClass(name) { return notesBundle }
            if isMailClass(name) { return mailBundle }
            if isSafariClass(name) { return safariBundle }
        }
        return nil
    }

    static func bundleID(fromProcessPath path: String) -> String? {
        let last = (path as NSString).lastPathComponent.lowercased()
        if last == "mobilesms" || last == "messages" { return messagesBundle }
        if last == "mobilenotes" || last == "notes" { return notesBundle }
        if last == "mobilemail" || last == "mail" { return mailBundle }
        if last == "mobilesafari" || last == "safari" { return safariBundle }
        let lowered = path.lowercased()
        if lowered.contains("mobilesms") { return messagesBundle }
        if lowered.contains("mobilenotes") { return notesBundle }
        if lowered.contains("/notes.app/") { return notesBundle }
        if lowered.contains("mobilemail") { return mailBundle }
        if lowered.contains("mobilesafari") { return safariBundle }
        return nil
    }

    static func isMessagesClass(_ name: String) -> Bool {
        if name.hasPrefix("CKMessage") { return true }
        if name.hasPrefix("CKChat") { return true }
        if name.hasPrefix("CKConversation") { return true }
        if name.hasPrefix("CKTranscript") { return true }
        if name.hasPrefix("CKEditable") { return true }
        if name.hasPrefix("CKBrowser") { return true }
        if name.hasPrefix("CKEntry") { return true }
        if name.hasPrefix("IMChat") { return true }
        if name.contains("ChatKit") { return true }
        if name.contains("MobileSMS") { return true }
        return false
    }

    static func isNotesClass(_ name: String) -> Bool {
        if name.hasPrefix("ICText") { return true }
        if name.hasPrefix("ICNote") { return true }
        if name.hasPrefix("ICNA") { return true }
        if name.contains("NotesUI") { return true }
        if name.contains("NoteEditor") { return true }
        return false
    }

    static func isMailClass(_ name: String) -> Bool {
        name.hasPrefix("MFCompose") || name.hasPrefix("MFMail") || name.contains("MailCompose")
    }

    static func isSafariClass(_ name: String) -> Bool {
        name.hasPrefix("WKContent") || name.contains("TabDocument")
    }
}
