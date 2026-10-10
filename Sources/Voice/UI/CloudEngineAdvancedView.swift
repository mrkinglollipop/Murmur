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
            Text("Silence before split: \(settingsStore.xaiEndpointingMs) ms")
                .font(Theme.body(12))
                .foregroundColor(Theme.textPrimary)
        }

        Text("While you hold fn, how long a quiet stretch can last before Grok treats the next speech as a new utterance. Raise it if long pauses mid-sentence get cut.")
            .font(Theme.body(10))
            .foregroundColor(Theme.textSecondary)
    }

    @ViewBuilder
    private var elevenLabsAdvanced: some View {
        Toggle("Filter background audio", isOn: $settingsStore.elevenLabsFilterBackgroundAudio)
            .toggleStyle(.switch)
            .font(Theme.body(12))
            .foregroundColor(Theme.textPrimary)

        Text("Filters other voices, but can also omit quieter parts of your own speech. Leave off to preserve your words.")
            .font(Theme.body(10))
            .foregroundColor(Theme.textSecondary)

        Divider().overlay(Theme.hairline)

        Text("When text is finished")
            .font(Theme.body(11, weight: .medium))
            .foregroundColor(Theme.textSecondary)

        Picker("When text is finished", selection: $settingsStore.elevenLabsCommitStrategy) {
            ForEach(ElevenLabsCommitStrategy.allCases) { strategy in
                Text(strategy.displayName).tag(strategy)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        Text("On key release: text is finalized when you let go of fn. Voice activity: text is finalized when you pause. A long recording can be split into parts.")
            .font(Theme.body(10))
            .foregroundColor(Theme.textSecondary)

        if settingsStore.elevenLabsCommitStrategy == .vad {
            Divider().overlay(Theme.hairline)

            sliderRow(
                title: "Speech loudness",
                value: $settingsStore.elevenLabsVadThreshold,
                range: ElevenLabsRealtimeOptions.vadThresholdRange,
                step: 0.05,
                format: { String(format: "%.2f", $0) }
            )

            Text("Higher = only louder speech counts as talking.")
                .font(Theme.body(10))
                .foregroundColor(Theme.textSecondary)

            sliderRow(
                title: "Pause before finishing",
                value: $settingsStore.elevenLabsVadSilenceThresholdSecs,
                range: ElevenLabsRealtimeOptions.vadSilenceRange,
                step: 0.1,
                format: { String(format: "%.1fs", $0) }
            )

            Text("How long you need to pause before your text is finalized.")
                .font(Theme.body(10))
                .foregroundColor(Theme.textSecondary)

            Stepper(
                value: $settingsStore.elevenLabsMinSpeechDurationMs,
                in: ElevenLabsRealtimeOptions.minSpeechMsRange,
                step: 10
            ) {
                Text("Ignore blips shorter than: \(settingsStore.elevenLabsMinSpeechDurationMs) ms")
                    .font(Theme.body(12))
                    .foregroundColor(Theme.textPrimary)
            }

            Text("Drops clicks and tiny noise bursts so they never start an utterance.")
                .font(Theme.body(10))
                .foregroundColor(Theme.textSecondary)

            Stepper(
                value: $settingsStore.elevenLabsMinSilenceDurationMs,
                in: ElevenLabsRealtimeOptions.minSilenceMsRange,
                step: 10
            ) {
                Text("Ignore gaps shorter than: \(settingsStore.elevenLabsMinSilenceDurationMs) ms")
                    .font(Theme.body(12))
                    .foregroundColor(Theme.textPrimary)
            }

            Text("Brief pauses inside a sentence stay in the same utterance.")
                .font(Theme.body(10))
                .foregroundColor(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private var geminiAdvanced: some View {
        Text("Who decides you're done talking")
            .font(Theme.body(11, weight: .medium))
            .foregroundColor(Theme.textSecondary)

        Picker("Who decides you’re done talking", selection: $settingsStore.geminiVadMode) {
            ForEach(GeminiVadMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        Text("On key release: use fn to start and stop (default). Voice activity: text is finalized when you pause. Hybrid: either pausing or releasing fn finalizes the text.")
            .font(Theme.body(10))
            .foregroundColor(Theme.textSecondary)

        if settingsStore.geminiVadMode == .automatic || settingsStore.geminiVadMode == .hybrid {
            Divider().overlay(Theme.hairline)

            Text("Detect speech start")
                .font(Theme.body(11, weight: .medium))
                .foregroundColor(Theme.textSecondary)

            Picker("Start sensitivity", selection: $settingsStore.geminiStartSensitivity) {
                ForEach(GeminiStartSensitivity.allCases) { value in
                    Text(value.displayName).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("High picks up quieter starts sooner; Low waits for clearer speech.")
                .font(Theme.body(10))
                .foregroundColor(Theme.textSecondary)

            Text("Detect speech end")
                .font(Theme.body(11, weight: .medium))
                .foregroundColor(Theme.textSecondary)

            Picker("End sensitivity", selection: $settingsStore.geminiEndSensitivity) {
                ForEach(GeminiEndSensitivity.allCases) { value in
                    Text(value.displayName).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("High ends the utterance after a shorter pause; Low waits longer before cutting.")
                .font(Theme.body(10))
                .foregroundColor(Theme.textSecondary)

            Stepper(
                value: $settingsStore.geminiPrefixPaddingMs,
                in: GeminiLiveOptions.prefixPaddingRange,
                step: 10
            ) {
                Text("Audio kept before speech: \(settingsStore.geminiPrefixPaddingMs) ms")
                    .font(Theme.body(12))
                    .foregroundColor(Theme.textPrimary)
            }

            Text("Include a little sound before Gemini decides talking started — protects the first syllable.")
                .font(Theme.body(10))
                .foregroundColor(Theme.textSecondary)

            Stepper(
                value: $settingsStore.geminiSilenceDurationMs,
                in: GeminiLiveOptions.silenceDurationRange,
                step: 10
            ) {
                Text("Silence before end: \(settingsStore.geminiSilenceDurationMs) ms")
                    .font(Theme.body(12))
                    .foregroundColor(Theme.textPrimary)
            }

            Text("Quiet stretch Gemini needs before it treats the utterance as finished.")
                .font(Theme.body(10))
                .foregroundColor(Theme.textSecondary)
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
                .accessibilityLabel(title)
                .accessibilityValue(format(value.wrappedValue))
        }
    }
}
