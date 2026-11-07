import AVFoundation
import PocketVoice
import XCTest
@testable import SentiPocketApp

/// Ticket b21646d8: calls were stuck on the loudspeaker (every call's session asked for `.defaultToSpeaker`). Now a call
/// is on the speaker, or on the earpiece while the phone is held to the ear, unless the person picks one; headphones
/// and Bluetooth take over the moment they connect.
final class CallAudioRoutingTests: XCTestCase {
    func test_automatic_is_the_speaker_unless_the_phone_is_held_to_the_ear() {
        XCTAssertEqual(CallAudioRouting.output(for: .automatic, nearEar: false, external: false), .speaker)
        XCTAssertEqual(CallAudioRouting.output(for: .automatic, nearEar: true, external: false), .iPhone,
                       "held to the ear, a call sounds like a phone call")
    }

    func test_a_picked_output_holds_wherever_the_phone_is() {
        XCTAssertEqual(CallAudioRouting.output(for: .speaker, nearEar: true, external: false), .speaker)
        XCTAssertEqual(CallAudioRouting.output(for: .speaker, nearEar: false, external: false), .speaker)
        XCTAssertEqual(CallAudioRouting.output(for: .iPhone, nearEar: false, external: false), .iPhone)
        XCTAssertEqual(CallAudioRouting.output(for: .iPhone, nearEar: true, external: false), .iPhone)
    }

    func test_headphones_and_bluetooth_take_over_whatever_was_picked() {
        for route in CallAudioRoute.allCases {
            for nearEar in [false, true] {
                XCTAssertNil(CallAudioRouting.output(for: route, nearEar: nearEar, external: true),
                             "\(route), near the ear \(nearEar): left to the headphones")
            }
        }
    }

    func test_no_call_is_forced_onto_the_speaker() {
        XCTAssertFalse(CallAudioRouting.sessionOptions.contains(.defaultToSpeaker))
        XCTAssertTrue(CallAudioRouting.sessionOptions.contains(.allowBluetooth), "Bluetooth headsets still work")
        XCTAssertFalse(PhoneVoiceRoomAudioSession.options.contains(.defaultToSpeaker), "a call in the app")
        XCTAssertFalse(CallKitVoiceRoomAudioSession.options.contains(.defaultToSpeaker), "an answered call")
        XCTAssertTrue(PhoneVoiceRoomAudioSession.options.contains(.allowBluetoothA2DP))
    }

    func test_the_call_screen_names_each_choice() {
        XCTAssertEqual(CallAudioRoute.allCases.map(CallAudioRouteControl.title),
                       ["Automatic (iPhone at your ear)", "Speaker", "iPhone"])
    }
}
