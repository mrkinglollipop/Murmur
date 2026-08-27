import SwiftUI

/// Per-cloud-model knobs that are not on the main Cloud row. Chevron
/// (`DisclosureGroup`) so the picker stays short; defaults match previous
/// hardcoded engine behavior.
struct CloudEngineAdvancedView: View {
    @ObservedObject var settingsStore: SettingsStore

    var body: some View {
        switch settingsStore.selectedCloudModel.provider {
        case .xai:
            advancedGroup {
                xaiAdvanced
            }
        case .elevenLabs:
            advancedGroup {
                elevenLabsAdvanced
            }
        case .gemini:
            advancedGroup {
                geminiAdvanced
            }
        default:
            EmptyView()
        }
    }

    private func advancedGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let inner = content()
        return VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Theme.hairline)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    inner
                }
                .padding(.top, 6)
            } label: {
                Text("Advanced")
                    .font(Theme.body(12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
            }
            .tint(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private var xaiAdvanced: some View {
        Stepper(value: $settingsStore.xaiEndpointingMs, in: XAIStreamingTranscriber.endpointingMsRange, step: 100) {
            Text("Pause before new utterance: \(settingsStore.xaiEndpointingMs) ms")
                .font(Theme.body(12))
                .foregroundColor(Theme.textPrimary)
        }

        Text("How long a pause can last before Grok starts a new utterance. Highest (5000, the previous default) avoids splitting a long hold.")
            .font(Theme.body(10))
            .foregroundColor(Theme.textSecondary)
    }

    @ViewBuilder
    private var elevenLabsAdvanced: some View {
        Toggle("Filter background audio", isOn: $settingsStore.elevenLabsFilterBackgroundAudio)
            .toggleStyle(.switch)
            .font(Theme.body(12))
            .foregroundColor(Theme.textPrimary)

        Text("Server-side: reduces other talkers and ambient false activations. Separate from Focus on my voice (local speaker gating).")
            .font(Theme.body(10))
            .foregroundColor(Theme.textSecondary)

        Divider().overlay(Theme.hairline)

        Text("Commit")
            .font(Theme.body(11, weight: .medium))
            .foregroundColor(Theme.textSecondary)

        Picker("Commit", selection: $settingsStore.elevenLabsCommitStrategy) {
            ForEach(ElevenLabsCommitStrategy.allCases) { strategy in
                Text(strategy.displayName).tag(strategy)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        Text("On key release keeps fn-hold as the boundary (previous default). Voice activity auto-commits when Scribe hears silence — can split a long hold.")
            .font(Theme.body(10))
            .foregroundColor(Theme.textSecondary)

        if settingsStore.elevenLabsCommitStrategy == .vad {
            Divider().overlay(Theme.hairline)

            sliderRow(
                title: "Speech threshold",
                value: $settingsStore.elevenLabsVadThreshold,
                range: ElevenLabsRealtimeOptions.vadThresholdRange,
                step: 0.05,
                format: { String(format: "%.2f", $0) }
            )

            sliderRow(
                title: "Silence to commit",
                value: $settingsStore.elevenLabsVadSilenceThresholdSecs,
                range: ElevenLabsRealtimeOptions.vadSilenceRange,
                step: 0.1,
                format: { String(format: "%.1fs", $0) }
            )

            Stepper(
                value: $settingsStore.elevenLabsMinSpeechDurationMs,
                in: ElevenLabsRealtimeOptions.minSpeechMsRange,
                step: 10
            ) {
                Text("Minimum speech: \(settingsStore.elevenLabsMinSpeechDurationMs) ms")
                    .font(Theme.body(12))
                    .foregroundColor(Theme.textPrimary)
            }

            Stepper(
                value: $settingsStore.elevenLabsMinSilenceDurationMs,
                in: ElevenLabsRealtimeOptions.minSilenceMsRange,
                step: 10
            ) {
                Text("Minimum silence: \(settingsStore.elevenLabsMinSilenceDurationMs) ms")
                    .font(Theme.body(12))
                    .foregroundColor(Theme.textPrimary)
            }
        }
    }

    @ViewBuilder
    private var geminiAdvanced: some View {
        Text("Voice activity")
            .font(Theme.body(11, weight: .medium))
            .foregroundColor(Theme.textSecondary)

        Picker("VAD mode", selection: $settingsStore.geminiVadMode) {
            ForEach(GeminiVadMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        Text("On key release keeps fn-hold as the utterance boundary (default). Voice activity and Hybrid use server VAD; Hybrid also sends stream-end on release.")
            .font(Theme.body(10))
            .foregroundColor(Theme.textSecondary)

        if settingsStore.geminiVadMode == .automatic || settingsStore.geminiVadMode == .hybrid {
            Divider().overlay(Theme.hairline)

            Picker("Start sensitivity", selection: $settingsStore.geminiStartSensitivity) {
                ForEach(GeminiStartSensitivity.allCases) { value in
                    Text(value.displayName).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("End sensitivity", selection: $settingsStore.geminiEndSensitivity) {
                ForEach(GeminiEndSensitivity.allCases) { value in
                    Text(value.displayName).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Stepper(
                value: $settingsStore.geminiPrefixPaddingMs,
                in: GeminiLiveOptions.prefixPaddingRange,
                step: 10
            ) {
                Text("Prefix padding: \(settingsStore.geminiPrefixPaddingMs) ms")
                    .font(Theme.body(12))
                    .foregroundColor(Theme.textPrimary)
            }

            Stepper(
                value: $settingsStore.geminiSilenceDurationMs,
                in: GeminiLiveOptions.silenceDurationRange,
                step: 10
            ) {
                Text("Silence duration: \(settingsStore.geminiSilenceDurationMs) ms")
                    .font(Theme.body(12))
                    .foregroundColor(Theme.textPrimary)
            }
        }
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(Theme.body(12))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(Theme.body(11))
                    .foregroundColor(Theme.textSecondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
