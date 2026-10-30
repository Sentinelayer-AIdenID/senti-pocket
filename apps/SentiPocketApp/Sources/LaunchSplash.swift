import SwiftUI

/// The SentinelLayer logo grows in and fades out at launch, over the app while it loads your rooms (Carter, #55287:
/// "a nice growing and disappearing animation of sentinelayer logo at all start ... the loading room messages can
/// be in the background"). It stays at least `shortest` so it can be seen, never longer than `longest`, and leaves as
/// soon as the rooms are in. Reduce Motion gets a plain fade. Tests and previews skip it.
struct LaunchSplash: View {
    /// The room list has loaded (or failed): the app underneath is ready.
    let isReady: Bool

    static let shortest: TimeInterval = 0.9
    static let longest: TimeInterval = 2.6
    static let motto = "Every agent. One room. Proof of everything."

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var leaving = false
    @State private var gone = CrashReporter.isTestRun
    @State private var shownAt = Date()

    var body: some View {
        if !gone {
            ZStack {
                Color(red: 0.035, green: 0.05, blue: 0.16)
                    .ignoresSafeArea()
                VStack(spacing: 22) {
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 128, height: 128)
                        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                        .shadow(color: Color(red: 0.3, green: 0.4, blue: 1).opacity(appeared ? 0.55 : 0), radius: 28)
                        .scaleEffect(reduceMotion ? 1 : (leaving ? 1.3 : (appeared ? 1 : 0.55)))
                    Text(Self.motto)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared || reduceMotion ? 0 : 8)
                }
            }
            .opacity(leaving ? 0 : 1)
            .allowsHitTesting(!leaving)
            .accessibilityHidden(true)
            .onAppear {
                shownAt = Date()
                withAnimation(reduceMotion ? .easeOut(duration: 0.3) : .spring(response: 0.7, dampingFraction: 0.68)) {
                    appeared = true
                }
                if isReady { leave(in: Self.shortest) }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.longest) { leave(in: 0) }
            }
            .onChange(of: isReady) { ready in
                if ready { leave(in: max(0, Self.shortest - Date().timeIntervalSince(shownAt))) }
            }
        }
    }

    private func leave(in delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard !leaving else { return }
            withAnimation(.easeIn(duration: 0.45)) { leaving = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { gone = true }
        }
    }
}
