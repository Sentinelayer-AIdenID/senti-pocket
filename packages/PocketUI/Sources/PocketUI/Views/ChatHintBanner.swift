#if canImport(SwiftUI)
import SwiftUI

private struct ChatHintsKey: EnvironmentKey {
    static let defaultValue: ChatHints? = nil
}

private struct ChatHintsVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

public extension EnvironmentValues {
    /// One per signed-in app. Only the banner observes it, so a dismissal never redraws the conversation.
    var chatHints: ChatHints? {
        get { self[ChatHintsKey.self] }
        set { self[ChatHintsKey.self] = newValue }
    }

    /// The launch screen can cover all hint surfaces without pausing unrelated room work.
    var chatHintsVisible: Bool {
        get { self[ChatHintsVisibleKey.self] }
        set { self[ChatHintsVisibleKey.self] = newValue }
    }
}

/// A tip's copy and two distinct actions. Text wraps at narrow widths and accessibility sizes instead of truncating.
public struct ChatHintBanner: View {
    private let tip: ChatHints.Tip
    private let dismiss: () -> Void
    private let neverAgain: () -> Void

    public init(tip: ChatHints.Tip, dismiss: @escaping () -> Void, neverAgain: @escaping () -> Void) {
        self.tip = tip
        self.dismiss = dismiss
        self.neverAgain = neverAgain
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tip.text)
                .font(.caption)
                .foregroundStyle(PocketPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .padding(.trailing, 12)
                .accessibilityIdentifier("pocket.hint.text")
            HStack(spacing: 4) {
                Button("Don't show again", action: neverAgain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PocketPalette.accentStrong)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("pocket.hint.never")
                Spacer(minLength: 0)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PocketPalette.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Dismiss tip")
                .accessibilityIdentifier("pocket.hint.dismiss")
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(PocketPalette.separator, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pocket.hint")
    }
}

private struct ChatHintAtAnchor: View {
    @ObservedObject var hints: ChatHints
    let anchor: UUID

    var body: some View {
        if let current = hints.current, current.anchor == anchor {
            ChatHintBanner(tip: current.tip,
                           dismiss: { hints.dismiss(current, permanently: false) },
                           neverAgain: { hints.dismiss(current, permanently: true) })
        }
    }
}

/// A small hook around an existing surface. The overlay has no layout size: above the composer means outside its
/// top edge, so no message moves and no part of the message box is covered. Lists show their tip at the bottom.
struct ChatHintAnchor: ViewModifier {
    let context: ChatHints.Context
    var aboveComposer = false
    @Environment(\.chatHints) private var hints
    @Environment(\.chatHintsVisible) private var hintsVisible
    @Environment(\.roomIsCovered) private var covered
    @State private var anchor = UUID()

    private var visible: Bool { hintsVisible && !covered }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: aboveComposer ? .top : .bottom) {
                if let hints {
                    ChatHintAtAnchor(hints: hints, anchor: anchor)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.bottom, aboveComposer ? 4 : 8)
                        // A zero-height overlay at the top edge places its bottom-aligned content above the box.
                        // Its intrinsic height can change with the tip or text size without sizing the composer.
                        .frame(height: aboveComposer ? 0 : nil, alignment: .bottom)
                }
            }
            .onAppear { hints?.update(anchor: anchor, context: context, visible: visible) }
            .onChange(of: context) { next in hints?.update(anchor: anchor, context: next, visible: visible) }
            .onChange(of: visible) { next in hints?.update(anchor: anchor, context: context, visible: next) }
            .onDisappear { hints?.remove(anchor: anchor) }
    }
}
#endif
