import AppKit
import MemoCore
import Observation

/// What the app knows about your memos, shared by the menu and the window. The library is read
/// off the main thread, and only again once Voice Memos has changed it.
@MainActor
@Observable
final class MemoModel {
    enum Status: Equatable {
        case loading
        case ready
        case problem(LibraryError)
    }

    private(set) var status: Status = .loading
    /// Newest first, without Recently Deleted.
    private(set) var memos: [Memo] = []
    private(set) var transcripts: [String: Transcript] = [:]
    /// Memos whose audio is on this Mac rather than only in iCloud.
    private(set) var downloaded: Set<String> = []
    /// Downloaded memos not yet exported to the folder.
    private(set) var pending = 0
    private(set) var isExporting = false
    /// Why the last export stopped, if it did.
    private(set) var exportProblem: String?
    private(set) var failures: [ExportReport.Failure] = []
    private(set) var folder: ExportFolder?
    /// The memo shown in the window.
    var selection: String?

    /// Called after each export with what it did.
    var onExport: ((ExportReport) -> Void)?

    let library: VoiceMemosLibrary
    let preferences: Preferences
    private let scratch: URL
    private var lastChange: Date?
    private var loading: Task<Void, Never>?
    /// Transcripts already read, with their recording's date, so one is read again only when
    /// Voice Memos changes the recording, like after trimming it.
    private var known: [String: (date: Date?, transcript: Transcript)] = [:]

    init(library: VoiceMemosLibrary, preferences: Preferences, scratch: URL, folder: ExportFolder? = nil) {
        self.library = library
        self.preferences = preferences
        self.scratch = scratch
        if let folder {
            self.folder = folder
        } else if let bookmark = preferences.folderBookmark, let resolved = ExportFolder.resolve(bookmark) {
            self.folder = resolved.folder
            if let refreshed = resolved.refreshed { preferences.folderBookmark = refreshed }
        }
    }

    var withTranscripts: Int { memos.filter { transcripts[$0.id] != nil }.count }
    var lastExport: (date: Date, summary: String)? { preferences.lastExport }

    // MARK: Reading

    private struct Loaded: Sendable {
        var memos: [Memo]
        var transcripts: [String: (date: Date?, transcript: Transcript)]
        var downloaded: Set<String>
    }

    /// Reads the library again if Voice Memos has changed it since last time, or `force` is set.
    /// Returns whether it was read.
    @discardableResult
    func reload(force: Bool = false) async -> Bool {
        while let loading {
            await loading.value
            if !force { return false }
        }
        let change = library.lastChange()
        if !force, status == .ready, change == lastChange { return false }
        let task = Task { await read(change: change) }
        loading = task
        await task.value
        loading = nil
        return true
    }

    private func read(change: Date?) async {
        let library = library, scratch = scratch, cache = known
        let result = await Task.detached(priority: .utility) { () -> Result<Loaded, LibraryError> in
            do {
                let memos = try library.memos(scratch: scratch)
                var loaded = Loaded(memos: memos, transcripts: [:], downloaded: [])
                for memo in memos {
                    guard let audio = library.audioURL(for: memo) else { continue }
                    loaded.downloaded.insert(memo.id)
                    let date = try? audio.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    if let cached = cache[memo.id], cached.date == date {
                        loaded.transcripts[memo.id] = cached
                    } else if let transcript = (try? library.transcript(for: memo)) ?? nil {
                        loaded.transcripts[memo.id] = (date, transcript)
                    }
                }
                return .success(loaded)
            } catch let error as LibraryError {
                return .failure(error)
            } catch {
                return .failure(.unrecognized(error.localizedDescription))
            }
        }.value
        switch result {
        case .success(let loaded):
            memos = loaded.memos
            self.known = loaded.transcripts
            transcripts = loaded.transcripts.mapValues(\.transcript)
            downloaded = loaded.downloaded
            status = .ready
            lastChange = change
            if let selection, !memos.contains(where: { $0.id == selection }) { self.selection = nil }
        case .failure(let error):
            status = .problem(error)
            lastChange = nil
        }
        refreshPending()
    }

    private func refreshPending() {
        guard let folder, status == .ready else {
            pending = 0
            return
        }
        let options = preferences.options, memos = memos.filter { downloaded.contains($0.id) }
        do {
            pending = try folder.access { try Exporter(destination: $0, options: options).newMemos(memos).count }
        } catch let error as ExportError {
            pending = 0
            exportProblem = Describe.problem(error)
        } catch {
            pending = 0
        }
    }

    // MARK: Exporting

    func setFolder(_ url: URL) {
        exportProblem = nil
        failures = []
        folder = ExportFolder(url: url, scoped: false)
        // Reopened from the bookmark, so later exports work after a relaunch the same way.
        if let bookmark = ExportFolder.bookmark(for: url), let resolved = ExportFolder.resolve(bookmark) {
            preferences.folderBookmark = bookmark
            folder = resolved.folder
        } else {
            exportProblem = "macOS didn't let Memo Export remember this folder, so you'll need to choose it again after Memo Export quits."
        }
        refreshPending()
    }

    /// Exports what's new into the folder. Returns nil if there's no folder, the library can't be
    /// read, or an export is already running.
    @discardableResult
    func export(now: Date = Date()) async -> ExportReport? {
        guard let folder, status == .ready, !isExporting else { return nil }
        isExporting = true
        exportProblem = nil
        failures = []
        let memos = memos, options = preferences.options, library = library
        let result = await Task.detached(priority: .utility) { () -> Result<ExportReport, ExportError> in
            folder.access { url in
                do {
                    return .success(try Exporter(destination: url, options: options).export(memos, from: library, protected: [library.folder], now: now))
                } catch let error as ExportError {
                    return .failure(error)
                } catch {
                    return .failure(.cannotWrite(error.localizedDescription))
                }
            }
        }.value
        isExporting = false
        refreshPending()
        switch result {
        case .success(let report):
            failures = report.failed
            preferences.lastExport = (now, Describe.summary(report))
            onExport?(report)
            return report
        case .failure(let error):
            exportProblem = Describe.problem(error)
            return nil
        }
    }

    // MARK: Copying

    /// Puts a memo's transcript on the clipboard with its paragraphs, which copying out of Voice
    /// Memos loses.
    @discardableResult
    func copyTranscript(_ memo: Memo, timestamps: Bool, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let transcript = transcripts[memo.id] else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(Search.copyText(transcript, timestamps: timestamps, hours: memo.duration >= 3600), forType: .string)
    }
}
