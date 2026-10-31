#if canImport(SwiftUI)
import SwiftUI

/// A summary as prose: the paragraph, then one quiet line of when, who and how it was written (Carter, 10-31). Its
/// text styles follow Dynamic Type, it wraps at any width, and the paragraph can be selected.
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
#endif
