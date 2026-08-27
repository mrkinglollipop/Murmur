import AVFoundation
import SwiftUI
import UIKit

struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = AppGroupStore.apiKey
    @State private var geminiAPIKey = AppGroupStore.geminiAPIKey
    @State private var selectedCloudEngine = AppGroupStore.selectedCloudEngine
    @State private var giphyAPIKey = AppGroupStore.giphyAPIKey
    @State private var swipeTypingEnabled = AppGroupStore.swipeTypingEnabled
    @State private var removeFillerWords = AppGroupStore.removeFillerWords
    @State private var elevenLabsFilterBackgroundAudio = AppGroupStore.elevenLabsFilterBackgroundAudio
    @State private var elevenLabsCommitStrategy = AppGroupStore.elevenLabsCommitStrategy
    @State private var elevenLabsVadThreshold = AppGroupStore.elevenLabsVadThreshold
    @State private var elevenLabsVadSilenceThresholdSecs = AppGroupStore.elevenLabsVadSilenceThresholdSecs
    @State private var elevenLabsMinSpeechDurationMs = AppGroupStore.elevenLabsMinSpeechDurationMs
    @State private var elevenLabsMinSilenceDurationMs = AppGroupStore.elevenLabsMinSilenceDurationMs
    @State private var geminiVadMode = AppGroupStore.geminiVadMode
    @State private var geminiStartSensitivity = AppGroupStore.geminiStartSensitivity
    @State private var geminiEndSensitivity = AppGroupStore.geminiEndSensitivity
    @State private var geminiPrefixPaddingMs = AppGroupStore.geminiPrefixPaddingMs
    @State private var geminiSilenceDurationMs = AppGroupStore.geminiSilenceDurationMs
    @State private var interstitialIDs = AppGroupStore.interstitialReturnAppIDs
    @State private var showingAddApps = false
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
                            subtitle: "Off by default. Turn on to experiment. If typing still deletes whole sentences, leave this off."
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
                            title: "Cloud engine",
                            subtitle: "Host-app recording streams live during the take; batch is fallback only."
                        ) {
                            Picker("", selection: $selectedCloudEngine) {
                                ForEach(SelectedCloudEngine.allCases) { engine in
                                    Text(engine.displayName).tag(engine)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .onChange(of: selectedCloudEngine) { _, value in
                                AppGroupStore.selectedCloudEngine = value
                            }
                        }

                        divider

                        settingsRow(
                            title: "Action Button",
                            subtitle: "iPhone Settings → Action Button → Shortcut → Murmur → Start Dictation. Opens Murmur and listens. Stop in the app; the transcript copies to the clipboard. Keyboard Start still inserts in the host app."
                        )

                        divider
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 10) {
                                settingsRow(
                                    title: "Remove filler words",
                                    subtitle: "Strips ums, false starts, and stuttering. Turn off if it swallows a spoken correction."
                                ) {
                                    Toggle("", isOn: $removeFillerWords)
                                        .labelsHidden()
                                        .tint(AppTheme.coral)
                                        .onChange(of: removeFillerWords) { _, value in
                                            AppGroupStore.removeFillerWords = value
                                        }
                                }

                                if selectedCloudEngine == .elevenLabs {
                                    divider
                                    settingsRow(
                                        title: "Filter background audio",
                                        subtitle: "Server-side: reduces other talkers and ambient false activations."
                                    ) {
                                        Toggle("", isOn: $elevenLabsFilterBackgroundAudio)
                                            .labelsHidden()
                                            .tint(AppTheme.coral)
                                            .onChange(of: elevenLabsFilterBackgroundAudio) { _, value in
                                                AppGroupStore.elevenLabsFilterBackgroundAudio = value
                                            }
                                    }

                                    Picker("Commit", selection: $elevenLabsCommitStrategy) {
                                        ForEach(ElevenLabsCommitStrategy.allCases) { strategy in
                                            Text(strategy.displayName).tag(strategy)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .onChange(of: elevenLabsCommitStrategy) { _, value in
                                        AppGroupStore.elevenLabsCommitStrategy = value
                                    }

                                    if elevenLabsCommitStrategy == .vad {
                                        Stepper(
                                            "Speech threshold: \(elevenLabsVadThreshold, specifier: "%.2f")",
                                            value: $elevenLabsVadThreshold,
                                            in: ElevenLabsRealtimeOptions.vadThresholdRange,
                                            step: 0.05
                                        )
                                        .onChange(of: elevenLabsVadThreshold) { _, value in
                                            AppGroupStore.elevenLabsVadThreshold = value
                                        }
                                        Stepper(
                                            "Silence to commit: \(elevenLabsVadSilenceThresholdSecs, specifier: "%.1f")s",
                                            value: $elevenLabsVadSilenceThresholdSecs,
                                            in: ElevenLabsRealtimeOptions.vadSilenceRange,
                                            step: 0.1
                                        )
                                        .onChange(of: elevenLabsVadSilenceThresholdSecs) { _, value in
                                            AppGroupStore.elevenLabsVadSilenceThresholdSecs = value
                                        }
                                        Stepper(
                                            "Minimum speech: \(elevenLabsMinSpeechDurationMs) ms",
                                            value: $elevenLabsMinSpeechDurationMs,
                                            in: ElevenLabsRealtimeOptions.minSpeechMsRange,
                                            step: 10
                                        )
                                        .onChange(of: elevenLabsMinSpeechDurationMs) { _, value in
                                            AppGroupStore.elevenLabsMinSpeechDurationMs = value
                                        }
                                        Stepper(
                                            "Minimum silence: \(elevenLabsMinSilenceDurationMs) ms",
                                            value: $elevenLabsMinSilenceDurationMs,
                                            in: ElevenLabsRealtimeOptions.minSilenceMsRange,
                                            step: 10
                                        )
                                        .onChange(of: elevenLabsMinSilenceDurationMs) { _, value in
                                            AppGroupStore.elevenLabsMinSilenceDurationMs = value
                                        }
                                    }
                                }

                                if selectedCloudEngine == .gemini {
                                    divider
                                    Text("Preview model — a paid Gemini API key is recommended. Free-tier keys may be used to improve Google products.")
                                        .font(AppTheme.sans(13))
                                        .foregroundStyle(AppTheme.muted)

                                    Picker("VAD mode", selection: $geminiVadMode) {
                                        ForEach(GeminiVadMode.allCases) { mode in
                                            Text(mode.displayName).tag(mode)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .onChange(of: geminiVadMode) { _, value in
                                        AppGroupStore.geminiVadMode = value
                                    }

                                    if geminiVadMode == .automatic || geminiVadMode == .hybrid {
                                        Picker("Start sensitivity", selection: $geminiStartSensitivity) {
                                            ForEach(GeminiStartSensitivity.allCases) { value in
                                                Text(value.displayName).tag(value)
                                            }
                                        }
                                        .pickerStyle(.segmented)
                                        .onChange(of: geminiStartSensitivity) { _, value in
                                            AppGroupStore.geminiStartSensitivity = value
                                        }

                                        Picker("End sensitivity", selection: $geminiEndSensitivity) {
                                            ForEach(GeminiEndSensitivity.allCases) { value in
                                                Text(value.displayName).tag(value)
                                            }
                                        }
                                        .pickerStyle(.segmented)
                                        .onChange(of: geminiEndSensitivity) { _, value in
                                            AppGroupStore.geminiEndSensitivity = value
                                        }

                                        Stepper(
                                            "Prefix padding: \(geminiPrefixPaddingMs) ms",
                                            value: $geminiPrefixPaddingMs,
                                            in: GeminiLiveOptions.prefixPaddingRange,
                                            step: 10
                                        )
                                        .onChange(of: geminiPrefixPaddingMs) { _, value in
                                            AppGroupStore.geminiPrefixPaddingMs = value
                                        }

                                        Stepper(
                                            "Silence duration: \(geminiSilenceDurationMs) ms",
                                            value: $geminiSilenceDurationMs,
                                            in: GeminiLiveOptions.silenceDurationRange,
                                            step: 10
                                        )
                                        .onChange(of: geminiSilenceDurationMs) { _, value in
                                            AppGroupStore.geminiSilenceDurationMs = value
                                        }
                                    }
                                }
                            }
                        } label: {
                            Text("Advanced")
                                .font(AppTheme.sans(16, weight: .semibold))
                                .foregroundStyle(AppTheme.ink)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .tint(AppTheme.muted)
                    }

                    section("Return apps") {
                        settingsRow(
                            title: "Jump-back grid",
                            subtitle: "Shown on the swipe screen after keyboard dictation. Add any installed app, drag to rearrange, tap minus to remove. Swipe still works if you skip them."
                        )
                        JumpBackAppGrid(
                            bundleIDs: interstitialIDs,
                            showsAdd: true,
                            showsRemove: true,
                            allowsReorder: true,
                            onAdd: { showingAddApps = true },
                            onRemove: { id in
                                AppGroupStore.removeInterstitialReturnApp(id)
                                interstitialIDs = AppGroupStore.interstitialReturnAppIDs
                            },
                            onReorder: { moving, onto in
                                AppGroupStore.reorderInterstitialReturnApp(moving: moving, onto: onto)
                                interstitialIDs = AppGroupStore.interstitialReturnAppIDs
                            }
                        )
                        .padding(.horizontal, 12)
                        .padding(.bottom, 14)
                    }

                    section("Keys") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(selectedCloudEngine == .gemini ? "Gemini API key" : "ElevenLabs API key")
                                .font(AppTheme.sans(16, weight: .semibold))
                                .foregroundStyle(AppTheme.ink)
                            if selectedCloudEngine == .gemini {
                                SecureField("Gemini API key", text: $geminiAPIKey)
                                    .textContentType(.password)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .onChange(of: geminiAPIKey) { _, value in
                                        AppGroupStore.geminiAPIKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                    }
                            } else {
                                SecureField("xi-api-key", text: $apiKey)
                                    .textContentType(.password)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .onChange(of: apiKey) { _, value in
                                        AppGroupStore.apiKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                    }
                            }
                            if selectedCloudEngine == .gemini {
                                Text("Preview model — a paid Gemini API key is recommended. Free-tier keys may be used to improve Google products.")
                                    .font(AppTheme.sans(13))
                                    .foregroundStyle(AppTheme.muted)
                            }
                            Text("Stored in the App Group. Nothing goes to a Murmur server.")
                                .font(AppTheme.sans(13))
                                .foregroundStyle(AppTheme.muted)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                        divider

                        VStack(alignment: .leading, spacing: 8) {
                            Text(selectedCloudEngine == .gemini ? "ElevenLabs API key (alternate engine)" : "Gemini API key (alternate engine)")
                                .font(AppTheme.sans(14, weight: .semibold))
                                .foregroundStyle(AppTheme.ink)
                            if selectedCloudEngine == .gemini {
                                SecureField("xi-api-key", text: $apiKey)
                                    .textContentType(.password)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .onChange(of: apiKey) { _, value in
                                        AppGroupStore.apiKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                    }
                            } else {
                                SecureField("Gemini API key", text: $geminiAPIKey)
                                    .textContentType(.password)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .onChange(of: geminiAPIKey) { _, value in
                                        AppGroupStore.geminiAPIKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                    }
                            }
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
                apiKey = AppGroupStore.apiKey
                geminiAPIKey = AppGroupStore.geminiAPIKey
                selectedCloudEngine = AppGroupStore.selectedCloudEngine
                giphyAPIKey = AppGroupStore.giphyAPIKey
                swipeTypingEnabled = AppGroupStore.swipeTypingEnabled
                removeFillerWords = AppGroupStore.removeFillerWords
                elevenLabsFilterBackgroundAudio = AppGroupStore.elevenLabsFilterBackgroundAudio
                elevenLabsCommitStrategy = AppGroupStore.elevenLabsCommitStrategy
                elevenLabsVadThreshold = AppGroupStore.elevenLabsVadThreshold
                elevenLabsVadSilenceThresholdSecs = AppGroupStore.elevenLabsVadSilenceThresholdSecs
                elevenLabsMinSpeechDurationMs = AppGroupStore.elevenLabsMinSpeechDurationMs
                elevenLabsMinSilenceDurationMs = AppGroupStore.elevenLabsMinSilenceDurationMs
                geminiVadMode = AppGroupStore.geminiVadMode
                geminiStartSensitivity = AppGroupStore.geminiStartSensitivity
                geminiEndSensitivity = AppGroupStore.geminiEndSensitivity
                geminiPrefixPaddingMs = AppGroupStore.geminiPrefixPaddingMs
                geminiSilenceDurationMs = AppGroupStore.geminiSilenceDurationMs
                interstitialIDs = AppGroupStore.interstitialReturnAppIDs
                refreshMicStatus()
            }
            .sheet(isPresented: $showingAddApps) {
                AddJumpBackAppSheet(alreadyPicked: Set(interstitialIDs)) { id in
                    AppGroupStore.addInterstitialReturnApp(id)
                    interstitialIDs = AppGroupStore.interstitialReturnAppIDs
                    showingAddApps = false
                }
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
