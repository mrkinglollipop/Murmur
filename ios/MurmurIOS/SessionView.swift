import SwiftUI

/// Host-app surface while a take is active.
/// Listen-gate: Wispr-style interstitial (Murmur is on → swipe bottom edge).
/// Live take: mic / stop / discard controls.
struct SessionView: View {
    @ObservedObject private var session = DictationController.shared

    private let coral = Color(red: 0.847, green: 0.353, blue: 0.188) // #D85A30
    private let ink = Color(red: 0.11, green: 0.11, blue: 0.12)
    private let muted = Color(red: 0.45, green: 0.45, blue: 0.48)

    var body: some View {
        Group {
            if session.isAwaitingHostReturn {
                swipeInterstitial
            } else {
                activeSession
            }
        }
        .onAppear { session.becomeActive() }
    }

    /// Match Wispr’s “Flow is on / swipe bottom edge” interstitial — Murmur coral accent.
    private var swipeInterstitial: some View {
        ZStack(alignment: .bottom) {
            Color.white.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 48)

                VStack(spacing: 10) {
                    (Text("Murmur is ") + Text("on").foregroundColor(coral))
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(ink)

                    Text("You can start dictating once you’re back")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(muted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }

                Spacer(minLength: 28)

                phoneDiagram
                    .padding(.horizontal, 36)

                Spacer(minLength: 28)

                (
                    Text("Swipe right across the ")
                        + Text("bottom edge").foregroundColor(coral)
                        + Text(" to continue")
                )
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

                Spacer(minLength: 80)

                Button("Discard") {
                    session.discard()
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(muted)
                .padding(.bottom, 12)
            }

            swipeHintBar
        }
    }

    private var phoneDiagram: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(Color(red: 0.96, green: 0.96, blue: 0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 36, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )
                .frame(height: 280)

            VStack {
                Spacer()
                Image(systemName: "waveform")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.28))
                Spacer()
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 110, height: 5)
                    .padding(.bottom, 18)
            }
            .frame(height: 280)

            Circle()
                .fill(Color.black.opacity(0.12))
                .frame(width: 54, height: 54)
                .offset(y: 98)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Swipe right across the bottom edge to return to your app")
    }

    private var swipeHintBar: some View {
        HStack {
            Text("Swipe")
                .font(.system(size: 17, weight: .semibold))
            Spacer()
            Circle()
                .stroke(coral.opacity(0.85), lineWidth: 2.5)
                .frame(width: 28, height: 28)
            Spacer()
            Text("here")
                .font(.system(size: 17, weight: .semibold))
        }
        .foregroundStyle(coral)
        .padding(.horizontal, 28)
        .frame(height: 52)
        .background(coral.opacity(0.14).ignoresSafeArea(edges: .bottom))
        .accessibilityHidden(true)
    }

    private var activeSession: some View {
        ZStack {
            Color(red: 0.063, green: 0.063, blue: 0.078).ignoresSafeArea()
            VStack(spacing: 24) {
                Text(session.statusText)
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(red: 0.961, green: 0.961, blue: 0.969))
                    .padding(.horizontal, 24)

                if !session.transcript.isEmpty {
                    Text(session.transcript)
                        .font(.body)
                        .foregroundStyle(Color(red: 0.78, green: 0.78, blue: 0.80))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                HStack(spacing: 28) {
                    Button(action: { session.toggleMic() }) {
                        Image(systemName: session.isRecording ? "pause.fill" : "mic.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72)
                            .background(Circle().fill(Color.white.opacity(0.12)))
                    }
                    .disabled(session.isBusy)

                    Button(action: { session.send() }) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72)
                            .background(Circle().fill(Color(red: 0.886, green: 0.294, blue: 0.290)))
                    }
                    .disabled(session.isBusy)
                    .accessibilityLabel("Stop and send")
                }

                Button("Discard") {
                    session.discard()
                }
                .foregroundStyle(Color(red: 0.604, green: 0.604, blue: 0.635))
            }
        }
    }
}
