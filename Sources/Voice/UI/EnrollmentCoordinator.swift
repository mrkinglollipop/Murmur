import Foundation

/// Glue between enrollment UI, mic capture, FluidAudio download, and `VoiceGate`.
final class EnrollmentCoordinator: ObservableObject, Identifiable {

    /// Identity for `.sheet(item:)` presentation — binding presentation to the
    /// coordinator itself makes a content-less sheet unrepresentable.
    let id = UUID()

    static let prompts: [String] = [
        "The quick brown fox jumps over the lazy dog near the river bank.",
        "Bright violets shimmer while gentle waves wash the sandy shore.",
        "Seven plums ripen on the branch above my wooden garden gate.",
    ]

    @Published private(set) var flow = EnrollmentFlow()
    @Published var level: Float = 0

    private let profileStore: VoiceProfileStore
    private let sensitivityProvider: () -> VoiceGateSensitivity
    private let onGatingShouldRefresh: () -> Void

    private var embeddingProvider: FluidAudioEmbeddingProvider?
    private let enrollmentCapture = EnrollmentCapture()
    private var downloadTask: Task<Void, Never>?
    private var recordingTask: Task<Void, Never>?
    private var accumulatedWindows: [[Float]] = []

    init(
        profileStore: VoiceProfileStore,
        sensitivityProvider: @escaping () -> VoiceGateSensitivity,
        onGatingShouldRefresh: @escaping () -> Void
    ) {
        self.profileStore = profileStore
        self.sensitivityProvider = sensitivityProvider
        self.onGatingShouldRefresh = onGatingShouldRefresh
    }

    func start() {
        downloadTask?.cancel()
        recordingTask?.cancel()
        enrollmentCapture.stopCapture()
        accumulatedWindows.removeAll(keepingCapacity: false)
        level = 0

        flow.beginDownload()

        downloadTask = Task { [weak self] in
            guard let self else { return }

            if self.embeddingProvider == nil {
                self.embeddingProvider = FluidAudioEmbeddingProvider()
            }
            guard let provider = self.embeddingProvider else {
                await MainActor.run {
                    self.flow.downloadFailed("Voice model could not be loaded.")
                }
                return
            }

            let deadline = Date().addingTimeInterval(60)
            while !provider.isReady {
                if Task.isCancelled { return }
                if Date() >= deadline {
                    await MainActor.run {
                        self.flow.downloadFailed("Voice model download timed out. Check your connection and retry.")
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            if Task.isCancelled { return }

            await MainActor.run {
                self.flow.modelReady()
            }
        }
    }

    func recordCurrentStep() {
        guard case .recording = flow.phase else { return }

        recordingTask?.cancel()
        recordingTask = Task { [weak self] in
            guard let self else { return }

            let started = await withCheckedContinuation { continuation in
                self.enrollmentCapture.requestPermissionAndStart(
                    levelCallback: { [weak self] level in
                        self?.level = level
                    },
                    completion: { granted in
                        continuation.resume(returning: granted)
                    }
                )
            }

            guard !Task.isCancelled else {
                self.enrollmentCapture.stopCapture()
                await MainActor.run { self.level = 0 }
                return
            }

            if !started {
                await MainActor.run {
                    self.flow.stepFailed("Microphone access is required to enroll your voice.")
                    self.level = 0
                }
                return
            }

            try? await Task.sleep(nanoseconds: 10_000_000_000)

            if Task.isCancelled {
                self.enrollmentCapture.stopCapture()
                await MainActor.run { self.level = 0 }
                return
            }

            let windows = self.enrollmentCapture.stopCapture()
            self.accumulatedWindows.append(contentsOf: windows)

            await MainActor.run {
                self.level = 0
                self.flow.finishedStep()
            }

            if case .computing = self.flow.phase {
                await self.runEnrollment()
            }
        }
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        recordingTask?.cancel()
        recordingTask = nil
        enrollmentCapture.stopCapture()
        accumulatedWindows.removeAll(keepingCapacity: false)
        level = 0
        flow.cancel()
    }

    func deleteProfile(profileStore: VoiceProfileStore, disableGating: () -> Void) {
        profileStore.deleteProfile()
        disableGating()
        flow = EnrollmentFlow()
        accumulatedWindows.removeAll(keepingCapacity: false)
        level = 0
    }

    // MARK: - Private

    private func runEnrollment() async {
        guard let provider = embeddingProvider else {
            await MainActor.run {
                flow.computingFailed("Voice model is not available.")
            }
            return
        }

        let windows = accumulatedWindows
        let sensitivity = sensitivityProvider()
        let store = profileStore

        let profile = await Task.detached(priority: .userInitiated) {
            let gate = VoiceGate(
                profileStore: store,
                embeddingProvider: provider,
                sensitivity: sensitivity
            )
            return gate.enroll(segments: windows)
        }.value

        await MainActor.run {
            if profile != nil {
                flow.computingSucceeded()
                onGatingShouldRefresh()
            } else {
                flow.computingFailed("Could not build a voice profile from the recordings. Try again in a quieter room.")
            }
        }
    }
}
