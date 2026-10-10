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

    func testDictionaryMergePreservesIndependentAdds() {
        let first = DictionaryEntry(term: "First", variants: [])
        let second = DictionaryEntry(term: "Second", variants: [])
        XCTAssertEqual(
            DictionaryStore.mergingChanges(base: [], local: [second], current: [first]),
            [first, second]
        )
    }

    func testDictionaryMergePreservesUntouchedRemoteEdit() {
        let first = DictionaryEntry(term: "First", variants: [])
        let second = DictionaryEntry(term: "Second", variants: [])
        var local = first
        local.term = "Local"
        var remote = second
        remote.variants = ["remote"]
        XCTAssertEqual(
            DictionaryStore.mergingChanges(base: [first, second], local: [local, second], current: [first, remote]),
            [local, remote]
        )
    }

    func testDictionaryMergeDoesNotResurrectDeletion() {
        let entry = DictionaryEntry(term: "Deleted", variants: [])
        var edited = entry
        edited.term = "Stale edit"
        XCTAssertEqual(DictionaryStore.mergingChanges(base: [entry], local: [entry], current: []), [])
        XCTAssertEqual(DictionaryStore.mergingChanges(base: [entry], local: [edited], current: []), [])
        XCTAssertEqual(DictionaryStore.mergingChanges(base: [entry], local: [], current: [edited]), [])
    }

    func testDictionaryMergeCombinesIndependentFieldsAndFixCounts() {
        let entry = DictionaryEntry(term: "Original", variants: [], fixCount: 2)
        var local = entry
        local.term = "Edited"
        local.fixCount += 1
        var remote = entry
        remote.variants = ["new variant"]
        remote.fixCount += 2
        var expected = remote
        expected.term = local.term
        expected.fixCount = 5
        XCTAssertEqual(DictionaryStore.mergingChanges(base: [entry], local: [local], current: [remote]), [expected])
    }

    func testTwoDictionaryStoresMergeWritesAndReload() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dict-shared-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let host = DictionaryStore(fileURL: url)
        let keyboard = DictionaryStore(fileURL: url)
        host.add(term: "Host", variants: [])
        keyboard.add(term: "Keyboard", variants: [])
        host.flush()
        keyboard.flush()
        host.reload()
        XCTAssertEqual(Set(host.entries.map(\.term)), ["Host", "Keyboard"])
        XCTAssertEqual(host.entries, keyboard.entries)
        let removed = host.entries[0]
        host.delete(removed)
        host.flush()
        keyboard.flush()
        XCTAssertFalse(keyboard.entries.contains { $0.id == removed.id })
    }

    func testDictionaryReloadPreservesPendingLocalEdit() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dict-pending-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = DictionaryStore(fileURL: url)
        first.add(term: "Original", variants: [])
        first.flush()
        let second = DictionaryStore(fileURL: url)
        var local = first.entries[0]
        local.term = "Pending"
        first.update(local)
        second.add(term: "Remote", variants: [])
        second.flush()
        first.reload()
        first.flush()
        second.reload()
        XCTAssertEqual(Set(second.entries.map(\.term)), ["Pending", "Remote"])
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
