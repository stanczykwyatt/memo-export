import Foundation
import SQLite3

/// A recording in Voice Memos.
public struct Memo: Identifiable, Equatable, Sendable {
    /// Voice Memos' own ID for the recording, which stays the same when it's renamed or moved.
    public var id: String
    public var title: String
    public var date: Date
    /// In seconds.
    public var duration: Double
    /// The Voice Memos folder it's in, or nil for All Recordings.
    public var folder: String?
    /// The recording's file name in the Voice Memos library.
    public var fileName: String?

    public init(id: String, title: String, date: Date, duration: Double, folder: String? = nil, fileName: String? = nil) {
        self.id = id
        self.title = title
        self.date = date
        self.duration = duration
        self.folder = folder
        self.fileName = fileName
    }
}

public enum LibraryError: Error, Equatable {
    /// There's no Voice Memos library on this Mac yet.
    case notFound
    /// macOS blocked the read. Voice Memos' library needs Full Disk Access.
    case noPermission
    /// The library is there but laid out in a way this version doesn't know.
    case unrecognized(String)
}

/// Reads the Voice Memos library: the list of recordings from its database, and each recording's
/// transcript from inside its audio file. Nothing in the library is ever written to. The
/// database is copied to a scratch folder and only the copy is opened, so SQLite never touches
/// the original or the journal Voice Memos is writing to.
public struct VoiceMemosLibrary: Sendable {
    /// Where Voice Memos keeps recordings on macOS 14 and later, from the home folder.
    public static let relativePath = "Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"
    static let database = "CloudRecordings.db"
    /// Far bigger than any real library's database, which holds only titles, dates and paths.
    static let databaseLimit = 512 * 1024 * 1024

    public let folder: URL

    public init(folder: URL) {
        self.folder = folder.standardizedFileURL
    }

    public init(home: URL) {
        self.init(folder: home.appendingPathComponent(Self.relativePath, isDirectory: true))
    }

