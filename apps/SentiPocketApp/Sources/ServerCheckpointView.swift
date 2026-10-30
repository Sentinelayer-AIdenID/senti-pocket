import PocketUI
import PocketVoice
import SwiftUI

/// A room checkpoint as the server holds it (warden, 10-30, option (a)): its title, what it covers, who wrote it and
/// when, and its summary, with Listen. Said plainly that it is not a signed copy: the signing service that Pocket's
/// verified view needs is not live yet, and this view never claims to be that.
struct ServerCheckpointView: View {
    let row: SessionCheckpointRowPresentation
    @ObservedObject var reader: MessageReader
    let onDone: () -> Void

    private var readId: String { "checkpoint:" + row.checkpointId }
    private var text: String { row.summary?.isEmpty == false ? row.summary! : "No summary was written for this checkpoint." }

    private var coverage: String {
        var parts: [String] = []
        if let start = row.startSequence, let end = row.endSequence { parts.append("Messages #\(start)–#\(end)") }
        parts.append("by \(row.createdBy)")
        if let date = row.createdAt.date { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(row.title)
                        .font(.title3.weight(.semibold))
                    Label("From the server · not signed yet", systemImage: "shield.slash")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("pocket.checkpoint.server.unsigned")
                    Text(coverage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        if reader.readingId == readId {
                            reader.stop()
                        } else {
                            ReadAloudSource.shared.reading(in: row.sessionId)
                            _ = reader.read(id: readId, markdown: text, title: row.title)
                        }
                    } label: {
                        Label(reader.readingId == readId ? "Stop" : "Listen",
                              systemImage: reader.readingId == readId ? "stop.fill" : "speaker.wave.2.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("pocket.checkpoint.server.listen")
                    ChatMarkdownView(text: text, ownHandles: [])
                        .accessibilityIdentifier("pocket.checkpoint.server.summary")
                    Text("Pocket shows this checkpoint as the server holds it. A signed copy, checked on this phone, comes once the signing service is live.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .pocketCanvas()
            .navigationTitle("Checkpoint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                        .accessibilityIdentifier("pocket.checkpoint.server.done")
                }
            }
        }
    }
}
