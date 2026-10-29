import Foundation
import Testing
@testable import MemoCore

@Suite("Command line")
struct CommandTests {
    let folder = Fixtures.Folder()
    var home: URL { folder.sub("home") }
    var library: URL { home.appendingPathComponent(VoiceMemosLibrary.relativePath, isDirectory: true) }

    /// A made-up library in the made-up home folder: a lecture with a transcript, a memo with
    /// none, and one that hasn't downloaded.
    private func makeLibrary() throws {
        try Fixtures.library(in: library, rows: [
            .init(pk: 1, id: "AAA", title: "Lecture", date: Fixtures.date, duration: 9, path: "a.m4a", folder: 1),
            .init(pk: 2, id: "BBB", title: "Quiet", date: Fixtures.date.addingTimeInterval(60), duration: 3, path: "b.m4a"),
            .init(pk: 3, id: "CCC", title: "On my phone", date: Fixtures.date.addingTimeInterval(120), duration: 20, path: "c.m4a"),
        ], folders: [(1, "Neuro")])
        try Fixtures.recording(transcript: Fixtures.transcriptJSON(Fixtures.lecture)).write(to: library.appendingPathComponent("a.m4a"))
        try Fixtures.recording(transcript: nil).write(to: library.appendingPathComponent("b.m4a"))
    }

