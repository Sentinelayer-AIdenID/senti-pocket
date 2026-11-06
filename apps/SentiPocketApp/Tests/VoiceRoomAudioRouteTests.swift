import AVFoundation
import XCTest
@testable import SentiPocketApp

/// The Speaker choice lasts for its call only: once the call ends, the phone's audio is back on its default route, so a
/// room video after an earpiece call plays on the speaker. Room video sets no audio setup of its own and plays on what
/// the call left. Run against the shared audio session, whose setup is put back after each test.
@MainActor
final class VoiceRoomAudioRouteTests: XCTestCase {
    private var saved: (category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                        options: AVAudioSession.CategoryOptions)?

    override func setUp() {
        super.setUp()
        let session = AVAudioSession.sharedInstance()
        saved = (session.category, session.mode, session.categoryOptions)
    }

    override func tearDown() {
        if let saved {
            try? AVAudioSession.sharedInstance().setCategory(saved.category, mode: saved.mode, options: saved.options)
        }
        saved = nil
        super.tearDown()
    }

    func test_an_earpiece_call_leaves_the_phone_on_the_speaker_when_it_ends() throws {
        let session = AVAudioSession.sharedInstance()
        let call = CallKitVoiceRoomAudioSession()
        try call.activate()
        XCTAssertTrue(session.categoryOptions.contains(.defaultToSpeaker), "a call starts on the speaker")

        // The earpiece, for this call. (The simulator may refuse the port override; the call's setup is what matters.)
        try? call.setSpeaker(false)
        XCTAssertFalse(session.categoryOptions.contains(.defaultToSpeaker), "the earpiece, while the call lasts")

        call.deactivate()
        XCTAssertTrue(session.categoryOptions.contains(.defaultToSpeaker),
                      "the call is over: the next playback, a room video, plays on the speaker")
    }
}
