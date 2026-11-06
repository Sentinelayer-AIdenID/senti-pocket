#if canImport(Speech) && canImport(AVFoundation)
import Speech
import XCTest
@testable import PocketVoice

/// Apple's on-device recognizer, what a call listens with when no Whisper file is installed: on the device only, and a
/// permission question that never holds a call.
final class AppleOnDeviceSpeechRecognizerTests: XCTestCase {
    func test_a_request_never_leaves_the_device() throws {
        let request = try AppleOnDeviceSpeechRecognizer.speechRequest(
            TranscriptionRequest(samples: Array(repeating: 0.1, count: 1_600))
        )
        XCTAssertTrue(request.requiresOnDeviceRecognition, "never server-backed")
    }

    func test_it_needs_no_model_file() {
        XCTAssertFalse(AppleOnDeviceSpeechRecognizer(authorize: { true }).needsModelFile)
    }

    /// The question unanswered (a call taken on a locked phone) is a no once the wait is up, never a yes.
    func test_an_unanswered_permission_question_counts_as_no() async {
        let allowed = await AppleOnDeviceSpeechRecognizer.requestAuthorization(
            wait: 0.05, status: { .notDetermined }, request: { _ in }
        )
        XCTAssertFalse(allowed)
    }

    func test_the_permission_answer_is_the_persons() async {
        let yes = await AppleOnDeviceSpeechRecognizer.requestAuthorization(
            wait: 5, status: { .notDetermined }, request: { $0(.authorized) }
        )
        XCTAssertTrue(yes)
        let no = await AppleOnDeviceSpeechRecognizer.requestAuthorization(
            wait: 5, status: { .notDetermined }, request: { $0(.denied) }
        )
        XCTAssertFalse(no)
        let earlier = await AppleOnDeviceSpeechRecognizer.requestAuthorization(
            wait: 5, status: { .denied }, request: { $0(.authorized) }
        )
        XCTAssertFalse(earlier, "a no given before is not asked again")
    }
}
#endif
