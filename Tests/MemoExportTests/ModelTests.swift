import AppKit
import Foundation
import SQLite3
import Testing
@testable import MemoCore
@testable import MemoExport

@MainActor
@Suite("Model")
struct ModelTests {
    let folder = TestFolder()

    @Test func readsTheLibrary() async throws {
        let model = try await Gallery.model(in: folder)
        #expect(model.status == .ready)
        #expect(model.memos.map(\.title).first == "Lecture: synaptic plasticity")
        #expect(model.memos.count == 6)
        #expect(model.withTranscripts == 4)
        #expect(!model.downloaded.contains("MEMO-6"))
        #expect(model.memos.first?.folder == "Neuroscience")
    }

    @Test func aMissingLibrary() async {
        let model = MemoModel(library: VoiceMemosLibrary(folder: folder.url.appendingPathComponent("nope")), preferences: testPreferences(), scratch: folder.sub("s"))
        await model.reload()
        #expect(model.status == .problem(.notFound))
    }

    @Test func noPermission() async throws {
        let library = folder.sub("Locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: library.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: library.path) }
        let model = MemoModel(library: VoiceMemosLibrary(folder: library), preferences: testPreferences(), scratch: folder.sub("s"))
        await model.reload()
        #expect(model.status == .problem(.noPermission))
    }

    @Test func readsAgainOnlyWhenTheLibraryChanges() async throws {
        let model = try await Gallery.model(in: folder)
        let database = model.library.folder.appendingPathComponent("CloudRecordings.db")
        // A whole second, since file dates set by hand lose their fractions.
        let date = Date(timeIntervalSince1970: 1_777_000_000)
        let folder = model.library.folder
        func settle() throws {
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: folder.appendingPathComponent(name).path)
            }
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: folder.path)
        }
        try settle()
        await model.reload(force: true)
        // Every recording deleted behind the model's back, keeping the date it checks.
        var db: OpaquePointer?
        sqlite3_open(database.path, &db)
        sqlite3_exec(db, "DELETE FROM ZCLOUDRECORDING", nil, nil, nil)
        sqlite3_close(db)
        try settle()
        await model.reload()
        #expect(model.memos.count == 6)
        // Once the date moves, it reads again.
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(60)], ofItemAtPath: database.path)
        await model.reload()
        #expect(model.memos.isEmpty)
        #expect(model.status == .ready)
    }

    @Test func exportsAndCountsWhatsNew() async throws {
        let out = folder.sub("Vault/Voice Memos")
        let model = try await Gallery.model(in: folder, exportTo: out)
        // Five are on this Mac; the sixth is still in iCloud.
        #expect(model.pending == 5)
        var seen: ExportReport?
        model.onExport = { seen = $0 }
        let report = try #require(await model.export(now: Gallery.now))
        #expect(report.exported.count == 5)
        #expect(report.waiting == ["Voice note from the walk home"])
        #expect(seen == report)
        #expect(model.pending == 0)
        #expect(model.lastExport?.summary == "Exported 5 new memos, 1 waiting for iCloud")
        #expect(model.lastExport?.date == Gallery.now)
        let files = try FileManager.default.contentsOfDirectory(atPath: out.path)
        #expect(files.filter { $0.hasSuffix(".md") }.count == 5)
        #expect(files.filter { $0.hasSuffix(".m4a") }.count == 5)
        #expect(await model.export()?.unchanged == 5)
    }

    @Test func optionsComeFromPreferences() async throws {
        let out = folder.sub("Out")
        let model = try await Gallery.model(in: folder, exportTo: out)
        model.preferences.copiesAudio = false
        model.preferences.writesSubtitles = true
        model.preferences.groupsByFolder = true
        model.preferences.links = .markdown
        _ = await model.export()
        let lab = out.appendingPathComponent("Lab")
        let files = try FileManager.default.contentsOfDirectory(atPath: lab.path).sorted()
        #expect(files.count == 2)
        #expect(files.contains { $0.hasSuffix(".srt") })
        #expect(!files.contains { $0.hasSuffix(".m4a") })
    }

    @Test func aFolderItCantWriteTo() async throws {
        let file = folder.url.appendingPathComponent("not-a-folder")
        try Data().write(to: file)
        let model = try await Gallery.model(in: folder, exportTo: file)
        #expect(await model.export() == nil)
        #expect(model.exportProblem?.hasPrefix("Couldn't write to the export folder") == true)
    }

    @Test func noExportWithoutAFolder() async throws {
        let model = try await Gallery.model(in: folder)
        #expect(model.folder == nil)
        #expect(model.pending == 0)
        #expect(await model.export() == nil)
    }

    @Test func choosingAFolder() async throws {
        let model = try await Gallery.model(in: folder)
        let out = folder.sub("Chosen")
        model.setFolder(out)
        #expect(model.folder?.url.standardizedFileURL.path == out.standardizedFileURL.path)
        #expect(model.pending == 5)
    }

    @Test func copiesTranscriptsWithTheirParagraphs() async throws {
        let model = try await Gallery.model(in: folder)
        // A pasteboard of the test's own, never the clipboard you use.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MemoExportTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let lecture = model.memos[0]
        #expect(model.copyTranscript(lecture, timestamps: false, to: pasteboard))
        let text = try #require(pasteboard.string(forType: .string))
        #expect(text.hasPrefix("Okay, let's pick up where we left off on Tuesday."))
        #expect(text.components(separatedBy: "\n\n").count == 5)
        #expect(model.copyTranscript(lecture, timestamps: true, to: pasteboard))
        #expect(pasteboard.string(forType: .string)?.hasPrefix("[0:00] Okay") == true)
        let melody = try #require(model.memos.first { $0.title == "Melody for the bridge" })
        #expect(!model.copyTranscript(melody, timestamps: false, to: pasteboard))
    }

    @Test func aSelectionThatDisappearsIsCleared() async throws {
        let model = try await Gallery.model(in: folder)
        model.selection = "GONE"
        await model.reload(force: true)
        #expect(model.selection == nil)
    }

    @Test func preferencesDefaults() {
        let preferences = testPreferences()
        #expect(preferences.copiesAudio)
        #expect(!preferences.writesSubtitles)
        #expect(!preferences.groupsByFolder)
        #expect(preferences.links == .obsidian)
        #expect(!preferences.exportsAutomatically)
        #expect(preferences.lastExport == nil)
        preferences.lastExport = (Gallery.now, "Exported 1 new memo")
        #expect(preferences.lastExport?.summary == "Exported 1 new memo")
        preferences.lastExport = nil
        #expect(preferences.lastExport == nil)
    }

    @Test func theMenuBarIcon() {
        for alert in [false, true] {
            let icon = StatusIcon.image(alert: alert)
            #expect(icon.isTemplate)
            #expect(icon.size.height <= 22)
        }
        #expect(StatusIcon.image(alert: true).accessibilityDescription == "Memo Export, needs attention")
    }
}
