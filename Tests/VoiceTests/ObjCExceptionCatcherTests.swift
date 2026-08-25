import XCTest
@testable import Voice

final class ObjCExceptionCatcherTests: XCTestCase {

    func testCatcherConvertsRaisedNSExceptionToError() {
        let result = ObjCExceptionCatcher.run {
            NSException(
                name: .genericException,
                reason: "unit-test",
                userInfo: nil
            ).raise()
        }
        switch result {
        case .success:
            XCTFail("expected NSException to become an error")
        case .failure(let error):
            XCTAssertEqual(error.domain, ObjCExceptionCatcher.errorDomain)
            XCTAssertTrue(
                error.localizedDescription.contains("unit-test"),
                error.localizedDescription
            )
        }
    }

    func testCatcherSuccessWhenBlockDoesNotRaise() {
        var ran = false
        let result = ObjCExceptionCatcher.run { ran = true }
        XCTAssertTrue(ran)
        if case .failure(let error) = result {
            XCTFail("unexpected error: \(error)")
        }
    }
}
