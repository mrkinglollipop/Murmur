import SwiftUI

/// Host-app surface while a take is active.
/// Listen-gate: Wispr-style interstitial (Murmur is on → swipe bottom edge).
/// Live take: mic / stop / discard controls.
struct SessionView: View {
    @ObservedObject private var session = DictationController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    /// Match Wispr’s “Flow is on / swipe bottom edge” interstitial — Murmur coral.
    private var swipeInterstitial: some View {
        ZStack(alignment: .bottom) {
            Color.white.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 36)

                VStack(spacing: 12) {
                    (Text("Murmur is ") + Text("on").foregroundColor(coral))
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(ink)

                    Text("Swipe back to your app, then speak")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(muted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }

                Spacer(minLength: 20)

                PhoneSwipeDiagram(coral: coral, reduceMotion: reduceMotion)
                    .padding(.horizontal, 52)

                Spacer(minLength: 24)

                (
                    Text("Swipe right across the ")
                        + Text("bottom edge").foregroundColor(coral)
                        + Text(" to continue")
                )
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

                Spacer(minLength: 48)

                Button("Discard") {
                    session.discard()
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(muted)
                .padding(.bottom, 72)
            }

            BottomSwipeCoach(coral: coral, reduceMotion: reduceMotion)
        }
        .ignoresSafeArea(edges: .bottom)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Murmur is on. Swipe right across the bottom edge to return to your app, then speak.")
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

/// Bottom half of a phone with a finger target sliding on the home indicator.
private struct PhoneSwipeDiagram: View {
    var coral: Color
    var reduceMotion: Bool
    @State private var sliding = false

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 42, style: .continuous)
                .stroke(Color.black.opacity(0.88), lineWidth: 7)
                .background(
                    RoundedRectangle(cornerRadius: 42, style: .continuous)
                        .fill(Color(red: 0.97, green: 0.97, blue: 0.98))
                )
                .frame(height: 268)

            VStack(spacing: 0) {
                Spacer()
                Image(systemName: "waveform")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.28))
                Spacer()
                ZStack {
                    Capsule()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: 128, height: 5)
                    Circle()
                        .fill(Color.black.opacity(0.18))
                        .frame(width: 52, height: 52)
                        .offset(x: reduceMotion ? 0 : (sliding ? 36 : -36))
                    Circle()
                        .fill(coral)
                        .frame(width: 18, height: 18)
                        .offset(x: reduceMotion ? 0 : (sliding ? 36 : -36))
                }
                .padding(.bottom, 22)
            }
            .frame(height: 268)
        }
        .onAppear { startMotion() }
        .accessibilityHidden(true)
    }

    private func startMotion() {
        guard !reduceMotion else { return }
        sliding = false
        withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
            sliding = true
        }
    }
}

/// Sits on the home indicator: labels above, finger on the actual swipe edge.
private struct BottomSwipeCoach: View {
    var coral: Color
    var reduceMotion: Bool
    @State private var sliding = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Swipe")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Text("here")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(coral)
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .padding(.bottom, 4)

            GeometryReader { geo in
                let start = geo.size.width * 0.12
                let end = geo.size.width * 0.78
                ZStack(alignment: .bottomLeading) {
                    Capsule()
                        .fill(Color.black.opacity(0.22))
                        .frame(width: 134, height: 5)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 8)
                    Circle()
                        .fill(coral)
                        .frame(width: 22, height: 22)
                        .shadow(color: coral.opacity(0.45), radius: 6, y: 1)
                        .offset(
                            x: reduceMotion ? (start + end) / 2 - 11 : (sliding ? end : start),
                            y: -2
                        )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 34)
        }
        .frame(maxWidth: .infinity)
        .background(coral.opacity(0.16))
        .onAppear { startMotion() }
        .accessibilityHidden(true)
    }

    private func startMotion() {
        guard !reduceMotion else { return }
        sliding = false
        withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
            sliding = true
        }
    }
}

#Preview("Swipe interstitial") {
    SessionView()
        .onAppear {
            DictationController.shared.isAwaitingHostReturn = true
        }
}
