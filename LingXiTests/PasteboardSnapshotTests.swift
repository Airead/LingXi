import AppKit
import Foundation
import Testing
@testable import LingXi

struct PasteboardSnapshotTests {

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("io.github.airead.lingxi.test.snapshot-\(UUID().uuidString)"))
    }

    @Test func capturesAndRestoresText() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("original", forType: .string)

        let snapshot = PasteboardSnapshot(pasteboard: pb)
        pb.clearContents()
        pb.setString("voice text", forType: .string)
        #expect(pb.string(forType: .string) == "voice text")

        snapshot.restore(to: pb)
        #expect(pb.string(forType: .string) == "original")
    }

    @Test func restoresAllTypesOfAnItem() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("plain", forType: .string)
        item.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        pb.writeObjects([item])

        let snapshot = PasteboardSnapshot(pasteboard: pb)
        pb.clearContents()
        pb.setString("voice text", forType: .string)

        snapshot.restore(to: pb)
        #expect(pb.string(forType: .string) == "plain")
        #expect(pb.data(forType: .png) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func emptySnapshotRestoresToEmptyPasteboard() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()

        let snapshot = PasteboardSnapshot(pasteboard: pb)
        #expect(snapshot.isEmpty)

        pb.setString("voice text", forType: .string)
        snapshot.restore(to: pb)
        #expect(pb.string(forType: .string) == nil)
    }

    @Test func delayedRestoreRunsWhenChangeCountMatches() async {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("original", forType: .string)

        let snapshot = PasteboardSnapshot(pasteboard: pb)
        pb.clearContents()
        pb.setString("voice text", forType: .string)
        let written = pb.changeCount

        await snapshot.restore(
            to: pb, after: .milliseconds(10), ifChangeCountEquals: written
        )
        #expect(pb.string(forType: .string) == "original")
    }

    @Test func delayedRestoreSkippedWhenPasteboardChangedAgain() async {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("original", forType: .string)

        let snapshot = PasteboardSnapshot(pasteboard: pb)
        pb.clearContents()
        pb.setString("voice text", forType: .string)
        let written = pb.changeCount

        // The user copies something new before the restore fires.
        pb.clearContents()
        pb.setString("user copy", forType: .string)

        await snapshot.restore(
            to: pb, after: .milliseconds(10), ifChangeCountEquals: written
        )
        #expect(pb.string(forType: .string) == "user copy")
    }
}
