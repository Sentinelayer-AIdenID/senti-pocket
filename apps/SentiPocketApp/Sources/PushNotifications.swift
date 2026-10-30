import Foundation
import PocketSyncClient
import SwiftUI
import UIKit
import UserNotifications

/// This phone with the API, for the bell's Apple push (sentinelayer-api `PUT/DELETE /api/v1/me/push-devices`,
/// `PUT /api/v1/me/push-devices/{token}/preferences`), with the signed-in person's own bearer.
struct PushDeviceClient: Sendable {
    let apiBaseURL: URL?
    var urlSession: URLSession = SentiHTTPTransportPolicy.liveSession
    var tokenProvider: @Sendable () -> String? = { SessionTokenStore.load() }

    enum Failure: Error, Equatable { case notConfigured, signedOut, refused(Int), unreachable }

    /// `kind` is "voip" for the PushKit token agents' calls ring (sentinelayer-api #1046); an alert token sends none,
    /// so a server without calls still accepts it.
    func register(token: String, environment: String, bundleId: String, appVersion: String?, kind: String? = nil) async throws {
        try await send("PUT", path: "/api/v1/me/push-devices",
                       body: Self.registration(token: token, environment: environment, bundleId: bundleId,
                                               appVersion: appVersion, kind: kind))
    }

    static func registration(token: String, environment: String, bundleId: String, appVersion: String?,
                             kind: String?) -> [String: Any] {
        var body: [String: Any] = ["token": token, "environment": environment, "bundleId": bundleId]
        if let appVersion { body["appVersion"] = appVersion }
        if let kind { body["kind"] = kind }
        return body
    }

    func unregister(token: String) async throws {
        try await send("DELETE", path: "/api/v1/me/push-devices/\(token)", body: nil)
    }

    func setPreferences(token: String, sound: Bool, vibrate: Bool, showPreviews: Bool) async throws {
        try await send("PUT", path: "/api/v1/me/push-devices/\(token)/preferences",
                       body: ["sound": sound, "vibrate": vibrate, "showPreviews": showPreviews])
    }

    private func send(_ method: String, path: String, body: [String: Any]?) async throws {
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
        let response: URLResponse
        do {
            (_, response) = try await urlSession.data(for: request)
        } catch {
            throw Failure.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.refused(status) }
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
    @AppStorage("pocket.push.token") private var storedToken = ""
    /// The PushKit token agents' calls ring, registered with the API while someone is signed in.
    @AppStorage("pocket.push.voipToken") private var storedVoipToken = ""
    /// Settings the server has not confirmed yet; sent again when the app comes back.
    @AppStorage("pocket.push.preferencesPending") private var preferencesPending = false
    private var activeObserver: NSObjectProtocol?

    /// Where a tapped notification goes.
    weak var inbox: IncomingLinkInbox?
    /// The room on screen, if any.
    var currentRoomId: () -> String? = { nil }
    private var client = PushDeviceClient(apiBaseURL: GatewayEndpoint.resolve(infoPlistKeys: ["SENTI_API_URL", "SENTI_GATEWAY_URL"]))
    private var isRegistered = false

    var hasToken: Bool { !storedToken.isEmpty }

    /// After sign-in: asks for notifications (the first time), then registers with Apple; the token comes back
    /// through the app delegate.
    func start() async {
        if activeObserver == nil {
            activeObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.sendPendingPreferences() }
            }
        }
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

    /// PushKit dropped the token: the API stops ringing it.
    func voipTokenInvalidated() {
        guard !storedVoipToken.isEmpty else { return }
        let token = storedVoipToken
        storedVoipToken = ""
        Task { try? await self.client.unregister(token: token) }
    }

    private func registerVoip(_ token: String) async {
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        // A server without calls refuses the kind; the next sign-in or token tries again.
        try? await client.register(token: token, environment: environment,
                                   bundleId: Bundle.main.bundleIdentifier ?? "", appVersion: version, kind: "voip")
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
        do {
            try await client.register(token: token, environment: environment,
                                      bundleId: Bundle.main.bundleIdentifier ?? "", appVersion: version)
            isRegistered = true
            preferencesPending = true
            sendPendingPreferences()
        } catch {
            // The API may not offer push yet; the next launch tries again.
            isRegistered = false
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
        guard preferencesPending, !storedToken.isEmpty else { return }
        let token = storedToken, sound = sound, vibrate = vibrate, previews = showPreviews
        Task {
            guard (try? await self.client.setPreferences(token: token, sound: sound, vibrate: vibrate, showPreviews: previews)) != nil
            else { return }
            // Only what was sent is confirmed: a later change is still pending.
            if self.storedToken == token, self.sound == sound, self.vibrate == vibrate, self.showPreviews == previews {
                self.preferencesPending = false
            }
        }
    }

    /// Sign-out: this phone stops getting this person's notifications and calls. The sign-in goes right after this,
    /// so each request carries the person's credential from now, and tries again a few times while the app runs: a
    /// dropped connection must not leave this phone registered for them (warden). The credential is held in memory only.
    func signOut() {
        let bearer = SessionTokenStore.load()
        var unregistering = client
        unregistering.tokenProvider = { bearer }
        if !storedVoipToken.isEmpty {
            // The PushKit token itself is kept (PushKit does not re-send it); only this person's registration goes.
            unregister(storedVoipToken, with: unregistering)
        }
        guard !storedToken.isEmpty else { return }
        let token = storedToken
        storedToken = ""
        preferencesPending = false
        isRegistered = false
        UIApplication.shared.unregisterForRemoteNotifications()
        unregister(token, with: unregistering)
        setBadge(0)
    }

    /// Asks the server to forget one of this phone's tokens, again while the app runs if the request fails.
    private func unregister(_ token: String, with client: PushDeviceClient) {
        Task {
            for attempt in 0..<Self.unregisterAttempts {
                if (try? await client.unregister(token: token)) != nil { return }
                try? await Task.sleep(nanoseconds: UInt64(2 << attempt) * 1_000_000_000)
            }
        }
    }

    /// Tries over about a minute (2, 4, 8, 16 and 32 seconds apart).
    static let unregisterAttempts = 5

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
        let title = content.title
        let body = content.body
        Task { @MainActor in
            // During a call nothing slides in: a tap would take the room, and the call with it (warden, #267). It
            // still lands in the bell and Notification Center.
            let presentation = VoiceCallWindow.shared.isShowing ? ForegroundPush.quiet
                : ForegroundPush.presentation(sessionId: sessionId, roomOnScreen: self.currentRoomId(),
                                              bannerHosted: InAppBanner.shared.isHosted)
            guard presentation == .inApp else { return completionHandler(presentation.options) }
            InAppBanner.shared.show(title: title, body: body, link: link)
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
            if let link = PushRoute.link(from: userInfo) { self.inbox?.receive(link) }
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
}
