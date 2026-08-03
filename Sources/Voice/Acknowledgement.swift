import Foundation

struct Acknowledgement: Identifiable, Equatable {
    let id: String
    let name: String
    let licenseType: String
    let url: URL
    let licenseResourceName: String
}

enum Acknowledgements {
    static let all: [Acknowledgement] = [
        Acknowledgement(
            id: "whisperkit",
            name: "WhisperKit",
            licenseType: "MIT",
            url: URL(string: "https://github.com/argmaxinc/WhisperKit")!,
            licenseResourceName: "WhisperKit-LICENSE"
        ),
        Acknowledgement(
            id: "sparkle",
            name: "Sparkle",
            licenseType: "MIT",
            url: URL(string: "https://github.com/sparkle-project/Sparkle")!,
            licenseResourceName: "Sparkle-LICENSE"
        ),
        Acknowledgement(
            id: "fluidaudio",
            name: "FluidAudio",
            licenseType: "Apache 2.0",
            url: URL(string: "https://github.com/FluidInference/FluidAudio")!,
            licenseResourceName: "FluidAudio-LICENSE"
        ),
        Acknowledgement(
            id: "eb-garamond",
            name: "EB Garamond",
            licenseType: "OFL",
            url: URL(string: "https://github.com/octaviopardo/EBGaramond12")!,
            licenseResourceName: "EBGaramond-OFL"
        ),
        Acknowledgement(
            id: "figtree",
            name: "Figtree",
            licenseType: "OFL",
            url: URL(string: "https://github.com/erikdkennedy/figtree")!,
            licenseResourceName: "Figtree-OFL"
        ),
    ]

    /// Loads the verbatim bundled license text for `item`. Returns a clear
    /// placeholder string (never crashes) if the resource is somehow missing.
    static func licenseText(for item: Acknowledgement, bundle: Bundle = .main) -> String {
        let url = bundle.url(
            forResource: item.licenseResourceName,
            withExtension: "txt",
            subdirectory: "Licenses"
        ) ?? bundle.url(
            forResource: item.licenseResourceName,
            withExtension: "txt"
        )
        guard let url else {
            return "License text for \(item.name) is not available in this build."
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            return "License text for \(item.name) could not be read."
        }
        return text
    }
}
