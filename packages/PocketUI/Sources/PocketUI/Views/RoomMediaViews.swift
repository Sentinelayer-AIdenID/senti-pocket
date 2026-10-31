#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A small picture from bytes already on the phone (a preview, at most 640 px).
enum RoomImageData {
    static func image(from data: Data) -> Image? {
        #if canImport(UIKit)
        return UIImage(data: data).map { Image(uiImage: $0) }
        #elseif canImport(AppKit)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return nil
        #endif
    }
}

/// Where to attach from: photos and videos, the camera, files, or an image you copied. Opens from the composer's
/// paperclip; choosing one closes it, then the app shows that picker.
public struct RoomAttachSheet: View {
    let canUseCamera: Bool
    let canPaste: Bool
    /// How many more files this message can carry.
    let remaining: Int
    let choose: (RoomAttachSource) -> Void
    @Environment(\.dismiss) private var dismiss

    public init(canUseCamera: Bool, canPaste: Bool, remaining: Int, choose: @escaping (RoomAttachSource) -> Void) {
        self.canUseCamera = canUseCamera
        self.canPaste = canPaste
        self.remaining = remaining
        self.choose = choose
    }

    private func isEnabled(_ source: RoomAttachSource) -> Bool {
        guard remaining > 0 else { return false }
        switch source {
        case .camera: return canUseCamera
        case .paste: return canPaste
        case .photos, .files: return true
        }
    }

    private func detail(_ source: RoomAttachSource) -> String {
        switch source {
        case .camera where !canUseCamera: return "No camera on this device"
        case .paste where !canPaste: return "Copy an image first"
        default: return source.detail
        }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(RoomAttachSource.allCases) { source in
                        let enabled = isEnabled(source)
                        Button {
                            choose(source)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: source.symbolName)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(enabled ? PocketPalette.accent : PocketPalette.textSecondary)
                                    .frame(width: 44, height: 44)
                                    .background(PocketPalette.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.title)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(enabled ? PocketPalette.textPrimary : PocketPalette.textSecondary)
                                    Text(detail(source))
                                        .font(.footnote)
                                        .foregroundStyle(PocketPalette.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(PocketPalette.textSecondary.opacity(enabled ? 1 : 0.4))
                                    .accessibilityHidden(true)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(PocketPalette.separator.opacity(0.7), lineWidth: 0.5)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(source.title)
                        .accessibilityValue(detail(source))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("pocket.room.attach.\(source.rawValue)")
                    }
                    Text(remaining > 0
                         ? "Up to \(remaining) more in this message. Photos up to 50 MB; videos and files up to 250 MB. Location is removed from photos before they're sent."
                         : "This message has as many files as it can carry. Send it, then add more.")
                        .font(.footnote)
                        .foregroundStyle(PocketPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                        .accessibilityIdentifier("pocket.room.attach.limits")
                }
                .padding(16)
            }
            .pocketCanvas()
            .navigationTitle("Attach")
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("pocket.room.attach.cancel")
                }
            }
        }
    }
}

/// The ring over a file while it uploads: real bytes sent, not a guess. Only this redraws as bytes go.
struct RoomMediaRing: View {
    @ObservedObject var progress: RoomMediaProgress
    let isPreparing: Bool
    var diameter: CGFloat = 30

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.5))
            Circle().stroke(Color.white.opacity(0.3), lineWidth: 3)
            // Getting ready, or not started: a spinner. Once bytes go, the ring fills with them.
            if isPreparing || progress.totalBytes == 0 || progress.sentBytes == 0 {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Circle()
                    .trim(from: 0, to: max(0.02, progress.fraction))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPreparing ? "Getting ready" : "Uploading")
        .accessibilityValue(isPreparing ? "" : "\(Int((progress.fraction * 100).rounded())) percent")
    }
}

/// "4.2 MB of 12.6 MB", kept current as bytes go.
struct RoomMediaBytesText: View {
    @ObservedObject var progress: RoomMediaProgress

    var body: some View {
        Text(progress.text)
            .monospacedDigit()
            .accessibilityLabel("\(progress.text) uploaded")
    }
}

/// One file as a square: its picture (or its kind, for a document), a ring while it uploads, and what went wrong.
struct RoomMediaThumb: View {
    let item: RoomMediaItemRow
    var side: CGFloat = 64
    var onRemove: (() -> Void)?
    var onRetry: (() -> Void)?

