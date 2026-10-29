import CryptoKit
import Foundation

/// Where memos' audio and transcripts come from. The Voice Memos library in the app; made-up
/// recordings in tests.
public protocol MemoSource: Sendable {
    func audioURL(for memo: Memo) -> URL?
    func transcript(for memo: Memo) throws -> Transcript?
}

extension VoiceMemosLibrary: MemoSource {}

public struct ExportOptions: Equatable, Sendable {
    /// Copy each recording's audio next to its note.
    public var audio = true
    /// Also write SRT subtitles for memos with a transcript.
    public var subtitles = false
    /// Put each memo in a subfolder named after its Voice Memos folder.
    public var byFolder = false
    public var renderer = Renderer()

    public init(audio: Bool = true, subtitles: Bool = false, byFolder: Bool = false, renderer: Renderer = Renderer()) {
        self.audio = audio
        self.subtitles = subtitles
        self.byFolder = byFolder
        self.renderer = renderer
    }

    public static func == (a: ExportOptions, b: ExportOptions) -> Bool {
        a.audio == b.audio && a.subtitles == b.subtitles && a.byFolder == b.byFolder && a.renderer.links == b.renderer.links
    }
}

/// What an export did, memo by memo.
public struct ExportReport: Equatable, Sendable {
    public struct Failure: Equatable, Sendable {
        public var title: String
        public var reason: String
    }

    /// Memos exported for the first time, by title.
    public var exported: [String] = []
    /// Notes rewritten because the memo changed, like a transcript that wasn't ready last time.
    public var updated: [String] = []
    /// Memos whose audio hasn't downloaded from iCloud yet. They're exported once it has.
    public var waiting: [String] = []
    public var failed: [Failure] = []
    /// Memos already exported with nothing new.
    public var unchanged = 0

    public init() {}
}

public enum ExportError: Error, Equatable {
    /// The chosen folder is inside the Voice Memos library, which is never written to.
    case insideLibrary
    /// The folder's export record can't be read, so exporting could duplicate everything.
    case unreadableRecord
    /// The export record was written by a newer version.
    case newerRecord
    /// Another export into the same folder is running, like the app and the command line tool at once.
    case busy
    case cannotWrite(String)
}

/// What's been exported to a folder, kept in the folder itself as `.memo-export.json`, so a
/// re-run only adds new memos and the record travels with the files.
struct ExportRecord: Codable, Equatable {
    static let currentVersion = 1

    struct Entry: Codable, Equatable {
        /// Where the memo's files are, from the export folder, without an extension.
        var path: String
        /// The SHA-256 of the note as last written, to tell whether you've edited it since. Empty
        /// for a note found in the folder rather than written in this record, which is never rewritten.
        var markdownHash: String
        /// The SHA-256 of what the note was made from, so it's only rewritten when the memo changed.
        var sourceHash: String?
        var audio: Bool
        var subtitles: Bool
        var exported: Date
    }

    var version = currentVersion
    var memos: [String: Entry] = [:]
}

/// Exports memos into a folder: each one's audio, a Markdown note with its transcript, and
/// optionally subtitles. Files that are already there are never overwritten, except a note this
/// exporter wrote and you haven't touched, when the memo has changed. Nothing is ever deleted.
public struct Exporter: Sendable {
    public static let recordName = ".memo-export.json"
    static let lockName = ".memo-export.lock"
    /// The record is saved after this many changes, and at the end.
    static let saveEvery = 20

    public let destination: URL
    public var options: ExportOptions

    public init(destination: URL, options: ExportOptions = ExportOptions()) {
        self.destination = destination.standardizedFileURL
        self.options = options
    }

