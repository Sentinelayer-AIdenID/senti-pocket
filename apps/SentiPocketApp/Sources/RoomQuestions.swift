import Foundation
import PocketContracts
import PocketSyncClient

/// The authenticated, bounded question from sentinelayer-api SPEC G. Push payloads never carry this content.
struct RoomQuestion: Equatable, Sendable {
    struct Choice: Equatable, Identifiable, Sendable {
        let id: String
        let label: String
    }

    let id: String
    let sessionId: String
    let targetSequenceId: Int64
    let targetActionId: String?
    let text: String
    let choices: [Choice]
    let status: String
    let expiresAt: Date
    let callId: String?
    let answerActionId: String?
    let ringAllowed: Bool

    init?(json: JSONValue) {
        guard let id = json["questionId"]?.stringValue, UUID(uuidString: id) != nil,
              let session = json["sessionId"]?.stringValue, RoomCallDoorbell.isIdentifier(session),
              let sequence = json["targetSequenceId"]?.intValue, sequence > 0,
              let text = json["text"]?.stringValue, text.unicodeScalars.count <= 4_000,
              let status = json["status"]?.stringValue,
              ["pending", "called", "answered", "cancelled", "expired"].contains(status),
              let expiry = json["expiresAt"]?.stringValue.flatMap({ ParsedSessionTimestamp($0).date }),
              let rawChoices = json["choices"]?.arrayValue, rawChoices.isEmpty || (2...6).contains(rawChoices.count)
        else { return nil }
        var choices: [Choice] = []
        for raw in rawChoices {
            guard let key = raw["id"]?.stringValue, (1...32).contains(key.utf8.count),
                  key.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                      || (48...57).contains($0) || [45, 46, 95].contains($0) }),
                  let label = raw["label"]?.stringValue, (1...200).contains(label.unicodeScalars.count),
                  !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  label.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
                  !choices.contains(where: { $0.id == key }) else { return nil }
            choices.append(Choice(id: key, label: label))
        }
        for key in ["targetActionId", "callId", "answerActionId"] {
            if let value = json[key], value != .null {
                guard let value = value.stringValue, UUID(uuidString: value) != nil else { return nil }
            }
        }
        if ["pending", "called"].contains(status), text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        self.id = id
        self.sessionId = session
        self.targetSequenceId = sequence
        self.targetActionId = json["targetActionId"]?.stringValue
        self.text = text
        self.choices = choices
        self.status = status
        self.expiresAt = expiry
        self.callId = json["callId"]?.stringValue
        self.answerActionId = json["answerActionId"]?.stringValue
        self.ringAllowed = json["ringAllowed"]?.boolValue ?? false
    }

    func canAnswer(at now: Date) -> Bool { ["pending", "called"].contains(status) && expiresAt > now }

    /// Both the original source and its choices remain fixed; an edited source cannot silently become another ask.
    func isSameSource(as other: RoomQuestion) -> Bool {
        id == other.id && sessionId == other.sessionId && targetSequenceId == other.targetSequenceId
            && targetActionId == other.targetActionId && callId == other.callId && text == other.text
            && choices == other.choices
    }

    var spoken: String {
        let options = choices.enumerated().map { "Option \($0.offset + 1): \($0.element.label)." }.joined(separator: " ")
        return text + (options.isEmpty ? "\nSay your answer after the question."
                      : "\n" + options + "\nSay your answer after the question, or tap a choice.")
    }

    /// Only an unambiguous numbered option or complete label becomes a choice. Everything else stays your words.
    func answer(from speech: String) -> RoomQuestionAnswer {
        let said = speech.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = said.lowercased().trimmingCharacters(in: .punctuationCharacters)
        let numbers = ["one", "two", "three", "four", "five", "six"]
        let matches = choices.enumerated().filter { index, choice in
            ["\(index + 1)", numbers[index], "option \(index + 1)", "option \(numbers[index])",
             "choice \(index + 1)", "choice \(numbers[index])"].contains(normalized)
                || choice.label.lowercased().trimmingCharacters(in: .punctuationCharacters) == normalized
        }
        return matches.count == 1 ? .choice(matches[0].element.id) : .voice(said)
    }
}

