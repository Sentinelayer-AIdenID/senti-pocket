import AVFoundation
import Foundation

struct DuplexAudioSessionLease: Hashable, Sendable {
    fileprivate let id: UUID
}

/// Reading a message aloud: playback only, never while a call or briefing holds the session.
struct PlaybackAudioSessionLease: Hashable, Sendable {
    fileprivate let id: UUID
}

enum DuplexAudioSessionReleaseOutcome: Equatable, Sendable {
    case stale
    case retained(activeLeaseCount: Int)
    case releasedUnderCallKitOwnership
    case deactivated
    case deactivationFailed(String)

    var error: VoiceError? {
        guard case .deactivationFailed(let reason) = self else { return nil }
        return .audioSessionFailed("audio-session deactivation failed: \(reason)")
    }
}

protocol DuplexAudioSessionSystem: Sendable {
    func prepareForCallKit() throws
    func activate() throws
    /// Spoken audio for reading a message aloud: playback only, other apps' audio ducked.
    func activatePlayback() throws
    func deactivate() throws
}

extension DuplexAudioSessionSystem {
    func prepareForCallKit() throws {}
    func activatePlayback() throws {}
}

final class DuplexAudioSessionLeaseManager: @unchecked Sendable {
    static let shared = DuplexAudioSessionLeaseManager(system: SystemDuplexAudioSession())

    private let lock = NSLock()
    private let system: any DuplexAudioSessionSystem
    private var activeLeaseIDs = Set<UUID>()
    private var callKitOwnsAudioSession = false
    private var systemActivationOwned = false
    /// The reading-aloud lease, and what stops that reading when a call or briefing takes the session back.
    private var playback: (id: UUID, onPreempted: @Sendable () -> Void)?

    init(system: any DuplexAudioSessionSystem) {
        self.system = system
    }

    func acquire() throws -> DuplexAudioSessionLease {
        // A call or briefing always wins over reading aloud: the reading stops before the session is reconfigured.
        let preempted = takePlayback()
        preempted?()

        lock.lock()
        defer { lock.unlock() }

        if activeLeaseIDs.isEmpty {
            if callKitOwnsAudioSession {
                systemActivationOwned = false
            } else {
                try system.activate()
                systemActivationOwned = true
            }
        } else if !callKitOwnsAudioSession, !systemActivationOwned {
            // CallKit deactivated while an old voice operation was still unwinding. A new operation must not borrow
            // that dead session; the host's episode fence will cancel the old work and a later fresh call can retry.
            throw VoiceError.audioSessionFailed("CallKit audio session is no longer active")
        }
        let lease = DuplexAudioSessionLease(id: UUID())
        activeLeaseIDs.insert(lease.id)
        return lease
    }

    @discardableResult
    func release(_ lease: DuplexAudioSessionLease) -> DuplexAudioSessionReleaseOutcome {
        lock.lock()
        defer { lock.unlock() }

        guard activeLeaseIDs.remove(lease.id) != nil else { return .stale }
        guard activeLeaseIDs.isEmpty else {
            return .retained(activeLeaseCount: activeLeaseIDs.count)
        }
        guard systemActivationOwned else {
            return .releasedUnderCallKitOwnership
        }
        systemActivationOwned = false
        do {
            try system.deactivate()
            return .deactivated
        } catch {
            return .deactivationFailed(error.localizedDescription)
        }
    }

    var activeLeaseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeLeaseIDs.count
    }

    /// Reading aloud, only while no call or briefing holds the session: a live call is never reconfigured. A call or
    /// briefing that starts later takes the session back, and `onPreempted` runs first so the reading stops.
    func acquirePlayback(onPreempted: @escaping @Sendable () -> Void) throws -> PlaybackAudioSessionLease {
        lock.lock()
        defer { lock.unlock() }

        guard activeLeaseIDs.isEmpty, !callKitOwnsAudioSession else { throw VoiceError.audioSessionBusy }
        guard playback == nil else {
            // One reader reads at a time; it hands its lease on rather than taking a second one.
            throw VoiceError.audioSessionFailed("a message is already being read aloud")
        }
        try system.activatePlayback()
        let lease = PlaybackAudioSessionLease(id: UUID())
        playback = (lease.id, onPreempted)
        return lease
    }

    /// Ends a reading. The session is deactivated only if the reading still owns it: after a call or briefing took
    /// it back, the release is stale and changes nothing.
    @discardableResult
    func releasePlayback(_ lease: PlaybackAudioSessionLease) -> DuplexAudioSessionReleaseOutcome {
        lock.lock()
        defer { lock.unlock() }

        guard playback?.id == lease.id else { return .stale }
        playback = nil
        do {
            try system.deactivate()
            return .deactivated
        } catch {
            return .deactivationFailed(error.localizedDescription)
        }
    }

    /// Whether this reading still owns the session (a call or briefing has not taken it back).
    func holdsPlayback(_ lease: PlaybackAudioSessionLease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return playback?.id == lease.id
    }

    /// Detaches the reading-aloud lease, if any, and returns what stops it, to be run outside the lock.
    private func takePlayback() -> (@Sendable () -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let preempted = playback?.onPreempted
        playback = nil
        return preempted
    }

    func callKitDidActivate() {
        let preempted = takePlayback()
        preempted?()

        lock.lock()
        callKitOwnsAudioSession = true
        // CallKit is now authoritative even if it activated while a local lease was winding up. Its delegate owns
        // the matching deactivation; a later local release must not call setActive(false).
        systemActivationOwned = false
        lock.unlock()
    }

    func prepareForCallKit() throws {
        lock.lock()
        defer { lock.unlock() }
        try system.prepareForCallKit()
    }

    func callKitDidDeactivate() {
        lock.lock()
        callKitOwnsAudioSession = false
        lock.unlock()
    }
}

/// PocketDialVoice calls this from the host's CXProvider delegate bridge. Keeping the ownership bit in PocketVoice
/// lets every synthesizer/player/microphone lease share the same rule without importing CallKit into this package.
public enum CallKitAudioSessionOwnership {
    public static func prepareForAnswer() throws {
        try DuplexAudioSessionLeaseManager.shared.prepareForCallKit()
    }

    public static func didActivate() {
        DuplexAudioSessionLeaseManager.shared.callKitDidActivate()
    }

    public static func didDeactivate() {
        DuplexAudioSessionLeaseManager.shared.callKitDidDeactivate()
    }
}

private struct SystemDuplexAudioSession: DuplexAudioSessionSystem {
    func prepareForCallKit() throws {
        #if os(iOS)
        do {
            try configure(AVAudioSession.sharedInstance())
        } catch {
            throw VoiceError.audioSessionFailed(error.localizedDescription)
        }
        #endif
    }

    func activate() throws {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try configure(session)
            try session.setActive(true)
        } catch {
            throw VoiceError.audioSessionFailed(error.localizedDescription)
        }
        #endif
    }

    func activatePlayback() throws {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            throw VoiceError.audioSessionFailed(error.localizedDescription)
        }
        #endif
    }

    func deactivate() throws {
        #if os(iOS)
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    #if os(iOS)
    private func configure(_ session: AVAudioSession) throws {
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
    }
    #endif
}
