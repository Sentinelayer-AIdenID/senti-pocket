@testable import PocketVoice
import Foundation
import XCTest

final class DuplexAudioSessionLeaseTests: XCTestCase {
    func testActivatesOnFirstLeaseAndDeactivatesAfterLastRelease() throws {
        let system = RecordingDuplexAudioSessionSystem()
        let manager = DuplexAudioSessionLeaseManager(system: system)

        let microphone = try manager.acquire()
        let narration = try manager.acquire()

        XCTAssertEqual(manager.activeLeaseCount, 2)
        XCTAssertEqual(system.activationCount, 1)
        XCTAssertEqual(system.deactivationCount, 0)

        XCTAssertEqual(manager.release(microphone), .retained(activeLeaseCount: 1))
        XCTAssertEqual(manager.activeLeaseCount, 1)
        XCTAssertEqual(system.deactivationCount, 0)

        XCTAssertEqual(manager.release(narration), .deactivated)
        XCTAssertEqual(manager.activeLeaseCount, 0)
        XCTAssertEqual(system.deactivationCount, 1)
    }

    func testDuplicateAndStaleReleasesCannotAffectANewerLease() throws {
        let system = RecordingDuplexAudioSessionSystem()
        let manager = DuplexAudioSessionLeaseManager(system: system)
        let oldLease = try manager.acquire()

        XCTAssertEqual(manager.release(oldLease), .deactivated)
        XCTAssertEqual(manager.release(oldLease), .stale)
        XCTAssertEqual(system.deactivationCount, 1)

        let newLease = try manager.acquire()
        XCTAssertEqual(manager.release(oldLease), .stale)
        XCTAssertEqual(manager.activeLeaseCount, 1)
        XCTAssertEqual(system.deactivationCount, 1)

        XCTAssertEqual(manager.release(newLease), .deactivated)
        XCTAssertEqual(manager.activeLeaseCount, 0)
        XCTAssertEqual(system.activationCount, 2)
        XCTAssertEqual(system.deactivationCount, 2)
    }

    func testFailedActivationDoesNotMintALease() throws {
        let system = RecordingDuplexAudioSessionSystem()
        system.failNextActivation = true
        let manager = DuplexAudioSessionLeaseManager(system: system)

        XCTAssertThrowsError(try manager.acquire())
        XCTAssertEqual(manager.activeLeaseCount, 0)
        XCTAssertEqual(system.activationCount, 1)
        XCTAssertEqual(system.deactivationCount, 0)

        let lease = try manager.acquire()
        XCTAssertEqual(manager.activeLeaseCount, 1)
        XCTAssertEqual(system.activationCount, 2)
        manager.release(lease)
        XCTAssertEqual(system.deactivationCount, 1)
    }

    func testDeactivationFailureIsObservableAndDoesNotRetainLogicalOwnership() throws {
        let system = RecordingDuplexAudioSessionSystem()
        let manager = DuplexAudioSessionLeaseManager(system: system)
        let lease = try manager.acquire()
        system.failNextDeactivation = true

        XCTAssertEqual(
            manager.release(lease),
            .deactivationFailed("recording audio-session deactivation failed")
        )
        XCTAssertEqual(manager.activeLeaseCount, 0)
        XCTAssertEqual(system.deactivationCount, 1)

        let nextLease = try manager.acquire()
        XCTAssertEqual(system.activationCount, 2)
        XCTAssertEqual(manager.release(nextLease), .deactivated)
    }

    func testCallKitOwnedLeaseNeverActivatesOrDeactivatesTheSystemSession() throws {
        let system = RecordingDuplexAudioSessionSystem()
        let manager = DuplexAudioSessionLeaseManager(system: system)
        try manager.prepareForCallKit()
        manager.callKitDidActivate()

        let microphone = try manager.acquire()
        let narration = try manager.acquire()
        XCTAssertEqual(system.activationCount, 0)
        XCTAssertEqual(system.prepareForCallKitCount, 1)
        XCTAssertEqual(manager.release(microphone), .retained(activeLeaseCount: 1))
        XCTAssertEqual(manager.release(narration), .releasedUnderCallKitOwnership)
        XCTAssertEqual(system.deactivationCount, 0)

        manager.callKitDidDeactivate()
        let standalone = try manager.acquire()
        XCTAssertEqual(system.activationCount, 1)
        XCTAssertEqual(manager.release(standalone), .deactivated)
        XCTAssertEqual(system.deactivationCount, 1)
    }

