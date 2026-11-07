import SwiftUI

/// A bounded question uses the existing full-screen call window. The real server acknowledgement is the only
/// success state; uncertain writes keep the original answer for an explicit retry.
struct QuestionCallView: View {
    @ObservedObject var call: QuestionCallCoordinator

    var body: some View {
        VStack(spacing: 20) {
            Text("Question for you").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let question = call.question {
                        Text(question.text).font(.title3).textSelection(.enabled)
                            .accessibilityIdentifier("question.call.text")
                        ForEach(Array(question.choices.enumerated()), id: \.element.id) { index, choice in
                            Button { Task { await call.choose(choice.id) } } label: {
                                Text("\(index + 1). \(choice.label)")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!call.canAnswer)
                            .accessibilityIdentifier("question.call.choice.\(choice.id)")
                        }
                    }
                    if !call.partial.isEmpty { Text(call.partial).foregroundStyle(.secondary) }
                    Text(status).font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("question.call.status")
                    if let notice = call.notice {
                        Text(notice).font(.footnote).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("question.call.notice")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if call.phase == .retry {
                Button("Retry the same answer") { Task { await call.retry() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("question.call.retry")
            } else if call.canAnswer {
                HStack {
                    Button(call.phase == .listening ? "Send spoken answer" : "Speak answer") {
                        Task {
                            if call.phase == .listening { await call.finishSpeaking() }
                            else { await call.listen() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!call.canSpeak)
                    .accessibilityIdentifier("question.call.speak")
                    Button("Read again") { call.readQuestion() }
                        .disabled(call.listenerBusy)
                        .accessibilityIdentifier("question.call.read")
                }
            }
            HStack(spacing: 30) {
                Button { call.requestMute() } label: {
                    Label(call.isMuted ? "Unmute" : "Mute", systemImage: call.isMuted ? "mic.slash.fill" : "mic.fill")
                }
                Button(role: .destructive) { call.hangUp() } label: {
                    Label("Hang up", systemImage: "phone.down.fill")
                }
                .accessibilityIdentifier("question.call.hangup")
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .accessibilityIdentifier("question.call.screen")
    }

    private var status: String {
        switch call.phase {
        case .loading: return "Reading the question…"
        case .speaking: return "Reading aloud. You can tap a choice at any time."
        case .ready:
            if call.listenerBusy { return "Finishing the previous speech attempt. You can tap a choice." }
            return call.isMuted ? "Microphone muted. You can tap a choice." : "Speak your answer or tap a choice."
        case .listening: return call.listenerBusy ? "Preparing speech…" : "Listening. A pause sends your answer."
        case .recognizing: return "Finishing speech recognition…"
        case .sending: return "Posting your answer…"
        case .retry: return "Answer not confirmed."
        case .answered: return "Your answer is posted under the question."
        case .ended: return "Call ended."
        }
    }
}

@MainActor
final class QuestionCallPreferences: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var loaded = false
    @Published private(set) var working = false
    @Published private(set) var unavailable = false
    @Published private(set) var notice: String?
    private let api: any QuestionCallPreferencesAPI

    // The first read must answer before Settings offers this section. Keep an
    // ordinary read/save error visible so its retry remains available.
    var showsSection: Bool { !unavailable && (loaded || notice != nil) }

    init(api: any QuestionCallPreferencesAPI = RoomQuestionsClient()) { self.api = api }

    func load() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            enabled = try await api.preference()
            loaded = true
            unavailable = false
            notice = nil
        } catch RoomCallsClient.Failure.refused(404) {
            enabled = false
            loaded = false
            unavailable = true
            notice = nil
        } catch {
            loaded = false
            enabled = false
            unavailable = false
            notice = "Call preferences could not be read. Try again."
        }
    }

    func save(_ value: Bool) async {
        guard loaded, !working, enabled != value else { return }
        working = true
        defer { working = false }
        do {
            enabled = try await api.savePreference(value)
            notice = nil
        } catch RoomCallsClient.Failure.refused(404) {
            enabled = false
            loaded = false
            unavailable = true
            notice = nil
        } catch {
            // A lost response can hide a successful write. Read the server before offering another change.
            loaded = false
            notice = "The change is not confirmed. Read your setting again before changing it."
        }
    }
}

@MainActor
struct QuestionCallSettingsHost<Content: View>: View {
    @StateObject private var preferences: QuestionCallPreferences
    private let content: (QuestionCallPreferences) -> Content

    init(preferences: QuestionCallPreferences? = nil,
         @ViewBuilder content: @escaping (QuestionCallPreferences) -> Content) {
        _preferences = StateObject(wrappedValue: preferences ?? QuestionCallPreferences())
        self.content = content
    }

    var body: some View {
        // Observe at the Form's scope so availability changes its section list.
        // The signed-in branch owns this host, preserving the prior model lifetime.
        content(preferences)
            .task { await preferences.load() }
    }
}

@MainActor
struct QuestionCallSettingsSection: View {
    @ObservedObject var preferences: QuestionCallPreferences

    var body: some View {
        Section {
            Toggle("Call me about unanswered questions", isOn: Binding(
                get: { preferences.enabled }, set: { value in Task { await preferences.save(value) } }
            ))
            .disabled(!preferences.loaded || preferences.working)
            .accessibilityIdentifier("settings.questionCalls.enabled")
            if !preferences.loaded, !preferences.working {
                Button("Read call preferences") { Task { await preferences.load() } }
            }
            if preferences.working { ProgressView() }
        } header: {
            Text("Question calls")
        } footer: {
            Text(preferences.notice ?? "Off until you enable it. Your agents can call once after a question waits 30 minutes, at most once every 30 minutes across your rooms. Your quiet hours apply.")
        }
    }
}
