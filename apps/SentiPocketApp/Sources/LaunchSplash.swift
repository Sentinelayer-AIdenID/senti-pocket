import SwiftUI

/// Something the person is waiting on opened the app: a tapped notification, a link, or a call. The launch logo
/// steps aside at once for it (warden, #256: a call must never be answered late behind it).
@MainActor
final class LaunchUrgency: ObservableObject {
    static let shared = LaunchUrgency()
    @Published private(set) var isUrgent = false

    func raise() {
        if !isUrgent { isUrgent = true }
    }
}

/// The SentinelLayer logo grows in and bursts out at launch, over the app while it loads your rooms (Carter, #55287:
/// "a nice growing and disappearing animation of sentinelayer logo at all start ... the loading room messages can
/// be in the background"; #55513: "give it more time for someone to read it. Let it grow longer and just explode in
/// the screen"). It grows in slowly, keeps growing while the motto is read, and leaves by flying out at you in a glow
/// as the app shows through. It stays at least `shortest` so the motto can be read, never longer than `longest`, and
/// leaves once the rooms are in. Opened by a notification, a link or a call, it leaves at once. Reduce Motion gets a
/// plain fade. Tests and previews skip it.
struct LaunchSplash: View {
    /// The room list has loaded (or failed): the app underneath is ready.
    let isReady: Bool

    static let shortest: TimeInterval = 2.8
    static let longest: TimeInterval = 4.0
    /// How long the logo takes to grow in, and then to burst out.
    static let growIn: TimeInterval = 1.2
    static let burst: TimeInterval = 0.6
    static let motto = "Every agent. One room. Proof of everything."

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var urgency = LaunchUrgency.shared
    @State private var appeared = false
    @State private var growing = false
    @State private var leaving = false
    @State private var gone = CrashReporter.isTestRun
    @State private var shownAt = Date()

    private static let glow = Color(red: 0.2, green: 0.95, blue: 0.55)

    private var logoScale: CGFloat {
        if reduceMotion { return 1 }
        if leaving { return 7 }
        if growing { return 1.12 }
        return appeared ? 1 : 0.4
    }

    var body: some View {
        if !gone {
            ZStack {
                Color(red: 0.02, green: 0.045, blue: 0.05)
                    .ignoresSafeArea()
                    .opacity(leaving ? 0 : 1)
                VStack(spacing: 22) {
                    // SentinelLayer's shield, as on sentinelayer.com (Carter, 08:08: "this is not my logo").
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 150)
                        .shadow(color: Self.glow.opacity(leaving ? 0.9 : (appeared ? 0.45 : 0)), radius: leaving ? 60 : 28)
                        .scaleEffect(logoScale)
                        .blur(radius: leaving && !reduceMotion ? 8 : 0)
                        .opacity(leaving ? 0 : (appeared || !reduceMotion ? 1 : 0))
                    Text(Self.motto)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .opacity(appeared && !leaving ? 1 : 0)
                        .offset(y: appeared || reduceMotion ? 0 : 8)
                }
            }
            .allowsHitTesting(!leaving)
            .accessibilityHidden(true)
            .onAppear {
                shownAt = Date()
                withAnimation(reduceMotion ? .easeOut(duration: 0.3) : .easeOut(duration: Self.growIn)) {
                    appeared = true
                }
                if !reduceMotion {
                    withAnimation(.easeInOut(duration: Self.longest).delay(Self.growIn)) { growing = true }
                }
                if isReady || urgency.isUrgent {
                    leave(in: Self.leaveDelay(urgent: urgency.isUrgent, shownFor: 0))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.longest) { leave(in: 0) }
            }
            .onChange(of: isReady) { ready in
                if ready { leave(in: Self.leaveDelay(urgent: urgency.isUrgent, shownFor: Date().timeIntervalSince(shownAt))) }
            }
            .onChange(of: urgency.isUrgent) { urgent in
                if urgent { leave(in: 0) }
            }
        }
    }

    /// How long it still stays: until the motto has been up `shortest`, or not at all when something is waiting.
    static func leaveDelay(urgent: Bool, shownFor: TimeInterval) -> TimeInterval {
        urgent ? 0 : max(0, shortest - shownFor)
    }

    private func leave(in delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard !leaving else { return }
            withAnimation(reduceMotion ? .easeIn(duration: 0.45) : .easeIn(duration: Self.burst)) { leaving = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.burst + 0.05) { gone = true }
        }
    }
}