    /// Exports what's new or changed since the last run, oldest memo first. Nothing is written
    /// inside any of the `protected` folders, like the Voice Memos library. `progress` is called
    /// with how many memos are done and how many there are.
    public func export(
        _ memos: [Memo], from source: MemoSource, protected: [URL] = [], now: Date = Date(),
        progress: (Int, Int) -> Void = { _, _ in }
    ) throws -> ExportReport {
        if protected.contains(where: { Self.isInside(destination, $0) }) { throw ExportError.insideLibrary }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let report = try FileLock.run(at: destination.appendingPathComponent(Self.lockName), wait: false) {
                try run(memos, from: source, protected: protected, now: now, progress: progress)
            }
            guard let report else { throw ExportError.busy }
            return report
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.cannotWrite(error.localizedDescription)
        }
    }

    private func run(_ memos: [Memo], from source: MemoSource, protected: [URL], now: Date, progress: (Int, Int) -> Void) throws -> ExportReport {
        var record = try loadRecord()
        var report = ExportReport()
        let ordered = memos.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        // Notes already in the folder that the record doesn't know, like after it was lost or a
        // run stopped partway, are taken back rather than exported a second time.
        let missing = Set(ordered.map(\.id)).subtracting(record.memos.keys)
        if !missing.isEmpty {
            for (id, entry) in adoptable(missing) { record.memos[id] = entry }
        }
        var unsaved = 0
        for (index, memo) in ordered.enumerated() {
            if let entry = record.memos[memo.id] {
                if let changed = refresh(memo, entry: entry, from: source, protected: protected, report: &report) {
                    record.memos[memo.id] = changed
                    unsaved += 1
                } else {
                    report.unchanged += 1
                }
            } else if let entry = add(memo, from: source, taken: record, protected: protected, now: now, report: &report) {
                record.memos[memo.id] = entry
                unsaved += 1
            }
            if unsaved >= Self.saveEvery {
                try saveRecord(record)
                unsaved = 0
            }
            progress(index + 1, ordered.count)
        }
        try saveRecord(record)
        return report
    }

    /// Which memos would be exported for the first time. Throws if the folder's record can't be read.
    public func newMemos(_ memos: [Memo]) throws -> [Memo] {
        let known = try loadRecord().memos
        return memos.filter { known[$0.id] == nil }
    }

    // MARK: New memos

    private func add(_ memo: Memo, from source: MemoSource, taken record: ExportRecord, protected: [URL], now: Date, report: inout ExportReport) -> ExportRecord.Entry? {
        guard let audio = source.audioURL(for: memo) else {
            if memo.fileName == nil {
                report.failed.append(.init(title: memo.title, reason: "Voice Memos doesn't list an audio file for it."))
            } else {
                report.waiting.append(memo.title)
            }
            return nil
        }
        let transcript = try? source.transcript(for: memo)
        let ext = Self.audioExtension(audio)
        let path = uniquePath(for: memo, audioExtension: ext, taken: record)
        let base = destination.appendingPathComponent(path)
        let audioName = options.audio ? base.appendingPathExtension(ext).lastPathComponent : nil
        // The note goes first. If anything after it fails, the record still has the memo, and the
        // next export fills in what's missing instead of starting a second copy.
        let note = Data(options.renderer.markdown(memo, transcript: transcript, audioFile: audioName).utf8)
        do {
            try checkWritable(base.deletingLastPathComponent(), protected: protected)
            try FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
            try note.write(to: base.appendingPathExtension("md"), options: .withoutOverwriting)
        } catch {
            report.failed.append(.init(title: memo.title, reason: error.localizedDescription))
            return nil
        }
        var entry = ExportRecord.Entry(
            path: path, markdownHash: Self.hash(note), sourceHash: fingerprint(memo, transcript: transcript, audioFile: audioName),
            audio: false, subtitles: false, exported: now
        )
        var problems: [String] = []
        if options.audio {
            do {
                try copyAudio(audio, to: base.appendingPathExtension(ext), date: memo.date)
                entry.audio = true
            } catch {
                problems.append("Couldn't copy the audio: \(error.localizedDescription)")
            }
        }
        if options.subtitles, let transcript {
            do {
                try Data(options.renderer.subtitles(transcript).utf8).write(to: base.appendingPathExtension("srt"), options: .withoutOverwriting)
                entry.subtitles = true
            } catch {
                problems.append("Couldn't write the subtitles: \(error.localizedDescription)")
            }
        }
        if problems.isEmpty {
            report.exported.append(memo.title)
        } else {
            report.failed.append(.init(title: memo.title, reason: problems.joined(separator: " ")))
        }
        return entry
    }

    /// The memo's path without an extension: its date and title, plus a number if another memo or
    /// a file of yours already has that name. Names are compared ignoring case, as the Mac does,
    /// and across subfolders, so an Obsidian `![[link]]` to the audio can only mean one file.
    func uniquePath(for memo: Memo, audioExtension: String, taken record: ExportRecord) -> String {
        var folder = ""
        if options.byFolder, let name = memo.folder {
            folder = Renderer.safeName(name, fallback: "Folder") + "/"
        }
        let base = options.renderer.baseName(memo)
        let recorded = Set(record.memos.values.map { ($0.path as NSString).lastPathComponent.lowercased() })
        var number = 1
        while true {
            let name = number == 1 ? base : "\(base) (\(number))"
            let url = destination.appendingPathComponent(folder + name)
            let onDisk = ["md", "srt", audioExtension].contains {
                FileManager.default.fileExists(atPath: url.appendingPathExtension($0).path)
            }
            if !onDisk && !recorded.contains(name.lowercased()) { return folder + name }
            number += 1
        }
    }

    // MARK: Memos exported before

    /// Brings an exported memo up to date, or returns nil if there's nothing to do. A note is only
    /// rewritten if the memo changed and the note is exactly as it was exported; a note you've
    /// edited or deleted is left alone.
    private func refresh(_ memo: Memo, entry: ExportRecord.Entry, from source: MemoSource, protected: [URL], report: inout ExportReport) -> ExportRecord.Entry? {
        var entry = entry
        var changed = false
        let base = destination.appendingPathComponent(entry.path)
        // Without the recording, or if it can't be read right now, there's nothing to compare
        // against, so the note is left as it is rather than losing its transcript.
        guard let audio = source.audioURL(for: memo) else { return nil }
        let transcript: Transcript?
        do {
            transcript = try source.transcript(for: memo)
        } catch {
            return nil
        }
        do {
            try checkWritable(base.deletingLastPathComponent(), protected: protected)
            if options.audio, !entry.audio {
                let target = base.appendingPathExtension(Self.audioExtension(audio))
                if !FileManager.default.fileExists(atPath: target.path) {
                    try copyAudio(audio, to: target, date: memo.date)
                    entry.audio = true
                    changed = true
                }
            }
            let noteURL = base.appendingPathExtension("md")
            let audioName = entry.audio ? Self.existingAudioName(base) : nil
            let made = fingerprint(memo, transcript: transcript, audioFile: audioName)
            if made != entry.sourceHash, !entry.markdownHash.isEmpty,
               let existing = try? Data(contentsOf: noteURL), Self.hash(existing) == entry.markdownHash {
                let note = Data(options.renderer.markdown(memo, transcript: transcript, audioFile: audioName).utf8)
                try note.write(to: noteURL, options: .atomic)
                entry.markdownHash = Self.hash(note)
                entry.sourceHash = made
                changed = true
            }
            if options.subtitles, !entry.subtitles, let transcript {
                let target = base.appendingPathExtension("srt")
                if !FileManager.default.fileExists(atPath: target.path) {
                    try Data(options.renderer.subtitles(transcript).utf8).write(to: target, options: .withoutOverwriting)
                    entry.subtitles = true
                    changed = true
                }
            }
        } catch {
            report.failed.append(.init(title: memo.title, reason: error.localizedDescription))
            return changed ? entry : nil
        }
        if changed { report.updated.append(memo.title) }
        return changed ? entry : nil
    }

    /// The name of the audio file exported next to a note, whichever kind it is.
    private static func existingAudioName(_ base: URL) -> String? {
        for ext in ["m4a", "qta", "caf", "wav", "mp3", "aac", "mp4", "mov"] {
            let url = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: url.path) { return url.lastPathComponent }
        }
        return nil
    }

    /// What a note is made from, so changing the Mac's language or time zone doesn't rewrite every note.
    func fingerprint(_ memo: Memo, transcript: Transcript?, audioFile: String?) -> String {
        var parts = [memo.title, memo.folder ?? "", "\(memo.date.timeIntervalSinceReferenceDate)", "\(memo.duration)", audioFile ?? "", options.renderer.links.rawValue, transcript?.locale ?? ""]
        for word in transcript?.words ?? [] {
            parts.append("\(word.text)@\(word.start)-\(word.end)")
        }
        return Self.hash(Data(parts.joined(separator: "\u{1F}").utf8))
    }

    // MARK: Notes already in the folder

    /// Notes this exporter wrote that the record doesn't list, found by the `voice-memo-id` in
    /// their front matter, in the folder and its subfolders one level down. They're taken back as
    /// they are and never rewritten, since there's no telling whether you've edited them.
    func adoptable(_ ids: Set<String>) -> [String: ExportRecord.Entry] {
        var found: [String: ExportRecord.Entry] = [:]
        let manager = FileManager.default
        var folders = [(destination, "")]
        let subfolders = (try? manager.contentsOfDirectory(at: destination, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        for folder in subfolders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            folders.append((folder, folder.lastPathComponent + "/"))
        }
        for (folder, prefix) in folders {
            let notes = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for note in notes where note.pathExtension == "md" {
                guard let id = Self.memoID(in: note), ids.contains(id), found[id] == nil else { continue }
                let base = note.deletingPathExtension()
                found[id] = ExportRecord.Entry(
                    path: prefix + base.lastPathComponent, markdownHash: "", sourceHash: nil,
                    audio: Self.existingAudioName(base) != nil,
                    subtitles: manager.fileExists(atPath: base.appendingPathExtension("srt").path),
                    exported: (try? note.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                )
            }
        }
        return found.filter { Self.isSafePath($0.value.path) }
    }

    /// The `voice-memo-id` from a note's front matter, reading only its first few kilobytes.
    static func memoID(in note: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: note) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), head.starts(with: Data("---\n".utf8)) else { return nil }
        for line in String(decoding: head, as: UTF8.self).split(separator: "\n").dropFirst() {
            if line == "---" { break }
            guard line.hasPrefix("voice-memo-id: \"") && line.hasSuffix("\"") && line.count > 17 else { continue }
            let value = line.dropFirst(16).dropLast()
            // IDs are letters, digits and dashes; anything else wasn't written by this exporter.
            guard value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
            return String(value)
        }
        return nil
    }

    // MARK: Writing

    private func copyAudio(_ source: URL, to target: URL, date: Date) throws {
        try FileManager.default.copyItem(at: source, to: target)
        try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: target.path)
    }

    /// Makes sure `folder` is inside the export folder and outside every protected one, after
    /// following links, before anything is written there.
    private func checkWritable(_ folder: URL, protected: [URL]) throws {
        guard Self.isInside(folder, destination), !protected.contains(where: { Self.isInside(folder, $0) }) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "Its folder is outside the export folder or inside Voice Memos."])
        }
    }

    // MARK: Record

    var recordURL: URL { destination.appendingPathComponent(Self.recordName) }

    func loadRecord() throws -> ExportRecord {
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return ExportRecord() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: recordURL) else { throw ExportError.unreadableRecord }
        if let version = try? decoder.decode(Version.self, from: data).version, version > ExportRecord.currentVersion {
            throw ExportError.newerRecord
        }
        guard let record = try? decoder.decode(ExportRecord.self, from: data),
              record.memos.values.allSatisfy({ Self.isSafePath($0.path) })
        else { throw ExportError.unreadableRecord }
        return record
    }

    private struct Version: Decodable {
        var version: Int
    }

    func saveRecord(_ record: ExportRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(record).write(to: recordURL, options: .atomic)
        } catch {
            throw ExportError.cannotWrite(error.localizedDescription)
        }
    }

    /// Whether a path from the record stays inside the export folder: a file name, or a folder
    /// and a file name, with nothing that climbs out or hides.
    static func isSafePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !path.contains("\0"), !path.contains("\\") else { return false }
        return parts.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") }
    }

    // MARK: Helpers

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The recording's extension, kept only if it's plain letters and digits.
    static func audioExtension(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return !ext.isEmpty && ext.count <= 5 && ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? ext : "m4a"
    }

    /// Whether `url` is `folder` or inside it, after following symbolic links.
    public static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = resolved(url).lowercased(), base = resolved(folder).lowercased()
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// The path with every link followed, including links above a folder that doesn't exist yet.
    static func resolved(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var path = existing.resolvingSymlinksInPath().path
        for component in rest { path = (path as NSString).appendingPathComponent(component) }
        return path
    }
}
