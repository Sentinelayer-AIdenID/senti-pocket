import Foundation
import PocketCall
import PocketContracts
import XCTest
@testable import PocketUI

final class VerifiedCheckpointBriefingTests: XCTestCase {
    #if canImport(CryptoKit)
    func test_verified_presentation_preserves_exact_signed_checkpoint_content() throws {
        let verifiedBundle = try loadVerifiedBundle()
        let bundle = verifiedBundle.bundle

        let presentation = VerifiedCheckpointBriefingPresentation(
            verifiedBundle: verifiedBundle
        )

        XCTAssertEqual(presentation.verifiedBundle, verifiedBundle)
        XCTAssertEqual(presentation.sessionId, bundle.sessionId)
        XCTAssertEqual(presentation.checkpointId, bundle.checkpointId)
        XCTAssertEqual(presentation.sequenceStart, bundle.sequenceStart)
        XCTAssertEqual(presentation.sequenceEnd, bundle.sequenceEnd)
        XCTAssertEqual(presentation.signingKeyId, bundle.signingKeyId)
        XCTAssertEqual(presentation.summary, bundle.summary)
        XCTAssertEqual(presentation.evidenceCount, bundle.evidence.count)
        XCTAssertEqual(presentation.summary.perAgent.flatMap(\.claims).count, 4)
        XCTAssertEqual(presentation.summary.risks.count, 2)
        XCTAssertEqual(presentation.summary.blockers.count, 1)
    }

    #if canImport(SwiftUI)
    func test_public_view_is_constructed_from_verified_bundle() throws {
        _ = VerifiedCheckpointBriefingView(verifiedBundle: try loadVerifiedBundle())
    }
    #endif

    private func loadVerifiedBundle() throws -> VerifiedBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(
            PocketBundle.self,
            from: Data(contentsOf: canonicalFixtureURL)
        )
        return try XCTUnwrap(VerifiedBundle.verify(bundle))
    }

    private var canonicalFixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PocketUIUnitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // PocketUI
            .deletingLastPathComponent() // packages
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("packages/PocketContracts/Fixtures/canonical_checkpoint.json")
            .standardizedFileURL
    }
    #endif

    #if canImport(SwiftUI)
    func test_checkpoint_row_copy_names_exact_fetch_and_pre_display_verification() {
        XCTAssertEqual(
            SessionCheckpointListView.exactCheckpointOpenHint,
            "Checks this summary's signature before showing any of it."
        )
        XCTAssertEqual(
            SessionCheckpointListView.trustBoundaryMessage,
            "You see these summaries because you're in this chat. Each one's signature is checked before any of it is shown."
        )
    }
    #endif
}
