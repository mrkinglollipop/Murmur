import XCTest

final class GiphyClientTests: XCTestCase {
    func testTrendingURLUsesRatingGAndCappedLimit() {
        let url = GiphyClient.trendingURL(apiKey: "test-key", limit: 99)
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.host, "api.giphy.com")
        XCTAssertEqual(url?.path, "/v1/gifs/trending")
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(value("rating", in: items), "g")
        XCTAssertEqual(value("limit", in: items), "24")
        XCTAssertEqual(value("api_key", in: items), "test-key")
        XCTAssertNil(value("q", in: items))
    }

    func testSearchURLEncodesQuery() {
        let url = GiphyClient.searchURL(apiKey: "test-key", query: "nope cat")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.path, "/v1/gifs/search")
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(value("q", in: items), "nope cat")
        XCTAssertEqual(value("rating", in: items), "g")
    }

    func testEmptyKeyMakesNoURL() {
        XCTAssertNil(GiphyClient.trendingURL(apiKey: "  "))
        XCTAssertNil(GiphyClient.searchURL(apiKey: "", query: "nope"))
    }

    func testParseSkipsItemsWithoutRenditions() throws {
        let json = """
        {
          "data": [
            {
              "id": "abc",
              "title": "Nope",
              "images": {
                "fixed_height_small_still": { "url": "https://media.giphy.com/preview.gif" },
                "downsized": { "url": "https://media.giphy.com/downsized.gif" }
              }
            },
            {
              "id": "skip",
              "title": "Broken",
              "images": {}
            }
          ]
        }
        """.data(using: .utf8)!
        let gifs = try GiphyClient.parse(json)
        XCTAssertEqual(gifs.count, 1)
        XCTAssertEqual(gifs[0].id, "abc")
        XCTAssertEqual(gifs[0].title, "Nope")
        XCTAssertEqual(gifs[0].previewURL.absoluteString, "https://media.giphy.com/preview.gif")
        XCTAssertEqual(gifs[0].sendURL.absoluteString, "https://media.giphy.com/downsized.gif")
    }

    func testParseFallsBackToSmallThenOriginal() throws {
        let json = """
        {
          "data": [
            {
              "id": "def",
              "images": {
                "fixed_width_small": { "url": "https://media.giphy.com/small.gif" },
                "original": { "url": "https://media.giphy.com/original.gif" }
              }
            }
          ]
        }
        """.data(using: .utf8)!
        let gifs = try GiphyClient.parse(json)
        XCTAssertEqual(gifs[0].previewURL.absoluteString, "https://media.giphy.com/small.gif")
        XCTAssertEqual(gifs[0].sendURL.absoluteString, "https://media.giphy.com/original.gif")
    }

    private func value(_ name: String, in items: [URLQueryItem]) -> String? {
        items.first(where: { $0.name == name })?.value
    }
}
