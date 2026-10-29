import Foundation
import Testing
@testable import MemoCore

@Suite("Exporting")
struct ExporterTests {
    let folder = Fixtures.Folder()
    var destination: URL { folder.url.appendingPathComponent("Notes", isDirectory: true) }
    let transcript = Transcript(words: Fixtures.lecture.map { Word($0.0, start: $0.1, end: $0.2) }, locale: "en_US")

    /// A source with each memo's audio as a small file in the throwaway folder.
    private func source(_ memos: [Memo], transcripts: [String: Transcript] = [:]) throws -> FakeSource {
        let audio = folder.sub("audio")
        var source = FakeSource(transcripts: transcripts)
        for memo in memos {
            let url = audio.appendingPathComponent("\(memo.id).m4a")
            try Data("audio of \(memo.id)".utf8).write(to: url)
            source.audio[memo.id] = url
        }
        return source
    }

    private func exporter(_ options: ExportOptions = ExportOptions(renderer: Fixtures.renderer)) -> Exporter {
        Exporter(destination: destination, options: options)
    }

    private func files(_ sub: String = "") throws -> [String] {
        // The lock file is always there once an export has run, and never holds anything.
        try FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent(sub).path).filter { $0 != ".memo-export.lock" }.sorted()
    }

    private func note(_ name: String) throws -> String {
        try String(contentsOf: destination.appendingPathComponent(name + ".md"), encoding: .utf8)
    }

    @Test func exportsAudioAndNotes() throws {
        let memos = [Fixtures.memo("A1"), Fixtures.memo("B2", title: "Grocery idea", date: Fixtures.date.addingTimeInterval(86400))]
        let source = try source(memos, transcripts: ["A1": transcript])
        let report = try exporter().export(memos, from: source)
        #expect(report.exported == ["Lecture: synaptic plasticity", "Grocery idea"])
        #expect(try files() == [
            ".memo-export.json", "2026-04-30 Lecture synaptic plasticity.m4a", "2026-04-30 Lecture synaptic plasticity.md",
            "2026-05-01 Grocery idea.m4a", "2026-05-01 Grocery idea.md",
        ])
        let lecture = try note("2026-04-30 Lecture synaptic plasticity")
        #expect(lecture.contains("![[2026-04-30 Lecture synaptic plasticity.m4a]]"))
        #expect(lecture.contains("**0:05** When two neurons"))
        #expect(try note("2026-05-01 Grocery idea").contains("*No transcript yet."))
        let audio = destination.appendingPathComponent("2026-04-30 Lecture synaptic plasticity.m4a")
        #expect(try Data(contentsOf: audio) == Data("audio of A1".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: audio.path)
        #expect(attributes[.modificationDate] as? Date == Fixtures.date)
        #expect(attributes[.creationDate] as? Date == Fixtures.date)
    }

    @Test func aRerunExportsOnlyNewMemos() throws {
        let first = [Fixtures.memo("A1")]
        let all = first + [Fixtures.memo("B2", title: "Second", date: Fixtures.date.addingTimeInterval(60))]
        let source = try source(all, transcripts: ["A1": transcript])
        _ = try exporter().export(first, from: source)
        #expect(try exporter().newMemos(all).map(\.id) == ["B2"])
        let report = try exporter().export(all, from: source)
        #expect(report.exported == ["Second"])
        #expect(report.unchanged == 1)
        let again = try exporter().export(all, from: source)
        #expect(again.exported.isEmpty && again.updated.isEmpty)
        #expect(again.unchanged == 2)
        #expect(Describe.summary(again) == "No new memos")
    }

    @Test func aTranscriptThatArrivesLaterIsAdded() throws {
        let memos = [Fixtures.memo("A1")]
        var source = try source(memos)
        _ = try exporter().export(memos, from: source)
        source.transcripts["A1"] = transcript
        let report = try exporter().export(memos, from: source)
        #expect(report.updated == ["Lecture: synaptic plasticity"])
        #expect(try note("2026-04-30 Lecture synaptic plasticity").contains("**0:00** Today"))
        // A rename shows up too, but the file keeps its name so links to it still work.
        let renamed = [Fixtures.memo("A1", title: "LTP lecture")]
        #expect(try exporter().export(renamed, from: source).updated == ["LTP lecture"])
        #expect(try note("2026-04-30 Lecture synaptic plasticity").contains("title: \"LTP lecture\""))
    }

    @Test func notesYouEditedAreNeverOverwritten() throws {
        let memos = [Fixtures.memo("A1")]
        var source = try source(memos)
        _ = try exporter().export(memos, from: source)
        let url = destination.appendingPathComponent("2026-04-30 Lecture synaptic plasticity.md")
        try (try note("2026-04-30 Lecture synaptic plasticity") + "\nMy own notes.\n").write(to: url, atomically: true, encoding: .utf8)
        source.transcripts["A1"] = transcript
        let report = try exporter().export(memos, from: source)
        #expect(report.updated.isEmpty)
        #expect(try note("2026-04-30 Lecture synaptic plasticity").hasSuffix("My own notes.\n"))
    }

    @Test func notesYouDeletedStayDeleted() throws {
        let memos = [Fixtures.memo("A1")]
        let source = try source(memos, transcripts: ["A1": transcript])
        _ = try exporter().export(memos, from: source)
        try FileManager.default.removeItem(at: destination.appendingPathComponent("2026-04-30 Lecture synaptic plasticity.md"))
        try FileManager.default.removeItem(at: destination.appendingPathComponent("2026-04-30 Lecture synaptic plasticity.m4a"))
        let report = try exporter().export(memos, from: source)
        #expect(report.exported.isEmpty && report.updated.isEmpty)
        #expect(try files() == [".memo-export.json"])
    }

    @Test func yourFilesAreNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "mine".write(to: destination.appendingPathComponent("2026-04-30 Lecture synaptic plasticity.md"), atomically: true, encoding: .utf8)
        try "mine too".write(to: destination.appendingPathComponent("2026-04-30 Lecture synaptic plasticity (2).m4a"), atomically: true, encoding: .utf8)
        let memos = [Fixtures.memo("A1")]
        _ = try exporter().export(memos, from: try source(memos))
        #expect(try note("2026-04-30 Lecture synaptic plasticity") == "mine")
        #expect(try files().contains("2026-04-30 Lecture synaptic plasticity (3).md"))
        #expect(try files().contains("2026-04-30 Lecture synaptic plasticity (3).m4a"))
    }

    @Test func memosWithTheSameNameGetNumbers() throws {
        let memos = (1...3).map { Fixtures.memo("M\($0)", title: "New Recording", date: Fixtures.date.addingTimeInterval(Double($0))) }
        _ = try exporter().export(memos, from: try source(memos))
        #expect(try files().filter { $0.hasSuffix(".md") } == [
            "2026-04-30 New Recording (2).md", "2026-04-30 New Recording (3).md", "2026-04-30 New Recording.md",
        ])
    }

    @Test func namesDifferingOnlyInCaseAreKeptApart() throws {
        let memos = [Fixtures.memo("A", title: "Ideas"), Fixtures.memo("B", title: "ideas", date: Fixtures.date.addingTimeInterval(1))]
        _ = try exporter(ExportOptions(audio: false, renderer: Fixtures.renderer)).export(memos, from: try source(memos))
        #expect(try files().filter { $0.hasSuffix(".md") }.count == 2)
    }

    @Test func subtitlesAndOptions() throws {
        let memos = [Fixtures.memo("A1"), Fixtures.memo("B2", title: "No words", date: Fixtures.date.addingTimeInterval(9))]
        let options = ExportOptions(audio: false, subtitles: true, renderer: Fixtures.renderer)
        _ = try exporter(options).export(memos, from: try source(memos, transcripts: ["A1": transcript]))
        #expect(try files() == [".memo-export.json", "2026-04-30 Lecture synaptic plasticity.md", "2026-04-30 Lecture synaptic plasticity.srt", "2026-04-30 No words.md"])
        #expect(!(try note("2026-04-30 Lecture synaptic plasticity")).contains("![["))
    }

    @Test func turningOnSubtitlesOrAudioLaterFillsThemIn() throws {
        let memos = [Fixtures.memo("A1")]
        let source = try source(memos, transcripts: ["A1": transcript])
        _ = try exporter(ExportOptions(audio: false, renderer: Fixtures.renderer)).export(memos, from: source)
        let report = try exporter(ExportOptions(audio: true, subtitles: true, renderer: Fixtures.renderer)).export(memos, from: source)
        #expect(report.updated == ["Lecture: synaptic plasticity"])
        #expect(try files() == [".memo-export.json", "2026-04-30 Lecture synaptic plasticity.m4a", "2026-04-30 Lecture synaptic plasticity.md", "2026-04-30 Lecture synaptic plasticity.srt"])
        #expect(try note("2026-04-30 Lecture synaptic plasticity").contains("![[2026-04-30 Lecture synaptic plasticity.m4a]]"))
    }

    @Test func byFolder() throws {
        let memos = [Fixtures.memo("A1", folder: "Neuro: 3101"), Fixtures.memo("B2", title: "Loose", date: Fixtures.date.addingTimeInterval(1))]
        let options = ExportOptions(byFolder: true, renderer: Fixtures.renderer)
        _ = try exporter(options).export(memos, from: try source(memos))
        #expect(try files() == [".memo-export.json", "2026-04-30 Loose.m4a", "2026-04-30 Loose.md", "Neuro 3101"])
        #expect(try files("Neuro 3101") == ["2026-04-30 Lecture synaptic plasticity.m4a", "2026-04-30 Lecture synaptic plasticity.md"])
    }

    @Test func memosNotDownloadedWaitForICloud() throws {
        let memos = [Fixtures.memo("A1"), Fixtures.memo("B2", title: "Elsewhere", fileName: "remote.m4a"), Fixtures.memo("C3", title: "No file", fileName: nil)]
        var source = try source([memos[0]])
        let report = try exporter().export(memos, from: source)
        #expect(report.exported == ["Lecture: synaptic plasticity"])
        #expect(report.waiting == ["Elsewhere"])
        #expect(report.failed.map(\.title) == ["No file"])
        #expect(Describe.summary(report) == "Exported 1 new memo, 1 waiting for iCloud, 1 failed")
        // Once it downloads, the next export picks it up.
        let downloaded = folder.url.appendingPathComponent("remote.m4a")
        try Data("late".utf8).write(to: downloaded)
        source.audio["B2"] = downloaded
        #expect(try exporter().export(memos, from: source).exported == ["Elsewhere"])
    }

    @Test func anUnreadableTranscriptStillExportsTheAudio() throws {
        let memos = [Fixtures.memo("A1")]
        var source = try source(memos)
        source.broken = ["A1"]
        let report = try exporter().export(memos, from: source)
        #expect(report.exported.count == 1)
        #expect(try note("2026-04-30 Lecture synaptic plasticity").contains("*No transcript yet."))
    }

    @Test func refusesToWriteIntoTheLibrary() throws {
        let library = folder.sub("Recordings")
        let inside = Exporter(destination: library.appendingPathComponent("out"), options: ExportOptions())
        #expect(throws: ExportError.insideLibrary) { try inside.export([], from: FakeSource(), protected: [library]) }
        let same = Exporter(destination: library, options: ExportOptions())
        #expect(throws: ExportError.insideLibrary) { try same.export([], from: FakeSource(), protected: [library]) }
        // A link to the library is followed.
        let link = folder.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: library)
        let linked = Exporter(destination: link.appendingPathComponent("out"), options: ExportOptions())
        #expect(throws: ExportError.insideLibrary) { try linked.export([], from: FakeSource(), protected: [library]) }
        // A sibling whose name starts the same way is fine.
        #expect(!Exporter.isInside(folder.url.appendingPathComponent("Recordings Export"), library))
    }

    @Test func aDamagedRecordStopsTheExport() throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "{ not json".write(to: destination.appendingPathComponent(".memo-export.json"), atomically: true, encoding: .utf8)
        let memos = [Fixtures.memo("A1")]
        #expect(throws: ExportError.unreadableRecord) { try exporter().export(memos, from: try source(memos)) }
        #expect(try files() == [".memo-export.json"])
    }

    @Test func aRecordFromANewerVersionStopsTheExport() throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try #"{"version": 9, "memos": {}, "future": true}"#.write(to: destination.appendingPathComponent(".memo-export.json"), atomically: true, encoding: .utf8)
        #expect(throws: ExportError.newerRecord) { try exporter().export([], from: FakeSource()) }
    }

    @Test func theRecordIsReadable() throws {
        let memos = [Fixtures.memo("A1")]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try exporter().export(memos, from: try source(memos), now: now)
        let record = try exporter().loadRecord()
        #expect(record.version == 1)
        let entry = try #require(record.memos["A1"])
        #expect(entry.path == "2026-04-30 Lecture synaptic plasticity")
        #expect(entry.audio && !entry.subtitles)
        #expect(entry.sourceHash != nil)
        #expect(entry.exported == now)
        let text = try String(contentsOf: destination.appendingPathComponent(".memo-export.json"), encoding: .utf8)
        #expect(text.contains("\"path\" : \"2026-04-30 Lecture synaptic plasticity\""))
    }

    @Test func reportsProgress() throws {
        let memos = (1...3).map { Fixtures.memo("M\($0)", date: Fixtures.date.addingTimeInterval(Double($0))) }
        var seen: [Int] = []
        _ = try exporter().export(memos, from: try source(memos)) { done, total in
            #expect(total == 3)
            seen.append(done)
        }
        #expect(seen == [1, 2, 3])
    }

    @Test func aFolderItCantCreate() throws {
        let file = folder.url.appendingPathComponent("plain-file")
        try Data().write(to: file)
        let exporter = Exporter(destination: file.appendingPathComponent("sub"), options: ExportOptions())
        #expect {
            try exporter.export([], from: FakeSource())
        } throws: { error in
            if case ExportError.cannotWrite = error { return true }
            return false
        }
    }

    // MARK: Damage and mishaps

    @Test func aRecordThatPointsOutsideIsRefused() throws {
        let memos = [Fixtures.memo("A1")]
        let source = try source(memos, transcripts: ["A1": transcript])
        _ = try exporter().export(memos, from: source)
        let outside = folder.url.appendingPathComponent("victim.md")
        try "keep me".write(to: outside, atomically: true, encoding: .utf8)
        let good = try exporter().loadRecord()
        for path in ["../victim", "/tmp/victim", "a/b/c", ".hidden", "a//b", "", "a/../b", "sub/.x"] {
            var record = good
            record.memos["A1"]?.path = path
            record.memos["A1"]?.markdownHash = Exporter.hash(Data("keep me".utf8))
            try exporter().saveRecord(record)
            #expect(throws: ExportError.unreadableRecord, "\(path)") { try exporter().export(memos, from: source) }
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "keep me")
        #expect(!FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("victim.m4a").path))
        #expect(Exporter.isSafePath("2026-04-30 Lecture"))
        #expect(Exporter.isSafePath("Neuro/2026-04-30 Lecture"))
    }

    @Test func neverWritesIntoALibraryBelowTheFolder() throws {
        // Exporting into the folder that holds the library, grouped by a Voice Memos folder that
        // happens to share the library's name.
        let parent = folder.sub("Group")
        let library = parent.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let memos = [Fixtures.memo("A1", folder: "Recordings")]
        let exporter = Exporter(destination: parent, options: ExportOptions(byFolder: true, renderer: Fixtures.renderer))
        let report = try exporter.export(memos, from: try source(memos), protected: [library])
        #expect(report.exported.isEmpty)
        #expect(report.failed.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.path).isEmpty)
    }

    @Test func aLostRecordDoesntDuplicate() throws {
        let memos = [Fixtures.memo("A1"), Fixtures.memo("B2", title: "Second", date: Fixtures.date.addingTimeInterval(60), folder: "Lab")]
        var source = try source(memos, transcripts: ["A1": transcript])
        let options = ExportOptions(byFolder: true, renderer: Fixtures.renderer)
        _ = try exporter(options).export(memos, from: source)
        try FileManager.default.moveItem(at: destination.appendingPathComponent(".memo-export.json"), to: folder.url.appendingPathComponent("lost.json"))
        // Something you wrote in one of them.
        let lecture = destination.appendingPathComponent("2026-04-30 Lecture synaptic plasticity.md")
        try (try String(contentsOf: lecture, encoding: .utf8) + "\nMine.\n").write(to: lecture, atomically: true, encoding: .utf8)
        source.transcripts["B2"] = transcript
        let report = try exporter(options).export(memos, from: source)
        #expect(report.exported.isEmpty)
        #expect(report.updated.isEmpty)
        #expect(report.unchanged == 2)
        #expect(try files().filter { $0.hasSuffix(".md") } == ["2026-04-30 Lecture synaptic plasticity.md"])
        #expect(try files("Lab").count == 2)
        #expect(try String(contentsOf: lecture, encoding: .utf8).hasSuffix("Mine.\n"))
        let record = try exporter(options).loadRecord()
        #expect(record.memos["B2"]?.path == "Lab/2026-04-30 Second")
        #expect(record.memos["A1"]?.audio == true)
    }

    @Test func memoIDsAreReadOnlyFromFrontMatter() throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let cases = [
            ("ok", "---\ntitle: \"x\"\nvoice-memo-id: \"ABC-123\"\n---\n", "ABC-123"),
            ("body", "---\ntitle: \"x\"\n---\nvoice-memo-id: \"ABC-123\"\n", nil),
            ("none", "voice-memo-id: \"ABC-123\"\n", nil),
            ("odd", "---\nvoice-memo-id: \"../x\"\n---\n", nil),
        ]
        for (name, text, id) in cases {
            let url = destination.appendingPathComponent("\(name).md")
            try text.write(to: url, atomically: true, encoding: .utf8)
            #expect(Exporter.memoID(in: url) == id, "\(name)")
        }
    }

    @Test func aFailedAudioCopyIsFilledInLater() throws {
        let memos = [Fixtures.memo("A1")]
        var source = try source(memos, transcripts: ["A1": transcript])
        let late = folder.url.appendingPathComponent("not-yet.m4a")
        source.audio["A1"] = late
        try Data("x".utf8).write(to: late)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: late.path)
        let first = try exporter().export(memos, from: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: late.path)
        #expect(first.failed.first?.reason.hasPrefix("Couldn't copy the audio") == true)
        #expect(try files() == [".memo-export.json", "2026-04-30 Lecture synaptic plasticity.md"])
        let second = try exporter().export(memos, from: source)
        #expect(second.updated == ["Lecture: synaptic plasticity"])
        #expect(try files().filter { !$0.hasPrefix(".") } == ["2026-04-30 Lecture synaptic plasticity.m4a", "2026-04-30 Lecture synaptic plasticity.md"])
    }

    @Test func oneExportPerFolderAtATime() throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let held = try FileLock.run(at: destination.appendingPathComponent(".memo-export.lock"), wait: false) {
            #expect(throws: ExportError.busy) { try exporter().export([], from: FakeSource()) }
            return true
        }
        #expect(held == true)
        #expect(try exporter().export([], from: FakeSource()).unchanged == 0)
    }

    @Test func anUnreadableRecordingKeepsItsTranscript() throws {
        let memos = [Fixtures.memo("A1")]
        var source = try source(memos, transcripts: ["A1": transcript])
        _ = try exporter().export(memos, from: source)
        source.broken = ["A1"]
        let renamed = [Fixtures.memo("A1", title: "Renamed")]
        #expect(try exporter().export(renamed, from: source).updated.isEmpty)
        #expect(try note("2026-04-30 Lecture synaptic plasticity").contains("**0:05** When two neurons"))
    }

    @Test func aNewTimeZoneDoesntRewriteNotes() throws {
        let memos = [Fixtures.memo("A1")]
        let source = try source(memos, transcripts: ["A1": transcript])
        _ = try exporter().export(memos, from: source)
        var tokyo = Fixtures.renderer
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        tokyo.locale = Locale(identifier: "fr_FR")
        #expect(try exporter(ExportOptions(renderer: tokyo)).export(memos, from: source).updated.isEmpty)
        // A different link style does change the note.
        var links = Fixtures.renderer
        links.links = .markdown
        #expect(try exporter(ExportOptions(renderer: links)).export(memos, from: source).updated.count == 1)
    }

    @Test func absurdTimesDontCrash() throws {
        let words = [Word("Hi", start: 0, end: 1), Word(" there", start: 9e9, end: 1e300)]
        let memo = Fixtures.memo(duration: 1e300)
        let note = Fixtures.renderer.markdown(memo, transcript: Transcript(words: words), audioFile: nil)
        #expect(note.contains("duration:"))
        #expect(!Fixtures.renderer.subtitles(Transcript(words: words)).isEmpty)
        #expect(Describe.relative(Date.distantPast, now: Date()).hasSuffix("days ago"))
        #expect(Describe.timestamp(.infinity) == "0:00")
        let json = #"{"attributedString":{"attributeTable":[{"timeRange":[1e300,1e300]},{"timeRange":[1,1e300]}],"runs":["a",0,"b",1]}}"#
        let decoded = try Transcript.decode(Data(json.utf8))
        #expect(decoded.words.allSatisfy { $0.end <= 10_000_000 })
    }

    @Test func audioExtensions() {
        #expect(Exporter.audioExtension(URL(fileURLWithPath: "/a/x.M4A")) == "m4a")
        #expect(Exporter.audioExtension(URL(fileURLWithPath: "/a/x.qta")) == "qta")
        #expect(Exporter.audioExtension(URL(fileURLWithPath: "/a/x")) == "m4a")
        #expect(Exporter.audioExtension(URL(fileURLWithPath: "/a/x.m4a;rm")) == "m4a")
        #expect(Exporter.audioExtension(URL(fileURLWithPath: "/a/x.toolong")) == "m4a")
    }
}
