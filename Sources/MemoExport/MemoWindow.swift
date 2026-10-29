import AppKit
import MemoCore
import SwiftUI

/// The main window: every memo, searchable by what was said, with its transcript in paragraphs
/// ready to copy.
struct MemoView: View {
    @Bindable var model: MemoModel
    var home = VoiceMemosLibrary.realHome
    var now: () -> Date = Date.init
    var export: () -> Void = {}
    var chooseFolder: () -> Void = {}
    var openPrivacySettings: () -> Void = {}
    /// The selected memo's color. Your accent color in the app; a fixed blue in the screenshots.
    var selectionColor = Color.accentColor

    @State var query = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch model.status {
            case .loading:
                ProgressView("Reading Voice Memos…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .problem(let error):
                problem(error)
            case .ready:
                if model.memos.isEmpty {
                    ContentUnavailableView {
                        Label("No memos yet", systemImage: "waveform")
                    } description: {
                        Text("Recordings you make in Voice Memos show up here, on this Mac or synced from your iPhone.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Searched once per redraw and shared by the list and the transcript.
                    let shown = results
                    HStack(spacing: 0) {
                        list(shown).frame(width: 300)
                        Divider()
                        detail(selected(in: shown)).frame(maxWidth: .infinity)
                    }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 440)
        // The window draws this anyway; drawing it here too keeps off-screen renders right in dark mode.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.status == .ready ? Describe.count(model.memos.count, "memo") : "Memo Export")
                    .font(.title2.weight(.semibold))
                if model.status == .ready {
                    Text("\(model.withTranscripts) with transcripts")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if model.status == .ready {
                search
            }
            if model.folder == nil {
                Button("Choose Export Folder…", action: chooseFolder)
                    .disabled(model.status != .ready)
            } else {
                Button(action: export) {
                    Text(model.isExporting ? "Exporting…" : model.pending > 0 ? "Export \(Describe.count(model.pending, "New Memo"))" : "Export New Memos")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.status != .ready || model.isExporting)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search what was said", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 250)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let problem = model.exportProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if let folder = model.folder {
                Label("Exporting to \(Describe.path(folder.url, home: home))", systemImage: "folder")
                if let last = model.lastExport {
                    Text("· last export \(Describe.relative(last.date, now: now()))")
                }
            } else {
                Label("Choose a folder, like one in your Obsidian vault, to export to.", systemImage: "folder.badge.plus")
            }
            Spacer()
            Text("Read-only: your memos are never changed.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func problem(_ error: LibraryError) -> some View {
        if error == .noPermission {
            ContentUnavailableView {
                Label("Turn on Full Disk Access", systemImage: "lock.shield")
            } description: {
                Text("macOS keeps Voice Memos' recordings private. Turn on Memo Export in System Settings → Privacy & Security → Full Disk Access, then come back here. The App Sandbox still keeps it to Voice Memos, read-only, and the folder you choose.")
            } actions: {
                Button("Open Privacy & Security Settings…", action: openPrivacySettings)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Can't read Voice Memos", systemImage: "waveform.slash")
            } description: {
                Text(Describe.problem(error))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: The list

    private var results: [Search.Result] {
        Search.run(query, in: model.memos, transcripts: model.transcripts)
    }

    private func selected(in shown: [Search.Result]) -> Memo? {
        if let id = model.selection, let match = shown.first(where: { $0.memo.id == id }) { return match.memo }
        return shown.first?.memo
    }

    private func list(_ shown: [Search.Result]) -> some View {
        let current = selected(in: shown)?.id
        return ScrollView {
            VStack(spacing: 2) {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(shown.isEmpty ? "Nothing matches \"\(query)\"" : "\(Describe.count(shown.count, "memo")) \(shown.count == 1 ? "mentions" : "mention") \"\(query)\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                ForEach(shown, id: \.memo.id) { result in
                    row(result, selected: result.memo.id == current)
                }
            }
            .padding(8)
        }
    }

    private func row(_ result: Search.Result, selected: Bool) -> some View {
        let memo = result.memo
        var details = [model.preferences.options.renderer.fileDate(memo.date), Describe.duration(memo.duration)]
        if let folder = memo.folder { details.append(folder) }
        return Button {
            model.selection = memo.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(memo.title).font(.body.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    if !model.downloaded.contains(memo.id) {
                        Image(systemName: "icloud.and.arrow.down").help("Not downloaded from iCloud yet")
                    } else if model.transcripts[memo.id] == nil {
                        Image(systemName: "text.badge.xmark").help("No transcript yet")
                    }
                }
                Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                if let passage = result.passages.first {
                    Text(highlighted(passage.text, around: query, limit: 110))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? selectionColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: The transcript

    @ViewBuilder
    private func detail(_ selected: Memo?) -> some View {
        if let memo = selected {
            let transcript = model.transcripts[memo.id]
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(memo.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                        Text(subtitle(memo)).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    if transcript != nil {
                        Button("Copy Transcript") { model.copyTranscript(memo, timestamps: false) }
                        Button("Copy with Times") { model.copyTranscript(memo, timestamps: true) }
                    }
                }
                .padding(16)
                Divider()
                if let transcript {
                    ScrollView {
                        let hours = memo.duration >= 3600
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(transcript.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(Describe.timestamp(paragraph.start, hours: hours))
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: hours ? 60 : 44, alignment: .trailing)
                                    Text(highlighted(paragraph.text, around: query, limit: nil))
                                        .textSelection(.enabled)
                                        .lineSpacing(3)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(16)
                    }
                } else {
                    ContentUnavailableView {
                        Label(model.downloaded.contains(memo.id) ? "No transcript yet" : "Not downloaded yet", systemImage: "text.badge.xmark")
                    } description: {
                        Text(model.downloaded.contains(memo.id)
                             ? "Open the recording in Voice Memos and click the transcript button. It shows up here, and in its exported note, once Voice Memos has made it."
                             : "This recording is in iCloud but not on this Mac yet. Play it once in Voice Memos to download it.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            ContentUnavailableView.search(text: query)
        }
    }

    private func subtitle(_ memo: Memo) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        var parts = [formatter.string(from: memo.date), Describe.duration(memo.duration)]
        if let folder = memo.folder { parts.append(folder) }
        return parts.joined(separator: " · ")
    }

    /// The text with the searched words in bold and tinted. With a `limit`, it's cut to a snippet
    /// that starts a little before the first match.
    private func highlighted(_ text: String, around query: String, limit: Int?) -> AttributedString {
        var text = text
        let ranges = Search.ranges(of: query, in: text)
        if let limit, let first = ranges.first {
            let lead = text.distance(from: text.startIndex, to: first.lowerBound)
            if lead > 30 {
                let start = text.index(first.lowerBound, offsetBy: -24)
                let space = text[start...].firstIndex(of: " ").map { text.index(after: $0) } ?? start
                text = "…" + text[space...]
            }
            if text.count > limit { text = String(text.prefix(limit)) + "…" }
        }
        var out = AttributedString()
        var cursor = text.startIndex
        for range in Search.ranges(of: query, in: text) where range.lowerBound >= cursor {
            out += AttributedString(text[cursor..<range.lowerBound])
            var match = AttributedString(text[range])
            match.font = .body.bold()
            match.backgroundColor = Color.yellow.opacity(0.35)
            out += match
            cursor = range.upperBound
        }
        out += AttributedString(text[cursor...])
        return out
    }
}

/// The window, made the first time it's opened and kept for next time.
@MainActor
final class MemoWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let makeView: () -> MemoView
    /// Called when you close the window.
    var onClose: (() -> Void)?
    /// Called when the window comes to the front.
    var onActivate: (() -> Void)?

    init(makeView: @escaping () -> MemoView) {
        self.makeView = makeView
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onActivate?()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: makeView()))
        window.title = "Memo Export"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 900, height: 600))
        if !window.setFrameUsingName("MemoWindow") {
            window.center()
        }
        window.setFrameAutosaveName("MemoWindow")
        return window
    }
}
