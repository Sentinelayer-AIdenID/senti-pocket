import Combine
import Foundation
import SwiftUI

// Crash reports the person chooses to send go to the team through the API (`POST /api/v1/crash-reports`), which posts
// them in the team's feedback room. The phone never posts a report in any room. (Carter, 11-06: a report offered "in
// the next room you open" went into a room with other people in it. Ticket 70d6ccdd.)

/// One report as the API takes it: these fields and no others (the API refuses unknown keys), each inside the API's
/// bounds, counted in code points as the API counts them.
struct CrashReportPayload: Encodable, Equatable {
    static let fieldLength = 32
    static let headlineLength = 200
    static let frameCount = 64
    static let frameLength = 160
    static let stepCount = 20
    static let stepLength = 120
    static let binaryCount = 16
    static let binaryNameLength = 64

    /// A binary the frames are in, by name and build UUID, so the team can symbolicate them.
    struct Binary: Encodable, Equatable {
        let name: String
        let uuid: String
    }

    let kind: String
    let build: String
    let os: String
    let device: String
    let occurredAt: String
    let headline: String
    let frames: [String]
    let lastSteps: [String]
    /// Left out when the report names none the API would take.
    let binaries: [Binary]?

    init(_ report: CrashReport) {
        // The API knows crashes and hangs. A run that ended on screen with no crash of its own (most often the main
        // thread stuck, then the system ended it) is sent as a hang, and its headline says what happened.
        switch report.kind {
        case .crash: kind = "crash"
        case .hang, .closed: kind = "hang"
        }
        build = Self.label(report.build)
        os = Self.label(report.system)
        device = Self.label(report.device)
        occurredAt = Self.stamp(report.at)
        let reason = report.kind == .closed ? "Closed while open: " + report.reason : report.reason
        let line = Self.cut(CrashStepScrub.identifiers(in: Self.oneLine(reason)), to: Self.headlineLength)
        // The API takes no empty headline.
        headline = line.trimmingCharacters(in: .whitespaces).isEmpty ? "Pocket closed unexpectedly" : line
        frames = report.frames.prefix(Self.frameCount).map { Self.cut($0, to: Self.frameLength) }
        // The newest steps, each by its kind and counts only.
        lastSteps = report.trail.suffix(Self.stepCount).map { Self.cut(CrashStepScrub.step($0), to: Self.stepLength) }
        let named = Self.binaries(report.binaries)
        binaries = named.isEmpty ? nil : named
    }

    /// The report's "name UUID" pairs the API takes: a name of at most 64 of [A-Za-z0-9._+-] and a strict UUID, the
    /// first 16, once each. Any other pair is left out.
    static func binaries(_ listed: [String]) -> [Binary] {
        var kept: [Binary] = []
        for pair in listed {
            guard let space = pair.lastIndex(of: " ") else { continue }
            let binary = Binary(name: String(pair[..<space]), uuid: String(pair[pair.index(after: space)...]))
            guard binary.name.range(of: #"^[A-Za-z0-9._+-]{1,64}$"#, options: .regularExpression) != nil,
                  binary.uuid.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
                                    options: .regularExpression) != nil,
                  !kept.contains(binary) else { continue }
            kept.append(binary)
            if kept.count == binaryCount { break }
        }
        return kept
    }

    /// build, os and device as the API takes them (#1191): letters, digits, spaces and . _ ( ) + , - only, 1 to 32 of
    /// them. Anything else becomes a hyphen; nothing at all is "unknown".
    static func label(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._()+,-")
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: text.unicodeScalars.map { allowed.contains($0) ? $0 : "-" })
        let cut = Self.cut(String(kept).trimmingCharacters(in: .whitespaces), to: fieldLength)
        return cut.trimmingCharacters(in: .whitespaces).isEmpty ? "unknown" : cut
    }

    /// At most `length` code points (Python's `len`, as the API counts), never splitting one.
    static func cut(_ text: String, to length: Int) -> String {
        guard text.unicodeScalars.count > length else { return text }
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: text.unicodeScalars.prefix(length))
        return String(kept)
    }

    /// ISO 8601 with its offset (`+00:00`), as the API reads it.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxxxx"
        return formatter.string(from: date)
    }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// What a report may say on its way to the team: never a room's id or title, a message's number or text, or a
