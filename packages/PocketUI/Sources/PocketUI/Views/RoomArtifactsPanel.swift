#if canImport(SwiftUI)
import SwiftUI

/// The room's artifacts from the right, like the Claude app's: every pull request, ticket, file, link and code block
/// the room produced or pointed at, newest first. A tap goes to the message it came from; the arrow opens the thing.
public struct RoomArtifactsPanel: View {
    private let artifacts: [RoomArtifact]
    private let isLoading: Bool
    private let messagesRead: Int
    private let onClose: () -> Void
    private let onOpenMessage: (Int64) -> Void
    private let onOpen: (URL) -> Void
    @State private var filter: RoomArtifact.Kind?

    public init(
        artifacts: [RoomArtifact],
        isLoading: Bool,
        messagesRead: Int,
        onClose: @escaping () -> Void,
        onOpenMessage: @escaping (Int64) -> Void,
        onOpen: @escaping (URL) -> Void
    ) {
        self.artifacts = artifacts
        self.isLoading = isLoading
        self.messagesRead = messagesRead
        self.onClose = onClose
        self.onOpenMessage = onOpenMessage
        self.onOpen = onOpen
    }

    private var shown: [RoomArtifact] {
        guard let filter else { return artifacts }
        return artifacts.filter { $0.kind == filter }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Artifacts")
                        .font(.title3.bold())
                        .foregroundStyle(PocketPalette.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(isLoading ? "Reading the room…" : "\(artifacts.count) from the last \(messagesRead) messages")
                        .font(.caption)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close artifacts")
                .accessibilityIdentifier("pocket.artifacts.close")
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(nil, "All \(artifacts.count)")
                    ForEach(RoomArtifact.Kind.allCases, id: \.self) { kind in
                        let count = artifacts.filter { $0.kind == kind }.count
                        if count > 0 { chip(kind, "\(kind.title) \(count)") }
                    }
                }
                .padding(.horizontal, 14)
            }
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if isLoading && artifacts.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
                    }
                    if !isLoading && artifacts.isEmpty {
                        Text("Nothing yet: pull requests, tickets, files, links and code in this room show here.")
                            .font(.footnote)
                            .foregroundStyle(PocketPalette.textSecondary)
                            .padding(.horizontal, 18)
                    }
                    ForEach(shown) { artifact in row(artifact) }
                }
                .padding(.bottom, 16)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PocketPalette.canvas.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pocket.artifacts")
    }

    private func chip(_ kind: RoomArtifact.Kind?, _ label: String) -> some View {
        let selected = filter == kind
        return Button {
            filter = kind
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(selected ? Color.white : PocketPalette.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selected ? PocketPalette.accentStrong : PocketPalette.inset, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func row(_ artifact: RoomArtifact) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                onOpenMessage(artifact.sequenceId)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: artifact.kind.symbol)
                        .foregroundStyle(PocketPalette.accentStrong)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(artifact.title)
                            .font(artifact.kind == .code ? .footnote.monospaced() : .subheadline.weight(.semibold))
                            .foregroundStyle(PocketPalette.textPrimary)
                            .lineLimit(2)
                        Text(meta(artifact))
                            .font(.caption2)
                            .foregroundStyle(PocketPalette.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(artifact.kind.title): \(artifact.title). \(meta(artifact))")
            .accessibilityHint("Goes to the message it came from")
            if let url = artifact.url {
                Button {
                    onOpen(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(PocketPalette.textSecondary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(artifact.title)")
            }
        }
        .padding(12)
        .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 12)
        .accessibilityIdentifier("pocket.artifacts.row.\(artifact.id)")
    }

    private func meta(_ artifact: RoomArtifact) -> String {
        var parts: [String] = []
        if let detail = artifact.detail, detail != artifact.title { parts.append(detail) }
        parts.append(artifact.author)
        if let date = artifact.date { parts.append(PocketSidePanel.compactAge(of: date)) }
        if artifact.mentions > 1 { parts.append("\(artifact.mentions) mentions") }
        return parts.joined(separator: " · ")
    }
}
#endif
