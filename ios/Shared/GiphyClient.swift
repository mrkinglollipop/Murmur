import Foundation

/// Tiny Giphy REST client for the keyboard appex. No SDK. Grid uses still
/// renditions; animated bytes are fetched only after a tap.
enum GiphyClient {
    struct GIF: Equatable {
        let id: String
        let title: String
        let previewURL: URL
        let sendURL: URL
    }

    enum ClientError: Error, Equatable {
        case missingKey
        case badURL
        case http(Int)
        case decode
    }

    private static let host = "api.giphy.com"
    private static let maxLimit = 24
    private static let maxDownloadBytes = 8 * 1024 * 1024

    private static let session: URLSession = {
        let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupStore.suiteName
        )?.appendingPathComponent("Library/Caches/giphy", isDirectory: true)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let cache = URLCache(
            memoryCapacity: 4 * 1024 * 1024,
            diskCapacity: 16 * 1024 * 1024,
            directory: directory
        )
        let config = URLSessionConfiguration.default
        config.urlCache = cache
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: config)
    }()

    static func trendingURL(apiKey: String, limit: Int = maxLimit) -> URL? {
        makeURL(path: "/v1/gifs/trending", apiKey: apiKey, query: nil, limit: limit)
    }

    static func searchURL(apiKey: String, query: String, limit: Int = maxLimit) -> URL? {
        makeURL(path: "/v1/gifs/search", apiKey: apiKey, query: query, limit: limit)
    }

    static func parse(_ data: Data) throws -> [GIF] {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ClientError.decode
        }
        return envelope.data.compactMap(GIF.init(item:))
    }

    static func fetch(url: URL) async throws -> [GIF] {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ClientError.http(http.statusCode)
        }
        return try parse(data)
    }

    static func fetchData(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ClientError.http(http.statusCode)
        }
        guard data.count <= maxDownloadBytes else { throw ClientError.decode }
        return data
    }

    static func makeURL(path: String, apiKey: String, query: String?, limit: Int) -> URL? {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        var items = [
            URLQueryItem(name: "api_key", value: trimmed),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), maxLimit))),
            URLQueryItem(name: "rating", value: "g")
        ]
        if let query {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty {
                items.append(URLQueryItem(name: "q", value: q))
            }
        }
        components.queryItems = items
        return components.url
    }
}

private struct Envelope: Decodable {
    let data: [Item]
}

private struct Item: Decodable {
    let id: String
    let title: String?
    let images: Images?
}

private struct Images: Decodable {
    let fixedHeightSmallStill: Rendition?
    let fixedWidthSmallStill: Rendition?
    let fixedHeightSmall: Rendition?
    let fixedWidthSmall: Rendition?
    let downsized: Rendition?
    let original: Rendition?

    enum CodingKeys: String, CodingKey {
        case fixedHeightSmallStill = "fixed_height_small_still"
        case fixedWidthSmallStill = "fixed_width_small_still"
        case fixedHeightSmall = "fixed_height_small"
        case fixedWidthSmall = "fixed_width_small"
        case downsized
        case original
    }
}

private struct Rendition: Decodable {
    let url: String?
}

private extension GiphyClient.GIF {
    init?(item: Item) {
        guard !item.id.isEmpty else { return nil }
        let preview = item.images?.fixedHeightSmallStill?.url
            ?? item.images?.fixedWidthSmallStill?.url
            ?? item.images?.fixedHeightSmall?.url
            ?? item.images?.fixedWidthSmall?.url
        let send = item.images?.downsized?.url
            ?? item.images?.original?.url
            ?? preview
        guard let preview, let send,
              let previewURL = URL(string: preview),
              let sendURL = URL(string: send) else { return nil }
        self.init(
            id: item.id,
            title: item.title ?? "",
            previewURL: previewURL,
            sendURL: sendURL
        )
    }
}
