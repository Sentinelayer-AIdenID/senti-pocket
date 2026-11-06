import Foundation
import XCTest
@testable import PocketContracts

/// The room's timestamps are read by hand on the hot path; this keeps that reading identical to the formatters'.
final class TimestampFastPathTests: XCTestCase {
    /// The hand-read path gives exactly what the formatters give for the wire's shapes, and steps aside for others.
    func testFastTimestampReadingAgreesWithTheFormatters() {
        func formatters(_ s: String) -> Date? {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = fractional.date(from: s) { return d }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: s)
        }
        let samples = [
            "2026-10-30T06:12:36.545755+00:00", "2026-10-30T06:12:36.545Z", "2026-10-30T06:12:36Z",
            "1970-01-01T00:00:00Z", "2024-02-29T23:59:59.999+05:30", "2026-12-31T00:00:00-08:00",
            "2000-03-01T12:00:00.5Z", "2100-01-01T00:00:00Z", "1969-12-31T23:59:59Z"
        ]
        for sample in samples {
            let fast = ParsedSessionTimestamp.fastParse(sample)
            XCTAssertNotNil(fast, sample)
            guard let fast, let reference = formatters(sample) else { continue }
            XCTAssertEqual(fast.timeIntervalSince1970, reference.timeIntervalSince1970, accuracy: 0.001, sample)
        }
        for odd in ["2026-02-30T00:00:00Z", "2026-10-30 06:12:36Z", "2026-10-30T06:12:36", "2026-10-30T06:12:36.Z",
                    "2026-13-01T00:00:00Z", "2026-10-30T24:00:00Z", "2026-10-30T06:12:36+0000", "2026-W29-6T10:35Z", ""] {
            XCTAssertNil(ParsedSessionTimestamp.fastParse(odd), "\(odd) is left to the formatters")
        }
        XCTAssertEqual(ParsedSessionTimestamp("2026-10-30T06:12:36+0000").date, formatters("2026-10-30T06:12:36+0000"),
                       "a shape the hand-read path refuses still parses as before")
    }

}
