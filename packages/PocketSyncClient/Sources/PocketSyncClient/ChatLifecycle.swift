import Foundation
import PocketContracts
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ChatLifecycleError: Error, Equatable, Sendable {
    case unavailable
    case reauthenticationRequired
    case notAllowed
    case gone
    case invalidResponse
    case network
    case accountChanged
}

public protocol ChatLifecycleServing: Sendable {
    func archiveChat(_ roomId: String, accountId: String) async throws
    func endChat(_ roomId: String, accountId: String) async throws
    func leaveChat(_ roomId: String, accountId: String) async throws
}

/// An account resolved using this exact bearer. Tokens may rotate without changing the account.
public struct ChatLifecycleCredential: Sendable {
    public let accountId: String
    public let token: String

    public init(accountId: String, token: String) {
        self.accountId = accountId
        self.token = token
    }
}

/// The website's existing End chat call. Confirmations belong to an account, while each request resolves that
/// account's current credential. Leave is hidden and refused unless explicitly enabled.
public final class HTTPChatLifecycleClient: ChatLifecycleServing, @unchecked Sendable {
    private let apiBaseURL: URL?
    private let urlSession: URLSession
    private let credentialProvider: @Sendable () async throws -> ChatLifecycleCredential
    private let leaveEnabled: Bool

    public init(apiBaseURL: URL?, urlSession: URLSession,
                credentialProvider: @escaping @Sendable () async throws -> ChatLifecycleCredential,
                leaveEnabled: Bool = false) {
        self.apiBaseURL = apiBaseURL
        self.urlSession = urlSession
        self.credentialProvider = credentialProvider
        self.leaveEnabled = leaveEnabled
    }

    public func endChat(_ roomId: String, accountId: String) async throws {
        let answer = try await send(roomId, accountId: accountId, operation: "kill", body: ["reason": "human_dashboard_kill"])
        guard answer.json?["ok"]?.boolValue == true,
              answer.json?["sessionId"]?.stringValue == roomId,
              answer.json?["status"]?.stringValue == "killed" else {
            throw ChatLifecycleError.invalidResponse
        }
    }

    public func archiveChat(_ roomId: String, accountId: String) async throws {
        let answer = try await send(roomId, accountId: accountId, operation: "archive", body: [:])
        guard answer.json?["ok"]?.boolValue == true,
              answer.json?["archiveStatus"]?.stringValue == "archived" else {
            throw ChatLifecycleError.invalidResponse
        }
    }

    public func leaveChat(_ roomId: String, accountId: String) async throws {
        guard leaveEnabled else { throw ChatLifecycleError.unavailable }
        _ = try await send(roomId, accountId: accountId, operation: "leave")
    }

    private func send(_ roomId: String, accountId: String, operation: String,
                      body: [String: Any]? = nil) async throws -> PersonalRequest.Answer {
        guard PersonalRequest.isIdentifier(roomId) else { throw ChatLifecycleError.notAllowed }
        guard !accountId.isEmpty else { throw ChatLifecycleError.reauthenticationRequired }
        let credential = try await credentialProvider()
        guard credential.accountId == accountId else { throw ChatLifecycleError.accountChanged }
        // This bearer was resolved for the checked account. Do not load a different token between that check and
        // Authorization, or treat an ordinary refresh as a different person while the request is in flight.
        let request = PersonalRequest(apiBaseURL: apiBaseURL, urlSession: urlSession, tokenProvider: { credential.token })
        let answer: PersonalRequest.Answer
        do {
            answer = try await request.send("POST", ["api", "v1", "sessions", roomId, operation], body: body)
        } catch PersonalRequest.Failure.accountChanged {
            throw ChatLifecycleError.accountChanged
        } catch PersonalRequest.Failure.notLoggedIn {
            throw ChatLifecycleError.reauthenticationRequired
        } catch {
            throw ChatLifecycleError.network
        }
        guard try await credentialProvider().accountId == accountId else { throw ChatLifecycleError.accountChanged }
        switch answer.status {
        case 200..<300: return answer
        case 401: throw ChatLifecycleError.reauthenticationRequired
        case 403: throw ChatLifecycleError.notAllowed
        case 404: throw ChatLifecycleError.gone
        default: throw ChatLifecycleError.network
        }
    }
}
