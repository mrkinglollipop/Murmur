import AVFoundation
import SwiftUI
import UIKit

/// Containing-app shell: add keyboard, Full Access, mic permission, BYO key.
/// No accounts. Dark by design.
struct OnboardingView: View {
    @State private var apiKey = AppGroupStore.apiKey
    @State private var giphyAPIKey = AppGroupStore.giphyAPIKey
    @State private var micStatus: String = "Not requested"
    @State private var rehearsal = ""
    @FocusState private var rehearsalFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Enable the keyboard, then dictate in Messages. iOS blocks the mic in the keyboard, so the mic opens this app for a second, then you bounce back.")
                        .font(.subheadline)
                        .foregroundStyle(Color(red: 0.604, green: 0.604, blue: 0.635))

                    step(1, title: "Add the keyboard") {
                        Text("Settings → General → Keyboard → Keyboards → Add New Keyboard… → Murmur")
                            .font(.footnote)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    step(2, title: "Allow Full Access") {
                        Text("After adding it, go back to Keyboards and tap the Murmur row. Turn on Allow Full Access. Without it the keyboard cannot open Murmur to record.")
                            .font(.footnote)
                    }

                    step(3, title: "Microphone") {
                        Text("Grant mic here. Recording happens in this app, not inside the keyboard.")
                            .font(.footnote)
                        Text(micStatus)
                            .font(.footnote.monospaced())
                            .foregroundStyle(Color(red: 0.604, green: 0.604, blue: 0.635))
                        Button("Request microphone") {
                            requestMic()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.847, green: 0.353, blue: 0.188))
                    }

                    step(4, title: "ElevenLabs API key") {
                        SecureField("xi-api-key", text: $apiKey)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: apiKey) { _, value in
                                AppGroupStore.apiKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        Text("Stored in the App Group. The keyboard reads it; nothing goes to Murmur-server.")
                            .font(.footnote)
                            .foregroundStyle(Color(red: 0.604, green: 0.604, blue: 0.635))
                    }

                    step(5, title: "Giphy API key") {
                        SecureField("Giphy iOS key", text: $giphyAPIKey)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: giphyAPIKey) { _, value in
                                AppGroupStore.giphyAPIKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        Text("Optional. Full Access plus this key turns on the GIF button. Stored in the App Group; the keyboard calls Giphy’s REST API directly.")
                            .font(.footnote)
                            .foregroundStyle(Color(red: 0.604, green: 0.604, blue: 0.635))
                    }

                    step(6, title: "Rehearse") {
                        TextField("Tap here, switch to Murmur keyboard", text: $rehearsal, axis: .vertical)
                            .lineLimit(3...6)
                            .focused($rehearsalFocused)
                            .padding(10)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(20)
            }
            .background(Color(red: 0.063, green: 0.063, blue: 0.078).ignoresSafeArea())
            .foregroundStyle(Color(red: 0.961, green: 0.961, blue: 0.969))
            .navigationTitle("Murmur")
            .onAppear {
                AppGroupStore.consumeGiphySeedIfNeeded()
                giphyAPIKey = AppGroupStore.giphyAPIKey
                refreshMicStatus()
            }
        }
        .preferredColorScheme(.dark)
    }

    private func step(_ n: Int, title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(n). \(title)")
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func requestMic() {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                micStatus = granted ? "Granted" : "Denied"
            }
        }
    }

    private func refreshMicStatus() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: micStatus = "Granted"
        case .denied: micStatus = "Denied"
        case .undetermined: micStatus = "Not requested"
        @unknown default: micStatus = "Unknown"
        }
    }
}
