import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case engine = "Engine"
    case text = "Text"
    case storage = "Storage"
    case permissions = "Permissions"
    case about = "About"

    var id: String { rawValue }

    static func contains(_ card: String, in section: SettingsSection) -> Bool {
        switch section {
        case .general: return ["Activation", "System", "Voice"].contains(card)
        case .engine: return ["Transcription Engine", "Language", "Local Model", "Cloud Model"].contains(card)
        case .text: return ["Cleanup", "Dictation text"].contains(card)
        case .storage: return ["Storage", "Clipboard"].contains(card)
        case .permissions: return card == "Permissions"
        case .about: return ["What's New", "Acknowledgements"].contains(card)
        }
    }
}

@MainActor
private enum SettingsSectionSession {
    static var selected: SettingsSection = .general
}

/// Settings: activation-key choice, ASR engine choice, and a read-only
/// permissions note. Persists via `SettingsStore` (UserDefaults) and applies
/// changes live to the running `ActivationController` / `ASREngineSelector`.
struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var modelManager: ModelManager

    var onReplayOnboarding: () -> Void = {}
    @ObservedObject var clipboardStore: ClipboardStore
    var permissionOverride: PermissionSnapshot?

    init(settingsStore: SettingsStore, modelManager: ModelManager,
         onReplayOnboarding: @escaping () -> Void = {},
         clipboardStore: ClipboardStore,
         initialSection: SettingsSection? = nil, permissionOverride: PermissionSnapshot? = nil) {
        self.settingsStore = settingsStore
        self.modelManager = modelManager
        self.onReplayOnboarding = onReplayOnboarding
        self.clipboardStore = clipboardStore
        self.permissionOverride = permissionOverride
        _selectedSection = State(initialValue: initialSection ?? SettingsSectionSession.selected)
    }

    /// Local editing buffer for the currently-selected cloud model's API
    /// key field. Not written to Keychain until Save is tapped.
    @State private var apiKeyInput: String = ""

    /// Local editing buffer for the cleanup cloud (OpenAI) API key field.
    /// Not written to Keychain until Save is tapped.
    @State private var cleanupKeyInput: String = ""

    @State private var apiKeySaveFailed = false
    @State private var providerHealthTick = 0
    @State private var isCheckingProvider = false
    @State private var providerCheckOutcome: String?
    @State private var cleanupKeySaveFailed = false

    @State private var pendingModelDelete: LocalModel?
    @State private var showModelDeleteConfirmation = false

    @State private var showDeleteProfileConfirmation = false
    @State private var showAPIKeyRemoveConfirmation = false
    @State private var pendingAPIKeyRemoval: CloudProvider?
    @State private var showCleanupKeyRemoveConfirmation = false

    @State private var exportStatus: String?
    @State private var selectedSection: SettingsSection = SettingsSectionSession.selected
    @State private var permissionRefreshTick = 0
    @State private var permissionPollTimer: Timer?

    /// Non-nil only while the enrollment sheet is up — `.sheet(item:)` derives
    /// both presentation and content from this single value.
    @State private var enrollmentCoordinator: EnrollmentCoordinator?

    private var enrolledProfile: VoiceProfile? {
        settingsStore.enrolledVoiceProfile
    }

    private var hasVoiceProfile: Bool {
        enrolledProfile != nil
    }

    private var permissionSnapshot: PermissionSnapshot {
        _ = permissionRefreshTick
        if let permissionOverride { return permissionOverride }
        return PermissionSnapshot(
            microphone: MicrophonePermission.isGranted(),
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: InputMonitoringPermission.isGranted()
        )
    }

    private var geminiLanguageCaption: String {
        let tag = SettingsStore.geminiLanguageSelection(from: settingsStore.selectedLanguage)
        if tag.isEmpty {
            return "Uses Language above. Gemini will auto-detect (no languageCodes)."
        }
        return "Uses Language above. Gemini is sent \(tag)."
    }

    private func shows(_ card: String) -> Bool {
        SettingsSection.contains(card, in: selectedSection)
    }

    private var microphoneSelection: Binding<String> {
        Binding(
            get: {
                guard let uid = settingsStore.preferredInputDeviceUID,
                      settingsStore.microphoneDevices.contains(where: { $0.uid == uid }),
                      !settingsStore.isInputDeviceExcluded(uid)
                else { return "" }
                return uid
            },
            set: { uid in
                settingsStore.preferredInputDeviceUID = uid.isEmpty ? nil : uid
            }
        )
    }

    private func microphoneExclusion(_ device: MicrophoneDevice) -> Binding<Bool> {
        Binding(
            get: { settingsStore.isInputDeviceExcluded(device.uid) },
            set: { settingsStore.setInputDeviceExcluded(device.uid, excluded: $0) }
        )
    }

    /// Shared content keeps offscreen renders at the scroll pane's actual width.
    var sectionContent: some View {
            VStack(alignment: .leading, spacing: 20) {
                Text(selectedSection.rawValue)
                    .font(Theme.serifTitle(26, weight: .medium))
                    .foregroundColor(Theme.textPrimary)

                if shows("Transcription Engine") {
                section(title: "Transcription Engine") {
                    Picker("Engine", selection: $settingsStore.useCloudEngine) {
                        Text("Local").tag(false)
                        Text("Cloud").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                }

                if shows("Activation") {
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

                        Text("Double-tap fn quickly to start hands-free recording that continues after release. Tap fn again to stop.")
                            .font(Theme.body(10))
                            .foregroundColor(Theme.textSecondary)
                    }
                }

                }

                if shows("Language") {
                section(title: "Language") {
                    Picker("Dictation language", selection: $settingsStore.selectedLanguage) {
                        ForEach(SettingsStore.supportedLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                if !settingsStore.useCloudEngine {
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
                }

                if settingsStore.useCloudEngine {
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

                            Text("Transcribes as you speak for near-instant results at release. Off falls back to the batch path. ElevenLabs Scribe v2 Realtime and Gemini 3.5 Transcribe (selected separately above) always stream live regardless of this toggle.")
                                .font(Theme.body(10))
                                .foregroundColor(Theme.textSecondary)

                            CloudEngineAdvancedView(settingsStore: settingsStore)
                        }

                        if settingsStore.selectedCloudModel.provider == .elevenLabs {
                            Divider().overlay(Theme.hairline)

                            Toggle("Remove filler words", isOn: $settingsStore.removeFillerWords)
                                .toggleStyle(.switch)
                                .font(Theme.body(12))
                                .foregroundColor(Theme.textPrimary)

                            Text("Removes unquoted hesitation sounds like ‘um’ and ‘uh’ from prose. Keeps deliberate corrections and adds no AI cleanup delay.")
                                .font(Theme.body(10))
                                .foregroundColor(Theme.textSecondary)

                            CloudEngineAdvancedView(settingsStore: settingsStore)
                        }

                        if settingsStore.selectedCloudModel.provider == .gemini {
                            Divider().overlay(Theme.hairline)

                            Text("Preview model — a paid Gemini API key is recommended. Free-tier keys may be used to improve Google products.")
                                .font(Theme.body(10))
                                .foregroundColor(Theme.textSecondary)

                            Text(geminiLanguageCaption)
                                .font(Theme.body(10))
                                .foregroundColor(Theme.textSecondary)

                            Toggle("Remove filler words", isOn: $settingsStore.removeFillerWords)
                                .toggleStyle(.switch)
                                .font(Theme.body(12))
                                .foregroundColor(Theme.textPrimary)

                            Text("Smart mode strips filler words and disfluencies; verbatim keeps them. Same toggle applies to ElevenLabs when that engine is selected.")
                                .font(Theme.body(10))
                                .foregroundColor(Theme.textSecondary)

                            CloudEngineAdvancedView(settingsStore: settingsStore)
                        }

                        if settingsStore.selectedCloudModel.provider == .meta {
                            Divider().overlay(Theme.hairline)

                            Text("Meta Model API — Muse Voice Transcribe streams live at release. Get an API key from Meta AI Studio.")
                                .font(Theme.body(10))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                }
                }

                }

                if shows("Cleanup") {
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
                                if settingsStore.hasXAIKey {
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
                        Toggle("Edit selected text by voice", isOn: $settingsStore.voiceEditSelectedText)
                            .toggleStyle(.switch)
                            .font(Theme.body(12))
                            .foregroundColor(Theme.textPrimary)

                        Text("Hold ⇧ with the dictation key to dictate over a selection instead.")
                            .font(Theme.body(10))
                            .foregroundColor(Theme.textSecondary)

                        Divider().overlay(Theme.hairline)

                        Toggle("Code-aware mode (for coding)", isOn: $settingsStore.codeAwareMode)
                            .toggleStyle(.switch)
                            .font(Theme.body(12))
                            .foregroundColor(Theme.textPrimary)

                        Text("Turns spoken words like “dot” and “period” into symbols for coding. Does not require Cleanup — leave off for normal prose.")
                            .font(Theme.body(10))
                            .foregroundColor(Theme.textSecondary)
                    }
                }

                }

                if shows("System") {
                section(title: "Microphone") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Microphone", selection: microphoneSelection) {
                            Text("Automatic").tag("")
                            ForEach(settingsStore.microphoneDevices) { device in
                                Text(device.name).tag(device.uid)
                                    .disabled(settingsStore.isInputDeviceExcluded(device.uid))
                            }
                        }
                        .pickerStyle(.menu)

                        Text("Automatic uses an available microphone. A selected microphone is used when it is connected.")
                            .font(Theme.body(10))
                            .foregroundColor(Theme.textSecondary)

                        if let selectedUID = settingsStore.preferredInputDeviceUID,
                           (!settingsStore.microphoneDevices.contains(where: { $0.uid == selectedUID })
                               || settingsStore.isInputDeviceExcluded(selectedUID)) {
                            Text("Saved microphone is unavailable or excluded. Using Automatic for this hold.")
                                .font(Theme.body(10))
                                .foregroundColor(Theme.amberText)
                        }

                        Divider().overlay(Theme.hairline)

                        Toggle("Voice isolation", isOn: $settingsStore.voiceIsolation)
                            .toggleStyle(.switch)
                            .font(Theme.body(12))
                            .foregroundColor(Theme.textPrimary)

                        Text("Uses Apple voice processing on the built-in mic to reduce background noise. Other mics use standard capture. While dictating, Mic Mode can switch to Voice Isolation for stronger noise removal.")
                            .font(Theme.body(10))
                            .foregroundColor(Theme.textSecondary)

                        if settingsStore.voiceIsolation {
                            Button("Mic Mode…") {
                                AVCaptureDevice.showSystemUserInterface(.microphoneModes)
                            }
                            .buttonStyle(.glass)
                            .font(Theme.body(12, weight: .medium))
                            .foregroundColor(Theme.primary)
                        }

                        if !settingsStore.microphoneDevices.isEmpty {
                            Divider().overlay(Theme.hairline)

                            Text("Never use")
                                .font(Theme.body(12, weight: .medium))
                                .foregroundColor(Theme.textPrimary)

                            Text("Excluded microphones are never selected, including as a fallback.")
                                .font(Theme.body(10))
                                .foregroundColor(Theme.textSecondary)

                            ForEach(settingsStore.microphoneDevices) { device in
                                Toggle(device.name, isOn: microphoneExclusion(device))
                                    .toggleStyle(.switch)
                                    .font(Theme.body(12))
                                    .foregroundColor(Theme.textPrimary)
                            }
                        }
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

                        Toggle(
                            "Allow iPhone and virtual mics as fallback",
                            isOn: $settingsStore.allowLastResortInputFallback
                        )
                            .toggleStyle(.switch)
                            .font(Theme.body(12))
                            .foregroundColor(Theme.textPrimary)

                        Text("Off (default): stay on the MacBook mic. Continuity / Jump Desktop only if you pick them as Sound Input in System Settings. On: Murmur may fall back to those when the built-in looks dead.")
                            .font(Theme.body(10))
                            .foregroundColor(Theme.textSecondary)

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

                }

                if shows("Storage") {
                section(title: "Storage") {
                    storageSectionContent
                }

                }

                if shows("Clipboard") {
                section(title: "Clipboard") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Clipboard history", isOn: $settingsStore.clipboardHistoryEnabled)
                            .toggleStyle(.switch)
                            .font(Theme.body(12))
                            .foregroundColor(Theme.textPrimary)

                        Text("Saves what you copy, encrypted, on this Mac only.")
                            .font(Theme.body(10))
                            .foregroundColor(Theme.textSecondary)

                        ClearSavedClipboardButton(store: clipboardStore)
                    }
                }

                }

                if shows("Voice") {
                section(title: "Voice") {
                    voiceSectionContent
                }

                }

                if shows("Permissions") {
                section(title: "Permissions") {
                    permissionsSectionContent
                }
                }

                if shows("What's New") {
                section(title: "What's New") {
                    WhatsNewSettingsSectionView()
                }

                section(title: "Acknowledgements") {
                    AcknowledgementsSectionView()
                }
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsRail
                .onAppear { settingsStore.refreshKeyPresence() }
            Divider().overlay(Theme.hairline)
            ScrollView {
                sectionContent
            }
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
            refreshPermissionStatus()
            if selectedSection == .permissions { startPermissionPolling() }
        }
        .onChange(of: selectedSection) { _, section in
            if section == .permissions { startPermissionPolling() } else { stopPermissionPolling() }
        }
        .onDisappear { stopPermissionPolling() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatus()
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
    private var settingsRail: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsSection.allCases) { section in
                Button {
                    withAnimation(Theme.easeOutOrNil()) {
                        selectedSection = section
                        SettingsSectionSession.selected = section
                    }
                } label: {
                    settingsSectionLabel(section)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(section.rawValue) settings")
                .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
            }
            Spacer()
        }
        .padding(16)
        .frame(width: 154, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
    }

    @ViewBuilder
    private func settingsSectionLabel(_ section: SettingsSection) -> some View {
        let label = Text(section.rawValue)
            .font(Theme.body(13, weight: selectedSection == section ? .semibold : .regular))
            .foregroundColor(selectedSection == section ? Theme.textPrimary : Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: 32)
        if selectedSection == section {
            label.murmurGlassCard(cornerRadius: Theme.cornerRadiusCompact, tint: Theme.selectionTint)
        } else {
            label
        }
    }

    private var permissionsSectionContent: some View {
        let snapshot = permissionSnapshot
        return VStack(alignment: .leading, spacing: 0) {
            permissionRow(
                title: "Microphone",
                detail: "Records while you hold the key.",
                missingDetail: "Not granted. Murmur cannot record your voice.",
                granted: snapshot.microphone,
                settingsURL: PermissionDestination.microphone.url
            )
            Divider().overlay(Theme.hairline)
            permissionRow(
                title: "Accessibility",
                detail: "Types the text into the app you are using.",
                missingDetail: "Not granted. Murmur cannot type into other apps.",
                granted: snapshot.accessibility,
                settingsURL: PermissionDestination.accessibility.url
            )
            Divider().overlay(Theme.hairline)
            permissionRow(
                title: "Input Monitoring",
                detail: "Lets Murmur see the push-to-talk key.",
                missingDetail: "Not granted. Murmur cannot see the fn key.",
                granted: snapshot.inputMonitoring,
                settingsURL: PermissionDestination.inputMonitoring.url
            )
        }
        .onAppear { refreshPermissionStatus() }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        detail: String,
        missingDetail: String,
        granted: Bool,
        settingsURL: URL
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.body(12, weight: .medium)).foregroundColor(Theme.textPrimary)
                Text(granted ? detail : missingDetail)
                    .font(Theme.body(11)).foregroundColor(Theme.textSecondary)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(Theme.body(11, weight: .medium))
                    .foregroundColor(Theme.successGreen)
                    .accessibilityLabel("\(title), granted")
            } else {
                Button("Open System Settings") { NSWorkspace.shared.open(settingsURL) }
                    .buttonStyle(.glass)
                    .font(Theme.body(11, weight: .medium))
                    .foregroundColor(Theme.primary)
                    .accessibilityLabel("Open System Settings for \(title)")
            }
        }
        .padding(.vertical, 10)
        .id(permissionRefreshTick)
    }

    private func refreshPermissionStatus() {
        permissionRefreshTick += 1
    }

    private func startPermissionPolling() {
        guard permissionPollTimer == nil else { return }
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            refreshPermissionStatus()
        }
    }

    private func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    @ViewBuilder
    private var storageSectionContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                Self.storageSummary(
                    fileCount: settingsStore.recordingFileCount,
                    usageBytes: settingsStore.recordingUsageBytes,
                    budgetMB: settingsStore.recordingBudgetMB
                )
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

            Text("Recordings are kept until they exceed this budget, then the oldest are deleted first. Audio kept for failed-dictation retry is protected and can push usage past the budget.")
                .font(Theme.body(10))
                .foregroundColor(Theme.textSecondary)

            Divider().overlay(Theme.hairline)

            GlassEffectContainer(spacing: 10) {
                Button("Export recordings + transcripts…") {
                    exportRecordingsAndTranscripts()
                }
                .buttonStyle(.glassProminent)
                .foregroundColor(Theme.ctaText)
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

    static func storageSummary(fileCount: Int, usageBytes: Int64, budgetMB: Int) -> String {
        let files = "\(fileCount) \(fileCount == 1 ? "file" : "files")"
        let budgetBytes = Int64(budgetMB) * 1024 * 1024
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        let usage = usageBytes >= budgetBytes
            ? "\(budgetMB) MB, full"
            : "\(formatter.string(fromByteCount: usageBytes)) of \(budgetMB) MB"
        return "Retained audio: \(files) · \(usage)"
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
            Toggle("Focus on my voice (experimental)", isOn: $settingsStore.speakerGatingEnabled)
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
                .foregroundColor(Theme.ctaText)
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
        let prefix = telemetry.isSessionActive ? "Voice checks" : "Last session"

        if telemetry.attemptedWindows == 0 {
            let message = telemetry.isSessionActive
                ? "\(prefix): Listening — voice checks appear as you dictate."
                : "\(prefix): No voice checks yet — dictate with Focus on my voice turned on."
            Text(message)
                .font(Theme.body(10))
                .foregroundColor(Theme.textSecondary)
                .accessibilityLabel(message)
        } else if telemetry.evaluatedWindows == 0 {
            let message = "\(prefix): \(telemetry.unscoredWindows) voice check\(telemetry.unscoredWindows == 1 ? "" : "s") could not be completed. These checks identify your voice; they do not measure transcription accuracy."
            Text(message)
                .font(Theme.body(10))
                .foregroundColor(Theme.textSecondary)
                .accessibilityLabel(message)
        } else {
            let medianText = telemetry.medianSimilarity.map { String(format: "%.2f", $0) } ?? "—"
            let unscoredSuffix = telemetry.unscoredWindows > 0
                ? " · \(telemetry.unscoredWindows) not checked"
                : ""
            let summary = "\(prefix): \(telemetry.passedWindows)/\(telemetry.evaluatedWindows) voice checks passed · \(telemetry.attenuatedWindows) quietened\(unscoredSuffix) · median \(medianText)"
            Text(summary)
                .font(Theme.body(10))
                .foregroundColor(Theme.textSecondary)
                .accessibilityLabel(summary)
                .accessibilityHint("Checks that identify your voice each second. These do not measure transcription accuracy.")
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
        let hasKey = settingsStore.apiKeyPresence[provider.keychainAccount] == true
        // Re-read whenever provider health changes (plan 034).
        let _ = providerHealthTick
        let refusal = settingsStore.refusalNotice(for: provider)

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
                    .foregroundColor(Theme.ctaText)
                    .tint(Theme.lavender)
                    .font(Theme.body(11, weight: .medium))
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Remove") {
                        pendingAPIKeyRemoval = provider
                        showAPIKeyRemoveConfirmation = true
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
            } else if hasKey, let refusal {
                providerRefusalStatus(refusal, provider: provider)
            } else if hasKey {
                HStack(spacing: 4) {
                    Text("Key saved")
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(Theme.body(10))
                .foregroundColor(Theme.successGreen)
                if let checkOutcome = providerCheckOutcome {
                    Text(checkOutcome)
                        .font(Theme.body(10))
                        .foregroundColor(Theme.textSecondary)
                }
            } else {
                Text("No key — cloud falls back to local.")
                    .font(Theme.body(10))
                    .foregroundColor(Theme.amberText)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .providerHealthDidChange)) { _ in
            providerHealthTick &+= 1
        }
        .onChange(of: provider.id) { _, _ in providerCheckOutcome = nil }
        .confirmDelete(
            isPresented: $showAPIKeyRemoveConfirmation,
            title: "Remove \(pendingAPIKeyRemoval?.displayName ?? provider.displayName) API key?",
            message: "The key is deleted from your Keychain. You'll need to paste it again to use this provider.",
            onConfirm: {
                settingsStore.removeAPIKey(for: pendingAPIKeyRemoval ?? provider)
                pendingAPIKeyRemoval = nil
                apiKeyInput = ""
                apiKeySaveFailed = false
            }
        )
    }

    /// Amber "Rejected 8:43 PM: payment needed. Dictation is using on-device."
    /// line with Check now and Open billing (plan 034). Replaces "Key saved"
    /// until a request succeeds.
    @ViewBuilder
    private func providerRefusalStatus(_ notice: ProviderNotice, provider: CloudProvider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(notice.settingsLine())
                .font(Theme.body(10))
                .foregroundColor(Theme.amberText)
                .accessibilityLabel("\(provider.displayName) rejected requests. \(notice.reason). Dictation is using on-device.")
            HStack(spacing: 10) {
                Button(isCheckingProvider ? "Checking…" : "Check now") {
                    isCheckingProvider = true
                    providerCheckOutcome = nil
                    Task {
                        let result = await settingsStore.checkProvider(provider)
                        isCheckingProvider = false
                        switch result {
                        case .ok: providerCheckOutcome = "\(provider.displayName) accepted a test request."
                        case .rejected(let kind): providerCheckOutcome = "Still rejected: \(ProviderNotice(provider: provider, kind: kind, lastRejection: Date()).reason)."
                        case .noKey: providerCheckOutcome = "No key saved."
                        case .failed(let why): providerCheckOutcome = "Couldn't check: \(why)"
                        }
                    }
                }
                .buttonStyle(.glass)
                .font(Theme.body(11, weight: .medium))
                .disabled(isCheckingProvider)
                .accessibilityLabel("Check \(provider.displayName) now")
                .accessibilityHint("Sends a one second silent clip to test the key")

                Button(notice.kind == .billing ? "Open billing" : "Open key page") {
                    NSWorkspace.shared.open(notice.remedyURL)
                }
                .buttonStyle(.glass)
                .font(Theme.body(11, weight: .medium))
                .accessibilityLabel(notice.kind == .billing
                    ? "Open \(provider.displayName) billing page"
                    : "Open \(provider.displayName) key page")
            }
            if let providerCheckOutcome {
                Text(providerCheckOutcome)
                    .font(Theme.body(10))
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }

    /// SecureField + Save/Remove + status line for the cleanup cloud
    /// (OpenAI) Keychain-backed API key. Mirrors `apiKeyEntry(for:)`'s shape.
    @ViewBuilder
    private func cleanupKeyEntry() -> some View {
        let hasKey = settingsStore.hasCleanupKey

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
                    .foregroundColor(Theme.ctaText)
                    .tint(Theme.lavender)
                    .font(Theme.body(11, weight: .medium))
                    .disabled(cleanupKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Remove") {
                        showCleanupKeyRemoveConfirmation = true
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
        .confirmDelete(
            isPresented: $showCleanupKeyRemoveConfirmation,
            title: "Remove OpenAI API key?",
            message: "The key is deleted from your Keychain. You'll need to paste it again to use cleanup.",
            onConfirm: {
                settingsStore.removeCleanupKey()
                cleanupKeyInput = ""
                cleanupKeySaveFailed = false
            }
        )
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // A one-card section's caption would only repeat the page title.
            if title != selectedSection.rawValue {
                Text(title)
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 14)
            }

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .murmurGlassCard()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        let isSystemAsset = modelManager.isSystemAssetManaged(model)

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

                modelRowTrailingControl(model, isSidecar: isSidecar, isSystemAsset: isSystemAsset)
            }

            statusLine(model, isSidecar: isSidecar, isSystemAsset: isSystemAsset)

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
    private func modelRowTrailingControl(
        _ model: LocalModel,
        isSidecar: Bool,
        isSystemAsset: Bool
    ) -> some View {
        if isSidecar {
            // Parakeet — managed by the Python sidecar's own HF cache, not
            // this manager's download/delete flow. No actions offered.
            EmptyView()
        } else if isSystemAsset {
            switch modelManager.state[model] ?? .idle {
            case .idle:
                if modelManager.isDownloaded(model) {
                    EmptyView()
                } else {
                    Button("Install") {
                        modelManager.download(model)
                    }
                    .buttonStyle(.glass)
                    .font(Theme.body(11, weight: .medium))
                    .foregroundColor(Theme.primary)
                }
            case .downloading:
                Text("Installing…")
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
                HStack(spacing: 8) {
                    Text("\(Int((modelManager.downloadProgress[model] ?? 0) * 100))%")
                        .font(Theme.body(11))
                        .foregroundColor(Theme.textSecondary)
                    Button("Cancel") {
                        modelManager.cancelDownload(model)
                    }
                    .buttonStyle(.glass)
                    .font(Theme.body(11, weight: .medium))
                    .foregroundColor(Theme.primary)
                    .accessibilityLabel("Cancel \(model.displayName) download")
                }
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
    private func statusLine(
        _ model: LocalModel,
        isSidecar: Bool,
        isSystemAsset: Bool
    ) -> some View {
        if isSidecar {
            if let size = modelManager.diskSizeDisplay(model) {
                Text("Managed by Parakeet · \(size)")
                    .font(Theme.body(10))
                    .foregroundColor(Theme.textSecondary)
            } else {
                Text("Managed by Parakeet — size unavailable")
                    .font(Theme.body(10))
                    .foregroundColor(Theme.textSecondary)
            }
        } else if isSystemAsset {
            switch modelManager.state[model] ?? .idle {
            case .downloading:
                Text("Installing system asset…")
                    .font(Theme.body(10))
                    .foregroundColor(Theme.textSecondary)
            case .failed:
                Text("System asset unavailable")
                    .font(Theme.body(10))
                    .foregroundColor(Theme.amberText)
            case .idle:
                Text(modelManager.isDownloaded(model) ? "Ready" : "Install Apple speech asset")
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
