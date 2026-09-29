import XCTest
@testable import Voice

final class LockedReferenceTests: XCTestCase {

    private final class Probe {}

    func testSnapshotSurvivesClear() {
        let ref = LockedReference<Probe>(Probe())
        let snapshot = ref.current
        ref.current = nil
        XCTAssertNil(ref.current)
        XCTAssertNotNil(snapshot)
    }

    func testStartsEmptyAndReturnsAssignedValue() {
        let ref = LockedReference<Probe>()
        XCTAssertNil(ref.current)
        let probe = Probe()
        ref.current = probe
        XCTAssertTrue(ref.current === probe)
    }

    /// Main-thread writers racing a reader thread must never crash or hand
    /// back a dangling reference.
    func testConcurrentSetAndReadIsSafe() {
        let ref = LockedReference<Probe>(Probe())
        let finished = expectation(description: "reader finished")
        let reader = Thread {
            for _ in 0 ..< 50_000 {
                let snapshot = ref.current
                _ = snapshot.map { ObjectIdentifier($0) }
            }
            finished.fulfill()
        }
        reader.start()
        for i in 0 ..< 50_000 {
            ref.current = i.isMultiple(of: 2) ? nil : Probe()
        }
        wait(for: [finished], timeout: 30)
    }
}
