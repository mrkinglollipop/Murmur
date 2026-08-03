import XCTest
@testable import Voice

final class EnrollmentDeleteTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for dir in tempDirectories {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-enrollment-\(UUID().uuidString)", isDirectory: true)
        tempDirectories.append(url)
        return url
    }

    func testDeleteProfileRemovesStoredProfileAndDisablesGating() {
        let directory = tempDirectory()
        let store = VoiceProfileStore(directoryURL: directory)
        let profile = VoiceProfile(
            embedding: [0.1, 0.2, 0.3],
            createdAt: Date(),
            modelId: "test-model"
        )
        store.save(profile)
        XCTAssertNotNil(store.load())

        var disableCalled = false
        let coordinator = EnrollmentCoordinator(
            profileStore: store,
            sensitivityProvider: { .medium },
            onGatingShouldRefresh: {}
        )

        coordinator.deleteProfile(
            profileStore: store,
            disableGating: { disableCalled = true }
        )

        XCTAssertNil(store.load())
        XCTAssertTrue(disableCalled)
        XCTAssertEqual(coordinator.flow.phase, .notStarted)
    }
}