enum RoomQuestionAnswer: Equatable, Sendable {
    case choice(String)
    case voice(String)

    var body: [String: Any] {
        switch self {
        case .choice(let id): return ["choiceId": id]
        case .voice(let text): return ["text": text, "inputKind": "voice"]
        }
    }
}

protocol RoomQuestionsAPI: Sendable {
    func question(sessionId: String, questionId: String) async throws -> RoomQuestion
    func answer(_ answer: RoomQuestionAnswer, question: RoomQuestion) async throws -> RoomQuestion
}

protocol QuestionCallPreferencesAPI: Sendable {
    func preference() async throws -> Bool
    func savePreference(_ enabled: Bool) async throws -> Bool
}

/// Each call/settings presentation is bound to its starting credential. Sign-out/account switching cannot send a
/// retained answer as a new person or display a late protected response. No content is kept in a URL cache.
struct RoomQuestionsClient: RoomQuestionsAPI, QuestionCallPreferencesAPI {
    let apiBaseURL: URL?
    let urlSession: URLSession
    private let tokenProvider: @Sendable () -> String?
    private let accountToken: String?

    init(apiBaseURL: URL? = GatewayEndpoint.resolve(infoPlistKeys: ["SENTI_API_URL"]),
         urlSession: URLSession = SentiHTTPTransportPolicy.protectedReadSession,
         tokenProvider: @escaping @Sendable () -> String? = { SessionTokenStore.load() }) {
        self.apiBaseURL = apiBaseURL
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider
        self.accountToken = tokenProvider()
    }

    func question(sessionId: String, questionId: String) async throws -> RoomQuestion {
        let json = try await send("GET", path: try path(sessionId, questionId), body: nil)
        guard let question = RoomQuestion(json: json), question.id == questionId, question.sessionId == sessionId
        else { throw RoomCallsClient.Failure.unreadable }
        return question
    }

    func answer(_ answer: RoomQuestionAnswer, question: RoomQuestion) async throws -> RoomQuestion {
        switch answer {
        case .choice(let id):
            guard question.choices.contains(where: { $0.id == id }) else { throw RoomCallsClient.Failure.unreadable }
        case .voice(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.unicodeScalars.count <= 2_000
            else { throw RoomCallsClient.Failure.unreadable }
        }
        let json = try await send("POST", path: try path(question.sessionId, question.id) + "/answer", body: answer.body)
        guard json["ok"]?.boolValue == true, let value = json["question"], let result = RoomQuestion(json: value),
              result.isSameSource(as: question), result.status == "answered", result.answerActionId != nil
        else { throw RoomCallsClient.Failure.unreadable }
        return result
    }

    func preference() async throws -> Bool {
        let json = try await send("GET", path: "/api/v1/me/question-call-preferences", body: nil)
        guard let enabled = json["enabled"]?.boolValue else { throw RoomCallsClient.Failure.unreadable }
        return enabled
    }

    func savePreference(_ enabled: Bool) async throws -> Bool {
        let json = try await send("PUT", path: "/api/v1/me/question-call-preferences", body: ["enabled": enabled])
        guard let saved = json["enabled"]?.boolValue, saved == enabled else { throw RoomCallsClient.Failure.unreadable }
        return saved
    }

    private func path(_ sessionId: String, _ questionId: String) throws -> String {
        guard RoomCallDoorbell.isIdentifier(sessionId), UUID(uuidString: questionId) != nil
        else { throw RoomCallsClient.Failure.unreadable }
        return "/api/v1/sessions/\(sessionId)/questions/\(questionId)"
    }

    private func send(_ method: String, path: String, body: [String: Any]?) async throws -> JSONValue {
        guard let accountToken, !accountToken.isEmpty, tokenProvider() == accountToken
        else { throw RoomCallsClient.Failure.signedOut }
        let currentToken = tokenProvider
        let client = RoomCallsClient(apiBaseURL: apiBaseURL, urlSession: urlSession,
                                     tokenProvider: { currentToken() == accountToken ? accountToken : nil })
        let data = try await client.send(method, path: path, body: body)
        guard tokenProvider() == accountToken else { throw RoomCallsClient.Failure.signedOut }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw RoomCallsClient.Failure.unreadable }
        return json
    }
}
