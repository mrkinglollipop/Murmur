import SwiftUI

/// Pro sign-in sheet — the approved mock's two states: provider buttons, and
/// the "finishing in your browser" wait with cancel. The browser does the
/// actual authentication; this sheet's whole job is making the app→browser→app
/// hop feel intentional.
struct SignInSheetView: View {
    @ObservedObject var authFlow: AuthFlowController
    var onDismiss: () -> Void

    /// Drives the 5-minute waiting-state expiry check (mock: fall back to
    /// the buttons with "That took too long — try again.").
    private let expiryTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            switch authFlow.state {
            case .waitingForBrowser, .exchanging:
                waitingContent
            case .signedIn(let session):
                signedInContent(session)
            case .signedOut, .failed:
                buttonsContent
            }
        }
        .padding(24)
        .frame(width: 330)
        .background(Theme.bg)
        .onReceive(expiryTimer) { _ in authFlow.expireIfTimedOut() }
    }

    private var buttonsContent: some View {
        VStack(spacing: 10) {
            Text("Sign in to Murmur")
                .font(Theme.serifTitle(24))
                .foregroundColor(Theme.textPrimary)
            Text("One account for your subscription and minutes.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .padding(.bottom, 8)

            if case .failed(let message) = authFlow.state {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.amberText)
                    .padding(.bottom, 4)
            }

            Button {
                authFlow.beginSignIn(provider: .apple)
            } label: {
                Label("Sign in with Apple", systemImage: "apple.logo")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ProviderButtonStyle(prominent: true))

            Button {
                authFlow.beginSignIn(provider: .google)
            } label: {
                Text("Sign in with Google")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ProviderButtonStyle(prominent: false))

            Text("Your browser will open to finish securely.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textSecondary)
                .padding(.top, 6)

            // The sheet is modal; without this the only way out of a failed
            // sign-in is quitting the app.
            Button("Not now") {
                authFlow.cancelSignIn()
                onDismiss()
            }
            .buttonStyle(.link)
            .foregroundColor(Theme.textSecondary)
            .keyboardShortcut(.cancelAction)
            .padding(.top, 2)
        }
    }

    private var waitingContent: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .padding(.bottom, 4)
            Text("Finishing in your browser…")
                .font(Theme.serifTitle(18))
                .foregroundColor(Theme.textPrimary)
            Text("Murmur continues automatically when you're done. Nothing else to click here.")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundColor(Theme.textSecondary)
            Button("Cancel") { authFlow.cancelSignIn() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.link)
                .foregroundColor(Theme.primary)
                .padding(.top, 4)
        }
    }

    private func signedInContent(_ session: SupabaseAuthClient.Session) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(Theme.successGreen)
            Text("Signed in\(session.email.map { " as \($0)" } ?? "")")
                .font(.system(size: 12))
                .foregroundColor(Theme.textPrimary)
            Button("Done") { onDismiss() }
                .buttonStyle(ProviderButtonStyle(prominent: true))
        }
    }
}

/// Apple = prominent white (platform convention); Google = quiet glass.
private struct ProviderButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(prominent ? Color.white : Theme.surface)
            .foregroundColor(prominent ? .black : Theme.textPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(prominent ? Color.clear : Theme.hairline, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Signed-in account sheet: who you are, what plan you're on, sign out.
/// Reached from the sidebar account row.
struct AccountSheetView: View {
    @ObservedObject var authFlow: AuthFlowController
    let email: String?
    let isPro: Bool
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 34))
                .foregroundColor(Theme.primary)

            VStack(spacing: 3) {
                Text(email ?? "Signed in")
                    .font(Theme.body(14, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                HStack(spacing: 5) {
                    if isPro { ProChip() }
                    Text(isPro ? "Murmur Pro" : "Free plan")
                        .font(Theme.body(12))
                        .foregroundColor(isPro ? Theme.successGreen : Theme.textSecondary)
                }
            }

            HStack(spacing: 10) {
                Button("Sign out") {
                    authFlow.signOut()
                    onDismiss()
                }
                .buttonStyle(.plain)
                .font(Theme.body(12))
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .murmurGlassCapsule()

                Button("Done") { onDismiss() }
                    .buttonStyle(.plain)
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundColor(Theme.lavenderText)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .murmurGlassCapsule(tint: Theme.selectionTint)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 330)
        .background(Theme.bg)
    }
}
