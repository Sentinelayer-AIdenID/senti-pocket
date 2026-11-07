#if canImport(SwiftUI)
import Foundation
import PocketContracts
import SwiftUI

/// Full membership-authorized event presentation reached only from a validated visible Activity row.
public struct SessionEventDetailView: View {
    private let event: SessionEventRowPresentation
    private let provenance: SessionPresentationProvenance

    public init(
        event: SessionEventRowPresentation,
        provenance: SessionPresentationProvenance
    ) {
        self.event = event
        self.provenance = provenance
    }

    public var body: some View {
        List {
            Section {
                SessionProvenanceBanner(provenance: provenance)
                membershipNotice
            }
            .listRowBackground(PocketPalette.raised)

            Section("Details") {
                detail("What", event.eventTypeLabel)
                detail("From", event.author)
                timestamp
            }
            .listRowBackground(PocketPalette.raised)

            if let text = event.text {
                Section("Message") {
                    Text(text)
                        .foregroundStyle(PocketPalette.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowBackground(PocketPalette.raised)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(event.eventTypeLabel)
        .accessibilityIdentifier("pocket.activity.event-detail")
        .pocketCanvas()
    }

    private var membershipNotice: some View {
        Label(
            "You see this because you're in this chat. It isn't a signed briefing.",
            systemImage: "person.2"
        )
        .font(.subheadline)
        .foregroundStyle(PocketPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var timestamp: some View {
        if let date = event.timestamp.date {
            detail("When", date.formatted(date: .abbreviated, time: .standard))
        } else {
            detail("When", event.timestamp.raw, monospaced: true)
        }
    }

    private func detail(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        LabeledContent(label) {
            Text(verbatim: value)
                .font(monospaced ? Font.body.monospaced() : Font.body)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

/// Full membership-authorized action presentation reached only from a validated visible Activity row.
public struct SessionActionDetailView: View {
    private let action: SessionActionRowPresentation
    private let provenance: SessionPresentationProvenance

    public init(
        action: SessionActionRowPresentation,
        provenance: SessionPresentationProvenance
    ) {
        self.action = action
        self.provenance = provenance
    }

    public var body: some View {
        List {
            Section {
                SessionProvenanceBanner(provenance: provenance)
                membershipNotice
            }
            .listRowBackground(PocketPalette.raised)

            Section("Details") {
                detail("What", action.actionTypeLabel)
                detail("Who", action.actor)
                detail("On", action.targetLabel)
                timestamp
            }
            .listRowBackground(PocketPalette.raised)

            if let note = action.note {
                Section("Note") {
                    Text(note)
                        .foregroundStyle(PocketPalette.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowBackground(PocketPalette.raised)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(action.actionTypeLabel)
        .accessibilityIdentifier("pocket.activity.action-detail")
        .pocketCanvas()
    }

    private var membershipNotice: some View {
        Label(
            "You see this because you're in this chat. It isn't a signed receipt.",
            systemImage: "person.2"
        )
        .font(.subheadline)
        .foregroundStyle(PocketPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var timestamp: some View {
        if let date = action.createdAt.date {
            detail("When", date.formatted(date: .abbreviated, time: .standard))
        } else {
            detail("When", action.createdAt.raw, monospaced: true)
        }
    }

    private func detail(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        LabeledContent(label) {
            Text(verbatim: value)
                .font(monospaced ? Font.body.monospaced() : Font.body)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
#endif
