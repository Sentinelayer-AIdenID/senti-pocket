import Combine
import Foundation
import XCTest
@testable import PocketUI

@MainActor
final class RoomMediaPresentationTests: XCTestCase {
    /// A photo taken back after it was sent is no picture any more: only its name and "Attachment removed".
    func test_a_removed_photo_is_no_picture_and_says_it_was_removed() {
        let photo = RoomAttachmentChip(attachmentId: "pm_photo_000001", filename: "IMG_0001.jpg", kind: .image,
                                       sizeBytes: 2_048)
        XCTAssertTrue(photo.isVisual)
        let removed = RoomAttachmentChip(attachmentId: "pm_photo_000001", filename: "IMG_0001.jpg", kind: .image,
                                         sizeBytes: 2_048, isRemoved: true)
        XCTAssertFalse(removed.isVisual, "no preview is shown or fetched")
        XCTAssertEqual(removed.accessibilityLabel, "Photo, IMG_0001.jpg, Attachment removed")
    }

    func test_a_message_with_only_files_says_what_it_shares() {
        XCTAssertEqual(RoomMediaOutgoingRow.defaultText(for: [.image]), "Shared a photo.")
        XCTAssertEqual(RoomMediaOutgoingRow.defaultText(for: [.image, .image, .image]), "Shared 3 photos.")
        XCTAssertEqual(RoomMediaOutgoingRow.defaultText(for: [.video]), "Shared a video.")
        XCTAssertEqual(RoomMediaOutgoingRow.defaultText(for: [.image, .video]), "Shared 2 files.")
        XCTAssertEqual(RoomMediaOutgoingRow.defaultText(for: [.file]), "Shared a file.")
    }

    func test_progress_is_real_bytes_and_stays_in_bounds() {
        let progress = RoomMediaProgress()
        XCTAssertEqual(progress.fraction, 0, "no size yet is no progress")
        progress.update(sent: 1_048_576, total: 4_194_304)
        XCTAssertEqual(progress.fraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(progress.text, "1 MB of 4 MB")
        progress.update(sent: 9_000_000, total: 4_194_304)
        XCTAssertEqual(progress.fraction, 1)
    }

    func test_the_outgoing_line_says_how_far_it_has_got() {
        let items = (0..<3).map { index in
            RoomMediaItemRow(id: "pm_item_\(index)00000", filename: "IMG_\(index).jpg", kind: .image,
                             phase: index == 0 ? .uploaded : .uploading, progress: RoomMediaProgress())
        }
        var row = RoomMediaOutgoingRow(id: "hm_message01", text: nil, items: items, progress: RoomMediaProgress())
        XCTAssertEqual(row.statusText, "Uploaded 1 of 3")
        row.status = .failed(reason: "Not sent. Check your connection.", canRetry: true)
        XCTAssertTrue(row.canRetry)
        XCTAssertEqual(row.statusText, "Not sent. Check your connection.")
        XCTAssertEqual(items[1].accessibilityLabel, "Photo, IMG_1.jpg, uploading")
    }

    func test_the_board_changes_only_when_its_rows_do() {
        let board = RoomMediaBoard()
        var changes = 0
        let watch = board.objectWillChange.sink { changes += 1 }
        let progress = RoomMediaProgress()
        let item = RoomMediaItemRow(id: "pm_item_000000", filename: "a.jpg", kind: .image, phase: .uploading, progress: progress)
        board.setTray([item])
        board.setTray([item])
        progress.update(sent: 10, total: 100)
        XCTAssertEqual(changes, 1, "a progress tick never redraws what reads the board")
        XCTAssertEqual(board.remainingSlots, 4)
        board.setNotice("too big")
        board.setNotice("too big")
        XCTAssertEqual(changes, 2)
        watch.cancel()
    }

    func test_a_video_shows_as_a_picture_and_says_it_plays() {
        let video = RoomAttachmentChip(attachmentId: "pm_video_0001", filename: "demo.mov", kind: .video, sizeBytes: 3_000_000)
        XCTAssertTrue(video.isVisual)
        XCTAssertEqual(video.kindLabel, "Video")
        XCTAssertEqual(video.accessibilityHint, "Plays it")
        let photo = RoomAttachmentChip(attachmentId: "pm_photo_0001", filename: "a.jpg", kind: .image)
        XCTAssertTrue(photo.accessibilityLabel.hasPrefix("Photo, a.jpg"))
        XCTAssertFalse(RoomAttachmentChip(attachmentId: "doc-0001", filename: "a.pdf", kind: .pdf).isVisual)
    }

    /// Ticket 77fcdd2b: a file in the tray opens full screen before it is sent; Remove there takes only that one out,
    /// the others stay; once it has left the tray it closes; its row follows its upload while it is open.
    func test_a_file_in_the_tray_opens_and_remove_there_takes_only_it_out() {
        var asked: [RoomMediaIntent] = []
        let board = RoomMediaBoard(perform: { asked.append($0) })
        let photo = RoomMediaItemRow(id: "pm_1", filename: "site.jpg", kind: .image, phase: .uploading,
                                     progress: RoomMediaProgress(), localFile: URL(fileURLWithPath: "/tmp/site.jpg"))
        let pdf = RoomMediaItemRow(id: "pm_2", filename: "plan.pdf", kind: .file, phase: .uploading,
                                   progress: RoomMediaProgress(), localFile: URL(fileURLWithPath: "/tmp/plan.pdf"))
        board.setTray([photo, pdf])
        XCTAssertNil(board.opened)

        board.open("pm_2")
        XCTAssertEqual(board.opened?.id, "pm_2")
        XCTAssertEqual(board.opened?.localFile, URL(fileURLWithPath: "/tmp/plan.pdf"))
        XCTAssertTrue(asked.isEmpty, "opening sends and removes nothing")

        var uploaded = pdf
        uploaded.phase = .uploaded
        board.setTray([photo, uploaded])
        XCTAssertEqual(board.opened?.phase, .uploaded, "the open file follows its upload")

        board.removeOpened()
        XCTAssertNil(board.opened, "Remove closes the view")
        XCTAssertEqual(asked, [.remove(itemId: "pm_2")], "and takes only that file out")

        board.open("pm_1")
        board.closeOpened()
        XCTAssertNil(board.opened)
        XCTAssertEqual(asked, [.remove(itemId: "pm_2")], "Done removes nothing")

        board.open("pm_1")
        board.setTray([])
        XCTAssertNil(board.opened, "a file that left the tray closes")
        board.open("pm_9")
        XCTAssertNil(board.opened, "nothing opens for a file that is not in the tray")
    }
}