    func testCallKitDeactivationMakesNewWorkFailClosedWhileOldLeaseUnwinds() throws {
        let system = RecordingDuplexAudioSessionSystem()
        let manager = DuplexAudioSessionLeaseManager(system: system)
        manager.callKitDidActivate()
        let old = try manager.acquire()

        manager.callKitDidDeactivate()
        XCTAssertThrowsError(try manager.acquire())
        XCTAssertEqual(manager.release(old), .releasedUnderCallKitOwnership)
        XCTAssertEqual(system.activationCount, 0)
        XCTAssertEqual(system.deactivationCount, 0)

        let fresh = try manager.acquire()
        XCTAssertEqual(system.activationCount, 1)
        XCTAssertEqual(manager.release(fresh), .deactivated)
    }

    func testPlaybackIsRefusedWhileACallOrBriefingHoldsTheSession() throws {
        let system = RecordingDuplexAudioSessionSystem()
        let manager = DuplexAudioSessionLeaseManager(system: system)
        let call = try manager.acquire()

        XCTAssertThrowsError(try manager.acquirePlayback {}) { XCTAssertEqual($0 as? VoiceError, .audioSessionBusy) }
        XCTAssertEqual(system.playbackActivationCount, 0)
        manager.release(call)

        manager.callKitDidActivate()
        XCTAssertThrowsError(try manager.acquirePlayback {}) { XCTAssertEqual($0 as? VoiceError, .audioSessionBusy) }
        XCTAssertEqual(system.playbackActivationCount, 0)
    }

    func testACallTakesTheSessionFromPlaybackAndThePlaybackReleaseIsStale() throws {
        let system = RecordingDuplexAudioSessionSystem()
        let manager = DuplexAudioSessionLeaseManager(system: system)
        var preempted = 0
        let reading = try manager.acquirePlayback { preempted += 1 }
        XCTAssertEqual(system.playbackActivationCount, 1)
        XCTAssertTrue(manager.holdsPlayback(reading))

        let call = try manager.acquire()
        XCTAssertEqual(preempted, 1, "the reading is told to stop before the call sets up its session")
        XCTAssertFalse(manager.holdsPlayback(reading))
        XCTAssertEqual(system.activationCount, 1)
        XCTAssertEqual(manager.releasePlayback(reading), .stale)
        XCTAssertEqual(system.deactivationCount, 0, "the call's session stays up")
        XCTAssertEqual(manager.release(call), .deactivated)
    }

    func testCallKitTakesTheSessionFromPlayback() throws {
        let system = RecordingDuplexAudioSessionSystem()
        let manager = DuplexAudioSessionLeaseManager(system: system)
        var preempted = 0
        let reading = try manager.acquirePlayback { preempted += 1 }
        manager.callKitDidActivate()
        XCTAssertEqual(preempted, 1)
        XCTAssertEqual(manager.releasePlayback(reading), .stale)
        XCTAssertEqual(system.deactivationCount, 0)
    }

    func testPlaybackReleaseDeactivatesOnceAndOnlyOneReadingHoldsTheSession() throws {
        let system = RecordingDuplexAudioSessionSystem()
        let manager = DuplexAudioSessionLeaseManager(system: system)
        let reading = try manager.acquirePlayback {}
        XCTAssertThrowsError(try manager.acquirePlayback {})
        XCTAssertEqual(system.playbackActivationCount, 1)

        XCTAssertEqual(manager.releasePlayback(reading), .deactivated)
        XCTAssertEqual(manager.releasePlayback(reading), .stale)
        XCTAssertEqual(system.deactivationCount, 1)

        let next = try manager.acquirePlayback {}
        XCTAssertEqual(system.playbackActivationCount, 2)
        XCTAssertEqual(manager.releasePlayback(next), .deactivated)
    }
}

private final class RecordingDuplexAudioSessionSystem: DuplexAudioSessionSystem, @unchecked Sendable {
    private enum StubError: LocalizedError {
        case activationFailed
        case deactivationFailed

        var errorDescription: String? {
            switch self {
            case .activationFailed: return "recording audio-session activation failed"
            case .deactivationFailed: return "recording audio-session deactivation failed"
            }
        }
    }

    var activationCount = 0
    var playbackActivationCount = 0
    var deactivationCount = 0
    var prepareForCallKitCount = 0
    var failNextActivation = false
    var failNextDeactivation = false

    func prepareForCallKit() throws {
        prepareForCallKitCount += 1
    }

    func activate() throws {
        activationCount += 1
        if failNextActivation {
            failNextActivation = false
            throw StubError.activationFailed
        }
    }

    func activatePlayback() throws {
        playbackActivationCount += 1
    }

    func deactivate() throws {
        deactivationCount += 1
        if failNextDeactivation {
            failNextDeactivation = false
            throw StubError.deactivationFailed
        }
    }
}
