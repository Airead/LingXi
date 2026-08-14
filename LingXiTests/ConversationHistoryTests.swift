import Foundation
import Testing
@testable import LingXi

// MARK: - Helpers

private func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("lingxi-history-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeRecord(
    timestamp: String = "2026-08-14T02:00:00Z",
    asr: String = "平平你好",
    final: String = "萍萍你好",
    mode: String = "proofread",
    previewEnabled: Bool = true
) -> ConversationRecord {
    ConversationRecord(
        timestamp: timestamp,
        asrText: asr,
        enhancedText: final == asr ? nil : final,
        finalText: final,
        enhanceMode: mode,
        previewEnabled: previewEnabled,
        asrModel: "apple",
        llmModel: "ollama/qwen3",
        userCorrected: final != asr,
        audioDuration: 2.5
    )
}

// MARK: - Record codable

struct ConversationRecordTests {

    @Test func encodesSnakeCaseKeys() throws {
        let data = try JSONEncoder().encode(makeRecord())
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["asr_text"] as? String == "平平你好")
        #expect(json["final_text"] as? String == "萍萍你好")
        #expect(json["enhance_mode"] as? String == "proofread")
        #expect(json["preview_enabled"] as? Bool == true)
        #expect(json["asr_model"] as? String == "apple")
        #expect(json["llm_model"] as? String == "ollama/qwen3")
        #expect(json["user_corrected"] as? Bool == true)
        #expect(json["audio_duration"] as? Double == 2.5)
    }

    @Test func roundTrips() throws {
        let record = makeRecord()
        let decoded = try JSONDecoder().decode(
            ConversationRecord.self, from: try JSONEncoder().encode(record)
        )
        #expect(decoded == record)
    }

    @Test func timestampIsISO8601UTC() {
        let stamp = ConversationRecord.makeTimestamp(Date(timeIntervalSince1970: 0))
        #expect(stamp == "1970-01-01T00:00:00Z")
    }
}

// MARK: - Recording and reading

struct ConversationHistoryStoreTests {

    @Test func recordAppendsDecodableLines() async {
        let history = ConversationHistory(directory: makeTempDirectory())
        await history.record(makeRecord(asr: "a", final: "b"))
        await history.record(makeRecord(asr: "c", final: "c"))

        let records = await history.readRecords()
        #expect(records.count == 2)
        #expect(records[0].asrText == "a")
        #expect(records[1].finalText == "c")
    }

    @Test func corruptLinesAreSkipped() async throws {
        let dir = makeTempDirectory()
        let history = ConversationHistory(directory: dir)
        await history.record(makeRecord(asr: "good", final: "good"))

        let file = dir.appendingPathComponent("conversation_history.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json at all\n".utf8))
        try handle.close()
        await history.record(makeRecord(asr: "after", final: "after"))

        let records = await history.readRecords()
        #expect(records.map(\.asrText) == ["good", "after"])
    }

    @Test func recordFailureDoesNotThrow() async {
        // A directory that cannot be created (parent is a file).
        let parent = makeTempDirectory().appendingPathComponent("blocker")
        try? Data().write(to: parent)
        let history = ConversationHistory(directory: parent.appendingPathComponent("sub"))
        await history.record(makeRecord())
        let records = await history.readRecords()
        #expect(records.isEmpty)
    }
}

// MARK: - Injection

struct ConversationHistoryInjectionTests {

    @Test func filtersByModeAndPreviewConfirmed() async {
        let history = ConversationHistory(directory: makeTempDirectory())
        await history.record(makeRecord(asr: "p1", final: "p1c", mode: "proofread"))
        await history.record(makeRecord(asr: "t1", final: "t1c", mode: "translate_en"))
        await history.record(makeRecord(asr: "d1", final: "d1", mode: "proofread", previewEnabled: false))

        let block = await history.injectionBlock(mode: "proofread")
        #expect(block?.contains("p1 → p1c") == true)
        #expect(block?.contains("t1") == false)
        #expect(block?.contains("d1") == false)
    }

    @Test func formatUsesArrowOnlyWhenCorrected() async {
        let history = ConversationHistory(directory: makeTempDirectory())
        await history.record(makeRecord(asr: "unchanged", final: "unchanged"))
        await history.record(makeRecord(asr: "typo", final: "fixed"))

        let block = await history.injectionBlock(mode: "proofread")
        let lines = block?.components(separatedBy: "\n") ?? []
        #expect(lines.first == ConversationHistory.injectionHeader)
        #expect(lines.contains("unchanged"))
        #expect(lines.contains("typo → fixed"))
    }

    @Test func emptyHistoryInjectsNothing() async {
        let history = ConversationHistory(directory: makeTempDirectory())
        #expect(await history.injectionBlock(mode: "proofread") == nil)
    }

    @Test func appendKeepsPreviousBlockAsStablePrefix() async throws {
        let history = ConversationHistory(
            directory: makeTempDirectory(),
            limits: .init(maxEntries: 2, refreshThreshold: 50, maxChars: 6000)
        )
        await history.record(makeRecord(asr: "a", final: "a"))
        let block1 = await history.injectionBlock(mode: "proofread")

        await history.record(makeRecord(asr: "b", final: "b"))
        let block2 = await history.injectionBlock(mode: "proofread")

        await history.record(makeRecord(asr: "c", final: "c"))
        let block3 = await history.injectionBlock(mode: "proofread")

        // Entries append at the tail; earlier blocks stay as prefixes even
        // beyond maxEntries (no rebuild until refreshThreshold).
        let b1 = try #require(block1)
        let b2 = try #require(block2)
        let b3 = try #require(block3)
        #expect(b2.hasPrefix(b1))
        #expect(b3.hasPrefix(b2))
        #expect(b3.contains("a") && b3.contains("b") && b3.contains("c"))
    }

