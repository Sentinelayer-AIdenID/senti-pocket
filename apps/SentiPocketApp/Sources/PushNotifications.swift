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

    func register(token: String, environment: String, bundleId: String, appVersion: String?) async throws {
        var body: [String: Any] = ["token": token, "environment": environment, "bundleId": bundleId]
        if let appVersion { body["appVersion"] = appVersion }
        try await send("PUT", path: "/api/v1/me/push-devices", body: body)
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
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        var allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        if settings.authorizationStatus == .notDetermined {
            allowed = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        }
        guard allowed else { return }
        UIApplication.shared.registerForRemoteNotifications()
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
            try? await client.setPreferences(token: token, sound: sound, vibrate: vibrate, showPreviews: showPreviews)
        } catch {
            // The API may not offer push yet; the next launch tries again.
            isRegistered = false
        }
    }

    /// Settings changed: the server sends this phone's next push with them.
    func preferencesChanged() {
        guard !storedToken.isEmpty else { return }
        let token = storedToken, sound = sound, vibrate = vibrate, previews = showPreviews
        Task { try? await self.client.setPreferences(token: token, sound: sound, vibrate: vibrate, showPreviews: previews) }
    }

    /// Sign-out: this phone stops getting this person's notifications.
    func signOut() {
        guard !storedToken.isEmpty else { return }
        let token = storedToken
        storedToken = ""
        isRegistered = false
        UIApplication.shared.unregisterForRemoteNotifications()
        Task { try? await self.client.unregister(token: token) }
        setBadge(0)
    }

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
        let sessionId = notification.request.content.userInfo["sessionId"] as? String
        Task { @MainActor in
            let onScreen = sessionId != nil && sessionId == self.currentRoomId()
            completionHandler(onScreen ? [.list] : [.banner, .list, .sound, .badge])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
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
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushRegistrar.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}
}
