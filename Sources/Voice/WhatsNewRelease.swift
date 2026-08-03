import Foundation

struct WhatsNewRelease: Codable, Identifiable, Equatable {
    let version: String
    let build: String
    let title: String
    let items: [String]

    var id: String { "\(version)-\(build)" }

    var buildNumber: Int? { Int(build) }
}

enum WhatsNewCatalog {
    private final class BundleAnchor {}

    static let resourceName = "releases"
    static let resourceSubdirectory = "WhatsNew"

    static var resourceBundle: Bundle {
        Bundle(for: BundleAnchor.self)
    }

    /// Newest-first release notes bundled with the app. Returns an empty array
    /// when the resource is missing or cannot be decoded.
    static func load(bundle: Bundle = resourceBundle) -> [WhatsNewRelease] {
        let url =
            bundle.url(
                forResource: resourceName,
                withExtension: "json",
                subdirectory: resourceSubdirectory
            )
            ?? bundle.url(forResource: resourceName, withExtension: "json")

        guard let url else { return [] }
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let releases = try? JSONDecoder().decode([WhatsNewRelease].self, from: data) else {
            return []
        }
        return releases
    }

    static func latest(bundle: Bundle = resourceBundle) -> WhatsNewRelease? {
        load(bundle: bundle).first
    }

    static func releases(withBuildGreaterThan build: Int, bundle: Bundle = resourceBundle) -> [WhatsNewRelease] {
        load(bundle: bundle).filter { release in
            guard let releaseBuild = release.buildNumber else { return false }
            return releaseBuild > build
        }
    }
}
