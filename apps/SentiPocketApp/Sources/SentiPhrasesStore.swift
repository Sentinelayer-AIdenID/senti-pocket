import Foundation
import PocketUI

/// Senti's thinking phrases and the lines a new room opens with (`SentiPhrases`, Carter #61720): the copy the app ships,
/// or a newer one the web publishes at the same address, read at most once a day while the app is in use.
///
/// The read is this file's only network call: a plain GET of a public file, with no token or cookie, on its own
/// ephemeral session, off the main thread. A copy is kept only if `SentiPhrases.checked` takes it (it parses, its
/// version is at least the app's own, and every line is 1 to 80 characters with no control characters); it is kept in
/// Application Support and used from the next launch on. Anything else leaves the copy in use as it is.
@MainActor
final class SentiPhrasesStore: ObservableObject {
    static let shared = SentiPhrasesStore()

    static let publishedURL = URL(string: "https://sentinelayer.com/senti-thinking-phrases.json")!
    static let fileName = "senti-thinking-phrases"
    static let refreshInterval: TimeInterval = 24 * 60 * 60
    /// The published file is a few kilobytes; anything far larger is not it.
    static let largestFile = 64 * 1024
    static let lastTryKey = "pocket.sentiPhrases.lastTry"

    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    @Published private(set) var current: SentiPhrases
    /// The app's own copy: the oldest version a newer copy may be.
    let bundled: SentiPhrases
    private let cacheURL: URL?
    private let defaults: UserDefaults
    private let fetch: Fetch
    private let now: () -> Date
    private var refreshing: Task<Void, Never>?

    init(bundle: Bundle = .main, cacheURL: URL? = SentiPhrasesStore.defaultCacheURL, defaults: UserDefaults = .standard,
         fetch: @escaping Fetch = SentiPhrasesStore.fetchPublished, now: @escaping () -> Date = Date.init) {
        let bundled = bundle.url(forResource: Self.fileName, withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { SentiPhrases.checked($0, minimumVersion: 0) } ?? .fallback
        self.bundled = bundled
        self.cacheURL = cacheURL
        self.defaults = defaults
        self.fetch = fetch
        self.now = now
        let cached = cacheURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { SentiPhrases.checked($0, minimumVersion: bundled.version) }
        current = cached ?? bundled
    }

    /// Reads the published copy when a day has passed since the last try, whatever came of it. The caller asks only as
    /// the app becomes active, so nothing is read in the background.
    func refreshIfDue() {
        guard refreshing == nil else { return }
        let at = now()
        if let last = defaults.object(forKey: Self.lastTryKey) as? Date, at >= last,
           at.timeIntervalSince(last) < Self.refreshInterval { return }
        defaults.set(at, forKey: Self.lastTryKey)
        let fetch = self.fetch
        let minimum = bundled.version
        let cacheURL = self.cacheURL
        refreshing = Task.detached(priority: .utility) { [weak self] in
            let fresh = await Self.download(fetch: fetch, minimumVersion: minimum, cacheURL: cacheURL)
            await self?.finish(fresh)
        }
    }

    /// Waits for a read in flight (for tests).
    func settle() async {
        await refreshing?.value
    }

    private func finish(_ fresh: SentiPhrases?) {
        refreshing = nil
        if let fresh, fresh != current { current = fresh }
    }

    nonisolated static func download(fetch: Fetch, minimumVersion: Int, cacheURL: URL?) async -> SentiPhrases? {
        var request = URLRequest(url: publishedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        // A public file: no Authorization header, ever, and no cookies (the session keeps none).
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await fetch(request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= largestFile,
              let phrases = SentiPhrases.checked(data, minimumVersion: minimumVersion) else { return nil }
        if let cacheURL {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }
        return phrases
    }

    nonisolated static var defaultCacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(fileName + ".json")
    }

    /// Its own session: nothing cached, no cookies, no credentials kept.
    nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    nonisolated static let fetchPublished: Fetch = { request in try await session.data(for: request) }
}
