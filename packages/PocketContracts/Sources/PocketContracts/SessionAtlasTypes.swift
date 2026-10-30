import Foundation

// Atlas-owned NONVISUAL session types (V4 §85 ownership, reconciled per #239876):
//   Relay = wire DTOs + SessionTransport/SessionRepository.
//   Pulse = ALL view-models, fallbacks, copy, badges, and the factory off the repository snapshot.
//   Atlas = the bare shell + these two nonvisual types. **THIS LAYER DEFINES NO PRESENTATION TYPES.**
//
// Neither type formats, truncates, falls back, or produces display strings — that is Pulse's factory/view-models.
// Both are LOSSLESS (they never discard a wire value) and DECODE-ONLY (no fetch — live data arrives via Relay's
// gated Repository). The prior SessionRow/CheckpointContent projection is removed: SessionRow was a presentation
// view-model (Pulse's), and CheckpointContent was lossful + used a hardcoded-false bool.

/// A wire timestamp with its RAW String preserved (lossless) plus a best-effort tolerant-ISO8601 parse.
///
/// Nonvisual/data-only: it does NOT format or localize (that is Pulse's). The raw value is the authority and is never
/// discarded, so a parse miss — or a future server format this build doesn't recognize — still round-trips the exact
/// wire bytes. `date` is a convenience only; consumers that need fidelity use `raw`.
public struct ParsedSessionTimestamp: Equatable, Sendable {
    /// The exact wire string — never discarded (the lossless guarantee).
    public let raw: String
    /// Best-effort parse; `nil` when unrecognized. `raw` remains authoritative regardless.
    public let date: Date?

    public init(_ raw: String) {
        self.raw = raw
        self.date = ParsedSessionTimestamp.parse(raw)
    }
    /// Convenience for optional wire fields (e.g. `SessionSummary.lastActivityAt`): nil in ⇒ nil out.
    public init?(_ raw: String?) {
        guard let raw else { return nil }
        self.init(raw)
    }

    /// Tolerant ISO-8601: fractional seconds OR plain, UTC offset or `Z`. Pure; no shared mutable state.
    ///
    /// The wire's own shape (`2026-10-30T06:12:36.545755+00:00`, `…Z`) is read by hand: the room rebuilds on every
    /// update and reads thousands of these, and making two date formatters for each one stalled the main thread
    /// long enough for the watchdog to end the app (Carter's crash while scrolling, 10-30). Anything else falls back
    /// to the formatters.
    static func parse(_ s: String) -> Date? {
        if let date = fastParse(s) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    /// `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)`, exactly; nil for any other shape, which the formatters then read.
    static func fastParse(_ s: String) -> Date? {
        let u = Array(s.utf8)
        guard u.count >= 20, u[4] == 0x2D, u[7] == 0x2D, u[10] == 0x54, u[13] == 0x3A, u[16] == 0x3A else { return nil }
        func number(_ from: Int, _ to: Int) -> Int? {
            var value = 0
            for index in from..<to {
                let c = u[index]
                guard c >= 0x30, c <= 0x39 else { return nil }
                value = value * 10 + Int(c - 0x30)
            }
            return value
        }
        guard let year = number(0, 4), let month = number(5, 7), let day = number(8, 10),
              let hour = number(11, 13), let minute = number(14, 16), let second = number(17, 19),
              (1...12).contains(month), hour < 24, minute < 60, second < 60 else { return nil }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let daysInMonth = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        guard (1...daysInMonth).contains(day) else { return nil }
        var index = 19
        var fraction = 0.0
        if index < u.count, u[index] == 0x2E {
            index += 1
            let start = index
            var scale = 0.1
            while index < u.count, u[index] >= 0x30, u[index] <= 0x39 {
                fraction += Double(u[index] - 0x30) * scale
                scale /= 10
                index += 1
            }
            guard index > start else { return nil }
        }
        guard index < u.count else { return nil }
        var offset = 0
        if u[index] == 0x5A {
            index += 1
        } else if u[index] == 0x2B || u[index] == 0x2D {
            guard u.count == index + 6, u[index + 3] == 0x3A,
                  let hours = number(index + 1, index + 3), let minutes = number(index + 4, index + 6),
                  hours < 24, minutes < 60 else { return nil }
            offset = (u[index] == 0x2B ? 1 : -1) * (hours * 3600 + minutes * 60)
            index += 6
        } else {
            return nil
        }
        guard index == u.count else { return nil }
        // Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's days_from_civil).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }
}

/// A session checkpoint wrapped to make the TRUST BOUNDARY explicit at the type level.
///
/// LOSSLESS: it carries the FULL `SessionCheckpointDTO`, dropping nothing. NONVISUAL: no display strings, badges, or
/// fallbacks (Pulse's factory formats `checkpoint.title`/`summary`/`grade` for the UI).
///
/// TRUST GUARANTEE (structural, not a flag): a `MembershipAuthorizedCheckpoint` is a DIFFERENT TYPE from a
/// `VerifiedBundle`, and there is NO API here that yields verification. A room checkpoint is membership-authorized
/// CONTENT — it renders NEUTRAL, never GREEN. GREEN (cryptographically verified) belongs EXCLUSIVELY to a
/// `VerifiedBundle` (the separately-signed Pocket briefing, in PocketCall), which this type never imports, produces,
/// or imitates. The absence of any verified affordance IS the boundary — no hardcoded-false bool.
public struct MembershipAuthorizedCheckpoint: Identifiable, Equatable, Sendable {
    /// The full wire DTO — lossless.
    public let checkpoint: SessionCheckpointDTO

    public var id: String { checkpoint.checkpointId }
    /// The checkpoint's created-at, raw-preserved. Data-only; Pulse formats it for display.
    public var createdAt: ParsedSessionTimestamp { ParsedSessionTimestamp(checkpoint.createdAt) }

    public init(_ checkpoint: SessionCheckpointDTO) { self.checkpoint = checkpoint }
}