    /// The real home folder, even inside the App Sandbox, where `NSHomeDirectory()` is the container.
    public static var realHome: URL {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        }
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    }

    // MARK: Recordings

    /// Every recording, newest first, leaving out ones in Recently Deleted. `scratch` is a folder
    /// of the caller's own where the database is copied to be read.
    public func memos(scratch: URL) throws -> [Memo] {
        try checkAccess()
        let source = folder.appendingPathComponent(Self.database)
        guard FileManager.default.fileExists(atPath: source.path) else { throw LibraryError.notFound }
        let target = scratch.appendingPathComponent("VoiceMemos", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            throw LibraryError.unrecognized("Couldn't make a scratch folder: \(error.localizedDescription)")
        }
        // One read of the scratch copy at a time, so the app and the command line tool, or two
        // reads in the app, never replace each other's copy while it's open.
        let memos = try FileLock.run(at: target.appendingPathComponent("copy.lock"), wait: true) {
            try Self.readMemos(database: try copyDatabase(to: target))
        }
        return memos ?? []
    }

    /// Throws `noPermission` if macOS won't let the library be read, and `notFound` if it isn't there.
    public func checkAccess() throws {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw LibraryError.notFound
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw LibraryError.noPermission
        } catch {
            let code = ((error as NSError).underlyingErrors.first as NSError?)?.code ?? (error as NSError).code
            if code == Int(EPERM) || code == Int(EACCES) { throw LibraryError.noPermission }
            if code == Int(ENOENT) { throw LibraryError.notFound }
            throw LibraryError.unrecognized(error.localizedDescription)
        }
    }

    /// Copies the database and its write-ahead log into `target`, where SQLite may write freely.
    /// The log holds everything since Voice Memos last folded it in, often the newest recordings,
    /// so it has to come too. The two are read as a pair: if Voice Memos folded the log in or
    /// started a new one while they were being read, they're read again. The shared-memory index
    /// is left empty for SQLite to rebuild, since one copied mid-write might not match the log.
    func copyDatabase(to target: URL) throws -> URL {
        do {
            let copy = target.appendingPathComponent(Self.database)
            let log = folder.appendingPathComponent(Self.database + "-wal")
            var pair: (main: Data, log: Data)?
            for _ in 0..<4 where pair == nil {
                let before = snapshotStamp()
                let main = try readLimited(folder.appendingPathComponent(Self.database))
                let logData = FileManager.default.fileExists(atPath: log.path) ? try readLimited(log) : Data()
                if snapshotStamp() == before { pair = (main, logData) }
            }
            guard let (main, logData) = pair else {
                throw LibraryError.unrecognized("Voice Memos was busy saving. Try again in a moment.")
            }
            try main.write(to: copy, options: .atomic)
            try logData.write(to: target.appendingPathComponent(Self.database + "-wal"), options: .atomic)
            try Data().write(to: target.appendingPathComponent(Self.database + "-shm"), options: .atomic)
            return copy
        } catch let error as LibraryError {
            throw error
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw LibraryError.noPermission
        } catch {
            throw LibraryError.unrecognized("Couldn't copy the Voice Memos database: \(error.localizedDescription)")
        }
    }

    /// What changes when Voice Memos rewrites its database or starts a new log: the database's
    /// size and date, and the log's header, which holds a counter and salts that change each time.
    /// Words added to the end of the log don't count, since a copy cut short there is still sound.
    func snapshotStamp() -> String {
        let main = try? folder.appendingPathComponent(Self.database).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var stamp = "\(main?.fileSize ?? -1) \(main?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)"
        if let handle = try? FileHandle(forReadingFrom: folder.appendingPathComponent(Self.database + "-wal")) {
            stamp += " " + ((try? handle.read(upToCount: 32)) ?? Data()).base64EncodedString()
            try? handle.close()
        }
        return stamp
    }

    private func readLimited(_ url: URL) throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.databaseLimit else { throw LibraryError.unrecognized("The Voice Memos database is unexpectedly large.") }
        return try Data(contentsOf: url)
    }

    /// Reads the recordings from a copy of the database.
    static func readMemos(database url: URL) throws -> [Memo] {
        let database = try SQLiteDatabase(url)
        let columns = try database.columns(of: "ZCLOUDRECORDING")
        guard !columns.isEmpty else { throw LibraryError.unrecognized("The Voice Memos database has no recordings table.") }
        for required in ["Z_PK", "ZDATE", "ZPATH"] where !columns.contains(required) {
            throw LibraryError.unrecognized("The Voice Memos database has no \(required) column.")
        }
        func column(_ name: String) -> String { columns.contains(name) ? "r.\(name)" : "NULL" }
        let folders = try database.columns(of: "ZFOLDER")
        let folderName = columns.contains("ZFOLDER") && folders.contains("ZENCRYPTEDNAME") && folders.contains("Z_PK")
        let query = """
            SELECT r.Z_PK, \(column("ZUNIQUEID")), \(column("ZENCRYPTEDTITLE")), \(column("ZCUSTOMLABEL")), r.ZDATE,
                   \(column("ZDURATION")), r.ZPATH, \(column("ZEVICTIONDATE")), \(folderName ? "f.ZENCRYPTEDNAME" : "NULL")
            FROM ZCLOUDRECORDING r
            \(folderName ? "LEFT JOIN ZFOLDER f ON f.Z_PK = r.ZFOLDER" : "")
            ORDER BY r.ZDATE DESC
            """
        var memos: [Memo] = []
        var seen = Set<String>()
        try database.each(query) { row in
            // Recordings in Recently Deleted have the date they'll be removed for good.
            guard row.double(7) == nil else { return }
            // Dates far outside any real recording's are damage, not memos.
            guard let date = row.double(4), date.isFinite, abs(date) < 1e10 else { return }
            let title = [row.text(2), row.text(3)].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            let fileName = row.text(6).map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
            let folder = row.text(8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = row.text(1).flatMap { $0.isEmpty ? nil : $0 } ?? "recording-\(row.int(0))"
            // The newest of two rows with one ID wins, so each memo is exported once.
            guard seen.insert(id).inserted else { return }
            let duration = row.double(5) ?? 0
            memos.append(Memo(
                id: id,
                title: title ?? "New Recording",
                date: Date(timeIntervalSinceReferenceDate: date),
                duration: duration.isFinite ? min(max(0, duration), Transcript.longest) : 0,
                folder: folder.flatMap { $0.isEmpty ? nil : $0 },
                fileName: fileName
            ))
        }
        return memos
    }

    /// When anything in the library last changed, from file dates alone, to tell cheaply whether
    /// there's anything new: the database and its log, a recording finishing its download, or
    /// Voice Memos adding a transcript to one.
    public func lastChange() -> Date? {
        let key = URLResourceKey.contentModificationDateKey
        var dates = [try? folder.resourceValues(forKeys: [key]).contentModificationDate]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [key], options: .skipsHiddenFiles)) ?? []
        dates += files.map { try? $0.resourceValues(forKeys: [key]).contentModificationDate }
        return dates.compactMap { $0 }.max()
    }

    // MARK: Audio and transcripts

    /// The recording's audio file, if it's on this Mac. A recording synced from another device may
    /// not be downloaded yet. Only names directly inside the library are accepted, so a path in the
    /// database can never point anywhere else.
    public func audioURL(for memo: Memo) -> URL? {
        guard let name = memo.fileName, !name.hasPrefix("."), !name.contains("/") else { return nil }
        let url = folder.appendingPathComponent(name)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else { return nil }
        return url
    }

    /// The recording's transcript, or nil if Voice Memos hasn't made one.
    public func transcript(for memo: Memo) throws -> Transcript? {
        guard let url = audioURL(for: memo) else { return nil }
        let file = try FileSource(url)
        defer { file.close() }
        guard let data = try Atoms.transcriptData(in: file) else { return nil }
        let transcript = try Transcript.decode(data)
        return transcript.isEmpty ? nil : transcript
    }
}

