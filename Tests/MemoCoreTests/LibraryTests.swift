import Foundation
import Testing
@testable import MemoCore

@Suite("Library")
struct LibraryTests {
    let folder = Fixtures.Folder()
    var libraryURL: URL { folder.url.appendingPathComponent("Recordings", isDirectory: true) }
    var scratch: URL { folder.sub("scratch") }

    private func rows() -> [Fixtures.Row] {
        [
            .init(pk: 1, id: "AAA", title: "Lab meeting", date: Fixtures.date, duration: 1834.5, path: "20260430 094100.m4a", folder: 1),
            .init(pk: 2, id: "BBB", title: nil, label: "Grocery idea", date: Fixtures.date.addingTimeInterval(3600), duration: 12, path: "20260430 104100.m4a"),
            .init(pk: 3, id: "CCC", title: "Old take", date: Fixtures.date.addingTimeInterval(-86400), duration: 30, path: "20260429 094100.m4a", deleted: true),
            .init(pk: 4, id: nil, title: "  ", date: Fixtures.date.addingTimeInterval(-3600), duration: -1, path: "/private/var/mobile/Recordings/20260430 084100.m4a"),
        ]
    }

    @Test func readsRecordingsNewestFirst() throws {
        try Fixtures.library(in: libraryURL, rows: rows(), folders: [(1, "Research")])
        let memos = try VoiceMemosLibrary(folder: libraryURL).memos(scratch: scratch)
        #expect(memos.map(\.id) == ["BBB", "AAA", "recording-4"])
        #expect(memos[1] == Memo(id: "AAA", title: "Lab meeting", date: Fixtures.date, duration: 1834.5, folder: "Research", fileName: "20260430 094100.m4a"))
    }

    @Test func titlesFallBackToTheLabelThenANewRecording() throws {
        try Fixtures.library(in: libraryURL, rows: rows())
        let memos = try VoiceMemosLibrary(folder: libraryURL).memos(scratch: scratch)
        #expect(memos[0].title == "Grocery idea")
        #expect(memos[2].title == "New Recording")
        #expect(memos[2].duration == 0)
    }

    @Test func leavesOutRecentlyDeleted() throws {
        try Fixtures.library(in: libraryURL, rows: rows())
        let memos = try VoiceMemosLibrary(folder: libraryURL).memos(scratch: scratch)
        #expect(!memos.contains { $0.id == "CCC" })
    }

    @Test func pathsAreJustFileNames() throws {
        try Fixtures.library(in: libraryURL, rows: rows())
        let memos = try VoiceMemosLibrary(folder: libraryURL).memos(scratch: scratch)
        #expect(memos[2].fileName == "20260430 084100.m4a")
    }

    @Test func readsRecordingsStillInTheLog() throws {
        // Voice Memos' newest recordings are often only in the write-ahead log.
        try Fixtures.library(in: libraryURL, rows: rows(), inLog: true)
        let log = try FileManager.default.attributesOfItem(atPath: libraryURL.appendingPathComponent("CloudRecordings.db-wal").path)[.size] as? Int
        #expect((log ?? 0) > 0)
        let memos = try VoiceMemosLibrary(folder: libraryURL).memos(scratch: scratch)
        #expect(memos.count == 3)
    }

    @Test func neverTouchesTheLibrary() throws {
        try Fixtures.library(in: libraryURL, rows: rows(), inLog: true)
        try Fixtures.recording(transcript: Fixtures.transcriptJSON(Fixtures.lecture)).write(to: libraryURL.appendingPathComponent("20260430 094100.m4a"))
        let before = try snapshot(libraryURL)
        let library = VoiceMemosLibrary(folder: libraryURL)
        for _ in 0..<2 {
            let memos = try library.memos(scratch: scratch)
            _ = try memos.map { try library.transcript(for: $0) }
        }
        #expect(try snapshot(libraryURL) == before)
    }

