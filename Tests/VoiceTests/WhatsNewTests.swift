import XCTest
@testable import Voice

final class WhatsNewTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "WhatsNewTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDecodesFixtureJSON() throws {
        let json = """
        [
          {
            "version": "0.1.18",
            "build": "19",
            "title": "What's New in 0.1.18",
            "items": ["First bullet", "Second bullet"]
          }
        ]
        """
        let releases = try JSONDecoder().decode([WhatsNewRelease].self, from: Data(json.utf8))
        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(releases[0].version, "0.1.18")
        XCTAssertEqual(releases[0].build, "19")
        XCTAssertEqual(releases[0].title, "What's New in 0.1.18")
        XCTAssertEqual(releases[0].items, ["First bullet", "Second bullet"])
    }

    func testShouldPresentWhenLastSeenIsLower() {
        XCTAssertTrue(
            WhatsNewStore.shouldPresent(
                currentBuild: 19,
                lastSeenBuild: 18,
                catalogNonEmpty: true
            )
        )
    }

    func testShouldPresentFalseWhenEqual() {
        XCTAssertFalse(
            WhatsNewStore.shouldPresent(
                currentBuild: 19,
                lastSeenBuild: 19,
                catalogNonEmpty: true
            )
        )
    }

    func testShouldPresentFalseWhenCatalogEmpty() {
        XCTAssertFalse(
            WhatsNewStore.shouldPresent(
                currentBuild: 19,
                lastSeenBuild: 0,
                catalogNonEmpty: false
            )
        )
    }

    func testShouldPresentTreatsMissingLastSeenAsZero() {
        XCTAssertEqual(WhatsNewStore.lastSeenBuild(defaults: defaults), 0)
        XCTAssertTrue(
            WhatsNewStore.shouldPresent(
                currentBuild: 1,
                lastSeenBuild: WhatsNewStore.lastSeenBuild(defaults: defaults),
                catalogNonEmpty: true
            )
        )
    }

    func testMarkSeenPersistsCurrentBuild() {
        guard let build = WhatsNewStore.currentBuild(bundle: .main) else {
            XCTFail("Expected CFBundleVersion in test host bundle")
            return
        }
        WhatsNewStore.markSeen(bundle: .main, defaults: defaults)
        XCTAssertEqual(WhatsNewStore.lastSeenBuild(defaults: defaults), build)
    }

    func testBundledCatalogLoadsAtLeastOneRelease() {
        let releases = WhatsNewCatalog.load()
        XCTAssertFalse(releases.isEmpty)
        XCTAssertEqual(releases[0].build, "23")
        XCTAssertEqual(releases[0].version, "0.1.22")
    }

    func testReleasesWithBuildGreaterThanFiltersCorrectly() {
        let releases = [
            WhatsNewRelease(version: "0.1.18", build: "19", title: "A", items: []),
            WhatsNewRelease(version: "0.1.17", build: "18", title: "B", items: []),
        ]
        let filtered = releases.filter { release in
            guard let build = release.buildNumber else { return false }
            return build > 18
        }
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].build, "19")
    }
}
