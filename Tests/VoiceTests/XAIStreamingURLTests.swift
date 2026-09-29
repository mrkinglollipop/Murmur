import XCTest
@testable import Voice

final class XAIStreamingURLTests: XCTestCase {
    func testBuildSocketURLDefaultEndpointingIs5000() {
        let url = XAIStreamingTranscriber.buildSocketURL(language: "en")
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first(where: { $0.name == "endpointing" })?.value, "5000")
        XCTAssertEqual(items.first(where: { $0.name == "interim_results" })?.value, "true")
    }

    func testBuildSocketURLPinsModel() {
        let url = XAIStreamingTranscriber.buildSocketURL(language: "en")
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first(where: { $0.name == "model" })?.value, "grok-voice-transcribe-2.0")
    }

    func testBuildSocketURLClampsEndpointingToRange() {
        let low = XAIStreamingTranscriber.buildSocketURL(language: "en", endpointingMs: 1)
        let high = XAIStreamingTranscriber.buildSocketURL(language: "en", endpointingMs: 99_000)
        let lowItems = URLComponents(url: low!, resolvingAgainstBaseURL: false)!.queryItems!
        let highItems = URLComponents(url: high!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(lowItems.first(where: { $0.name == "endpointing" })?.value, "500")
        XCTAssertEqual(highItems.first(where: { $0.name == "endpointing" })?.value, "5000")
    }

    func testBuildSocketURLPassesExplicitEndpointing() {
        let url = XAIStreamingTranscriber.buildSocketURL(language: "en", endpointingMs: 1200)
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first(where: { $0.name == "endpointing" })?.value, "1200")
    }
}
