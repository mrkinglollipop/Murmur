import Foundation
import os.log

/// A saved rewrite preset: an arbitrary instruction applied over dictated
/// text on demand (not during the automatic cleanup pass).
struct Transform: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var prompt: String
    var description: String?

    init(id: UUID = UUID(), name: String, prompt: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.description = description
    }
}

/// Flat list of saved Transforms, persisted to Application Support — mirrors
/// `SnippetsStore`'s persistence pattern (same directory, same load/save/
/// thread-hop approach). Seeds two defaults on first run only.
final class TransformsStore: ObservableObject {

    @Published private(set) var transforms: [Transform] = []

    /// When set, this transform runs automatically after cleanup on each dictation.
    @Published var autoRunTransformID: UUID? {
        didSet {
            if let id = autoRunTransformID {
                UserDefaults.standard.set(id.uuidString, forKey: Keys.autoRunTransformID)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.autoRunTransformID)
            }
            pushAutoRunTransform()
        }
    }

    weak var asrEngineSelector: ASREngineSelector?

    private enum Keys {
        static let autoRunTransformID = "voice.settings.autoRunTransformID"
    }

    private let fileURL: URL
    private let logger = Logger(subsystem: "com.matt.voice-dictation", category: "transforms-store")
    private var saveWorkItem: DispatchWorkItem?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? TransformsStore.defaultFileURL()
        if let raw = UserDefaults.standard.string(forKey: Keys.autoRunTransformID),
           let id = UUID(uuidString: raw) {
            autoRunTransformID = id
        }
        load()
    }

    // MARK: - Paths

    private static func defaultFileURL() -> URL {
        VoicePaths.prepareApplicationSupportVoiceDirectory()
        return VoicePaths.applicationSupportVoiceDirectory.appendingPathComponent("transforms.json")
    }

    // MARK: - Load / save

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            seedDefaults()
            return
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            seedDefaults()
            return
        }
        do {
            transforms = try JSONDecoder().decode([Transform].self, from: data)
        } catch {
            quarantineCorruptFile(error: error)
            seedDefaults()
        }
        pushAutoRunTransform()
    }

    private func quarantineCorruptFile(error: Error) {
        let bak = URL(fileURLWithPath: fileURL.path + ".corrupt.\(Int(Date().timeIntervalSince1970))")
        do {
            if FileManager.default.fileExists(atPath: bak.path) {
                try FileManager.default.removeItem(at: bak)
            }
            try FileManager.default.moveItem(at: fileURL, to: bak)
            logger.error("Quarantined corrupt transforms.json → \(bak.lastPathComponent): \(error.localizedDescription)")
        } catch {
            logger.error("Failed to quarantine corrupt transforms.json: \(error.localizedDescription)")
        }
    }

    /// Seeds "Polish" and "Prompt Engineer" on first run (no persisted file
    /// yet, or a corrupt one) so the list isn't empty on first launch.
    private func seedDefaults() {
        transforms = [
            Transform(
                name: "Polish",
                prompt: "Improve clarity and conciseness without changing meaning.",
                description: "Tighten wording, keep the meaning"
            ),
            Transform(
                name: "Prompt Engineer",
                prompt: "Rewrite this as a clear, well-structured LLM prompt.",
                description: "Turn notes into a structured prompt"
            )
        ]
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(transforms) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.save()
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        save()
    }

    // MARK: - CRUD

    func add(name: String, prompt: String, description: String? = nil) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanPrompt.isEmpty else { return }
        let newTransform = Transform(name: cleanName, prompt: cleanPrompt, description: description)
        let mutate = {
            self.transforms.append(newTransform)
            self.scheduleSave()
        }
        Thread.isMainThread ? mutate() : DispatchQueue.main.async(execute: mutate)
    }

    func update(_ transform: Transform) {
        let mutate = {
            guard let idx = self.transforms.firstIndex(where: { $0.id == transform.id }) else { return }
            self.transforms[idx] = transform
            self.scheduleSave()
        }
        Thread.isMainThread ? mutate() : DispatchQueue.main.async(execute: mutate)
    }

    func delete(_ transform: Transform) {
        let mutate = {
            self.transforms.removeAll { $0.id == transform.id }
            if self.autoRunTransformID == transform.id {
                self.autoRunTransformID = nil
            }
            self.scheduleSave()
        }
        Thread.isMainThread ? mutate() : DispatchQueue.main.async(execute: mutate)
    }

    func transform(withID id: UUID) -> Transform? {
        transforms.first { $0.id == id }
    }

    func applyOnLaunch() {
        pushAutoRunTransform()
    }

    private func pushAutoRunTransform() {
        guard let asrEngineSelector else { return }
        if let id = autoRunTransformID {
            asrEngineSelector.autoRunTransform = transform(withID: id)
        } else {
            asrEngineSelector.autoRunTransform = nil
        }
    }
}
