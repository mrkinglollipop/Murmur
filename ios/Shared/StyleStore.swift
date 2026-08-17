import Combine
import Foundation

/// Persists the selected Style profile in the App Group. Applied locally
/// after transcription (caps / punctuation), not via an LLM.
final class StyleStore: ObservableObject {

    @Published var selected: StyleProfile {
        didSet {
            AppGroupStore.selectedStyleRaw = selected.rawValue
        }
    }

    init() {
        selected = StyleProfile(rawValue: AppGroupStore.selectedStyleRaw) ?? .casual
    }
}
