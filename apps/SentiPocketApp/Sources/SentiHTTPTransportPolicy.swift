import Foundation

/// Bounded deadlines for interactive Senti HTTP calls.
///
/// `URLSession.shared` inherits Foundation's multi-day resource timeout, which can leave a phone-facing operation
/// suspended long after the UI can use its result. Production clients use this policy while tests remain free to
/// inject purpose-built sessions and URL protocols.
enum SentiHTTPTransportPolicy {
    static let requestTimeout: TimeInterval = 15
    static let resourceTimeout: TimeInterval = 60
    static let liveSession = URLSession(configuration: makeConfiguration())
    static let checkpointSession = URLSession(configuration: makeCheckpointConfiguration())
    static let roomStreamSession = URLSession(configuration: makeRoomStreamConfiguration())
    static let protectedReadSession = URLSession(configuration: makeProtectedReadConfiguration())

    /// Reads of protected room data (sessions, room events, reactions, tickets): the live deadlines, but no URL
    /// cache, cookies or credential store, so room content never lands in Foundation's disk cache. The bearer is
    /// attached per request.
    static func makeProtectedReadConfiguration() -> URLSessionConfiguration {
        precondition(resourceTimeout >= requestTimeout)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return configuration
    }

    /// The live room stream stays open for a long time, so it gets its own session: the idle deadline sits above
    /// the server's 15-second keep-alive ticks, and the resource deadline lets one connection run for two hours
    /// before the room coordinator reconnects. Like the checkpoint session it keeps no cache, cookies or
    /// credentials; the bearer is attached per request.
    static func makeRoomStreamConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 2 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return configuration
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        precondition(resourceTimeout >= requestTimeout)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }

    /// Exact signed checkpoints are streamed under their own 45-second request deadline inside this 60-second wall.
    /// The session carries no URL cache, cookies, or credential store; authorization always comes from the current
    /// Keychain bearer explicitly attached by `HTTPCheckpointTransport`.
    static func makeCheckpointConfiguration() -> URLSessionConfiguration {
        precondition(resourceTimeout >= requestTimeout)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return configuration
    }
}
