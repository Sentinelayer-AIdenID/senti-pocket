#if canImport(SwiftUI)
import SwiftUI

/// A summary as prose: the paragraph, then one quiet line of when, who and how it was written. Its text styles follow
/// Dynamic Type, it wraps at any width, and the paragraph can be selected.
public struct SummaryReadingView: View {
    private let reading: SummaryReading
    private let identifier: String

    public init(_ reading: SummaryReading, identifier: String) {
        self.reading = reading
        self.identifier = identifier
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(reading.prose)
                .font(.body)
                .foregroundStyle(PocketPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier(identifier)
            if let details = reading.details {
                Text(details)
                    .font(.footnote)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(reading.spokenDetails ?? details)
                    .accessibilityIdentifier(identifier + ".details")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A summary cut to the lines its list gives it (the line limit around it), with Show more when the cut hides some of
/// it. Show more opens the whole summary, read-only, so every member of the room can read it; making a new summary
/// stays in the room, for its owner.
public struct SummaryPreviewText: View {
    private let text: String
    private let title: String
    private let identifier: String
    private let moreInline: Bool
    @State private var isCut = false
    @State private var showsWhole = false

    /// - Parameters:
    ///   - text: The summary, as prose.
    ///   - title: The room's name, which titles the whole summary.
    ///   - identifier: The summary's accessibility identifier; Show more's is the same with ".more".
    ///   - moreInline: Show more at the end of a one-line summary, instead of under it.
    public init(_ text: String, title: String, identifier: String, moreInline: Bool = false) {
        self.text = text
        self.title = title
        self.identifier = identifier
        self.moreInline = moreInline
    }

    public var body: some View {
        Group {
            if moreInline {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    shown
                    if isCut { more }
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    shown
                    if isCut { more }
                }
            }
        }
        .onPreferenceChange(SummaryCutKey.self) { isCut = $0 }
        .sheet(isPresented: $showsWhole) {
            SummaryWholeSheet(title: title, summary: text)
        }
    }

    private var shown: some View {
        Text(text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .topLeading) { whole }
            .accessibilityIdentifier(identifier)
            .accessibilityAction(named: "Show the whole summary") { showsWhole = true }
    }

    /// The whole summary at the width of the cut one, unseen: taller means the cut hides some of it.
    private var whole: some View {
        GeometryReader { cut in
            Text(text)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: cut.size.width, alignment: .topLeading)
                .background(GeometryReader { full in
                    Color.clear.preference(key: SummaryCutKey.self, value: full.size.height > cut.size.height + 1)
                })
                .hidden()
        }
        .accessibilityHidden(true)
    }

    private var more: some View {
        Button {
            showsWhole = true
        } label: {
            Text(moreInline ? "More" : "Show more")
                .fontWeight(.semibold)
                .foregroundStyle(PocketPalette.accentStrong)
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Show the whole summary")
        .accessibilityIdentifier(identifier + ".more")
    }
}

/// Whether a summary's cut hides some of it.
private struct SummaryCutKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// A room's whole summary, read-only: what Show more opens from the room list and the side panel.
struct SummaryWholeSheet: View {
    let title: String
    let summary: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                SummaryReadingView(SummaryReading(prose: summary), identifier: "pocket.summary.whole.text")
                    .padding(20)
            }
            .pocketCanvas()
            .navigationTitle(title)
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("pocket.summary.whole.done")
                }
            }
        }
        // The list's cut and its small type stay in the list.
        .lineLimit(nil)
        .font(.body)
    }
}
#endif
