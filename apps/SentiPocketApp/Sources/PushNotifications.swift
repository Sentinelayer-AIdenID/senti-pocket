import Foundation
import PocketSyncClient
import SwiftUI
import UIKit
import UserNotifications

/// This phone with the API, for the bell's Apple push (sentinelayer-api `PUT /api/v1/me/push-devices`, then
/// `DELETE /api/v1/me/push-devices/{id}` and `PUT /api/v1/me/push-devices/{id}/preferences` by the row id the
/// registration returns: a route never carries the device token), with the signed-in person's own bearer.
struct PushDeviceClient: Sendable {
    let apiBaseURL: URL?
    var urlSession: URLSession = SentiHTTPTransportPolicy.liveSession
    var tokenProvider: @Sendable () -> String? = { SessionTokenStore.load() }

    enum Failure: Error, Equatable { case notConfigured, signedOut, refused(Int), unreachable }

    /// `kind` is "voip" for the PushKit token agents' calls ring (sentinelayer-api #1046); an alert token sends none,
    /// so a server without calls still accepts it.
    /// Returns the row's id, which signing out and settings address it by (nil when the answer has none).
    @discardableResult
    func register(token: String, environment: String, bundleId: String, appVersion: String?,
                  kind: String? = nil) async throws -> String? {
        let answer = try await send("PUT", path: "/api/v1/me/push-devices",
                                    body: Self.registration(token: token, environment: environment, bundleId: bundleId,
                                                            appVersion: appVersion, kind: kind))
        return Self.deviceId(in: answer)
    }

    /// The row id in a registration's answer, only as a UUID: it goes into a route.
    static func deviceId(in answer: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: answer) as? [String: Any],
              let id = object["id"] as? String, let uuid = UUID(uuidString: id) else { return nil }
        return uuid.uuidString.lowercased()
    }

    static func registration(token: String, environment: String, bundleId: String, appVersion: String?,
                             kind: String?) -> [String: Any] {
        var body: [String: Any] = ["token": token, "environment": environment, "bundleId": bundleId]
        if let appVersion { body["appVersion"] = appVersion }
        if let kind { body["kind"] = kind }
        return body
    }

    /// Signs one row out. A row the server does not have for this person (gone already, or moved to the account
    /// signed in here since) is signed out too.
    func unregister(deviceId: String) async throws {
        guard let id = UUID(uuidString: deviceId) else { return }
        do {
            try await send("DELETE", path: "/api/v1/me/push-devices/\(id.uuidString.lowercased())", body: nil)
        } catch Failure.refused(404) {
            return
        }
    }

    func setPreferences(deviceId: String, sound: Bool, vibrate: Bool, showPreviews: Bool) async throws {
        guard let id = UUID(uuidString: deviceId) else { throw Failure.notConfigured }
        try await send("PUT", path: "/api/v1/me/push-devices/\(id.uuidString.lowercased())/preferences",
                       body: ["sound": sound, "vibrate": vibrate, "showPreviews": showPreviews])
    }

    @discardableResult
    private func send(_ method: String, path: String, body: [String: Any]?) async throws -> Data {
        guard let apiBaseURL, var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            throw Failure.notConfigured
        }
        guard let bearer = tokenProvider(), !bearer.isEmpty else { throw Failure.signedOut }
        components.percentEncodedPath = path
        components.query = nil
        guard let url = components.url else { throw Failure.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw Failure.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.refused(status) }
        return data
    }
}