    private func run(_ arguments: [String]) -> (status: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let status = Command.run(
            arguments, home: home, workingDirectory: folder.url, scratch: folder.sub("scratch"), renderer: Fixtures.renderer,
            out: { out.append($0) }, err: { err.append($0) }
        )
        return (status, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    @Test func parsing() throws {
        #expect(try Command.parse([]).0 == .help)
        #expect(try Command.parse(["list", "--help"]).0 == .help)
        #expect(try Command.parse(["-h"]).0 == .help)
        #expect(try Command.parse(["--version"]).0 == .version)
        #expect(try Command.parse(["list", "--json"]).0 == .list(json: true))
        #expect(try Command.parse(["show", "Lab", "meeting"]).0 == .show("Lab meeting", timestamps: true))
        #expect(try Command.parse(["show", "X", "--text"]).0 == .show("X", timestamps: false))
        let (command, library) = try Command.parse(["export", "~/Notes", "--srt", "--no-audio", "--markdown-links", "--by-folder", "--library", "/tmp/copy"])
        #expect(command == .export(folder: "~/Notes", options: ExportOptions(audio: false, subtitles: true, byFolder: true, renderer: Renderer(links: .markdown))))
        #expect(library == "/tmp/copy")
    }

    @Test func parsingMistakes() {
        for arguments in [["export"], ["export", "a", "b"], ["show"], ["list", "extra"], ["list", "--srt"], ["frobnicate"], ["list", "--library"]] {
            #expect(throws: Command.ParseError.self, "\(arguments)") { try Command.parse(arguments) }
        }
        #expect(run(["export", "--nope", "x"]).status == 2)
    }

    @Test func helpAndVersion() {
        #expect(run(["--help"]).out.contains("memo-export export <folder>"))
        #expect(run(["--version"]).out == "memo-export \(Command.toolVersion)")
    }

    @Test func list() throws {
        try makeLibrary()
        let result = run(["list"])
        #expect(result.status == 0)
        #expect(result.out == """
            2026-04-30     0:20  On my phone  (not downloaded)
            2026-04-30     0:03  Quiet  (no transcript)
            2026-04-30     0:09  Lecture  (Neuro)
            """)
    }

    @Test func listAsJSON() throws {
        try makeLibrary()
        let result = run(["list", "--json"])
        let items = try #require(try JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [[String: Any]])
        #expect(items.map { $0["id"] as? String } == ["CCC", "BBB", "AAA"])
        #expect(items[2]["transcript"] as? Bool == true)
        #expect(items[2]["folder"] as? String == "Neuro")
        #expect(items[0]["downloaded"] as? Bool == false)
        #expect(items[0]["folder"] is NSNull)
    }

    @Test func show() throws {
        try makeLibrary()
        let note = run(["show", "lecture"])
        #expect(note.status == 0)
        #expect(note.out.contains("**0:05** When two neurons fire together"))
        #expect(run(["show", "AAA", "--text"]).out == "Today we're looking at long-term potentiation.\n\nWhen two neurons fire together, the synapse between them gets stronger.")
        #expect(run(["show", "Quiet", "--text"]).status == 1)
        let missing = run(["show", "Nothing"])
        #expect(missing.status == 1)
        #expect(missing.err.contains("memo-export list"))
    }

    @Test func export() throws {
        try makeLibrary()
        let result = run(["export", "Out", "--srt"])
        #expect(result.status == 0)
        #expect(result.out.hasPrefix("Exported 2 new memos, 1 waiting for iCloud."))
        #expect(result.out.contains("  … On my phone: not downloaded from iCloud yet"))
        let out = folder.url.appendingPathComponent("Out")
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("2026-04-30 Lecture.srt").path))
        #expect(run(["export", "Out"]).out.hasPrefix("1 waiting for iCloud."))
    }

    @Test func exportWithTilde() throws {
        try makeLibrary()
        #expect(run(["export", "~/Notes/Memos"]).status == 0)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("Notes/Memos/2026-04-30 Lecture.md").path))
    }

    @Test func neverExportsIntoTheLibrary() throws {
        try makeLibrary()
        let result = run(["export", library.appendingPathComponent("out").path])
        #expect(result.status == 1)
        #expect(result.err.contains("outside the Voice Memos library"))
    }

    @Test func anotherLibrary() throws {
        try makeLibrary()
        let copy = folder.url.appendingPathComponent("Backup")
        try FileManager.default.copyItem(at: library, to: copy)
        #expect(run(["list", "--library", "Backup"]).out.contains("Lecture"))
    }

    @Test func noLibrary() {
        let result = run(["list"])
        #expect(result.status == 1)
        #expect(result.err.contains("No Voice Memos library"))
    }

    @Test func noPermission() throws {
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: library.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: library.path) }
        let result = run(["list"])
        #expect(result.status == 1)
        #expect(result.err.contains("Full Disk Access"))
    }
}

@Suite("Wording")
struct DescribeTests {
    @Test func durations() {
        #expect(Describe.duration(0) == "0:00")
        #expect(Describe.duration(54.889) == "0:55")
        #expect(Describe.duration(59.6) == "1:00")
        #expect(Describe.duration(3599.4) == "59:59")
        #expect(Describe.duration(3725) == "1:02:05")
        #expect(Describe.duration(.nan) == "0:00")
        #expect(Describe.timestamp(65, hours: true) == "0:01:05")
        #expect(Describe.timestamp(-3) == "0:00")
    }

    @Test func relativeTimes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Describe.relative(now.addingTimeInterval(-20), now: now) == "just now")
        #expect(Describe.relative(now.addingTimeInterval(-300), now: now) == "5 min ago")
        #expect(Describe.relative(now.addingTimeInterval(-3 * 3600), now: now) == "3 hr ago")
        #expect(Describe.relative(now.addingTimeInterval(-30 * 3600), now: now) == "yesterday")
        #expect(Describe.relative(now.addingTimeInterval(-4 * 86400), now: now) == "4 days ago")
    }

    @Test func paths() {
        let home = URL(fileURLWithPath: "/Users/example")
        #expect(Describe.path(URL(fileURLWithPath: "/Users/example/Notes/Memos"), home: home) == "~/Notes/Memos")
        #expect(Describe.path(home, home: home) == "~")
        #expect(Describe.path(URL(fileURLWithPath: "/Users/examples"), home: home) == "/Users/examples")
    }

    @Test func summaries() {
        var report = ExportReport()
        #expect(Describe.summary(report) == "No new memos")
        report.updated = ["a"]
        #expect(Describe.summary(report) == "Updated 1 note")
        report.exported = ["a", "b"]
        #expect(Describe.summary(report) == "Exported 2 new memos, updated 1 note")
    }

    @Test func counts() {
        #expect(Describe.count(1, "memo") == "1 memo")
        #expect(Describe.count(2, "memo") == "2 memos")
        #expect(Describe.count(0, "match", "matches") == "0 matches")
    }
}
