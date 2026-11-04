#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The room's (and a thread's) writing box. SwiftUI's `TextField(axis: .vertical)` laid its whole text out again
/// (TextKit 2) each time SwiftUI measured it, and the room measures its bottom bar many times per change, once per
/// nested safe-area inset: with a long draft every keystroke laid the text out again and again (Carter: "super chat lag
/// after 1k chars"; the 11-04 freezes followed long sends; sampled on the Mac, 43% of the main thread while typing at
/// 1,450 characters). Here the box tells SwiftUI a height it already knows, and only UIKit lays the text out, as it
/// changes.
struct ComposerTextField: View {
    let placeholder: String
    @Binding var text: String
    @Binding var isFocused: Bool
    /// The accessibility identifier, on the text view itself (so a UI test finds exactly one element).
    let identifier: String
    var maxLines: Int = 6

    #if canImport(UIKit)
    @State private var height: CGFloat = ComposerTextField.lineHeight

    static var lineHeight: CGFloat { ceil(UIFont.preferredFont(forTextStyle: .body).lineHeight) }

    var body: some View {
        ComposerTextView(text: $text, isFocused: $isFocused, height: $height, identifier: identifier,
                         placeholder: placeholder, maxHeight: Self.lineHeight * CGFloat(maxLines))
            .frame(height: height)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(Color(uiColor: .placeholderText))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
    #else
    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(1...maxLines)
            .textFieldStyle(.plain)
            .accessibilityIdentifier(identifier)
    }
    #endif
}

#if canImport(UIKit)
/// The text view behind `ComposerTextField`: SwiftUI asks its size and gets the height already known, never a fresh
/// layout of the whole text.
private struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var height: CGFloat
    let identifier: String
    let placeholder: String
    let maxHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> HeightReportingTextView {
        let view = HeightReportingTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = true
        view.accessibilityIdentifier = identifier
        view.accessibilityLabel = placeholder
        view.text = text
        let coordinator = context.coordinator
        view.onContentHeight = { [weak coordinator] contentHeight in coordinator?.contentHeightChanged(contentHeight) }
        return view
    }

    func updateUIView(_ view: HeightReportingTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // A change made here (a send empties the box, an @ or a restored draft is put in) reaches the text view; a
        // change typed in the view already matches.
        if view.text != text { view.text = text }
        // Focus asked from SwiftUI (Mention someone, File as a ticket, swipe to reply). Only a change since the last
        // update moves it, so the view's own focus (a tap, the keyboard dismissed by scrolling) is never undone.
        if isFocused != coordinator.lastFocus {
            coordinator.lastFocus = isFocused
            let wanted = isFocused
            DispatchQueue.main.async {
                if wanted, !view.isFirstResponder, view.window != nil {
                    view.becomeFirstResponder()
                } else if !wanted, view.isFirstResponder {
                    view.resignFirstResponder()
                }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: HeightReportingTextView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.bounds.width, height: height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        var lastFocus = false

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            if parent.text != view.text { parent.text = view.text }
        }

        func textViewDidBeginEditing(_ view: UITextView) {
            lastFocus = true
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ view: UITextView) {
            lastFocus = false
            if parent.isFocused { parent.isFocused = false }
        }

        /// The text's height changed: the box grows to it, up to `maxHeight`, and scrolls beyond. Set on the next
        /// turn of the run loop, never inside the layout that reported it.
        func contentHeightChanged(_ contentHeight: CGFloat) {
            let target = min(max(ceil(contentHeight), ComposerTextField.lineHeight), parent.maxHeight)
            guard abs(target - parent.height) > 0.5 else { return }
            let binding = parent.$height
            DispatchQueue.main.async { binding.wrappedValue = target }
        }
    }
}

/// A text view that says when its content height changes (UIKit keeps it as it lays out what changed).
final class HeightReportingTextView: UITextView {
    var onContentHeight: ((CGFloat) -> Void)?

    override var contentSize: CGSize {
        didSet {
            if contentSize.height != oldValue.height { onContentHeight?(contentSize.height) }
        }
    }
}
#endif
#endif
