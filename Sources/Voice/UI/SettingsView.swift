import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings: activation-key choice, ASR engine choice, and a read-only
/// permissions note. Persists via `SettingsStore` (UserDefaults) and applies
/// changes live to the running `ActivationController` / `ASREngineSelector`.
struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var modelManager: ModelManager

    var onReplayOnboarding: () -> Void = {}

    /// Local editing buffer for the currently-selected cloud model's API
    /// key field. Not written to Keychain until Save is tapped.
    @State private var apiKeyInput: String = ""

    /// Local editing buffer for the cleanup cloud (OpenAI) API key field.
    /// Not written to Keychain until Save is tapped.
    @State private var cleanupKeyInput: String = ""

    @State private var apiKeySaveFailed = false
    @State private var cleanupKeySaveFailed = false

    @State private var pendingModelDelete: LocalModel?
    @State private var showModelDeleteConfirmation = false

    @State private var showDeleteProfileConfirmation = false

    @State private var exportStatus: String?

    /// Non-nil only while the enrollment sheet is up — `.sheet(item:)` derives
    /// both presentation and content from this single value.
    @State private var enrollmentCoordinator: EnrollmentCoordinator?

    private var enrolledProfile: VoiceProfile? {
        settingsStore.enrolledVoiceProfile
    }

    private var hasVoiceProfile: Bool {
        enrolledProfile != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section(title: "Transcription Engine") {
                    Picker("Engine", selection: $settingsStore.useCloudEngine) {
                        Text("Local").tag(false)
                        Text("Cloud").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                section(title: "Activation") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Push-to-talk key", selection: $settingsStore.activationKeyOption) {
                            ForEach(ActivationKeyOption.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()

                        Toggle("Toggle-lock recording (double-tap fn)", isOn: $settingsStore.useToggleLock)
                            .toggleStyle(.switch)
                            .font(Theme.body(12))
                            .foregroundColor(Theme.textPrimary)

                        Text("Double-tap fn within 400ms to start hands-free recording that continues after release. Tap fn again to stop.")
                            .font(Theme.body(10))
                            .foregroundColor(Theme.textSecondary)
                    }
                }

                section(title: "Language") {
                    Picker("Dictation language", selection: $settingsStore.selectedLanguage) {
                        ForEach(SettingsStore.supportedLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                section(title: "Local Model") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Local model", selection: $settingsStore.selectedLocalModel) {
                            ForEach(LocalModel.allCases) { model in
                                Text(model.displayName)
                                    .foregroundColor(Theme.textPrimary)
                                    .tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()

                        Text("Active: \(settingsStore.selectedLocalModel.displayName)")
                            .font(Theme.body(11))
                            .foregroundColor(Theme.textSecondary)

                        Divider().overlay(Theme.hairline)

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(LocalModel.allCases) { model in
                                modelRow(model)
                                if model != LocalModel.allCases.last {
                                    Divider().overlay(Theme.hairline)
                                }
                            }
                        }
                    }
                }

                section(title: "Cloud Model") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Cloud model", selection: $settingsStore.selectedCloudModel) {
                            ForEach(CloudModel.selectable) { model in
                                Text(model.displayName)
                                    .foregroundColor(Theme.textPrimary)
                                    .tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()

                        Divider().overlay(Theme.hairline)

                        apiKeyEntry(for: settingsStore.selectedCloudModel.provider)

                        Text("Stored in your macOS Keychain.")
                            .font(Theme.body(10))
                            .foregroundColor(Theme.textSecondary)

                        if settingsStore.selectedCloudModel.provider == .xai {
                            Divider().overlay(Theme.hairline)

                            Toggle("Live streaming (xAI Grok)", isOn: $settingsStore.useStreaming)
                                .toggleStyle(.switch)
                                .font(Theme.body(12))
                                .foregroundColor(Theme.textPrimary)

                            Text("Transcribes as you speak for near-instant results at release. Off falls back to the batch path. ElevenLabs Scribe v2 Realtime (selected separately above) always streams live regardless of this toggle.")
                                .font(Theme.body(10))
                                .foregroundColor(Theme.textSecondary)
                        }

                        if settingsStore.selectedCloudModel.provider == .elevenLabs {
                            Divider().overlay(Theme.hairline)

                            Toggle("Remove filler words (ElevenLabs)", isOn: $settingsStore.removeFillerWords)
                                .toggleStyle(.switch)
                                .font(Theme.body(12))
                                .foregroundColor(Theme.textPrimary)

                            Text("Strips filler words, false starts, and stuttering during transcription. May occasionally swallow a deliberate spoken correction (e.g. \"um, actually, no —\"). Turn off if that happens.")
                                .font(Theme.body(10))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                }

                section(title: "Cleanup") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Clean up dictation", isOn: $settingsStore.cleanupEnabled)
                            .toggleStyle(.switch)
                            .font(Theme.body(12))
                            .foregroundColor(Theme.textPrimary)

                        if settingsStore.cleanupEnabled {
                            Divider().overlay(Theme.hairline)

                            Picker("Backend", selection: $settingsStore.cleanupBackend) {
                                ForEach(CleanupBackend.allCases) { backend in
                                    Text(backend.displayName).tag(backend)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            if settingsStore.cleanupBackend == .onDevice && !settingsStore.onDeviceCleanupAvailable {
                                Label(
                                    "On-device cleanup needs macOS 26 + Apple Intelligence — pick Cloud or turn off.",
                                    systemImage: "exclamationmark.triangle"
                                )
                                .font(Theme.body(11))
                                .foregroundColor(Theme.amberText)
                            }

                            if settingsStore.cleanupBackend == .cloud {
                                Divider().overlay(Theme.hairline)
                                cleanupKeyEntry()
                                Text("Stored in your macOS Keychain.")
                                    .font(Theme.body(10))
                                    .foregroundColor(Theme.textSecondary)
                            }

                            if settingsStore.cleanupBackend == .xaiGrok {
                                Divider().overlay(Theme.hairline)
                                if settingsStore.hasXAIKey() {
                                    Text("Uses your xAI API key from the Cloud Model section.")
                                        .font(Theme.body(11))
                                        .foregroundColor(Theme.textSecondary)
                                } else {
                                    Label(
                                        "No xAI key yet — add one under Cloud Model to enable Grok cleanup.",
                                        systemImage: "exclamationmark.triangle"
                                    )
                                    .font(Theme.body(11))
                                    .foregroundColor(Theme.amberText)
                                }
                            }
                        }
                    }
                }

                section(title: "Dictation text") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Code-aware mode (for coding)", isOn: $settingsStore.codeAwareMode)
                            .toggleStyle(.switch)
                            .font(Theme.body(12))
                            .foregroundColor(Theme.textPrimary)

                        Text("Turns spoken words like “dot” and “period” into symbols for coding. Does not require Cleanup — leave off for normal prose.")
                            .font(Theme.body(10))
                            .foregroundColor(Theme.textSecondary)
                    }
                }

                section(title: "System") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Launch at login", isOn: $settingsStore.launchAtLogin)
                            .toggleStyle(.switch)
                            .font(Theme.body(12))
                            .foregroundColor(Theme.textPrimary)

                        Divider().overlay(Theme.hairline)

                        Toggle("Play a sound on dictation start/stop", isOn: $settingsStore.playDictationSound)
                            .toggleStyle(.switch)
                            .font(Theme.body(12))
                            .foregroundColor(Theme.textPrimary)

                        Divider().overlay(Theme.hairline)

                        Toggle("Smart leading space", isOn: $settingsStore.smartLeadingSpace)
                            .toggleStyle(.switch)
                            .font(Theme.body(12))
                            .foregroundColor(Theme.textPrimary)

                        Text("Prepends a space before injected text so it doesn't glue to prior text. Also strips a trailing period, question mark, or exclamation when replacing selected mid-sentence words.")
                            .font(Theme.body(10))
                            .foregroundColor(Theme.textSecondary)

                        Divider().overlay(Theme.hairline)

                        Toggle("Learn from corrections in other apps", isOn: $settingsStore.learnFromInlineCorrections)
                            .toggleStyle(.switch)
                            .font(Theme.body(12))
                            .foregroundColor(Theme.textPrimary)

                        Text("When you fix a misheard word after dictation, Murmur learns it for next time.")
                            .font(Theme.body(10))
                            .foregroundColor(Theme.textSecondary)

                        Divider().overlay(Theme.hairline)

                        Button("Replay onboarding") {
                            onReplayOnboarding()
                        }
                        .buttonStyle(.glass)
                        .font(Theme.body(12, weight: .medium))
                        .foregroundColor(Theme.primary)
                    }
                }

                section(title: "Storage") {
                    storageSectionContent
                }

                section(title: "Voice") {
                    voiceSectionContent
                }

                section(title: "Permissions") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            "Murmur requires Input Monitoring (and, for fn suppression, Accessibility) access to detect the push-to-talk key globally. Grant these in System Settings → Privacy & Security if prompted.",
                            systemImage: "info.circle"
                        )
                        .font(Theme.body(12))
                        .foregroundColor(Theme.textSecondary)
                    }
                }

                section(title: "What's New") {
                    WhatsNewSettingsSectionView()
                }

                section(title: "Acknowledgements") {
                    AcknowledgementsSectionView()
                }

                Spacer(minLength: 0)
            }
            .padding(20)
        }

        .sheet(item: $enrollmentCoordinator) { coordinator in
            EnrollmentSheetView(
                coordinator: coordinator,
                onDone: {
                    // Only auto-enable Focus when the flow actually finished
                    // successfully — cancel / Esc must not flip the toggle.
                    let succeeded = coordinator.flow.phase == .done
                    enrollmentCoordinator = nil
                    settingsStore.refreshEnrolledVoiceProfile(autoEnableGatingIfPresent: succeeded)
                }
            )
            .onDisappear {
                // Esc / outside dismiss never hits the X button's cancel path.
                coordinator.cancel()
            }
        }
        .onAppear {
            settingsStore.refreshEnrolledVoiceProfile(autoEnableGatingIfPresent: false)
            settingsStore.refreshRecordingUsage()
        }
        .onChange(of: enrollmentCoordinator?.id) { _, newID in
            // Sheet dismissed (any path) — refresh CTA from disk without
            // forcing Focus on. Success already auto-enabled via onDone /
            // onGatingShouldRefresh.
            if newID == nil {
                settingsStore.refreshEnrolledVoiceProfile(autoEnableGatingIfPresent: false)
            }
        }
        .confirmDelete(
            isPresented: $showModelDeleteConfirmation,
            title: pendingModelDelete.map { "Delete \($0.displayName)?" } ?? "Delete model?",
            message: modelDeleteMessage,
            onConfirm: {
                if let model = pendingModelDelete {
                    modelManager.delete(model)
                }
                pendingModelDelete = nil
            }
        )
        .confirmDelete(
            isPresented: $showDeleteProfileConfirmation,
            title: "Delete voice profile?",
            message: "Focus on my voice will turn off until you enroll again.",
            onConfirm: {
                VoiceProfileStore().deleteProfile()
                settingsStore.clearEnrolledVoiceProfile()
            }
        )
        .tint(Theme.primary)
    }

    @ViewBuilder
    private var storageSectionContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Retained audio: \(settingsStore.recordingFileCount) file(s) · \(SettingsStore.formatByteCount(settingsStore.recordingUsageBytes)) of \(settingsStore.recordingBudgetMB) MB"
            )
            .font(Theme.body(12))
            .foregroundColor(Theme.textPrimary)

            Picker("Audio budget", selection: $settingsStore.recordingBudgetMB) {
                ForEach(SettingsStore.recordingBudgetOptionsMB, id: \.self) { mb in
                    Text("\(mb) MB").tag(mb)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Text("Keeps up to \(RecordingRetention.maxRetained) recent recordings within the budget. Oldest are deleted first. Audio kept for failed-dictation retry is protected.")
                .font(Theme.body(10))
                .foregroundColor(Theme.textSecondary)

            Divider().overlay(Theme.hairline)

            GlassEffectContainer(spacing: 10) {
                Button("Export recordings + transcripts…") {
                    exportRecordingsAndTranscripts()
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.lavender)
                .font(Theme.body(12, weight: .medium))
            }

            if let exportStatus {
                Text(exportStatus)
                    .font(Theme.body(11))
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }

    private func exportRecordingsAndTranscripts() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.zip]
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "Murmur-export-\(stamp).zip"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let entries = settingsStore.historyStore?.entries ?? []
            // Zip + file copies off main; hop back only for status UI.
            Task.detached(priority: .userInitiated) {
                do {
                    let count = try RecordingRetention.exportZip(
                        to: url,
                        historyEntries: entries
                    )
                    await MainActor.run {
                        exportStatus = count == 0
                            ? "Exported transcripts (no audio files on disk)."
                            : "Exported \(count) recording(s) + transcripts."
                        settingsStore.refreshRecordingUsage()
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } catch RecordingRetention.ExportError.nothingToExport {
                    await MainActor.run {
                        exportStatus = "Nothing to export yet — dictate something first."
                    }
                } catch {
                    await MainActor.run {
                        exportStatus = "Export failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var voiceSectionContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Focus on my voice", isOn: $settingsStore.speakerGatingEnabled)
                .toggleStyle(.switch)
                .font(Theme.body(12))
                .foregroundColor(Theme.textPrimary)
                .disabled(!hasVoiceProfile)

            if !hasVoiceProfile {
                Text("Enroll your voice first")
                    .font(Theme.body(10))
                    .foregroundColor(Theme.textSecondary)
            }

            if settingsStore.speakerGatingEnabled && hasVoiceProfile {
                Divider().overlay(Theme.hairline)

                Picker("Sensitivity", selection: $settingsStore.speakerGatingSensitivity) {
                    Text("Low").tag(VoiceGateSensitivity.low)
                    Text("Medium").tag(VoiceGateSensitivity.medium)
                    Text("High").tag(VoiceGateSensitivity.high)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                voiceGateTelemetrySummary
            }

            Divider().overlay(Theme.hairline)

            if let profile = enrolledProfile {
                Text("Enrolled \(enrolledDateLabel(for: profile.createdAt))")
                    .font(Theme.body(11))
                    .foregroundColor(Theme.textSecondary)

                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        Button("Re-enroll") {
                            enrollmentCoordinator = makeEnrollmentCoordinator()
                        }
                        .buttonStyle(.glass)
                        .font(Theme.body(12, weight: .medium))
                        .foregroundColor(Theme.primary)

                        Button("Delete profile") {
                            showDeleteProfileConfirmation = true
                        }
                        .buttonStyle(.glass)
                        .font(Theme.body(12, weight: .medium))
                        .foregroundColor(Theme.recordRed)
                    }
                }
            } else {
                Button("Enroll your voice") {
                    enrollmentCoordinator = makeEnrollmentCoordinator()
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.lavender)
                .font(Theme.body(12, weight: .medium))

                Text("Your voice profile stays on this Mac.")
                    .font(Theme.body(10))
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var voiceGateTelemetrySummary: some View {
        let telemetry = settingsStore.voiceGateTelemetry
        let prefix = telemetry.isSessionActive ? "Voice windows" : "Last session"

        if telemetry.attemptedWindows == 0 {
            let message = telemetry.isSessionActive
                ? "\(prefix): listening — gate stats appear as one-second windows are evaluated."
                : "\(prefix): no gate data yet — stats appear after you dictate with Focus on."
            Text(message)
                .font(Theme.body(10))
                .foregroundColor(Theme.textSecondary)
                .accessibilityLabel(message)
        } else if telemetry.evaluatedWindows == 0 {
            let message = "\(prefix): \(telemetry.unscoredWindows) voice window\(telemetry.unscoredWindows == 1 ? "" : "s") could not be scored (gate unavailable). Speaker-gate stats only — not transcription accuracy."
            Text(message)
                .font(Theme.body(10))
                .foregroundColor(Theme.textSecondary)
                .accessibilityLabel(message)
        } else {
            let medianText = telemetry.medianSimilarity.map { String(format: "%.2f", $0) } ?? "—"
            let unscoredSuffix = telemetry.unscoredWindows > 0
                ? " · \(telemetry.unscoredWindows) unscored"
                : ""
            let summary = "\(prefix): \(telemetry.passedWindows)/\(telemetry.evaluatedWindows) voice windows passed · \(telemetry.attenuatedWindows) attenuated\(unscoredSuffix) · median \(medianText)"
            Text(summary)
                .font(Theme.body(10))
                .foregroundColor(Theme.textSecondary)
                .accessibilityLabel(summary)
                .accessibilityHint("Speaker-gate stats for one-second audio windows. This is not transcription accuracy.")
        }
    }

    private func makeEnrollmentCoordinator() -> EnrollmentCoordinator {
        EnrollmentCoordinator(
            profileStore: VoiceProfileStore(),
            sensitivityProvider: { settingsStore.speakerGatingSensitivity },
            onGatingShouldRefresh: { [settingsStore] in
                // Enrollment just wrote the profile — refresh UI + enable gating
                // immediately, while the success sheet is still up.
                // settingsStore is a class (ObservableObject); safe from this
                // long-lived coordinator callback (unlike mutating @State).
                settingsStore.refreshEnrolledVoiceProfile(autoEnableGatingIfPresent: true)
            }
        )
    }

    private func enrolledDateLabel(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let relative = formatter.localizedString(for: date, relativeTo: Date())
        if relative.contains("ago") || relative.contains("in ") {
            return relative
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private var modelDeleteMessage: String {
        guard let model = pendingModelDelete else {
            return "The model will need to be downloaded again."
        }
        if settingsStore.selectedLocalModel == model {
            return "The model will need to be downloaded again. Dictation will fall back until you choose another local model."
        }
        return "The model will need to be downloaded again."
    }

    /// SecureField + Save/Remove + status line for the given provider's
    /// Keychain-backed API key. Reloads its editing buffer whenever the
    /// selected cloud model (and therefore provider) changes.
    @ViewBuilder
    private func apiKeyEntry(for provider: CloudProvider) -> some View {
        let hasKey = settingsStore.hasAPIKey(for: provider)

        VStack(alignment: .leading, spacing: 8) {
            Text("\(provider.displayName) API key")
                .font(Theme.body(11, weight: .medium))
                .foregroundColor(Theme.textPrimary)

            SecureField("Paste your \(provider.displayName) API key", text: $apiKeyInput)
                .textFieldStyle(.plain)
                .font(Theme.body(12))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .murmurGlassCard()
                .onAppear { apiKeyInput = "" }
                .onChange(of: provider.id) { _, _ in apiKeyInput = "" }

            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Button("Save") {
                        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        if settingsStore.saveAPIKey(trimmed, for: provider) {
                            apiKeyInput = ""
                            apiKeySaveFailed = false
                        } else {
                            // Keep SecureField contents so the user can retry.
                            apiKeySaveFailed = true
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.lavender)
                    .font(Theme.body(11, weight: .medium))
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Remove") {
                        settingsStore.removeAPIKey(for: provider)
                        apiKeyInput = ""
                        apiKeySaveFailed = false
                    }
                    .buttonStyle(.glass)
                    .font(Theme.body(11, weight: .medium))
                    .foregroundColor(Theme.amberText)
                    .disabled(!hasKey)

                    Spacer()

                    Link("Get a key", destination: provider.signupURL)
                        .font(Theme.body(11))
                        .foregroundColor(Theme.textSecondary)
                }
            }

            if apiKeySaveFailed {
                Text("Keychain save failed — key not stored. Try again.")
                    .font(Theme.body(10))
                    .foregroundColor(Theme.amberText)
            } else if hasKey {
                HStack(spacing: 4) {
                    Text("Key saved")
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(Theme.body(10))
                .foregroundColor(Theme.successGreen)
            } else {
                Text("No key — cloud falls back to local.")
                    .font(Theme.body(10))
                    .foregroundColor(Theme.amberText)
            }
        }
    }

    /// SecureField + Save/Remove + status line for the cleanup cloud
    /// (OpenAI) Keychain-backed API key. Mirrors `apiKeyEntry(for:)`'s shape.
    @ViewBuilder
    private func cleanupKeyEntry() -> some View {
        let hasKey = settingsStore.hasCleanupKey()

        VStack(alignment: .leading, spacing: 8) {
            Text("OpenAI API key")
                .font(Theme.body(11, weight: .medium))
                .foregroundColor(Theme.textPrimary)

            SecureField("Paste your OpenAI API key", text: $cleanupKeyInput)
                .textFieldStyle(.plain)
                .font(Theme.body(12))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .murmurGlassCard()
                .onAppear { cleanupKeyInput = "" }

            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Button("Save") {
                        let trimmed = cleanupKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        if settingsStore.saveCleanupKey(trimmed) {
                            cleanupKeyInput = ""
                            cleanupKeySaveFailed = false
                        } else {
                            cleanupKeySaveFailed = true
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.lavender)
                    .font(Theme.body(11, weight: .medium))
                    .disabled(cleanupKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Remove") {
                        settingsStore.removeCleanupKey()
                        cleanupKeyInput = ""
                        cleanupKeySaveFailed = false
                    }
                    .buttonStyle(.glass)
                    .font(Theme.body(11, weight: .medium))
                    .foregroundColor(Theme.amberText)
                    .disabled(!hasKey)

                    Spacer()
                }
            }

            if cleanupKeySaveFailed {
                Text("Keychain save failed — key not stored. Try again.")
                    .font(Theme.body(10))
                    .foregroundColor(Theme.amberText)
            } else if hasKey {
                HStack(spacing: 4) {
                    Text("Key saved")
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(Theme.body(10))
                .foregroundColor(Theme.successGreen)
            } else {
                Text("No key — cleanup will be skipped.")
                    .font(Theme.body(10))
                    .foregroundColor(Theme.amberText)
            }
        }
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Theme.body(12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
                .textCase(.uppercase)

            content()
        }
        .padding(14)
        .murmurGlassCard()
    }

    // MARK: - Model management row

    /// One row in the per-model storage-management list: name + size/status,
    /// a Download button (with live progress + Retry-on-failure) when
    /// absent, and an individual Delete (trash) button when present. The
    /// active model is highlighted with the lavender pill background used
    /// elsewhere in the theme for "selected" state.
    @ViewBuilder
    private func modelRow(_ model: LocalModel) -> some View {
        let isActive = settingsStore.selectedLocalModel == model
        let isSidecar = modelManager.isSidecarManaged(model)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(model.displayName)
                    .font(Theme.body(12, weight: isActive ? .semibold : .regular))
                    .foregroundColor(Theme.textPrimary)

                if isActive {
                    Text("ACTIVE")
                        .font(Theme.body(9, weight: .semibold))
                        .foregroundColor(Theme.lavenderText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .murmurGlassCapsule(tint: Theme.selectionTint)
                }

                Spacer()

                modelRowTrailingControl(model, isSidecar: isSidecar)
            }

            statusLine(model, isSidecar: isSidecar)

            if case .downloading = modelManager.state[model] ?? .idle {
                ProgressView(value: modelManager.downloadProgress[model] ?? 0, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(Theme.primary)
            }

            if case .failed(let message) = modelManager.state[model] ?? .idle {
                Text(message)
                    .font(Theme.body(10))
                    .foregroundColor(Theme.amberText)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, isActive ? 8 : 0)
        .background(isActive ? Theme.lavender.opacity(0.25) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Right-aligned action control for a model row: Download / progress /
    /// Retry / Delete, depending on current state.
    @ViewBuilder
    private func modelRowTrailingControl(_ model: LocalModel, isSidecar: Bool) -> some View {
        if isSidecar {
            // Parakeet — managed by the Python sidecar's own HF cache, not
            // this manager's download/delete flow. No actions offered.
            EmptyView()
        } else {
            switch modelManager.state[model] ?? .idle {
            case .idle:
                if modelManager.isDownloaded(model) {
                    Button {
                        pendingModelDelete = model
                        showModelDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(Theme.amberText)
                    }
                    .buttonStyle(.plain)
                    .help("Delete downloaded model")
                } else {
                    Button("Download") {
                        modelManager.download(model)
                    }
                    .buttonStyle(.glass)
                    .font(Theme.body(11, weight: .medium))
                    .foregroundColor(Theme.primary)
                }
            case .downloading:
                Text("\(Int((modelManager.downloadProgress[model] ?? 0) * 100))%")
                    .font(Theme.body(11))
                    .foregroundColor(Theme.textSecondary)
            case .failed:
                Button("Retry") {
                    modelManager.retry(model)
                }
                .buttonStyle(.glass)
                .font(Theme.body(11, weight: .medium))
                .foregroundColor(Theme.primary)
            }
        }
    }

    /// Secondary status text under the model name: disk size, "Not
    /// downloaded", "Downloading…", or the sidecar note for Parakeet.
    @ViewBuilder
    private func statusLine(_ model: LocalModel, isSidecar: Bool) -> some View {
        if isSidecar {
            if let size = modelManager.diskSizeDisplay(model) {
                Text("Managed by Parakeet sidecar (HF cache) · \(size)")
                    .font(Theme.body(10))
                    .foregroundColor(Theme.textSecondary)
            } else {
                Text("Managed by Parakeet sidecar — size unavailable")
                    .font(Theme.body(10))
                    .foregroundColor(Theme.textSecondary)
            }
        } else {
            switch modelManager.state[model] ?? .idle {
            case .downloading:
                Text("Downloading…")
                    .font(Theme.body(10))
                    .foregroundColor(Theme.textSecondary)
            case .failed:
                Text("Download failed")
                    .font(Theme.body(10))
                    .foregroundColor(Theme.amberText)
            case .idle:
                if let size = modelManager.diskSizeDisplay(model) {
                    Text(size)
                        .font(Theme.body(10))
                        .foregroundColor(Theme.textSecondary)
                } else {
                    Text("Not downloaded")
                        .font(Theme.body(10))
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
    }
}
