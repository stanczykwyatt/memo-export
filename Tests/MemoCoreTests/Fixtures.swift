import Foundation
import SQLite3
@testable import MemoCore

/// Made-up recordings and libraries, built in throwaway folders. Nothing here reads the real
/// Voice Memos library.
enum Fixtures {
    // MARK: Recordings

    /// One box: its size, its four letters, then its contents.
    static func box(_ type: String, _ contents: Data) -> Data {
        var data = Data()
        withUnsafeBytes(of: UInt32(contents.count + 8).bigEndian) { data.append(contentsOf: $0) }
        data.append(Data(type.utf8))
        data.append(contents)
        return data
    }

    static func box(_ type: String, _ children: [Data]) -> Data {
        box(type, children.reduce(Data(), +))
    }

    /// A transcript box's JSON, in Voice Memos' layout: runs alternating text and attribute
    /// index, and an attribute table of time ranges.
    static func transcriptJSON(_ words: [(String, Double, Double)], locale: String = "en_US") -> Data {
        var runs: [Any] = []
        var table: [Any] = []
        for (index, word) in words.enumerated() {
            runs.append(word.0)
            runs.append(index)
            table.append(["timeRange": [word.1, word.2]])
        }
        let root: [String: Any] = [
            "locale": ["identifier": locale, "current": 1],
            "attributedString": ["runs": runs, "attributeTable": table],
        ]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    /// A recording laid out like Voice Memos' own: a file type, the audio, then the movie with
    /// the transcript in the track's user data and the title in the movie's.
    static func recording(transcript: Data?, audioBytes: Int = 4096, inTrack: Bool = true) -> Data {
        let ftyp = box("ftyp", Data("M4A \0\0\0\0M4A mp42isom".utf8))
        let mdat = box("mdat", Data(repeating: 0xAB, count: audioBytes))
        var track: [Data] = [box("tkhd", Data(count: 84)), box("mdia", [box("mdhd", Data(count: 24))])]
        var movie: [Data] = [box("mvhd", Data(count: 100))]
        if let transcript {
            if inTrack { track.append(box("udta", [box("tsrp", transcript)])) } else { movie.append(box("udta", [box("tsrp", transcript)])) }
        }
        movie.insert(box("trak", track), at: 1)
        movie.append(box("udta", [box("meta", Data(count: 40))]))
        return ftyp + mdat + box("moov", movie)
    }

    static let lecture: [(String, Double, Double)] = [
        ("Today", 0.0, 0.4), (" we're", 0.4, 0.7), (" looking", 0.7, 1.1), (" at", 1.1, 1.2), (" long-term", 1.2, 1.8),
        (" potentiation.", 1.8, 2.6), (" When", 5.0, 5.3), (" two", 5.3, 5.5), (" neurons", 5.5, 6.0), (" fire", 6.0, 6.3),
        (" together,", 6.3, 6.9), (" the", 7.0, 7.1), (" synapse", 7.1, 7.6), (" between", 7.6, 7.9), (" them", 7.9, 8.1),
        (" gets", 8.1, 8.3), (" stronger.", 8.3, 9.0),
    ]

    // MARK: Libraries

    struct Row {
        var pk: Int
        var id: String?
        var title: String?
        var label: String? = nil
        var date: Date
        var duration: Double
        var path: String?
        var folder: Int? = nil
        var deleted = false
    }

    /// A throwaway folder that's removed when the test ends.
    final class Folder {
        let url: URL

        init() {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("MemoExportTests-\(UUID().uuidString)", isDirectory: true)
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

    /// A Voice Memos library: a database shaped like Voice Memos' own, with its tables' Core
    /// Data names. With `inLog`, the rows stay in the write-ahead log, as the newest recordings
    /// do until Voice Memos folds the log into the database.
    static func library(in folder: URL, rows: [Row], folders: [(Int, String)] = [], inLog: Bool = false, columns: String? = nil) throws {
        // Built beside the library, then copied in while the database is still open, as Voice
        // Memos' is. Closing it first would fold the log into the database.
        let work = folder.deletingLastPathComponent().appendingPathComponent("build-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(work.appendingPathComponent("CloudRecordings.db").path, &db) == SQLITE_OK else { throw Failure.sqlite }
        defer {
            sqlite3_close(db)
            try? FileManager.default.removeItem(at: work)
        }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.sqlite }
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA wal_autocheckpoint=0")
        try exec("CREATE TABLE ZFOLDER (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZCOUNTOFRECORDINGS INTEGER, ZRANK INTEGER, ZENCRYPTEDNAME VARCHAR, ZUUID VARCHAR)")
        try exec(columns.map { "CREATE TABLE ZCLOUDRECORDING (\($0))" } ?? """
            CREATE TABLE ZCLOUDRECORDING (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZFLAGS INTEGER, ZFOLDER INTEGER,
            ZDATE TIMESTAMP, ZDURATION FLOAT, ZEVICTIONDATE TIMESTAMP, ZCUSTOMLABEL VARCHAR, ZENCRYPTEDTITLE VARCHAR,
            ZPATH VARCHAR, ZUNIQUEID VARCHAR)
            """)
        try exec("PRAGMA wal_checkpoint(TRUNCATE)")
        for (pk, name) in folders {
            try exec("INSERT INTO ZFOLDER (Z_PK, ZENCRYPTEDNAME) VALUES (\(pk), \(quote(name)))")
        }
        if columns == nil {
            for row in rows {
                try exec("""
                    INSERT INTO ZCLOUDRECORDING (Z_PK, ZFOLDER, ZDATE, ZDURATION, ZEVICTIONDATE, ZCUSTOMLABEL, ZENCRYPTEDTITLE, ZPATH, ZUNIQUEID)
                    VALUES (\(row.pk), \(row.folder.map(String.init) ?? "NULL"), \(row.date.timeIntervalSinceReferenceDate), \(row.duration),
                    \(row.deleted ? String(row.date.timeIntervalSinceReferenceDate + 30 * 86400) : "NULL"), \(quote(row.label)),
                    \(quote(row.title)), \(quote(row.path)), \(quote(row.id)))
                    """)
            }
        }
        if !inLog { try exec("PRAGMA wal_checkpoint(TRUNCATE)") }
        for name in try FileManager.default.contentsOfDirectory(atPath: work.path) {
            let target = folder.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: work.appendingPathComponent(name), to: target)
        }
    }

    enum Failure: Error { case sqlite }

    private static func quote(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// 9:41 AM on April 30, 2026, in Minneapolis.
    static let date = Date(timeIntervalSince1970: 1_777_560_060)
    static let central = TimeZone(identifier: "America/Chicago")!
    static let renderer = Renderer(timeZone: central, locale: Locale(identifier: "en_US_POSIX"))

    static func memo(_ id: String = "A1", title: String = "Lecture: synaptic plasticity", date: Date = date, duration: Double = 9, folder: String? = nil, fileName: String? = "20260430 094100.m4a") -> Memo {
        Memo(id: id, title: title, date: date, duration: duration, folder: folder, fileName: fileName)
    }
}

/// Memos and transcripts held in memory, for testing the exporter without a library.
struct FakeSource: MemoSource, @unchecked Sendable {
    var audio: [String: URL] = [:]
    var transcripts: [String: Transcript] = [:]
    var broken: Set<String> = []

    func audioURL(for memo: Memo) -> URL? { audio[memo.id] }

    func transcript(for memo: Memo) throws -> Transcript? {
        if broken.contains(memo.id) { throw TranscriptError.unrecognized }
        return transcripts[memo.id]
    }
}