/// person's name or address. The steps keep their kind and counts only ("closeThread (101 rows)"). The server
/// scrubs again. (Review, #352.)
enum CrashStepScrub {
    private static let identifierRules: [(pattern: String, placeholder: String)] = [
        (#"https?://\S+"#, "<link>"),
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
        (#"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, "<room>"),
        (#"#[0-9]+"#, "<msg>")
    ]

    /// Links, email addresses, room ids and message numbers, replaced. Used for the headline too.
    static func identifiers(in text: String) -> String {
        identifierRules.reduce(text) { text, rule in
            text.replacingOccurrences(of: rule.pattern, with: rule.placeholder, options: .regularExpression)
        }
    }

    /// A step: identifiers replaced, quoted text replaced, and every word a step's kind never has (one that starts
    /// with a capital, or holds a letter outside ASCII: a title or a name) replaced.
    static func step(_ line: String) -> String {
        let plain = identifiers(in: line)
            .replacingOccurrences(of: #""[^"]*"|“[^”]*”|'[^']*'"#, with: "<text>", options: .regularExpression)
        let words = plain.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let token = String(word)
            let core = token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard let first = core.unicodeScalars.first else { return token }
            let named = CharacterSet.uppercaseLetters.contains(first) || core.unicodeScalars.contains { !$0.isASCII }
            return named ? token.replacingOccurrences(of: core, with: "<name>") : token
        }
        return words.joined(separator: " ")
            .replacingOccurrences(of: #"<name>(\s+<name>)+"#, with: "<name>", options: .regularExpression)
    }
}

/// The API's answer to one report.
enum CrashReportSendResult: Equatable {
    /// 202: the team has it.
    case accepted
    /// 422: the API will never take it. Dropped after a note, so it is not offered again and again.
    case refused
    /// 429: too many lately. Kept for the next launch.
    case rateLimited(retryAfter: Int?)
    /// 503 or 404: reports are not taken yet. Kept for the next launch.
    case unavailable
    /// 401 or 403: this credential cannot send reports. Kept.
    case notSignedIn
    /// No answer, or another one. Kept.
    case failed
}

/// Sending one report to the team.
protocol CrashReportSending: Sendable {
    /// The credential stored now; nil when nobody is signed in.
    func currentToken() -> String?
    /// `POST /api/v1/crash-reports` with exactly `token`, whatever is stored by the time it goes out.
    func send(_ payload: CrashReportPayload, token: String) async -> CrashReportSendResult
}

struct HTTPCrashReports: CrashReportSending, @unchecked Sendable {
    let apiBaseURL: URL?
    var urlSession: URLSession = SentiHTTPTransportPolicy.liveSession
    var tokenProvider: @Sendable () -> String? = { SessionTokenStore.load() }

    func currentToken() -> String? {
        tokenProvider()
    }

    func send(_ payload: CrashReportPayload, token: String) async -> CrashReportSendResult {
        guard let apiBaseURL, var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false),
              let body = try? JSONEncoder().encode(payload) else { return .failed }
        components.percentEncodedPath = "/api/v1/crash-reports"
        components.query = nil
        guard let url = components.url else { return .failed }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let response: URLResponse
        do {
            (_, response) = try await urlSession.data(for: request)
        } catch {
            return .failed
        }
        guard let http = response as? HTTPURLResponse else { return .failed }
        switch http.statusCode {
        case 200..<300: return .accepted
        case 422: return .refused
        case 429: return .rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) })
        case 404, 503: return .unavailable
        case 401, 403: return .notSignedIn
        default: return .failed
        }
    }
}

/// Sends the crash reports a person chose to share to the team, and says which the phone is done with.
@MainActor
final class CrashReportDelivery {
    /// The API takes nothing older.
    static let maximumAge: TimeInterval = 14 * 24 * 60 * 60

    private let api: any CrashReportSending
    private let now: () -> Date
    private let note: @MainActor (String) -> Void

    init(api: any CrashReportSending, now: @escaping () -> Date = { Date() },
         note: @escaping @MainActor (String) -> Void = { CrashReporter.shared.note($0) }) {
        self.api = api
        self.now = now
        self.note = note
    }