/// Rows this phone owes the server a sign-out for, with the account each belongs to, kept on the phone until the
/// server confirms. They are sent with the credential of the sign-out that owed them, again while the app runs. They
/// are never sent with a later credential: an account that signs in here again reclaims its rows by registering, and
/// deleting them then would end its own bells and calls (warden, #298 review). A row a registration returns is
/// current again, for whoever registered it.
struct PushUnregisterQueue: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let deviceId: String
        let account: String
        let since: Date
    }

    var entries: [Entry] = []

    /// After this long an entry goes: the server forgets a phone it has not seen for a while anyway.
    static let keptFor: TimeInterval = 30 * 24 * 3600
    static let key = "pocket.push.pendingUnregisters"

    /// A row whose account cannot be told is not kept: no credential could ever sign it out. A row is owed once per
    /// account: an older account's entry never stands in for a newer one's.
    mutating func add(deviceId: String, account: String?, now: Date = Date()) {
        guard let account, !account.isEmpty, UUID(uuidString: deviceId) != nil,
              !entries.contains(where: { $0.deviceId == deviceId && $0.account == account }) else { return }
        entries.append(Entry(deviceId: deviceId, account: account, since: now))
    }

    /// What `account`'s credential can sign out, oldest first. Entries past `keptFor` are dropped.
    mutating func due(for account: String?, now: Date = Date()) -> [Entry] {
        entries.removeAll { now.timeIntervalSince($0.since) > Self.keptFor }
        guard let account else { return [] }
        return entries.filter { $0.account == account }
    }

    /// Signed out by `account`'s credential.
    mutating func remove(deviceIds: [String], account: String) {
        entries.removeAll { $0.account == account && deviceIds.contains($0.deviceId) }
    }

    /// `account` signed in here again: its registrations reclaim its rows.
    mutating func forgive(account: String) {
        entries.removeAll { $0.account == account }
    }

    /// A registration returned this row: it is current again, whoever owed it.
    mutating func forgive(deviceId: String) {
        entries.removeAll { $0.deviceId == deviceId }
    }

    static func load(from defaults: UserDefaults = .standard) -> PushUnregisterQueue {
        guard let data = defaults.data(forKey: key),
              let queue = try? JSONDecoder().decode(PushUnregisterQueue.self, from: data) else { return PushUnregisterQueue() }
        return queue
    }

    func save(to defaults: UserDefaults = .standard) {
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }

    /// Signs each entry out; returns the ones the server confirmed. With `account`, each entry is checked against the
    /// stored queue right before its request: one reclaimed meanwhile is skipped, never deleted (warden, #298 review).
    static func confirmed(of entries: [Entry], account: String? = nil, from defaults: UserDefaults = .standard,
                          unregister: (String) async throws -> Void) async -> [String] {
        var done: [String] = []
        for entry in entries {
            if let account, !load(from: defaults).entries.contains(where: { $0.deviceId == entry.deviceId && $0.account == account }) {
                continue
            }
            if (try? await unregister(entry.deviceId)) != nil { done.append(entry.deviceId) }
        }
        return done
    }
}

/// What a push carries: the room, and the message (or reply) it is about.
enum PushRoute {
    /// Built as a room link and parsed like one, so a push is held to exactly the rules a tapped link is.
    static func link(from userInfo: [AnyHashable: Any]) -> SentiLink? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard let sessionId = userInfo["sessionId"] as? String,
              let encoded = sessionId.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        var query: [String] = []
        let sequence = (userInfo["sequenceId"] as? NSNumber)?.int64Value
            ?? (userInfo["sequenceId"] as? String).flatMap { Int64($0) }
        if let sequence, sequence > 0 { query.append("message=\(sequence)") }
        if let reply = userInfo["replyId"] as? String, UUID(uuidString: reply) != nil { query.append("reply=\(reply.lowercased())") }
        return SentiLink(string: "/dashboard/sessions/\(encoded)" + (query.isEmpty ? "" : "?" + query.joined(separator: "&")))
    }

    /// The bell notification a push is, when the server says (an opaque id, nothing governed).
    static func notificationId(from userInfo: [AnyHashable: Any]) -> String? {
        guard let id = userInfo["notificationId"] as? String, UUID(uuidString: id) != nil else { return nil }
        return id.lowercased()
    }
}

