import SwiftUI

struct EnrollmentSheetView: View {
    @ObservedObject var coordinator: EnrollmentCoordinator
    var onDone: () -> Void

    @State private var isRecording = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 16) {
                phaseContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)

            Button {
                coordinator.cancel()
                onDone()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .padding(8)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .frame(width: 420, height: 360)
        .background(Theme.bg)
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch coordinator.flow.phase {
        case .notStarted:
            Text("Read 3 short sentences aloud so Murmur can recognize your voice.")
                .font(Theme.body(13))
                .foregroundColor(Theme.textSecondary)

            Spacer(minLength: 0)

            GlassEffectContainer(spacing: 10) {
                Button("Start") {
                    coordinator.start()
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.lavender)
                .font(Theme.body(12, weight: .medium))
            }

        case .downloadingModel:
            HStack(spacing: 10) {
                ProgressView()
                Text("Downloading voice model (~100MB, first time only)…")
                    .font(Theme.body(12))
                    .foregroundColor(Theme.textSecondary)
            }

        case .recording(let step):
            Text(EnrollmentCoordinator.prompts[step])
                .font(Theme.serifTitle(20, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            levelMeter

            Text("Step \(step + 1) of 3")
                .font(Theme.body(11))
                .foregroundColor(Theme.textSecondary)

            Spacer(minLength: 0)

            GlassEffectContainer(spacing: 10) {
                Button("Record ~10s") {
                    guard !isRecording else { return }
                    isRecording = true
                    coordinator.recordCurrentStep()
                    Task {
                        try? await Task.sleep(nanoseconds: 10_500_000_000)
                        await MainActor.run { isRecording = false }
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.lavender)
                .font(Theme.body(12, weight: .medium))
                .disabled(isRecording)
            }

        case .computing:
            HStack(spacing: 10) {
                ProgressView()
                Text("Computing your voice profile…")
                    .font(Theme.body(12))
                    .foregroundColor(Theme.textSecondary)
            }

        case .done:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Theme.successGreen)
                Text("Your voice profile is ready.")
                    .font(Theme.body(13, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
            }

            Spacer(minLength: 0)

            GlassEffectContainer(spacing: 10) {
                Button("Done") {
                    onDone()
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.lavender)
                .font(Theme.body(12, weight: .medium))
            }

        case .failed(let message):
            Text(message)
                .font(Theme.body(12))
                .foregroundColor(Theme.amberText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            GlassEffectContainer(spacing: 10) {
                Button("Retry") {
                    coordinator.start()
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.lavender)
                .font(Theme.body(12, weight: .medium))
            }
        }
    }

    private var levelMeter: some View {
        HStack(spacing: 4) {
            ForEach(0 ..< 12, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(barFill(for: index) ? Theme.lavender : Theme.hairline)
                    .frame(width: 8, height: barHeight(for: index))
            }
        }
        .frame(height: 28, alignment: .bottom)
        .animation(.easeOut(duration: 0.08), value: coordinator.level)
    }

    private func barFill(for index: Int) -> Bool {
        let threshold = Float(index + 1) / 12.0
        return coordinator.level >= threshold
    }

    private func barHeight(for index: Int) -> CGFloat {
        let base: CGFloat = 8
        let maxExtra: CGFloat = 20
        let progress = CGFloat(min(1, max(0, coordinator.level)))
        let indexBoost = CGFloat(index) / 11.0
        return base + maxExtra * progress * indexBoost
    }
}
