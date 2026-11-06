#if canImport(SwiftUI)
import SwiftUI

/// An estimate's card in the room: the priced options, the suggested one, how each judge is paid for, what the
/// numbers are based on, and where it stands. Pick shows only to whoever asked and to the room's owners and admins.
struct RoomEstimateCardView: View {
    let card: RoomEstimateCard?
    let send: (RoomChatIntent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "dollarsign.circle")
                    .foregroundStyle(PocketPalette.accent)
                    .accessibilityHidden(true)
                Text("Estimate")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PocketPalette.accent)
                Spacer(minLength: 4)
                Text(RoomEstimateCard.notAQuote)
                    .font(.caption2)
                    .foregroundStyle(PocketPalette.textSecondary)
            }
            if let card {
                ForEach(card.options) { option in
                    optionView(option, in: card)
                }
                if let basis = card.basisLine {
                    Text(basis)
                        .font(.caption2)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
                if let question = card.planQuestion {
                    planQuestion(question, estimateId: card.estimateId)
                }
                if let status = card.statusText {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(PocketPalette.textSecondary)
                        .accessibilityIdentifier("pocket.room.estimate.status")
                }
                if let notice = card.notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(PocketPalette.warning)
                }
                if card.canAskAgain {
                    Button("Ask again") { send(.askEstimateAgain(estimateId: card.estimateId)) }
                        .font(.footnote.weight(.semibold))
                        .disabled(card.isBusy)
                        .accessibilityIdentifier("pocket.room.estimate.askAgain")
                }
            } else {
                Text("Getting the estimate…")
                    .font(.footnote)
                    .foregroundStyle(PocketPalette.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(PocketPalette.accent.opacity(0.35), lineWidth: 0.75)
        )
        .accessibilityIdentifier("pocket.room.estimate")
    }

    private func optionView(_ option: RoomEstimateCard.Option, in card: RoomEstimateCard) -> some View {
        let isPicked = card.pickedOptionId == option.id
        return VStack(alignment: .leading, spacing: 4) {
            // One element for VoiceOver: its label, cost, time, then "suggested".
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(option.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PocketPalette.textPrimary)
                    if option.isSuggested {
                        Text("Suggested")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(PocketPalette.accent, in: Capsule())
                    }
                    Spacer(minLength: 0)
                    if isPicked {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(PocketPalette.accent)
                    }
                }
                Text(option.costText)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PocketPalette.textPrimary)
                if let time = option.timeText {
                    Text(time)
                        .font(.footnote)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(option.accessibilityLabel + (isPicked ? ", picked" : ""))
            if let rounds = option.roundsText {
                Text(rounds).font(.caption).foregroundStyle(PocketPalette.textSecondary)
            }
            if let billing = option.billingText {
                Text(billing).font(.caption).foregroundStyle(PocketPalette.textSecondary)
            }
            ForEach(option.caveats, id: \.self) { caveat in
                Text(caveat).font(.caption2).foregroundStyle(PocketPalette.textSecondary)
            }
            if card.canPick {
                Button("Pick this") { send(.pickEstimate(estimateId: card.estimateId, optionId: option.id)) }
                    .font(.footnote.weight(.semibold))
                    .disabled(card.isBusy)
                    .accessibilityLabel("Pick \(option.label)")
                    .accessibilityIdentifier("pocket.room.estimate.pick.\(option.id)")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PocketPalette.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func planQuestion(_ question: RoomEstimateCard.PlanQuestion, estimateId: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.question)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PocketPalette.textPrimary)
            HStack(spacing: 8) {
                ForEach(question.choices) { choice in
                    Button(choice.title) { send(.answerEstimatePlan(estimateId: estimateId, plan: choice.value)) }
                        .font(.footnote.weight(.semibold))
                }
                Button("Not now") { send(.answerEstimatePlan(estimateId: estimateId, plan: nil)) }
                    .font(.footnote)
            }
        }
        .accessibilityIdentifier("pocket.room.estimate.plan")
    }
}
#endif