/// The bell's Apple push on this phone: asks once, registers the phone for the signed-in person, signs it out on
/// sign-out, and keeps its sound, vibrate and preview settings. A tap on a notification opens its room at the message.
/// While the app is open, a notification for the room on screen is not shown as a banner.
@MainActor
final class PushRegistrar: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = PushRegistrar()

    @AppStorage("pocket.push.sound") var sound = true
    @AppStorage("pocket.push.vibrate") var vibrate = true
    @AppStorage("pocket.push.previews") var showPreviews = true
    /// This phone's Apple token for bells. Like everything below, read straight from the phone's settings each time,
    /// never a cached copy (warden, #298 review).
    private var storedToken: String {
        get { UserDefaults.standard.string(forKey: "pocket.push.token") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "pocket.push.token") }
    }
    /// The PushKit token agents' calls ring, registered with the API while someone is signed in.
    private var storedVoipToken: String {
        get { UserDefaults.standard.string(forKey: "pocket.push.voipToken") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "pocket.push.voipToken") }
    }
    /// The rows the server keeps for this phone's bell and call tokens, by the ids its registrations returned. Read
    /// straight from the phone's settings each time, never a cached copy: a call checks `voipAccount` as it rings.
    private var deviceId: String {
        get { UserDefaults.standard.string(forKey: "pocket.push.deviceId") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "pocket.push.deviceId") }
    }
    private var voipDeviceId: String {
        get { UserDefaults.standard.string(forKey: "pocket.push.voipDeviceId") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "pocket.push.voipDeviceId") }
    }
    /// The account the call row was confirmed for: calls ring only for that account (`ringsForSignedInAccount`).
    private var voipAccount: String {
        get { UserDefaults.standard.string(forKey: "pocket.push.voipAccount") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "pocket.push.voipAccount") }
    }
    /// Settings the server has not confirmed yet; sent again when the app comes back.
    private var preferencesPending: Bool {
        get { UserDefaults.standard.bool(forKey: "pocket.push.preferencesPending") }
        set { UserDefaults.standard.set(newValue, forKey: "pocket.push.preferencesPending") }
    }
    private var activeObserver: NSObjectProtocol?

    /// Where a tapped notification goes.
    weak var inbox: IncomingLinkInbox?
    /// The room on screen, if any.
    var currentRoomId: () -> String? = { nil }
    /// A tapped push's notification, to read it (the signed-in app sets it). A push tapped to launch the app arrives
    /// before the app sets it; that one is kept and handed over then (warden, #275).
    var onOpened: ((SentiLink, String?) -> Void)? {
        didSet {
            guard let onOpened else { return }
            let early = openedEarly
            openedEarly = []
            for opened in early { onOpened(opened.link, opened.id) }
        }
    }
    private var openedEarly: [(link: SentiLink, id: String?)] = []
    var client = PushDeviceClient(apiBaseURL: GatewayEndpoint.resolve(infoPlistKeys: ["SENTI_API_URL", "SENTI_GATEWAY_URL"]))
    private var isRegistered = false

    var hasToken: Bool { !storedToken.isEmpty }

    /// Whether a call ringing here is for the person signed in now: this phone's call row was confirmed for their
    /// account. Until it is, the server may still hold the last account's row, so a ring is not theirs (warden, #298).
    var ringsForSignedInAccount: Bool {
        Self.rings(callAccount: voipAccount, signedIn: RoomSendOutbox.account(token: SessionTokenStore.load()))
    }

    nonisolated static func rings(callAccount: String, signedIn: String?) -> Bool {
        guard let signedIn, !callAccount.isEmpty else { return false }
        return callAccount == signedIn
    }

    /// At launch: a phone no one is signed in on keeps no Apple registration for bells, whatever an older build left
    /// behind (a refused credential there never signed it out). The server disables the row once Apple refuses it.
    func launched(signedIn: Bool) {
        guard !signedIn, !storedToken.isEmpty else { return }
        storedToken = ""
        deviceId = ""
        isRegistered = false
        preferencesPending = false
        UIApplication.shared.unregisterForRemoteNotifications()
    }

    /// After sign-in: asks for notifications (the first time), then registers with Apple; the token comes back
    /// through the app delegate.
    func start() async {
        if activeObserver == nil {
            activeObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.cameBack() }
            }
        }
        signedIn(account: RoomSendOutbox.account(token: SessionTokenStore.load()))
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        var allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        if settings.authorizationStatus == .notDetermined {
            allowed = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        }
        // Calls ring whether or not banners are allowed: CallKit shows them.
        if !storedVoipToken.isEmpty { Task { await self.registerVoip(storedVoipToken) } }
        guard allowed else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// PushKit's token for agents' calls: kept, and registered at once when someone is signed in.
    func voipTokenUpdated(_ token: String) {
        guard token != storedVoipToken else { return }
        storedVoipToken = token
        guard SessionTokenStore.load()?.isEmpty == false else { return }
        Task { await self.registerVoip(token) }
    }

    /// PushKit dropped the token: the API stops ringing it. Only that row goes, and only with its own account's
    /// credential (the person signed in now, if it was theirs); otherwise it stays owed like any other.
    func voipTokenInvalidated() {
        guard !storedVoipToken.isEmpty else { return }
        storedVoipToken = ""
        let row = voipDeviceId
        owe([row], account: voipAccount)
        voipDeviceId = ""
        voipAccount = ""
        sendOwedUnregisters(bearer: SessionTokenStore.load(), only: [row])
    }

    private func registerVoip(_ token: String) async {
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        // Again while the app runs if it fails: until it lands, calls do not ring here (`ringsForSignedInAccount`).
        for attempt in 0..<Self.registerAttempts {
            let bearer = SessionTokenStore.load()
            guard let account = RoomSendOutbox.account(token: bearer), storedVoipToken == token else { return }
            var registering = client
            registering.tokenProvider = { bearer }
            do {
                let id = try await registering.register(token: token, environment: environment,
                                                        bundleId: Bundle.main.bundleIdentifier ?? "", appVersion: version,
                                                        kind: "voip")
                guard registered(id, account: account, bearer: bearer,
                                 stillCurrent: storedVoipToken == token) else { return }
                voipDeviceId = id ?? ""
                voipAccount = account
                return
            } catch {
                try? await Task.sleep(nanoseconds: UInt64(2 << attempt) * 1_000_000_000)
            }
        }
    }

    /// A registration landed for `account`. Its row is current again, so nothing owed may delete it. If this phone
    /// has moved on since (signed out, or someone else), the row is owed at once, with the credential that made it.
    /// Returns whether the row is this phone's current one.
    func registered(_ deviceId: String?, account: String, bearer: String?, stillCurrent: Bool) -> Bool {
        if let deviceId {
            var queue = PushUnregisterQueue.load()
            queue.forgive(deviceId: deviceId)
            queue.save()
        }
        guard stillCurrent, RoomSendOutbox.account(token: SessionTokenStore.load()) == account else {
            if let deviceId {
                owe([deviceId], account: account)
                sendOwedUnregisters(bearer: bearer, attempts: Self.unregisterAttempts)
            }
            return false
        }
        return true
    }

    /// Someone signed in here: the rows their earlier sign-out still owed are theirs again, reclaimed by the
    /// registrations that follow (never deleted from under them: warden, #298 review).
    func signedIn(account: String?) {
        guard let account else { return }
        var queue = PushUnregisterQueue.load()
        queue.forgive(account: account)
        queue.save()
    }

    func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        storedToken = token
        Task { await self.register(token) }
    }

    private func register(_ token: String) async {
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        // Again while the app runs if it fails, and when the app comes back (warden, #298 review).
        for attempt in 0..<Self.registerAttempts {
            let bearer = SessionTokenStore.load()
            guard let account = RoomSendOutbox.account(token: bearer), storedToken == token else { return }
            var registering = client
            registering.tokenProvider = { bearer }
            do {
                let id = try await registering.register(token: token, environment: environment,
                                                        bundleId: Bundle.main.bundleIdentifier ?? "", appVersion: version)
                guard registered(id, account: account, bearer: bearer, stillCurrent: storedToken == token) else { return }
                deviceId = id ?? ""
                isRegistered = true
                preferencesPending = true
                sendPendingPreferences()
                return
            } catch {
                isRegistered = false
                try? await Task.sleep(nanoseconds: UInt64(2 << attempt) * 1_000_000_000)
            }
        }
    }

    /// The app came back: settings the server has not confirmed go again, and so does a registration that failed.
    private func cameBack() {
        sendPendingPreferences()
        guard SessionTokenStore.load()?.isEmpty == false else { return }
        if !isRegistered, !storedToken.isEmpty { Task { await self.register(self.storedToken) } }
        if !storedVoipToken.isEmpty, !Self.rings(callAccount: voipAccount, signedIn: RoomSendOutbox.account(token: SessionTokenStore.load())) {
            Task { await self.registerVoip(self.storedVoipToken) }
        }
    }

    /// Settings changed: the server sends this phone's next push with them. Until the server confirms, they stay
    /// pending and go again each time the app comes back, so "previews off" never silently fails to apply (warden).
    func preferencesChanged() {
        guard !storedToken.isEmpty else { return }
        preferencesPending = true
        sendPendingPreferences()
    }

    private func sendPendingPreferences() {
        guard preferencesPending, !deviceId.isEmpty else { return }
        let id = deviceId, sound = sound, vibrate = vibrate, previews = showPreviews
        Task {
            guard (try? await self.client.setPreferences(deviceId: id, sound: sound, vibrate: vibrate, showPreviews: previews)) != nil
            else { return }
            // Only what was sent is confirmed: a later change is still pending.
            if self.deviceId == id, self.sound == sound, self.vibrate == vibrate, self.showPreviews == previews {
                self.preferencesPending = false
            }
        }
    }

    /// Sign-out: this phone stops getting this person's notifications and calls. The sign-in goes right after this,
    /// so each request carries the person's credential from now, and tries again a few times while the app runs: a
    /// dropped connection must not leave this phone registered for them (warden). The credential is held in memory only.
    func signOut(bearer: String? = SessionTokenStore.load()) {
        // Both rows are owed until the server confirms: kept on the phone and sent again while the app runs, with this
        // sign-out's credential only (`PushUnregisterQueue`). A refused credential confirms nothing; the phone's own
        // Apple registrations go regardless. The PushKit token itself is kept (PushKit does not re-send it); only this
        // person's registration goes.
        owe([voipDeviceId, deviceId], account: RoomSendOutbox.account(token: bearer))
        voipDeviceId = ""
        voipAccount = ""
        deviceId = ""
        sendOwedUnregisters(bearer: bearer, attempts: Self.unregisterAttempts)
        guard !storedToken.isEmpty else { return }
        storedToken = ""
        preferencesPending = false
        isRegistered = false
        UIApplication.shared.unregisterForRemoteNotifications()
        setBadge(0)
    }

    private func owe(_ deviceIds: [String], account: String?) {
        var queue = PushUnregisterQueue.load()
        for id in deviceIds { queue.add(deviceId: id, account: account) }
        queue.save()
    }

    /// Sends the sign-outs `bearer`'s account owes (or just the rows in `only`), again while the app runs if they
    /// fail; the ones the server confirms are dropped. The credential is held in memory only.
    private func sendOwedUnregisters(bearer: String?, attempts: Int = 1, only: [String]? = nil) {
        guard let bearer, !bearer.isEmpty, let account = RoomSendOutbox.account(token: bearer) else { return }
        var queue = PushUnregisterQueue.load()
        var owed = queue.due(for: account).filter { only?.contains($0.deviceId) ?? true }
        queue.save()
        guard !owed.isEmpty else { return }
        var unregistering = client
        unregistering.tokenProvider = { bearer }
        Task {
            for attempt in 0..<attempts {
                // Only what is still owed: a row its account reclaimed (or a registration returned) since the last
                // try is never deleted from under it (warden, #298 review).
                let stillOwed = PushUnregisterQueue.load().entries
                owed.removeAll { !stillOwed.contains($0) }
                guard !owed.isEmpty else { return }
                let done = await PushUnregisterQueue.confirmed(of: owed, account: account) {
                    try await unregistering.unregister(deviceId: $0)
                }
                var stored = PushUnregisterQueue.load()
                stored.remove(deviceIds: done, account: account)
                stored.save()
                owed.removeAll { done.contains($0.deviceId) }
                guard !owed.isEmpty, attempt < attempts - 1 else { return }
                try? await Task.sleep(nanoseconds: UInt64(2 << attempt) * 1_000_000_000)
            }
        }
    }

    /// Tries over about a minute (2, 4, 8, 16 and 32 seconds apart).
    static let unregisterAttempts = 5
    static let registerAttempts = 5

    /// The app icon's badge: the bell's unread count.
    func setBadge(_ count: Int) {
        if #available(iOS 17.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(max(0, count))
        } else {
            UIApplication.shared.applicationIconBadgeNumber = max(0, count)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let content = notification.request.content
        let sessionId = content.userInfo["sessionId"] as? String
        let link = PushRoute.link(from: content.userInfo)
        let notificationId = PushRoute.notificationId(from: content.userInfo)
        let title = content.title
        let body = content.body
        Task { @MainActor in
            // During a call nothing slides in: a tap would take the room, and the call with it (warden, #267). It
            // still lands in the bell and Notification Center.
            let presentation = VoiceCallWindow.shared.isShowing ? ForegroundPush.quiet
                : ForegroundPush.presentation(sessionId: sessionId, roomOnScreen: self.currentRoomId(),
                                              bannerHosted: InAppBanner.shared.isHosted)
            guard presentation == .inApp else { return completionHandler(presentation.options) }
            InAppBanner.shared.show(title: title, body: body, link: link, notificationId: notificationId)
            completionHandler(presentation.options)
            // It sounds and taps as the notification settings say, Pocket's and the phone's (warden, #255).
            let systemSounds = await UNUserNotificationCenter.current().notificationSettings().soundSetting == .enabled
            let feedback = ForegroundPush.feedback(soundSetting: self.sound, vibrateSetting: self.vibrate,
                                                   systemSounds: systemSounds)
            RoomFeedback.shared.play(.received, sound: feedback.sound, haptic: feedback.haptic)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            LaunchUrgency.shared.raise()
            if let link = PushRoute.link(from: userInfo) {
                let id = PushRoute.notificationId(from: userInfo)
                if let onOpened = self.onOpened {
                    onOpened(link, id)
                } else {
                    self.openedEarly = Array((self.openedEarly + [(link, id)]).suffix(5))
                }
                self.inbox?.receive(link)
            }
            completionHandler()
        }
    }
}

/// Hands Apple's push token to the registrar, and makes the registrar the notification center's delegate before
/// the first notification can arrive.
final class PocketAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = PushRegistrar.shared
        // First, so the last run's end and iOS's crash records are read before anything else can fail.
        CrashReporter.shared.start()
        // Before any room opens: the outbox keeps only what can still be sent, never an original left mid-way.
        RoomMediaOutbox.sweep()
        PushRegistrar.shared.launched(signedIn: SessionTokenStore.load()?.isEmpty == false)
        return true
    }

    /// A quit is not a crash: written before the app ends.
    func applicationWillTerminate(_ application: UIApplication) {
        CrashReporter.shared.activeChanged(false)
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushRegistrar.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    /// A room's photo, video or file finished uploading while the app was in the background: its session takes the
    /// events, then tells iOS it is done.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == RoomMediaPutSession.backgroundIdentifier else { return completionHandler() }
        RoomMediaPutSession.shared.handleBackgroundEvents(completion: completionHandler)
    }
}
