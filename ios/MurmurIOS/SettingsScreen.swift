import AVFoundation
import SwiftUI
import UIKit

struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = AppGroupStore.apiKey
    @State private var giphyAPIKey = AppGroupStore.giphyAPIKey
    @State private var swipeTypingEnabled = AppGroupStore.swipeTypingEnabled
    @State private var micStatus = "Not requested"
    @State private var rehearsal = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("Setup") {
                        settingsRow(
                            title: "Add the keyboard",
                            subtitle: "Settings → General → Keyboard → Keyboards → Add New Keyboard… → Murmur"
                        ) {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .font(AppTheme.sans(15, weight: .semibold))
                            .foregroundStyle(AppTheme.coral)
                        }

                        divider
                        settingsRow(
                            title: "Allow Full Access",
                            subtitle: "Open the Murmur keyboard row and turn on Allow Full Access. Without it the keyboard cannot open Murmur to record."
                        )

                        divider
                        settingsRow(
                            title: "Microphone",
                            subtitle: "Grant mic here. Recording happens in this app, not inside the keyboard. \(micStatus)"
                        ) {
                            Button("Request microphone") {
                                requestMic()
                            }
                            .font(AppTheme.sans(15, weight: .semibold))
                            .foregroundStyle(AppTheme.coral)
                        }
                    }

                    section("Keyboard") {
                        settingsRow(
                            title: "Swipe to type",
                            subtitle: "Experimental. Off turns swipe off and leaves tap typing. Kill this if it still loses to Apple QuickPath."
                        ) {
                            Toggle("", isOn: $swipeTypingEnabled)
                                .labelsHidden()
                                .tint(AppTheme.coral)
                                .onChange(of: swipeTypingEnabled) { _, value in
                                    AppGroupStore.swipeTypingEnabled = value
                                }
                        }

                        divider
                        settingsRow(
                            title: "Learn new words",
                            subtitle: "English only. Type a name or jargon, then tap the quoted spelling in the suggestion bar — same gesture as Apple’s keyboard. The word is saved for typing, swipe, and dictation. Manage the list in Dictionary."
                        )
                    }

                    section("Dictation") {
                        settingsRow(
                            title: "Action Button",
                            subtitle: "iPhone Settings → Action Button → Shortcut → Murmur → Start Dictation. Opens Murmur and listens. Stop in the app; the transcript copies to the clipboard. Keyboard Start still inserts in the host app."
                        )
                    }

                    section("Keys") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("ElevenLabs API key")
                                .font(AppTheme.sans(16, weight: .semibold))
                                .foregroundStyle(AppTheme.ink)
                            SecureField("xi-api-key", text: $apiKey)
                                .textContentType(.password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .onChange(of: apiKey) { _, value in
                                    AppGroupStore.apiKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            Text("Stored in the App Group. Nothing goes to a Murmur server.")
                                .font(AppTheme.sans(13))
                                .foregroundStyle(AppTheme.muted)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                        divider

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Giphy API key")
                                .font(AppTheme.sans(16, weight: .semibold))
                                .foregroundStyle(AppTheme.ink)
                            SecureField("Giphy iOS key", text: $giphyAPIKey)
                                .textContentType(.password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .onChange(of: giphyAPIKey) { _, value in
                                    AppGroupStore.giphyAPIKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            Text("Optional. Full Access plus this key turns on the GIF button.")
                                .font(AppTheme.sans(13))
                                .foregroundStyle(AppTheme.muted)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }

                    section("Rehearse") {
                        TextField("Tap here, switch to Murmur keyboard", text: $rehearsal, axis: .vertical)
                            .lineLimit(3...6)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                    }
                }
                .padding(20)
            }
            .background(AppTheme.bg.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                AppGroupStore.consumeGiphySeedIfNeeded()
                giphyAPIKey = AppGroupStore.giphyAPIKey
                swipeTypingEnabled = AppGroupStore.swipeTypingEnabled
                refreshMicStatus()
            }
        }
        .preferredColorScheme(.light)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(AppTheme.sans(12, weight: .medium))
                .foregroundStyle(AppTheme.muted)
                .padding(.leading, 8)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
        }
    }

    private func settingsRow(
        title: String,
        subtitle: String,
        @ViewBuilder accessory: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AppTheme.sans(16, weight: .semibold))
                .foregroundStyle(AppTheme.ink)
            Text(subtitle)
                .font(AppTheme.sans(13))
                .foregroundStyle(AppTheme.muted)
            accessory()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var divider: some View {
        Divider().overlay(AppTheme.hairline).padding(.leading, 16)
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
