#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit) && canImport(AuthenticationServices)
import AuthenticationServices
import UIKit
#endif

public struct PocketSignInView: View {
    private let phase: PocketSignInPhase
    private let offersApple: Bool
    private let send: (PocketProductIntent) -> Void
    @Environment(\.colorScheme) private var colorScheme

    /// `offersApple` adds Sign in with Apple wherever a sign-in can start; the build turns it on.
    public init(phase: PocketSignInPhase, offersApple: Bool = false, send: @escaping (PocketProductIntent) -> Void) {
        self.phase = phase
        self.offersApple = offersApple
        self.send = send
    }

    /// The phases with a sign-in button, where Apple is offered beside it.
    static func showsApple(in phase: PocketSignInPhase, offersApple: Bool) -> Bool {
        guard offersApple else { return false }
        switch phase {
        case .signedOut, .reauthenticationRequired, .unavailable: return true
        case .authorizing, .signedIn, .signingOut: return false
        }
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 58, weight: .semibold))
                    .foregroundStyle(PocketPalette.accent)
                    .accessibilityHidden(true)

                VStack(spacing: 10) {
                    Text("Sign in to Senti")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("See the sessions you belong to and answer your agents from your phone.")
                        .font(.body)
                        .foregroundStyle(PocketPalette.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        providerLabel("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        providerLabel("Google", systemImage: "g.circle.fill")
                    }
                    VStack(spacing: 10) {
                        providerLabel("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        providerLabel("Google", systemImage: "g.circle.fill")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Sign-in providers: GitHub or Google")

                phaseCard

                if Self.showsApple(in: phase, offersApple: offersApple) {
                    appleButton
                }

                Text("Sign-in opens Senti’s secure authorization page. Pocket never asks for or stores your GitHub or Google password.")
                    .font(.footnote)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                // Agreeing to the terms comes with signing in, said where you sign in.
                Text(PocketHelp.signInAgreement)
                    .font(.footnote)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .tint(PocketPalette.accent)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pocket.signin.terms")

                PocketHelpLinks()
            }
            .padding(28)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Account")
        .accessibilityIdentifier("pocket.signin.screen")
        .pocketCanvas()
    }

    @ViewBuilder
    private var phaseCard: some View {
        switch phase {
        case .signedOut:
            actionCard(
                title: "Continue securely",
                detail: "Choose GitHub or Google on Senti’s authorization page.",
                buttonTitle: "Continue with GitHub or Google",
                intent: .beginSignIn
            )

        case .authorizing:
            VStack(spacing: 14) {
                ProgressView()
                    .tint(PocketPalette.accent)
                Text("Waiting for secure sign-in…")
                    .font(.headline)
                Button("Cancel") { send(.cancelSignIn) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("pocket.signin.cancel")
            }
            .frame(maxWidth: .infinity)
            .pocketCard()

        case .signedIn:
            VStack(alignment: .leading, spacing: 12) {
                Label("Signed in securely", systemImage: "checkmark.shield")
                    .font(.headline)
                    .foregroundStyle(PocketPalette.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("pocket.signin.signed-in")
                // Atlas-greenlit local sign-out (Pulse): clears local credentials + protected cache on THIS device.
                // Honest scope — NO server-side session-revocation claim (the copy says "on this device").
                Button("Sign out on this device") { send(.signOut) }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("pocket.signin.sign-out")
            }
            .pocketCard()

        case .reauthenticationRequired:
            actionCard(
                title: "Sign in again",
                detail: "Your authorization is no longer valid. Protected cached content stays hidden until you sign in.",
                buttonTitle: "Sign in again",
                intent: .retryAuthentication,
                color: PocketPalette.warning
            )

        case .signingOut:
            VStack(spacing: 12) {
                ProgressView()
                Text("Securing this device…")
                    .font(.headline)
                Text("Session access remains disabled until local credentials and protected cache are cleared.")
                    .font(.body)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .pocketCard()

        case .unavailable(let reason):
            actionCard(
                title: "Secure sign-in unavailable",
                detail: reason.userMessage,
                buttonTitle: "Try again",
                intent: .retryAuthentication,
                color: PocketPalette.danger
            )
        }
    }

    private func actionCard(
        title: String,
        detail: String,
        buttonTitle: String,
        intent: PocketProductIntent,
        color: Color = PocketPalette.accent
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(color)
            Text(detail)
                .font(.body)
                .foregroundStyle(PocketPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { send(intent) } label: {
                Text(buttonTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(PocketPalette.accent)
            .accessibilityIdentifier("pocket.signin.primary")
        }
        .pocketCard()
    }

    @ViewBuilder
    private var appleButton: some View {
        #if canImport(UIKit) && canImport(AuthenticationServices)
        AppleSignInButton(style: colorScheme == .dark ? .white : .black) { send(.beginAppleSignIn) }
            .frame(maxWidth: .infinity, minHeight: 50, maxHeight: 50)
            .id(colorScheme)   // the button's style is set once, so a new appearance makes a new button
            .accessibilityIdentifier("pocket.signin.apple")
        #else
        Button("Sign in with Apple") { send(.beginAppleSignIn) }
            .accessibilityIdentifier("pocket.signin.apple")
        #endif
    }

    private func providerLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PocketPalette.textSecondary)
    }
}
#endif

#if canImport(SwiftUI) && canImport(UIKit) && canImport(AuthenticationServices)
/// Apple's own Sign in with Apple button (its look is Apple's to set); a tap only sends the intent.
private struct AppleSignInButton: UIViewRepresentable {
    let style: ASAuthorizationAppleIDButton.Style
    let action: () -> Void

    func makeCoordinator() -> Tap { Tap(action: action) }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(authorizationButtonType: .signIn, authorizationButtonStyle: style)
        button.cornerRadius = 12
        button.addTarget(context.coordinator, action: #selector(Tap.fire), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action
    }

    final class Tap: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}
#endif