    @Test func rebuildsToMaxEntriesAtRefreshThreshold() async {
        let history = ConversationHistory(
            directory: makeTempDirectory(),
            limits: .init(maxEntries: 2, refreshThreshold: 3, maxChars: 6000)
        )
        for name in ["a", "b", "c", "d"] {
            await history.record(makeRecord(asr: name, final: name))
        }
        // The list grew to 4 (>= 3), so it rebuilds to the last 2 records.
        let block = await history.injectionBlock(mode: "proofread")
        let lines = block?.components(separatedBy: "\n").dropFirst() ?? []
        #expect(Array(lines) == ["c", "d"])
    }

    @Test func rebuildsWhenCharBudgetExceeded() async {
        let history = ConversationHistory(
            directory: makeTempDirectory(),
            limits: .init(maxEntries: 1, refreshThreshold: 50, maxChars: 10)
        )
        await history.record(makeRecord(asr: "aaaaaaaaaa", final: "aaaaaaaaaa"))
        await history.record(makeRecord(asr: "bbbb", final: "bbbb"))
        let block = await history.injectionBlock(mode: "proofread")
        let lines = block?.components(separatedBy: "\n").dropFirst() ?? []
        #expect(Array(lines) == ["bbbb"])
    }

    @Test func unreadableFileMeansNoInjection() async {
        let history = ConversationHistory(directory: makeTempDirectory().appendingPathComponent("missing"))
        #expect(await history.injectionBlock(mode: "proofread") == nil)
    }
}

// MARK: - Rotation

struct ConversationHistoryRotationTests {

    @Test func archivesOverflowByMonthAndKeepsTail() async throws {
        let dir = makeTempDirectory()
        let history = ConversationHistory(
            directory: dir,
            limits: .init(rotationCheckBytes: 1, maxRecords: 2)
        )
        await history.record(makeRecord(timestamp: "2026-06-30T23:59:59Z", asr: "june", final: "june"))
        await history.record(makeRecord(timestamp: "2026-07-01T08:00:00Z", asr: "july-1", final: "july-1"))
        await history.record(makeRecord(timestamp: "2026-07-02T08:00:00Z", asr: "july-2", final: "july-2"))
        await history.record(makeRecord(timestamp: "2026-08-01T08:00:00Z", asr: "aug-1", final: "aug-1"))
        await history.record(makeRecord(timestamp: "2026-08-02T08:00:00Z", asr: "aug-2", final: "aug-2"))

        // Main file keeps only the newest two records.
        let kept = await history.readRecords()
        #expect(kept.map(\.asrText) == ["aug-1", "aug-2"])

        let archives = dir.appendingPathComponent("conversation_history_archives")
        let june = try String(contentsOf: archives.appendingPathComponent("2026-06.jsonl"), encoding: .utf8)
        #expect(june.contains("june"))
        let july = try String(contentsOf: archives.appendingPathComponent("2026-07.jsonl"), encoding: .utf8)
        #expect(july.contains("july-1") && july.contains("july-2"))
    }

    @Test func unparseableTimestampFallsBackToUnknownArchive() async throws {
        let dir = makeTempDirectory()
        let history = ConversationHistory(
            directory: dir,
            limits: .init(rotationCheckBytes: 1, maxRecords: 1)
        )
        await history.record(makeRecord(timestamp: "garbage", asr: "old", final: "old"))
        await history.record(makeRecord(timestamp: "2026-08-02T08:00:00Z", asr: "new", final: "new"))

        let unknown = dir.appendingPathComponent("conversation_history_archives/unknown.jsonl")
        let content = try String(contentsOf: unknown, encoding: .utf8)
        #expect(content.contains("old"))
        let kept = await history.readRecords()
        #expect(kept.map(\.asrText) == ["new"])
    }

    @Test func groupByMonthPreservesOrderWithinMonth() {
        let lines = [
            #"{"timestamp":"2026-07-01T00:00:00Z","x":1}"#,
            #"{"timestamp":"2026-07-02T00:00:00Z","x":2}"#,
            #"{"timestamp":"2026-08-01T00:00:00Z","x":3}"#,
            "not json",
        ]
        let groups = ConversationHistory.groupByMonth(lines)
        #expect(groups.map(\.month) == ["2026-07", "2026-08", "unknown"])
        #expect(groups[0].lines == [lines[0], lines[1]])
        #expect(groups[2].lines == ["not json"])
    }

    @Test func smallFileSkipsRotation() async {
        let dir = makeTempDirectory()
        // Default limits: rotation check requires 4 MB.
        let history = ConversationHistory(directory: dir)
        await history.record(makeRecord())
        await history.record(makeRecord())
        let archives = dir.appendingPathComponent("conversation_history_archives")
        #expect(!FileManager.default.fileExists(atPath: archives.path))
        #expect(await history.readRecords().count == 2)
    }
}
