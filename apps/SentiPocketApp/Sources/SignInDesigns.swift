#if DEBUG
import SwiftUI

/// Sign-in page directions to choose from (DEBUG only, never shipped): `-PocketSignInDesign A|B|C` opens one full
/// screen. They are pictures to pick from; the chosen one is then built for real, with Apple's own button.
enum SignInDesignPreview {
    static var requested: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-PocketSignInDesign"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    @ViewBuilder
    static func view(_ design: String) -> some View {
        switch design {
        case "B": LiveRoomDesign()
        case "C": MinimalDesign()
        default: EmberDesign()
        }
    }
}

private let ember = Color(red: 0.96, green: 0.42, blue: 0.16)
private let emberDeep = Color(red: 0.55, green: 0.16, blue: 0.05)

/// The three ways in, as the mocks draw them. Apple's is a stand-in drawn to Apple's look; the real one is Apple's.
private struct ProviderButtons: View {
    var dark: Bool
    var body: some View {
        VStack(spacing: 12) {
            pill(icon: "apple.logo", title: "Sign in with Apple",
                 fill: dark ? .white : .black, text: dark ? .black : .white, stroke: .clear)
            pill(icon: "chevron.left.forwardslash.chevron.right", title: "Continue with GitHub",
                 fill: dark ? Color.white.opacity(0.08) : Color(white: 0.97), text: dark ? .white : .black,
                 stroke: dark ? Color.white.opacity(0.25) : Color.black.opacity(0.12))
            pill(icon: "g.circle.fill", title: "Continue with Google",
                 fill: dark ? Color.white.opacity(0.08) : Color(white: 0.97), text: dark ? .white : .black,
                 stroke: dark ? Color.white.opacity(0.25) : Color.black.opacity(0.12))
        }
    }

    private func pill(icon: String, title: String, fill: Color, text: Color, stroke: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold))
            Text(title).font(.system(size: 17, weight: .semibold))
        }
        .foregroundStyle(text)
        .frame(maxWidth: .infinity, minHeight: 54)
        .background(fill, in: Capsule())
        .overlay(Capsule().stroke(stroke, lineWidth: 1))
    }
}

private struct Legal: View {
    var dark: Bool
    var body: some View {
        Text("By continuing you agree to the Terms and Privacy Policy. Pocket never sees your passwords.")
            .font(.footnote)
            .foregroundStyle(dark ? Color.white.opacity(0.55) : Color.secondary)
            .multilineTextAlignment(.center)
    }
}

/// A: dark and warm, the logo glowing, one bold promise, the ways in at the bottom.
private struct EmberDesign: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.05, blue: 0.07), Color(red: 0.09, green: 0.06, blue: 0.06), emberDeep],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            Circle().fill(ember.opacity(0.35)).frame(width: 420).blur(radius: 120).offset(y: -170)
            VStack(spacing: 0) {
                Spacer(minLength: 40)
                Image("Logo").resizable().scaledToFit().frame(width: 104, height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: ember.opacity(0.8), radius: 36)
                Spacer().frame(height: 34)
                Text("Your agents.\nIn your pocket.")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("Every room, every call, every answer they need from you.")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
                Spacer()
                ProviderButtons(dark: true)
                Legal(dark: true).padding(.top, 16)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .preferredColorScheme(.dark)
    }
}

/// B: the product shows itself first, a small live room above the ways in.
private struct LiveRoomDesign: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: [ember.opacity(scheme == .dark ? 0.35 : 0.22), .clear], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("3 agents online").font(.caption.weight(.semibold))
                        Spacer()
                        Text("Design review").font(.caption).foregroundStyle(.secondary)
                    }
                    bubble("review-agent", "Two findings on the onboarding flow. Fix for the first is up.", mine: false)
                    bubble("build-agent", "Build 319 is green. Ready for a look on device.", mine: false)
                    bubble("You", "Ship it after the retry fix 🚀", mine: true)
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 20, y: 10)
                .padding(.horizontal, 22)
                .rotation3DEffect(.degrees(6), axis: (x: 1, y: 0, z: 0))
            }
            .frame(maxHeight: .infinity)
            VStack(spacing: 10) {
                Text("Run your agents from anywhere")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text("Talk to them, answer their asks, and see who's working, live.")
                    .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 22)
            ProviderButtons(dark: scheme == .dark).padding(.horizontal, 24)
            Legal(dark: scheme == .dark).padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 12)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private func bubble(_ who: String, _ text: String, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 3) {
                if !mine { Text(who).font(.caption2.weight(.bold)).foregroundStyle(ember) }
                Text(text).font(.subheadline)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(mine ? ember.opacity(0.9) : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(mine ? .white : .primary)
            if !mine { Spacer(minLength: 40) }
        }
    }
}

/// C: calm and native: the mark, one line, three equal ways in.
private struct MinimalDesign: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image("Logo").resizable().scaledToFit().frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text("Senti")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .padding(.top, 18)
            Text("Your rooms and agents, wherever you are.")
                .font(.title3).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            Spacer()
            ProviderButtons(dark: scheme == .dark)
            Legal(dark: scheme == .dark).padding(.top, 16)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
        .background(Color(.systemBackground).ignoresSafeArea())
    }
}
#endif
