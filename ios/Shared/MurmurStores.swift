import Foundation

enum MurmurStores {
    static let dictionary = DictionaryStore()
    static let snippets = SnippetsStore()
    static let scratchpad = ScratchpadStore()
    static let style = StyleStore()
    static let history = HistoryStore()
}
