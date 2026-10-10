import XCTest
@testable import Voice

/// Loopback OAuth redirect: request parsing (pure) and one real HTTP round
/// trip over 127.0.0.1. No Keychain, no external network.
final class LoopbackRedirectServerTests: XCTestCase {

    // MARK: - Request-head parsing (pure)

    func testRequestTargetParsesGetLine() {
        XCTAssertEqual(
            LoopbackRedirectServer.requestTarget(
                fromRequestHead: "GET /auth-callback?code=abc HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"),
            "/auth-callback?code=abc"
        )
    }

    func testRequestTargetRejectsNonGetAndGarbage() {
        XCTAssertNil(LoopbackRedirectServer.requestTarget(fromRequestHead: "POST /auth-callback HTTP/1.1\r\n"))
        XCTAssertNil(LoopbackRedirectServer.requestTarget(fromRequestHead: "not http at all"))
        XCTAssertNil(LoopbackRedirectServer.requestTarget(fromRequestHead: ""))
        XCTAssertNil(LoopbackRedirectServer.requestTarget(fromRequestHead: "GET /auth-callback HTTP/what\r\nHost: 127.0.0.1\r\n\r\n"))
        XCTAssertNil(LoopbackRedirectServer.requestTarget(fromRequestHead: "GET /auth-callback HTTP/1.1\r\nMalformed header\r\n\r\n"))
        XCTAssertNil(LoopbackRedirectServer.requestTarget(fromRequestHead: "GET /auth-callback HTTP/1.1 extra\r\nHost: 127.0.0.1\r\n\r\n"))
    }

    func testMalformedHeadGets400AndCannotProduceCallback() {
        let malformed = "GET /auth-callback?code=must-not-deliver HTTP/1.1\r\nMalformed header\r\n\r\n"
        XCTAssertEqual(LoopbackRedirectServer.responseStatus(forRequestHead: malformed), "400 Bad Request")
        XCTAssertNil(LoopbackRedirectServer.requestTarget(fromRequestHead: malformed))
    }

    func testFragmentedRequestHeadWaitsThenDeliversOnlyAfterTerminator() {
        let first = Data("GET /auth-callback?code=fragment HTTP/1.1\r\nHost: 127.0.0.1\r\n".utf8)
        XCTAssertEqual(
            LoopbackRedirectServer.requestHeadResult(accumulated: Data(), received: first, complete: false),
            .waitForMore
        )
        XCTAssertEqual(
            LoopbackRedirectServer.requestHeadResult(accumulated: first, received: Data("\r\n".utf8), complete: false),
            .target("/auth-callback?code=fragment")
        )
    }

    func testOversizeHeadIsRejectedBeforeCallbackParsing() {
        let oversized = Data(repeating: 65, count: 9 * 1024)
        XCTAssertEqual(
            LoopbackRedirectServer.requestHeadResult(accumulated: Data(), received: oversized, complete: false),
            .badRequest
        )
    }

    func testConnectionAdmissionIsBoundedAndStopsAfterEnd() {
        XCTAssertTrue(LoopbackRedirectServer.shouldAcceptConnection(
            retainedCount: 7, hasResultHandler: true, isStopped: false
        ))
        XCTAssertFalse(LoopbackRedirectServer.shouldAcceptConnection(
            retainedCount: 8, hasResultHandler: true, isStopped: false
        ))
        XCTAssertFalse(LoopbackRedirectServer.shouldAcceptConnection(
            retainedCount: 0, hasResultHandler: false, isStopped: false
        ))
        XCTAssertFalse(LoopbackRedirectServer.shouldAcceptConnection(
            retainedCount: 0, hasResultHandler: true, isStopped: true
        ))
    }

    // MARK: - Callback extraction (pure)

    func testCallbackResultParsesCode() {
        XCTAssertEqual(
            LoopbackRedirectServer.callbackResult(fromTarget: "/auth-callback?code=xyz-123"),
            .success("xyz-123")
        )
    }

    func testCallbackResultPrefersErrorDescription() {
        XCTAssertEqual(
            LoopbackRedirectServer.callbackResult(fromTarget: "/auth-callback?error=access_denied&error_description=Nope"),
            .failure(.callbackCarriedError("Nope"))
        )
    }

    func testCallbackResultMissingCodeFails() {
        XCTAssertEqual(
            LoopbackRedirectServer.callbackResult(fromTarget: "/auth-callback"),
            .failure(.callbackMissingCode)
        )
    }

    /// Favicon and other stray requests are not callbacks at all.
    func testNonCallbackPathsReturnNil() {
        XCTAssertNil(LoopbackRedirectServer.callbackResult(fromTarget: "/favicon.ico"))
        XCTAssertNil(LoopbackRedirectServer.callbackResult(fromTarget: "/"))
    }

    func testCallbackPageMakesNoSignInClaim() {
        let page = LoopbackRedirectServer.responseHTML()
        XCTAssertTrue(page.contains("You can return to Murmur"))
        XCTAssertFalse(page.localizedCaseInsensitiveContains("signed in"))
    }

    // MARK: - Redirect URI shape

    func testRedirectURIMatchesAllowListShape() {
        XCTAssertEqual(LoopbackRedirectServer.redirectURI(port: 52795), "http://127.0.0.1:52795/auth-callback")
    }

    /// The authorize URL must carry whatever redirect the caller chose —
    /// the loopback flow depends on this parameter actually landing in the
    /// query string.
    func testAuthorizeURLCarriesCustomRedirect() {
        let url = SupabaseAuthClient.authorizeURL(
            provider: .google, verifier: "v", redirectTo: "http://127.0.0.1:52795/auth-callback")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(
            items.first(where: { $0.name == "redirect_to" })?.value,
            "http://127.0.0.1:52795/auth-callback"
        )
    }

    // MARK: - Live round trip

    /// Boot the listener, GET the callback URL like a browser would, and
    /// expect both the parsed code and a human-readable close-this-tab page.
    func testLiveRoundTripDeliversCodeAndClosePage() async throws {
        let delivered = expectation(description: "code delivered")
        var received: Result<String, SupabaseAuthClient.AuthError>?
        guard let server = LoopbackRedirectServer.start(onResult: { result in
            received = result
            delivered.fulfill()
        }) else {
            XCTFail("no loopback port available")
            return
        }
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(server.port)/auth-callback?code=live-abc")!
        let (body, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(data: body, encoding: .utf8)?.contains("close this tab") == true)

        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(received, .success("live-abc"))
    }

    /// An unbound error must not consume the listener. The still-open browser
    /// can subsequently deliver the current attempt's valid code on the exact
    /// redirect port it was originally given.
    func testListenerDeliversErrorThenCodeCandidates() async throws {
        var received: [Result<String, SupabaseAuthClient.AuthError>] = []
        let candidates = expectation(description: "both candidates delivered")
        candidates.expectedFulfillmentCount = 2
        guard let server = LoopbackRedirectServer.start(onResult: { result in
            received.append(result)
            candidates.fulfill()
        }) else {
            XCTFail("no loopback port available")
            return
        }
        defer { server.stop() }

        let base = "http://127.0.0.1:\(server.port)/auth-callback"
        _ = try await URLSession.shared.data(from: URL(string: "\(base)?error=access_denied")!)
        _ = try await URLSession.shared.data(from: URL(string: "\(base)?code=current")!)
        await fulfillment(of: [candidates], timeout: 5)
        XCTAssertEqual(received, [
            .failure(.callbackCarriedError("access_denied")),
            .success("current")
        ])
    }

}
