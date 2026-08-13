import Foundation

/// Testable emoji-search chrome rules. `KeyboardChromeView` is not in
/// `MurmurKeyboardTests`; this helper is.
enum EmojiSearchRouting {
    /// Category strip (ABC, tabs, delete) stays on screen in grid and search.
    static func showsCategoryBar(isSearchMode: Bool) -> Bool {
        _ = isSearchMode
        return true
    }

    /// In search mode, Delete is always consumed (never forwarded to the host).
    /// An empty query no-ops inside the picker; a non-empty query deletes a character.
    static func consumeDelete(isSearchMode: Bool, searchIsEmpty: Bool) -> Bool {
        _ = searchIsEmpty
        return isSearchMode
    }
}
