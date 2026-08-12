import SwiftUI

/// Shown if the user opens Murmur while a keyboard-started take is active.
struct SessionView: View {
    @ObservedObject private var session = DictationController.shared

    var body: some View {
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
        .onAppear { session.becomeActive() }
    }
}
