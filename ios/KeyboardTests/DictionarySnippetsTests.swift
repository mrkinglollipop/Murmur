import XCTest

final class DictionarySnippetsTests: XCTestCase {
    func testDictionaryReplacesWholeWordVariants() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dict-\(UUID().uuidString).json")
        let store = DictionaryStore(fileURL: url)
        store.add(term: "Kubernetes", variants: ["kubernetis", "kubernettes"])
        XCTAssertEqual(store.correct("deploy to kubernetis now"), "deploy to Kubernetes now")
        XCTAssertEqual(store.correct("running Kubernettes now"), "running Kubernetes now")
        XCTAssertEqual(store.correct("kubernetisation"), "kubernetisation")
    }

    func testAddSameTermMergesVariants() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dict-merge-\(UUID().uuidString).json")
        let store = DictionaryStore(fileURL: url)
        store.add(term: "Khipu", variants: ["Keepu"])
        store.add(term: "khipu", variants: ["Keefu"])
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(Set(store.entries.first?.variants.map { $0.lowercased() } ?? []), ["keepu", "keefu"])
        XCTAssertEqual(
            store.correct("open Keepu and Keefu"),
            "open Khipu and Khipu"
        )
    }

    func testEmptyDictionaryLeavesTextAlone() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dict-empty-\(UUID().uuidString).json")
        let store = DictionaryStore(fileURL: url)
        XCTAssertEqual(store.correct("leave this"), "leave this")
    }

    func testSnippetExpandsLongestTriggerFirst() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snip-\(UUID().uuidString).json")
        let store = SnippetsStore(fileURL: url)
        store.add(trigger: "see", expansion: "SEE")
        store.add(trigger: "see you soon", expansion: "SYSexpanded")
        XCTAssertEqual(store.expand("see you soon tomorrow"), "SYSexpanded tomorrow")
        XCTAssertEqual(store.expand("see the seeds"), "SEE the seeds")
    }

    func testSnippetPunctuationTrigger() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snip-at-\(UUID().uuidString).json")
        let store = SnippetsStore(fileURL: url)
        store.add(trigger: "@work", expansion: "matt@example.com")
        XCTAssertEqual(store.expand("ping me @work tomorrow"), "ping me matt@example.com tomorrow")
        XCTAssertEqual(store.expand("user@workplace"), "user@workplace")
    }
}