    var body: some View {
        ZStack {
            picture
            switch item.phase {
            case .preparing:
                RoomMediaRing(progress: item.progress, isPreparing: true, diameter: side > 70 ? 36 : 28)
            case .uploading:
                RoomMediaRing(progress: item.progress, isPreparing: false, diameter: side > 70 ? 36 : 28)
            case .uploaded:
                if item.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: side > 70 ? 30 : 22))
                        .foregroundStyle(Color.white, Color.black.opacity(0.45))
                        .accessibilityHidden(true)
                }
            case .failed(_, let canRetry):
                Button {
                    onRetry?()
                } label: {
                    Image(systemName: canRetry && onRetry != nil ? "arrow.clockwise.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: side > 70 ? 30 : 24))
                        .foregroundStyle(Color.white, PocketPalette.danger)
                }
                .buttonStyle(.plain)
                .disabled(!(canRetry && onRetry != nil))
                .accessibilityLabel(canRetry && onRetry != nil ? "Try \(item.filename) again" : "\(item.filename) was not sent")
                .accessibilityIdentifier("pocket.room.media.item.retry")
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(item.isFailed ? PocketPalette.danger : PocketPalette.separator.opacity(0.7),
                        lineWidth: item.isFailed ? 1.5 : 0.5)
        )
        .overlay(alignment: .topTrailing) {
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.white, Color.black.opacity(0.6))
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(item.filename)")
                .accessibilityIdentifier("pocket.room.media.item.remove")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityIdentifier("pocket.room.media.item")
    }

    @ViewBuilder
    private var picture: some View {
        if let data = item.thumbnail, let image = RoomImageData.image(from: data) {
            image
                .resizable()
                .scaledToFill()
                .frame(width: side, height: side)
                .clipped()
                .accessibilityHidden(true)
        } else {
            VStack(spacing: 3) {
                Image(systemName: item.symbolName)
                    .font(.system(size: side > 70 ? 26 : 20, weight: .semibold))
                    .foregroundStyle(PocketPalette.accent)
                Text(((item.filename as NSString).pathExtension).uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(PocketPalette.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: side, height: side)
            .background(PocketPalette.inset)
            .accessibilityHidden(true)
        }
    }
}

/// Above the composer's field: what will go with the next message, each uploading already, and why something picked
/// was not added.
struct RoomMediaTray: View {
    @ObservedObject var board: RoomMediaBoard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let notice = board.notice {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(PocketPalette.danger)
                        .accessibilityHidden(true)
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(PocketPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button {
                        board.perform(.dismissNotice)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PocketPalette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("pocket.room.media.notice")
            }
            if !board.tray.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(board.tray) { item in
                            RoomMediaThumb(
                                item: item,
                                side: 64,
                                onRemove: { board.perform(.remove(itemId: item.id)) },
                                onRetry: { board.perform(.retryItem(itemId: item.id)) }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Attached, \(board.tray.count) of \(board.perMessageLimit)")
                .accessibilityIdentifier("pocket.room.media.tray")
            }
        }
    }
}

/// The composer's paperclip: opens the attach sheet, then hands the chosen source to the app.
struct RoomAttachButton: View {
    @ObservedObject var board: RoomMediaBoard
    @State private var showsSheet = false
    @State private var chosen: RoomAttachSource?
    @State private var canPaste = false

    var body: some View {
        Button {
            canPaste = board.canPaste()
            showsSheet = true
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(PocketPalette.textPrimary)
                .frame(width: 36, height: 36)
                .background(PocketPalette.raised, in: Circle())
                .overlay(Circle().stroke(PocketPalette.separator.opacity(0.8), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attach")
        .accessibilityHint("Adds photos, videos or files to your message")
        .accessibilityIdentifier("pocket.room.composer.attach")
        .sheet(isPresented: $showsSheet, onDismiss: {
            // The picker opens once this sheet has gone: one sheet at a time.
            if let source = chosen {
                chosen = nil
                board.perform(.choose(source))
            }
        }) {
            RoomAttachSheet(canUseCamera: board.canUseCamera, canPaste: canPaste, remaining: board.remainingSlots) { source in
                chosen = source
                showsSheet = false
            }
            // Tall enough for the four sources and the limits at the default text size, on a 375-point phone too.
            .presentationDetents([.height(450), .large])
        }
    }
}

/// The send button when files can go with a message: it sends as soon as there are words or files.
struct RoomMediaSendButton: View {
    @ObservedObject var board: RoomMediaBoard
    let canSendText: Bool
    let hasProblem: Bool
    let action: () -> Void

    var body: some View {
        let enabled = !hasProblem && (canSendText || !board.tray.isEmpty)
        Button(action: action) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(enabled ? PocketPalette.accent : PocketPalette.textSecondary.opacity(0.5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(board.tray.isEmpty ? "Send" : "Send with \(board.tray.count) attached")
        .accessibilityIdentifier("pocket.room.send")
    }
}

/// Messages with files on their way, in the room's own place for them (after the room's rows): each file's picture at
/// once, with real progress, Cancel while it goes, and Retry if it stopped. Each stays in place until the room shows it.
struct RoomMediaOutgoingList: View {
    @ObservedObject var board: RoomMediaBoard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(board.outgoing) { row in
                RoomMediaOutgoingCard(row: row, perform: board.perform)
                    .id("media:\(row.id)")
            }
        }
    }
}

struct RoomMediaOutgoingCard: View {
    let row: RoomMediaOutgoingRow
    let perform: (RoomMediaIntent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if row.items.count == 1, let item = row.items.first, item.kind != .file, let data = item.thumbnail,
               let image = RoomImageData.image(from: data) {
                single(item, image: image)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 84), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(row.items) { item in
                        RoomMediaThumb(item: item, side: 84,
                                       onRetry: row.canRetry ? { perform(.retry(clientId: row.id)) } : nil)
                    }
                }
            }
            if let text = row.text {
                ChatMarkdownView(text: text)
                    .font(.body)
                    .foregroundStyle(PocketPalette.textPrimary.opacity(row.isFailed ? 0.7 : 1))
            }
            statusLine
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(PocketPalette.listening.opacity(0.08))
        )
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pocket.room.media.outgoing")
    }

    /// One photo or video, shown as it will be in the room.
    private func single(_ item: RoomMediaItemRow, image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 240, maxHeight: 240, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                switch item.phase {
                case .preparing:
                    RoomMediaRing(progress: item.progress, isPreparing: true, diameter: 44)
                case .uploading:
                    RoomMediaRing(progress: item.progress, isPreparing: false, diameter: 44)
                case .uploaded:
                    if item.kind == .video {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(Color.white, Color.black.opacity(0.45))
                            .accessibilityHidden(true)
                    }
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.white, PocketPalette.danger)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.accessibilityLabel)
            .accessibilityIdentifier("pocket.room.media.item")
    }

    @ViewBuilder
    private var statusLine: some View {
        switch row.status {
        case .uploading:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    uploadingLabel
                    Spacer(minLength: 4)
                    cancelButton
                }
                VStack(alignment: .leading, spacing: 4) {
                    uploadingLabel
                    cancelButton
                }
            }
        case .posting:
            Label("Sending…", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(PocketPalette.textSecondary)
        case .sent:
            Label("Sent", systemImage: "checkmark")
                .font(.caption)
                .foregroundStyle(PocketPalette.textSecondary)
        case .failed(let reason, let canRetry):
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    failedLabel(reason)
                    failedButtons(canRetry)
                }
                VStack(alignment: .leading, spacing: 6) {
                    failedLabel(reason)
                    HStack(spacing: 16) { failedButtons(canRetry) }
                }
            }
        }
    }

    private var uploadingLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.circle")
                .accessibilityHidden(true)
            Text(row.statusText)
            Text("·").accessibilityHidden(true)
            RoomMediaBytesText(progress: row.progress)
        }
        .font(.caption)
        .foregroundStyle(PocketPalette.textSecondary)
        .accessibilityElement(children: .combine)
    }

    private var cancelButton: some View {
        Button("Cancel") { perform(.cancel(clientId: row.id)) }
            .font(.caption.weight(.semibold))
            .accessibilityLabel("Cancel sending")
            .accessibilityIdentifier("pocket.room.media.cancel")
    }

    private func failedLabel(_ reason: String) -> some View {
        Label(reason, systemImage: "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(PocketPalette.danger)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func failedButtons(_ canRetry: Bool) -> some View {
        if canRetry {
            Button("Retry") { perform(.retry(clientId: row.id)) }
                .font(.caption.weight(.semibold))
                .accessibilityIdentifier("pocket.room.media.retry")
        }
        Button("Discard", role: .destructive) { perform(.cancel(clientId: row.id)) }
            .font(.caption.weight(.semibold))
            .accessibilityIdentifier("pocket.room.media.discard")
    }
}
#endif