/// A recording on disk, opened read-only and read a piece at a time.
final class FileSource: ByteSource {
    private let handle: FileHandle
    let count: UInt64

    init(_ url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        count = try handle.seekToEnd()
    }

    func read(at offset: UInt64, length: Int) throws -> Data {
        guard offset + UInt64(length) <= count else { throw AtomError.truncated }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: length) ?? Data()
        guard data.count == length else { throw AtomError.truncated }
        return data
    }

    func close() {
        try? handle.close()
    }
}

/// Just enough of SQLite to read a few columns.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(_ url: URL) throws {
        // The copy is ours, so SQLite may write to it while folding in the log.
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK else {
            sqlite3_close(handle)
            throw LibraryError.unrecognized("Couldn't open the Voice Memos database (SQLite error \(status)).")
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    struct Row {
        let statement: OpaquePointer?

        func text(_ column: Int32) -> String? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL, let text = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: text)
        }

        func double(_ column: Int32) -> Double? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
        }

        func int(_ column: Int32) -> Int64 {
            sqlite3_column_int64(statement, column)
        }
    }

    func each(_ query: String, _ body: (Row) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_finalize(statement)
            throw LibraryError.unrecognized("Couldn't read the Voice Memos database: \(message)")
        }
        defer { sqlite3_finalize(statement) }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else {
                throw LibraryError.unrecognized("Couldn't read the Voice Memos database (SQLite error \(status)).")
            }
            try body(Row(statement: statement))
        }
    }

    /// The table's column names, or none if there's no such table.
    func columns(of table: String) throws -> Set<String> {
        var names = Set<String>()
        try each("PRAGMA table_info(\(table))") { row in
            if let name = row.text(1) { names.insert(name) }
        }
        return names
    }
}
