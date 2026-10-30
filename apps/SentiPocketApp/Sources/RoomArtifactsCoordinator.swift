import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI

/// The room's artifacts for the panel: reads the room back on its own (never moving the chat), up to the newest
/// thousand messages, and pulls out its pull requests, tickets, files, links and code. Read again when the panel
/// opens after a minute.
@MainActor
final class RoomArtifactsCoordinator: ObservableObject {
    @Published private(set) var artifacts: [RoomArtifact] = []
    @Published private(set) var isLoading = false
    @Published private(set) var messagesRead = 0

    private let sessionId: String
    private let transport: any RoomTransport
    private var readAt: Date?
    private var task: Task<Void, Never>?

    static let pageSize = 100
    static let messageLimit = 1_000
    static let freshFor: TimeInterval = 60

    init(sessionId: String, transport: any RoomTransport) {
        self.sessionId = sessionId
        self.transport = transport
    }

    func open() {
        if let readAt, Date().timeIntervalSince(readAt) < Self.freshFor { return }
        task?.cancel()
        isLoading = true
        let sessionId = self.sessionId
        let transport = self.transport
        task = Task { [weak self] in
            var sources: [RoomArtifactSource] = []
            var before: Int64?
            while sources.count < Self.messageLimit, !Task.isCancelled {
                guard let page = try? await transport.roomEventsBefore(sessionId: sessionId, beforeSequence: before,
                                                                       limit: Self.pageSize) else { break }
                for message in page.messages where message.kind == .message {
                    sources.append(RoomArtifactSource(
                        id: message.id,
                        sequenceId: message.sequenceId,
                        author: message.authorName,
                        text: message.text,
                        date: ParsedSessionTimestamp(message.timestamp).date,
                        files: message.attachments.map { ($0.attachmentId, $0.filename) }
                    ))
                }
                guard page.hasMore, let next = page.nextBeforeSequence ?? page.minSequence, next != before else { break }
                before = next
            }
            let extracted = RoomArtifacts.extract(from: sources)
            guard let self, !Task.isCancelled else { return }
            self.artifacts = extracted
            self.messagesRead = sources.count
            self.isLoading = false
            self.readAt = Date()
        }
    }

    func close() {
        task?.cancel()
        isLoading = false
    }
}
