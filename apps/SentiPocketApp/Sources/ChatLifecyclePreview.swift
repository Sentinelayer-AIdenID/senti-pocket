#if DEBUG
import Foundation
import PocketSyncClient
import SwiftUI

/// The production confirmation on made-up chats, with its acknowledged calls visible to UI tests.
enum ChatLifecyclePreview {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PocketChatLifecyclePreview")
    }

    @MainActor
    static var rootView: some View {
        ChatLifecyclePreviewScreen()
            .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-ShotsDark") ? .dark : .light)
    }
}

@MainActor
private final class PreviewChatLifecycle: ObservableObject, ChatLifecycleServing {
    @Published private(set) var calls: [String] = []

    func archiveChat(_ roomId: String, accountId: String) async throws {
        calls.append("archive:\(accountId):\(roomId)")
    }

    func endChat(_ roomId: String, accountId: String) async throws {
        calls.append("end:\(accountId):\(roomId)")
    }

    func leaveChat(_ roomId: String, accountId: String) async throws {
        calls.append("leave:\(accountId):\(roomId)")
    }
}

@MainActor
private struct ChatLifecyclePreviewScreen: View {
    @StateObject private var client: PreviewChatLifecycle
    @StateObject private var center: ChatLifecycleCenter
    @State private var changed: [String] = []

    init() {
        let client = PreviewChatLifecycle()
        let center = ChatLifecycleCenter(client: client, lookup: { $0 == "preview-chat" ? .end : nil })
        center.setAccountId("preview-account")
        _client = StateObject(wrappedValue: client)
        _center = StateObject(wrappedValue: center)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Chat confirmation").font(.title2)
            Button("End chat") { center.request("preview-chat", action: .end) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("chat-lifecycle.preview.end")
            Text("Calls: \(client.calls.count)")
                .accessibilityIdentifier("chat-lifecycle.preview.calls")
            Text("Changes: \(changed.count)")
                .accessibilityIdentifier("chat-lifecycle.preview.changes")
            Text(client.calls.last ?? "No call")
                .accessibilityIdentifier("chat-lifecycle.preview.lastCall")
            Text(changed.last ?? "No changed chat")
                .accessibilityIdentifier("chat-lifecycle.preview.changedChat")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(ChatLifecycleAlerts(center: center) { changed.append($0) })
    }
}
#endif
