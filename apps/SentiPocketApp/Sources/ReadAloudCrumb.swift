import Foundation
import ImageIO
import PocketUI
import UIKit

/// What a Read aloud happened in, for the freeze recorder: where it was started, the thread open at the time, the text
/// size, the images on what is read, and how often the reader had just changed. Never what is read, nor who wrote it.
/// Carter's phone stopped for 19 s right after a Read aloud (11-05) and its trail said only "readAloud (75 rows)".
struct ReadAloudCrumb: Equatable {
    enum Origin: String {
        case message, reply, summary, other
    }

    let origin: Origin
    let rows: Int
    /// The thread open in its sheet, if one is: how many replies and how deep they nest.
    let threadReplies: Int?
    let threadDepth: Int
    /// The text size, as the phone names it ("L", "XXXL", "AccessibilityXXXL").
    let textSize: String
    /// Images on what is read, and the largest one's pixel size when the room has its picture.
    let images: Int
    let largestImage: (width: Int, height: Int)?
    /// How many times the reader changed in the ten seconds before.
    let readerChanges: Int

    static func == (lhs: ReadAloudCrumb, rhs: ReadAloudCrumb) -> Bool { lhs.step == rhs.step }

    /// "readAloud (75 rows, reply, thread open with 14 replies 3 deep, text size L, 1 image 1320×2868, reader changed
    /// 0 times in 10 s)".
    var step: String {
        var details = ["\(rows) rows", origin.rawValue]
        if let threadReplies {
            let replies = "\(threadReplies) \(threadReplies == 1 ? "reply" : "replies")"
            details.append("thread open with \(replies) \(threadDepth) deep")
        } else {
            details.append("no thread open")
        }
        details.append("text size \(textSize)")
        if images > 0 {
            let size = largestImage.map { " \($0.width)×\($0.height)" } ?? ""
            details.append("\(images) \(images == 1 ? "image" : "images")\(size)")
        }
        details.append("reader changed \(readerChanges) \(readerChanges == 1 ? "time" : "times") in 10 s")
        return "readAloud (\(details.joined(separator: ", ")))"
    }

    /// Where a read-aloud id was started from.
    static func origin(of id: String) -> Origin {
        if id.hasPrefix("msg:") { return .message }
        if id.hasPrefix("reply:") { return .reply }
        if id.hasPrefix("summary:") { return .summary }
        return .other
    }

    /// The phone's text size without its prefix: "UICTContentSizeCategoryAccessibilityXXXL" is "AccessibilityXXXL".
    static func textSize(_ category: UIContentSizeCategory) -> String {
        let name = category.rawValue
        let prefix = "UICTContentSizeCategory"
        return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
    }

    /// An image's pixel size from its header, without decoding it.
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// The crumb for reading `id` aloud in `state`, with the reader's changes counted by `changes`.
    static func make(id: String, state: RoomChatPresentationState, textSize: UIContentSizeCategory,
                     readerChanges: Int) -> ReadAloudCrumb {
        var chips: [RoomAttachmentChip] = []
        if id.hasPrefix("msg:"), let sequence = Int64(id.dropFirst("msg:".count)),
           case .message(let row)? = state.messageRow(for: sequence) {
            chips = row.attachments
        } else if id.hasPrefix("reply:") {
            let replyId = String(id.dropFirst("reply:".count))
            if let reply = state.thread?.replies.first(where: { $0.id == replyId }) {
                chips = reply.attachments
            } else if let row = state.rows.lazy.compactMap({ row -> RoomChatMessageRow? in
                if case .message(let message) = row, message.inlineReplyId == replyId { return message }
                return nil
            }).first {
                chips = row.attachments
            }
        }
        let images = chips.filter { $0.kind == .image }
        let sizes = images.compactMap { state.attachmentPreviews[$0.attachmentId].flatMap(pixelSize(of:)) }
        let largest = sizes.max { $0.width * $0.height < $1.width * $1.height }
        let depth = state.thread?.replies.map(\.depth).max() ?? 0
        return ReadAloudCrumb(origin: origin(of: id), rows: state.rows.count,
                              threadReplies: state.thread?.replies.count, threadDepth: depth,
                              textSize: Self.textSize(textSize), images: images.count, largestImage: largest,
                              readerChanges: readerChanges)
    }
}

/// When the reader changed, kept without redrawing the room, so a Read aloud can say how often it had just changed.
final class ReaderChangeLog {
    private var times: [Date] = []

    func record(_ date: Date = Date()) {
        times.append(date)
        if times.count > 200 { times.removeFirst(times.count - 200) }
    }

    func count(within seconds: TimeInterval, of date: Date = Date()) -> Int {
        times.filter { date.timeIntervalSince($0) <= seconds }.count
    }
}