    /// Sends the reports, newest first, one request each. Returns the ones the phone is done with: taken by the API,
    /// refused by it for good, or too old for it. The rest stay on the phone and are offered again at the next launch;
    /// a report never goes to any room from here.
    func deliver(_ reports: [CrashReport]) async -> [CrashReport] {
        // The credential and its account when the person chose to send: every request carries this credential, and
        // the send stops once another one is stored, or none (a sign-out, another account) (review, #352).
        guard let token = api.currentToken(), let account = RoomSendOutbox.account(token: token) else { return [] }
        var done: [CrashReport] = []
        for report in reports.sorted(by: { $0.at > $1.at }) {
            guard let stored = api.currentToken(), stored == token, RoomSendOutbox.account(token: stored) == account else {
                break
            }
            guard now().timeIntervalSince(report.at) <= Self.maximumAge else {
                done.append(report)
                continue
            }
            switch await api.send(CrashReportPayload(report), token: token) {
            case .accepted:
                done.append(report)
            case .refused:
                note("crash report refused by the API")
                done.append(report)
            case .rateLimited, .unavailable, .notSignedIn, .failed:
                return done
            }
        }
        return done
    }
}

/// When the crash report offer is up: once a launch, a moment after the app opens (so iOS can hand over its own crash
/// records first and both go together), while the app is in front and no call is on, and only with reports to offer. A
/// call that starts while the offer is up takes it down, unanswered; it comes back once the call ends. (Carter, 11-06:
/// never an alert over a live call.)
@MainActor
final class CrashOfferTiming: ObservableObject {
    /// The alert is up.
    @Published var presented = false
    private let available: Bool
    private var settled = false
    private var inFront = false
    private var callOn = false
    private var pending = 0
    private var answered = false
    private var watching: [AnyCancellable] = []

    /// `available`: reports can be sent from here. `calls`: whether a call is on (`CallPresence`). `reports`: how many
    /// reports wait to be offered.
    init(available: Bool, calls: AnyPublisher<Bool, Never>, reports: AnyPublisher<Int, Never>) {
        self.available = available
        watching.append(calls.sink { [weak self] on in self?.call(on: on) })
        watching.append(reports.sink { [weak self] count in
            self?.pending = count
            self?.update()
        })
    }

    /// A moment has passed since the app opened.
    func settle() {
        settled = true
        update()
    }

    func inFront(_ active: Bool) {
        inFront = active
        update()
    }

    /// The person answered ("Send to the team" or "Not now"): it is not offered again this launch.
    func answer() {
        answered = true
        presented = false
    }

    private func call(on: Bool) {
        callOn = on
        // Taken down for the call, not answered: it comes back once the call ends.
        if on, presented { presented = false }
        update()
    }

    private func update() {
        guard available, settled, !answered, !presented, inFront, !callOn, pending > 0 else { return }
        presented = true
    }
}

/// The one offer to send crash reports, for the whole app (`CrashOfferTiming` says when): "Send to the team" sends them
/// to the team through the API (`CrashReportDelivery`); "Not now" keeps them on the phone, where Settings shares them.
/// Behind the root and watching nothing the root draws, so a new report or a call draws this alone.
struct CrashReportOffer: View {
    let api: (any CrashReportSending)?
    @StateObject private var timing: CrashOfferTiming
    @Environment(\.scenePhase) private var scenePhase

    static let message = "Send what the phone recorded to the team so it can be fixed? It has where the app stopped and "
        + "your last few steps, never your messages, rooms or names."

    init(api: (any CrashReportSending)?) {
        self.api = api
        _timing = StateObject(wrappedValue: CrashOfferTiming(
            available: api != nil,
            calls: CallPresence.shared.$isOn.eraseToAnyPublisher(),
            reports: CrashReporter.shared.$unhandled.map(\.count).eraseToAnyPublisher()
        ))
    }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .alert("Pocket closed unexpectedly", isPresented: $timing.presented) {
                Button("Send to the team") {
                    timing.answer()
                    send(CrashReporter.shared.unhandled)
                }
                Button("Not now", role: .cancel) {
                    timing.answer()
                    CrashReporter.shared.markHandled(CrashReporter.shared.unhandled)
                }
            } message: {
                Text(Self.message)
            }
            .task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                timing.settle()
            }
            .onAppear { timing.inFront(scenePhase == .active) }
            .onChange(of: scenePhase) { phase in timing.inFront(phase == .active) }
    }

    private func send(_ reports: [CrashReport]) {
        guard let api, !reports.isEmpty else { return }
        CrashReporter.shared.note("crash report sent to the team")
        let delivery = CrashReportDelivery(api: api)
        Task { @MainActor in
            let done = await delivery.deliver(reports)
            // Done with only once the API took them (or refused them for good): the rest are offered again next launch.
            if !done.isEmpty { CrashReporter.shared.markHandled(done) }
        }
    }
}