    private func snapshot(_ url: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
            files[name] = try Data(contentsOf: url.appendingPathComponent(name))
        }
        return files
    }

    @Test func duplicateIDsAreReadOnce() throws {
        try Fixtures.library(in: libraryURL, rows: [
            .init(pk: 1, id: "SAME", title: "Older", date: Fixtures.date, duration: 1, path: "a.m4a"),
            .init(pk: 2, id: "SAME", title: "Newer", date: Fixtures.date.addingTimeInterval(9), duration: 1, path: "b.m4a"),
            .init(pk: 3, id: "ODD", title: "Damaged", date: Fixtures.date.addingTimeInterval(1e20), duration: 5, path: "c.m4a"),
            .init(pk: 4, id: "LONG", title: "Long", date: Fixtures.date, duration: 1e300, path: "d.m4a"),
        ])
        let memos = try VoiceMemosLibrary(folder: libraryURL).memos(scratch: scratch)
        #expect(memos.map(\.title) == ["Newer", "Long"])
        #expect(memos[1].duration == 10_000_000)
    }

    @Test func readsAtTheSameTimeDontCollide() async throws {
        try Fixtures.library(in: libraryURL, rows: rows(), inLog: true)
        let library = VoiceMemosLibrary(folder: libraryURL), scratch = scratch
        let counts = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<6 {
                group.addTask { (try? library.memos(scratch: scratch).count) ?? -1 }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(counts == Array(repeating: 3, count: 6))
    }

    @Test func lastChangeNoticesRecordings() throws {
        try Fixtures.library(in: libraryURL, rows: rows())
        let library = VoiceMemosLibrary(folder: libraryURL)
        let before = try #require(library.lastChange())
        let audio = libraryURL.appendingPathComponent("20260430 094100.m4a")
        try Data([1]).write(to: audio)
        try FileManager.default.setAttributes([.modificationDate: before.addingTimeInterval(120)], ofItemAtPath: audio.path)
        #expect(try #require(library.lastChange()) > before.addingTimeInterval(100))
        #expect(library.snapshotStamp() == library.snapshotStamp())
    }

    @Test func aMissingLibrary() {
        #expect(throws: LibraryError.notFound) { try VoiceMemosLibrary(folder: libraryURL).memos(scratch: scratch) }
        try? FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        #expect(throws: LibraryError.notFound) { try VoiceMemosLibrary(folder: libraryURL).memos(scratch: scratch) }
    }

    @Test func anUnreadableLibraryNeedsPermission() throws {
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: libraryURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: libraryURL.path) }
        #expect(throws: LibraryError.noPermission) { try VoiceMemosLibrary(folder: libraryURL).memos(scratch: scratch) }
    }

    @Test func anUnfamiliarDatabase() throws {
        try Fixtures.library(in: libraryURL, rows: [], columns: "Z_PK INTEGER PRIMARY KEY, ZTITLE VARCHAR")
        #expect(throws: LibraryError.unrecognized("The Voice Memos database has no ZDATE column.")) {
            try VoiceMemosLibrary(folder: libraryURL).memos(scratch: scratch)
        }
    }

    @Test func aDatabaseWithFewerColumnsStillReads() throws {
        try Fixtures.library(in: libraryURL, rows: [], columns: "Z_PK INTEGER PRIMARY KEY, ZDATE TIMESTAMP, ZPATH VARCHAR")
        #expect(try VoiceMemosLibrary(folder: libraryURL).memos(scratch: scratch).isEmpty)
    }

    @Test func aDamagedDatabase() throws {
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        try Data("not a database at all, just text".utf8).write(to: libraryURL.appendingPathComponent("CloudRecordings.db"))
        #expect {
            try VoiceMemosLibrary(folder: libraryURL).memos(scratch: scratch)
        } throws: { error in
            if case LibraryError.unrecognized = error { return true }
            return false
        }
    }

    @Test func theLibraryIsInTheGroupContainer() {
        let library = VoiceMemosLibrary(home: URL(fileURLWithPath: "/Users/example"))
        #expect(library.folder.path == "/Users/example/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings")
        #expect(VoiceMemosLibrary.realHome.path.hasPrefix("/"))
        #expect(!VoiceMemosLibrary.realHome.path.contains("/Containers/"))
    }

    // MARK: Audio and transcripts

    @Test func audioMustBeARegularFileInsideTheLibrary() throws {
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        try Data([1]).write(to: libraryURL.appendingPathComponent("a.m4a"))
        try FileManager.default.createDirectory(at: libraryURL.appendingPathComponent("b.m4a"), withIntermediateDirectories: true)
        let library = VoiceMemosLibrary(folder: libraryURL)
        #expect(library.audioURL(for: Fixtures.memo(fileName: "a.m4a"))?.lastPathComponent == "a.m4a")
        #expect(library.audioURL(for: Fixtures.memo(fileName: "b.m4a")) == nil)
        #expect(library.audioURL(for: Fixtures.memo(fileName: "missing.m4a")) == nil)
        #expect(library.audioURL(for: Fixtures.memo(fileName: "../a.m4a")) == nil)
        #expect(library.audioURL(for: Fixtures.memo(fileName: ".hidden.m4a")) == nil)
        #expect(library.audioURL(for: Fixtures.memo(fileName: nil)) == nil)
    }

    @Test func readsTranscriptsFromRecordings() throws {
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        try Fixtures.recording(transcript: Fixtures.transcriptJSON(Fixtures.lecture)).write(to: libraryURL.appendingPathComponent("with.m4a"))
        try Fixtures.recording(transcript: nil).write(to: libraryURL.appendingPathComponent("without.m4a"))
        try Fixtures.recording(transcript: Data("{}".utf8)).write(to: libraryURL.appendingPathComponent("broken.m4a"))
        let library = VoiceMemosLibrary(folder: libraryURL)
        #expect(try library.transcript(for: Fixtures.memo(fileName: "with.m4a"))?.words.count == Fixtures.lecture.count)
        #expect(try library.transcript(for: Fixtures.memo(fileName: "without.m4a")) == nil)
        #expect(try library.transcript(for: Fixtures.memo(fileName: "missing.m4a")) == nil)
        #expect(throws: TranscriptError.unrecognized) { try library.transcript(for: Fixtures.memo(fileName: "broken.m4a")) }
    }

    @Test func aTruncatedRecording() throws {
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        let whole = Fixtures.recording(transcript: Fixtures.transcriptJSON(Fixtures.lecture))
        try whole.prefix(whole.count - 50).write(to: libraryURL.appendingPathComponent("cut.m4a"))
        #expect(throws: AtomError.truncated) { try VoiceMemosLibrary(folder: libraryURL).transcript(for: Fixtures.memo(fileName: "cut.m4a")) }
    }

    @Test func fileSourceReadsPieces() throws {
        let url = folder.url.appendingPathComponent("bytes")
        try Data([0, 1, 2, 3, 4, 5]).write(to: url)
        let file = try FileSource(url)
        defer { file.close() }
        #expect(file.count == 6)
        #expect(try file.read(at: 2, length: 3) == Data([2, 3, 4]))
        #expect(throws: AtomError.truncated) { try file.read(at: 5, length: 2) }
    }
}
