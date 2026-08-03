import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics

/// First-launch permission walkthrough for Input Monitoring, Microphone, and
/// Accessibility. Shown once until the user completes or skips onboarding.
struct OnboardingView: View {

    var onComplete: () -> Void = {}

    @State private var stepIndex = 0
    @State private var permissionRefreshTick = 0
    @State private var permissionPollTimer: Timer?

    private let steps: [OnboardingStep] = [
        OnboardingStep(
            title: "Input Monitoring",
            systemImage: "keyboard",
            description: """
            Murmur needs Input Monitoring to detect the push-to-talk key (fn / Globe) \
            while you work in any app.
            """,
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!,
            isGranted: InputMonitoringPermission.isGranted
        ),
        OnboardingStep(
            title: "Microphone",
            systemImage: "mic.fill",
            description: """
            Murmur captures audio from your microphone only while you hold the \
            push-to-talk key.
            """,
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!,
            isGranted: MicrophonePermission.isGranted
        ),
        OnboardingStep(
            title: "Accessibility",
            systemImage: "hand.point.up.left.fill",
            description: """
            Accessibility lets Murmur suppress the emoji picker when fn is held and \
            inject transcribed text at your cursor.
            """,
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!,
            isGranted: { AXIsProcessTrusted() }
        )
    ]

    private var isFinalStep: Bool { stepIndex == steps.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)

            VStack(alignment: .leading, spacing: 20) {
                Group {
                    if isFinalStep {
                        finalStepContent
                    } else {
                        stepContent(for: steps[stepIndex])
                    }
                }
                .transition(.opacity)
                .animation(Theme.easeOutOrNil(), value: stepIndex)

                progressDots

                Spacer(minLength: 0)

                HStack {
                    if stepIndex > 0 {
                        Button("Back") {
                            withAnimation(Theme.easeOutOrNil()) { stepIndex -= 1 }
                        }
                        .buttonStyle(.plain)
                        .font(Theme.body(12))
                        .foregroundColor(Theme.textSecondary)
                    }

                    Spacer()

                    if isFinalStep {
                        Button("Get Started") { completeOnboarding() }
                            .buttonStyle(.glassProminent)
                            .tint(Theme.lavender)
                            .font(Theme.body(12, weight: .semibold))
                    } else {
                        Button("Continue") {
                            withAnimation(Theme.easeOutOrNil()) { stepIndex += 1 }
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.lavender)
                        .font(Theme.body(12, weight: .semibold))
                    }
                }
            }
            .padding(24)
        }
        .frame(width: 480, height: 340)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .onAppear { startPermissionPolling() }
        .onDisappear { stopPermissionPolling() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionRefreshTick += 1
        }
    }

    @ViewBuilder
    private func stepContent(for step: OnboardingStep) -> some View {
        let granted = isStepGranted(step)

        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: step.systemImage)
                    .font(.system(size: 28))
                    .foregroundColor(Theme.primary)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(step.title)
                        .font(Theme.serifTitle(22, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                    Text("Step \(stepIndex + 1) of \(steps.count)")
                        .font(Theme.body(11))
                        .foregroundColor(Theme.textSecondary)
                }
            }

            Text(step.description)
                .font(Theme.body(13))
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundColor(granted ? Theme.primary : Theme.amberText)
                Text(granted ? "Granted" : "Not yet granted — open System Settings and enable Murmur.")
                    .font(Theme.body(12))
                    .foregroundColor(granted ? Theme.textSecondary : Theme.amberText)
            }

            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(step.settingsURL)
                    }
                    .buttonStyle(.glass)
                    .font(Theme.body(12, weight: .medium))
                    .foregroundColor(Theme.primary)

                    if step.title == "Input Monitoring", !InputMonitoringPermission.isGranted() {
                        Button("Request Access") {
                            InputMonitoringPermission.request()
                            permissionRefreshTick += 1
                        }
                        .buttonStyle(.glass)
                        .font(Theme.body(12, weight: .medium))
                        .foregroundColor(Theme.primary)
                    }

                    if step.title == "Microphone", !MicrophonePermission.isGranted() {
                        Button("Request Access") {
                            MicrophonePermission.request()
                            permissionRefreshTick += 1
                        }
                        .buttonStyle(.glass)
                        .font(Theme.body(12, weight: .medium))
                        .foregroundColor(Theme.primary)
                    }

                    if step.title == "Accessibility", !AXIsProcessTrusted() {
                        Button("Request Access") {
                            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
                            AXIsProcessTrustedWithOptions(options)
                            permissionRefreshTick += 1
                        }
                        .buttonStyle(.glass)
                        .font(Theme.body(12, weight: .medium))
                        .foregroundColor(Theme.primary)
                    }
                }
            }
        }
    }

    private var finalStepContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Theme.primary)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text("You're set")
                        .font(Theme.serifTitle(22, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                    Text("Step \(steps.count + 1) of \(steps.count + 1)")
                        .font(Theme.body(11))
                        .foregroundColor(Theme.textSecondary)
                }
            }

            Text("Hold your push-to-talk key to dictate anywhere. Your transcriptions land in Recent activity — nothing gets lost.")
                .font(Theme.body(13))
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< steps.count + 1, id: \.self) { index in
                Circle()
                    .fill(index == stepIndex ? Theme.primary : Theme.hairline)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 4)
    }

    private func isStepGranted(_ step: OnboardingStep) -> Bool {
        _ = permissionRefreshTick
        return step.isGranted()
    }

    private func startPermissionPolling() {
        stopPermissionPolling()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            permissionRefreshTick += 1
        }
    }

    private func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    private var header: some View {
        HStack {
            Text("Welcome to Murmur")
                .font(Theme.serifTitle(20, weight: .medium))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Button("Skip") { completeOnboarding() }
                .buttonStyle(.plain)
                .font(Theme.body(11))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: OnboardingStore.completeKey)
        onComplete()
    }
}

// MARK: - Step model

private struct OnboardingStep {
    let title: String
    let systemImage: String
    let description: String
    let settingsURL: URL
    let isGranted: () -> Bool
}

// MARK: - Permission helpers

enum OnboardingStore {
    static let completeKey = "voice.onboardingComplete"

    static var isComplete: Bool {
        UserDefaults.standard.bool(forKey: completeKey)
    }
}

enum MicrophonePermission {
    static func isGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func request() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }
}

enum InputMonitoringPermission {
    static func isGranted() -> Bool {
        CGPreflightListenEventAccess()
    }

    static func request() {
        CGRequestListenEventAccess()
    }
}
