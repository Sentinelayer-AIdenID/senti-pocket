#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A message or reply from someone you blocked, as one line in its place. Show opens this one, once.
struct RoomBlockedLine: View {
    let identifier: String
    let onShow: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised")
                .font(.caption)
                .foregroundStyle(PocketPalette.textSecondary)
                .accessibilityHidden(true)
            Text(RoomBlocking.hiddenLine)
                .font(.footnote)
                .foregroundStyle(PocketPalette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(action: onShow) {
                Text("Show")
                    .font(.footnote.weight(.semibold))
                    .frame(minWidth: RoomBlocking.minimumTapSize, minHeight: RoomBlocking.minimumTapSize)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.borderless)
                .accessibilityHint("Shows this one message")
                .accessibilityIdentifier("\(identifier).show")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// Report someone else's message or reply: a reason and an optional note, then thanks, and the offer to block them.
struct RoomReportSheet: View {
    let report: RoomReportState
    let send: (RoomChatIntent) -> Void
    @State private var reason: RoomReportReason?
    @State private var note = ""
    @State private var blocking: RoomBlockTarget?
    @FocusState private var writingNote: Bool

    private var name: String { report.target.authorName }
    private var limit: Int { report.target.noteLimit }

    var body: some View {
        NavigationStack {
            Group {
                if report.phase == .sent {
                    sent
                } else {
                    choosing
                }
            }
            .navigationTitle(report.phase == .sent ? "Report sent" : "Report")
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .toolbar {
                if report.phase == .sent {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { send(.closeReport) }
                            .accessibilityIdentifier("pocket.report.done")
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { send(.closeReport) }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if report.phase == .sending {
                            ProgressView()
                        } else {
                            Button("Send") {
                                guard let reason else { return }
                                send(.sendReport(reason: reason, note: note))
                            }
                            .disabled(reason == nil || report.phase == .refused)
                            .accessibilityIdentifier("pocket.report.send")
                        }
                    }
                }
            }
        }
        .roomBlockConfirmation($blocking, send: send)
        .onChange(of: report.phase) { phase in
            guard let said = RoomReport.announcement(for: phase) else { return }
            #if canImport(UIKit)
            UIAccessibility.post(notification: .announcement, argument: said)
            #endif
        }
    }

    private var choosing: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    ForEach(RoomReportReason.allCases) { item in
                        Button {
                            reason = item
                        } label: {
                            HStack {
                                Text(item.title)
                                    .foregroundStyle(PocketPalette.textPrimary)
                                Spacer(minLength: 8)
                                if reason == item {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(PocketPalette.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(reason == item ? .isSelected : [])
                        .accessibilityIdentifier("pocket.report.reason.\(item.rawValue)")
                    }
                } header: {
                    Text("Why are you reporting this \(report.target.replyId == nil ? "message" : "reply") from \(name)?")
                }
                Section {
                    TextField("Add a note (optional)", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                        .focused($writingNote)
                        .onChange(of: note) { typed in
                            let kept = RoomReport.clamped(typed, to: limit)
                            if kept != typed { note = kept }
                        }
                        .accessibilityIdentifier("pocket.report.note")
                        .id("pocket.report.noteRow")
                } footer: {
                    Text("\(note.unicodeScalars.count) of \(limit) characters")
                        .monospacedDigit()
                }
                if report.phase == .failed {
                    Section {
                        Label(RoomReport.notSent, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(PocketPalette.warning)
                            .accessibilityIdentifier("pocket.report.notSent")
                    }
                } else if report.phase == .refused {
                    Section {
                        Label(RoomReport.refused, systemImage: "nosign")
                            .foregroundStyle(PocketPalette.warning)
                            .accessibilityIdentifier("pocket.report.refused")
                    }
                }
                Section {
                    Text("Reports go to the Senti team. \(name) isn't told who reported it.")
                        .font(.footnote)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
            }
            .disabled(report.phase == .sending)
            // The note stays in sight above the keyboard while it is written.
            .onChange(of: writingNote) { writing in
                guard writing else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation { proxy.scrollTo("pocket.report.noteRow", anchor: .center) }
                }
            }
        }
    }

    private var sent: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(PocketPalette.verified)
                .accessibilityHidden(true)
            Text(RoomReport.thanks)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("pocket.report.thanks")
            if report.authorIsBlocked {
                Text("You blocked \(name).")
                    .foregroundStyle(PocketPalette.textSecondary)
            } else if report.canBlock {
                Button(role: .destructive) {
                    blocking = RoomBlockTarget(report.target, name: name)
                } label: {
                    Label("Block \(name) too", systemImage: "hand.raised")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("pocket.report.blockToo")
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// Blocking asks first: what it does, and that it can be undone in Settings.
    public func roomBlockConfirmation(_ target: Binding<RoomBlockTarget?>,
                                      send: @escaping (RoomChatIntent) -> Void) -> some View {
        confirmationDialog(
            "Block \(target.wrappedValue?.name ?? "")?",
            isPresented: Binding(get: { target.wrappedValue != nil }, set: { if !$0 { target.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: target.wrappedValue
        ) { blocked in
            Button("Block \(blocked.name)", role: .destructive) { send(.block(blocked)) }
                .accessibilityIdentifier("pocket.block.confirm")
            Button("Cancel", role: .cancel) {}
        } message: { blocked in
            Text(RoomBlocking.confirmation(for: blocked))
        }
    }
}

/// The one-time notice before anything you write in a room is shared with AI (App Store guideline 5.1.2(i)): what is
/// shared, and with whom. Agree records your consent for this account and the write goes ahead; Not now cancels it.
public struct RoomAIConsentSheet: View {
    private let onAllow: () -> Void
    private let onNotNow: () -> Void

    public init(onAllow: @escaping () -> Void, onNotNow: @escaping () -> Void) {
        self.onAllow = onAllow
        self.onNotNow = onNotNow
    }

    public var body: some View {
        // At full height, every word, then Agree and Not now after them, at every text size: what is shared is read
        // before it is agreed to, and at the largest sizes the whole of it scrolls.
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "cpu")
                    .font(.system(size: 30))
                    .foregroundStyle(PocketPalette.listening)
                    .accessibilityHidden(true)
                Text(AIConsentText.title)
                    .font(.title3.bold())
                    .foregroundStyle(PocketPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(AIConsentText.notice)
                    .font(.body)
                    .foregroundStyle(PocketPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pocket.aiConsent.notice")
                Text(AIConsentText.settingsHint)
                    .font(.footnote)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pocket.aiConsent.hint")
                PocketHelpLinks(showsContact: false)
                answers
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .presentationDetents([.large])
        .accessibilityElement(children: .contain)
        // VoiceOver's escape (two-finger scrub) is Not now, as the sheet can't be swiped away.
        .accessibilityAction(.escape) { onNotNow() }
        .accessibilityIdentifier("pocket.aiConsent")
    }

    @ViewBuilder private var answers: some View {
        Button(action: onAllow) {
            Text(AIConsentText.agree).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(PocketPalette.accent)
        .accessibilityIdentifier("pocket.aiConsent.ok")
        Button(action: onNotNow) {
            Text(AIConsentText.notNow).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityIdentifier("pocket.aiConsent.notNow")
    }
}

/// A send held until the person answers the AI consent sheet.
public struct AIConsentHeld: Identifiable {
    public let id = UUID()
    /// What OK does, after the consent is recorded.
    public let proceed: () -> Void
    /// What Not now does.
    public let decline: () -> Void

    /// `proceed` runs after OK; `decline` after Not now (an answered call ends there).
    public init(_ proceed: @escaping () -> Void, onDecline decline: @escaping () -> Void = {}) {
        self.proceed = proceed
        self.decline = decline
    }
}

private struct AIConsentPrompt: ViewModifier {
    @Binding var held: AIConsentHeld?
    let onAllow: () -> Void
    /// The question on screen: shown a moment after it is asked for, so a menu, alert or sheet still leaving never
    /// swallows it.
    @State private var asking: AIConsentHeld?
    /// The answer, acted on once the sheet has gone, so a sheet the send opens (a call's picker) is never dropped.
    @State private var answer: (request: AIConsentHeld, allowed: Bool)?

    func body(content: Content) -> some View {
        content
            .onChange(of: held?.id) { id in
                guard id != nil else {
                    // Cleared by what asked (not answered here): the question goes.
                    if answer == nil { asking = nil }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if asking == nil, let held { asking = held }
                }
            }
            // Asked before this screen was up (a call answered as the app opened): asked once it is.
            .onAppear {
                guard held != nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if asking == nil, let held { asking = held }
                }
            }
            .sheet(item: $asking, onDismiss: {
                guard let answer else { return }
                self.answer = nil
                if answer.allowed {
                    answer.request.proceed()
                } else {
                    answer.request.decline()
                }
            }) { request in
                RoomAIConsentSheet(
                    onAllow: {
                        onAllow()
                        answer = (request, true)
                        held = nil
                        asking = nil
                    },
                    onNotNow: {
                        answer = (request, false)
                        held = nil
                        asking = nil
                    }
                )
                // OK or Not now: the answer is never left to a swipe.
                .interactiveDismissDisabled()
            }
    }
}

extension View {
    /// Asks the AI consent question while `held` is set: OK calls `onAllow` (which records the consent), then the
    /// held send; Not now drops the send and leaves what was written where it was.
    public func aiConsentPrompt(_ held: Binding<AIConsentHeld?>, onAllow: @escaping () -> Void) -> some View {
        modifier(AIConsentPrompt(held: held, onAllow: onAllow))
    }
}
/// Contact us, Terms of Use and Privacy Policy (`PocketHelp`), as links that wrap at any text size.
public struct PocketHelpLinks: View {
    private let showsContact: Bool

    public init(showsContact: Bool = true) {
        self.showsContact = showsContact
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { links }
            VStack(spacing: 10) { links }
        }
        .font(.footnote)
        .tint(PocketPalette.accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pocket.help.links")
    }

    @ViewBuilder private var links: some View {
        if showsContact {
            Link("Contact us", destination: PocketHelp.mailURL)
                .accessibilityIdentifier("pocket.help.contact")
        }
        Link("Terms of Use", destination: PocketHelp.termsURL)
            .accessibilityIdentifier("pocket.help.terms")
        Link("Privacy Policy", destination: PocketHelp.privacyURL)
            .accessibilityIdentifier("pocket.help.privacy")
    }
}
#endif
