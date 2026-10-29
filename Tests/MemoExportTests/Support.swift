import AppKit
import Foundation
import SQLite3
@testable import MemoCore
@testable import MemoExport

/// A throwaway folder that's removed when the test ends.
final class TestFolder {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("MemoExportAppTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func sub(_ name: String) -> URL {
        let sub = url.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        return sub
    }
}

/// Settings in a suite of their own, so tests never touch the app's real ones.
func testPreferences() -> Preferences {
    let name = "MemoExportTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return Preferences(defaults: defaults)
}

/// A made-up Voice Memos library: a database shaped like Voice Memos' own and recordings with
/// transcripts inside, all in a throwaway folder. Every memo, word and folder here is invented.
enum Gallery {
    struct Recording {
        var title: String
        var minutesAgo: Double
        var duration: Double
        var folder: Int?
        /// Paragraphs of what was said, or nil for no transcript.
        var said: [String]?
        var downloaded = true
    }

    static let now = Date(timeIntervalSince1970: 1_777_560_060)

    static let folders = [(1, "Neuroscience"), (2, "Lab"), (3, "Ideas")]

    static let recordings: [Recording] = [
        Recording(title: "Lecture: synaptic plasticity", minutesAgo: 95, duration: 1122, folder: 1, said: [
            "Okay, let's pick up where we left off on Tuesday. Today is all about synaptic plasticity, which is really the question of how experience changes the strength of a connection between two neurons.",
            "The classic example is long-term potentiation in the hippocampus. If you stimulate the input pathway at a high frequency, the response in the postsynaptic cell gets bigger, and it stays bigger for hours, sometimes days.",
            "The key player is the NMDA receptor. It needs two things at once: glutamate bound to it, and the cell already depolarized enough to push the magnesium block out. That's why people call it a coincidence detector.",
            "When both happen, calcium comes in, and that calcium signal is what kicks off the changes, more AMPA receptors at the synapse, and eventually structural changes to the spine itself.",
            "For the exam, I want you to be able to draw this from memory. Receptor, magnesium block, calcium, and what happens downstream.",
        ]),
        Recording(title: "Lab meeting: imaging pipeline", minutesAgo: 60 * 26, duration: 1930, folder: 2, said: [
            "Quick update on the imaging pipeline. Motion correction is done for all twelve sessions, and the segmentation looks a lot cleaner since we changed the threshold.",
            "The open question is whether we trust the automatic cell detection or go through by hand. My vote is we spot check twenty percent and see how often we disagree with it.",
            "Action items: I'll rerun session nine, which had the drift problem, and send everyone the comparison plots by Friday.",
        ]),
        Recording(title: "Grocery idea", minutesAgo: 60 * 30, duration: 12, folder: 3, said: [
            "Oat milk, coffee filters, and those little clementines. Also check if we're out of rice.",
        ]),
        Recording(title: "Melody for the bridge", minutesAgo: 60 * 50, duration: 41, folder: 3, said: nil),
        Recording(title: "Interview practice", minutesAgo: 60 * 72, duration: 365, said: [
            "Tell me about a time something didn't go to plan. Okay. In my second year I was running a behavior experiment, and halfway through we realized the timing on the reward pump was off by almost a second.",
            "Instead of throwing the data out, we figured out which sessions were affected, reran those, and wrote the fix into the protocol so the next person wouldn't hit it.",
        ]),
        Recording(title: "Voice note from the walk home", minutesAgo: 60 * 96, duration: 208, said: nil, downloaded: false),
    ]

    /// Words with times, about three a second, and a pause between paragraphs.
    static func words(_ paragraphs: [String]) -> [(String, Double, Double)] {
        var time = 0.4
        var words: [(String, Double, Double)] = []
        for (index, paragraph) in paragraphs.enumerated() {
            for (position, word) in paragraph.split(separator: " ").enumerated() {
                let length = 0.18 + Double(word.count) * 0.035
                words.append(((words.isEmpty || position == 0 && index == 0 ? "" : " ") + word, time, time + length))
                time += length + 0.06
            }
            time += 2.4
        }
        return words
    }

    /// Writes the library into `folder`, the way Voice Memos lays it out.
    static func write(to folder: URL, now: Date = now) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(folder.appendingPathComponent("CloudRecordings.db").path, &db) == SQLITE_OK else { throw Failure.sqlite }
        defer { sqlite3_close(db) }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.sqlite }
        }
        try exec("CREATE TABLE ZFOLDER (Z_PK INTEGER PRIMARY KEY, ZENCRYPTEDNAME VARCHAR)")
        try exec("CREATE TABLE ZCLOUDRECORDING (Z_PK INTEGER PRIMARY KEY, ZFOLDER INTEGER, ZDATE TIMESTAMP, ZDURATION FLOAT, ZEVICTIONDATE TIMESTAMP, ZCUSTOMLABEL VARCHAR, ZENCRYPTEDTITLE VARCHAR, ZPATH VARCHAR, ZUNIQUEID VARCHAR)")
        for (pk, name) in folders {
            try exec("INSERT INTO ZFOLDER VALUES (\(pk), '\(name)')")
        }
        for (index, recording) in recordings.enumerated() {
            let date = now.addingTimeInterval(-recording.minutesAgo * 60)
            let file = "memo-\(index + 1).m4a"
            let title = recording.title.replacingOccurrences(of: "'", with: "''")
            try exec("INSERT INTO ZCLOUDRECORDING VALUES (\(index + 1), \(recording.folder.map(String.init) ?? "NULL"), \(date.timeIntervalSinceReferenceDate), \(recording.duration), NULL, NULL, '\(title)', '\(file)', 'MEMO-\(index + 1)')")
            if recording.downloaded {
                try recordingFile(recording.said.map { transcriptJSON(words($0)) }).write(to: folder.appendingPathComponent(file))
            }
        }
    }

    enum Failure: Error { case sqlite }

    static func transcriptJSON(_ words: [(String, Double, Double)]) -> Data {
        var runs: [Any] = [], table: [Any] = []
        for (index, word) in words.enumerated() {
            runs += [word.0, index]
            table.append(["timeRange": [word.1, word.2]])
        }
        return try! JSONSerialization.data(withJSONObject: ["locale": ["identifier": "en_US", "current": 1], "attributedString": ["runs": runs, "attributeTable": table]])
    }

    static func box(_ type: String, _ contents: Data) -> Data {
        var data = Data()
        withUnsafeBytes(of: UInt32(contents.count + 8).bigEndian) { data.append(contentsOf: $0) }
        return data + Data(type.utf8) + contents
    }

    static func recordingFile(_ transcript: Data?) -> Data {
        var track = box("tkhd", Data(count: 84))
        if let transcript { track += box("udta", box("tsrp", transcript)) }
        return box("ftyp", Data("M4A \0\0\0\0".utf8)) + box("mdat", Data(repeating: 0x5A, count: 2048)) + box("moov", box("mvhd", Data(count: 100)) + box("trak", track))
    }

    /// A model reading the made-up library, already loaded.
    @MainActor
    static func model(in folder: TestFolder, exportTo: URL? = nil) async throws -> MemoModel {
        let library = folder.url.appendingPathComponent("Recordings", isDirectory: true)
        try write(to: library)
        let model = MemoModel(
            library: VoiceMemosLibrary(folder: library), preferences: testPreferences(), scratch: folder.sub("scratch"),
            folder: exportTo.map { ExportFolder(url: $0, scoped: false) }
        )
        await model.reload()
        return model
    }
}
