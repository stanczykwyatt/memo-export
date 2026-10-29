import AppKit
import MemoCore
import ServiceManagement

/// What the menu's items do. The app delegate does them; tests record them.
@MainActor
protocol StatusMenuActions: AnyObject {
    func exportNow()
    func chooseFolder()
    func showFolder()
    func openWindow(memo: String?)
    func openPrivacySettings()
    func toggleOpenAtLogin()
    func optionsChanged()
    func showAbout()
}

/// Builds the menu bar menu fresh each time it opens.
@MainActor
final class StatusMenu: NSObject {
    private let model: MemoModel
    private weak var actions: StatusMenuActions?
    var now: () -> Date = Date.init
    var opensAtLogin: () -> Bool = { SMAppService.mainApp.status == .enabled }
    var home = VoiceMemosLibrary.realHome

    static let recentLimit = 8

    init(model: MemoModel, actions: StatusMenuActions) {
        self.model = model
        self.actions = actions
    }

    func build(into menu: NSMenu) {
        menu.removeAllItems()
        switch model.status {
        case .loading:
            menu.addItem(disabled("Reading Voice Memos…"))
        case .problem(.noPermission):
            menu.addItem(disabled("Needs Full Disk Access"))
            menu.addItem(disabled("Turn on Memo Export in Full Disk Access to read your memos. It can still only read Voice Memos.", small: true))
            menu.addItem(item("Open Privacy & Security Settings…", #selector(openPrivacySettings)))
        case .problem(let error):
            menu.addItem(disabled("Can't read Voice Memos"))
            menu.addItem(disabled(Describe.problem(error), small: true))
        case .ready:
            menu.addItem(disabled(model.memos.isEmpty ? "No memos yet" : "\(Describe.count(model.memos.count, "memo")) · \(model.withTranscripts) with transcripts"))
            if let last = model.lastExport {
                menu.addItem(disabled("Last export \(Describe.relative(last.date, now: now())): \(last.summary.prefix(1).lowercased() + last.summary.dropFirst())", small: true))
            }
        }
        if let problem = model.exportProblem {
            menu.addItem(disabled(problem, small: true, warning: true))
        } else if !model.failures.isEmpty {
            let names = model.failures.prefix(3).map(\.title).joined(separator: ", ")
            menu.addItem(disabled("Couldn't export \(names)\(model.failures.count > 3 ? " and \(model.failures.count - 3) more" : ""). \(model.failures[0].reason)", small: true, warning: true))
        }
        menu.addItem(.separator())

        if model.folder == nil {
            let choose = item("Choose Export Folder…", #selector(chooseFolder), key: "e")
            choose.isEnabled = model.status == .ready && !model.isExporting
            menu.addItem(choose)
        } else {
            let title = model.isExporting ? "Exporting…" : model.pending > 0 ? "Export \(Describe.count(model.pending, "New Memo"))" : "Export New Memos"
            let export = item(title, #selector(exportNow), key: "e")
            export.isEnabled = model.status == .ready && !model.isExporting
            menu.addItem(export)
            menu.addItem(folderItem())
        }
        menu.addItem(item("Open Memo Export…", #selector(openWindow), key: "o"))
        menu.addItem(recentItem())

        menu.addItem(.separator())
        menu.addItem(optionsItem())
        let automatic = item("Export New Memos Automatically", #selector(toggleAutomatic))
        automatic.state = model.preferences.exportsAutomatically ? .on : .off
        automatic.toolTip = "Exports each new memo a few minutes after it appears, while Memo Export is running."
        menu.addItem(automatic)
        let login = item("Open at Login", #selector(toggleOpenAtLogin))
        login.state = opensAtLogin() ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("About Memo Export", #selector(showAbout)))
        let quit = NSMenuItem(title: "Quit Memo Export", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: Parts

    private func folderItem() -> NSMenuItem {
        let path = model.folder.map { Describe.path($0.url, home: home) } ?? ""
        let item = NSMenuItem(title: "Export Folder: \(path)", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        let submenu = NSMenu()
        submenu.addItem(self.item("Show in Finder", #selector(showFolder)))
        let change = self.item("Choose Another Folder…", #selector(chooseFolder))
        change.isEnabled = !model.isExporting
        submenu.addItem(change)
        item.submenu = submenu
        return item
    }

    private func recentItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Recent Memos", action: nil, keyEquivalent: "")
        let recent = model.memos.prefix(Self.recentLimit)
        item.isEnabled = !recent.isEmpty
        let submenu = NSMenu()
        submenu.addItem(disabled("Click to read and copy", small: true))
        for memo in recent {
            var detail = [Describe.relative(memo.date, now: now()), Describe.duration(memo.duration)]
            if !model.downloaded.contains(memo.id) {
                detail.append("not downloaded")
            } else if model.transcripts[memo.id] == nil {
                detail.append("no transcript")
            }
            let entry = twoLine(memo.title, detail.joined(separator: " · "), #selector(openMemo(_:)))
            entry.representedObject = memo.id
            entry.image = NSImage(systemSymbolName: model.transcripts[memo.id] == nil ? "waveform" : "text.quote", accessibilityDescription: nil)
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    private func optionsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Export Options", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let preferences = model.preferences
        let options: [(String, Bool, Selector, String)] = [
            ("Copy the Audio", preferences.copiesAudio, #selector(toggleAudio), "Puts each recording's .m4a next to its note."),
            ("Save Subtitles (.srt)", preferences.writesSubtitles, #selector(toggleSubtitles), "Also writes SRT subtitles that players can show with the audio."),
            ("Group by Voice Memos Folder", preferences.groupsByFolder, #selector(toggleByFolder), "Puts memos exported from now on in subfolders named after their Voice Memos folders."),
            ("Obsidian Audio Links", preferences.links == .obsidian, #selector(toggleLinks), "On: ![[memo.m4a]], which Obsidian plays inline. Off: a standard Markdown link."),
        ]
        for (title, on, action, tip) in options {
            let option = self.item(title, action)
            option.state = on ? .on : .off
            option.toolTip = tip
            submenu.addItem(option)
        }
        item.submenu = submenu
        return item
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func twoLine(_ title: String, _ detail: String, _ action: Selector) -> NSMenuItem {
        let item = self.item(title, action)
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        text.append(NSAttributedString(string: "\n" + detail, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        item.attributedTitle = text
        return item
    }

    private func disabled(_ title: String, small: Bool = false, warning: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if small || warning {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            item.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: warning ? NSColor.systemOrange : NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ])
            if title.count > 44 { item.view = wrapping(item.attributedTitle!) }
        }
        return item
    }

    /// Long notes in the menu wrap instead of making it as wide as the screen.
    private func wrapping(_ text: NSAttributedString) -> NSView {
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = text
        label.preferredMaxLayoutWidth = 270
        label.frame.size = label.fittingSize
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: label.frame.height + 6))
        label.frame.origin = NSPoint(x: 14, y: 3)
        view.addSubview(label)
        return view
    }

    // MARK: Actions

    @objc private func exportNow() { actions?.exportNow() }
    @objc private func chooseFolder() { actions?.chooseFolder() }
    @objc private func showFolder() { actions?.showFolder() }
    @objc private func openWindow() { actions?.openWindow(memo: nil) }
    @objc private func openMemo(_ sender: NSMenuItem) { actions?.openWindow(memo: sender.representedObject as? String) }
    @objc private func openPrivacySettings() { actions?.openPrivacySettings() }
    @objc private func toggleOpenAtLogin() { actions?.toggleOpenAtLogin() }
    @objc private func showAbout() { actions?.showAbout() }

    @objc private func toggleAutomatic() {
        model.preferences.exportsAutomatically.toggle()
        actions?.optionsChanged()
    }

    @objc private func toggleAudio() {
        model.preferences.copiesAudio.toggle()
        actions?.optionsChanged()
    }

    @objc private func toggleSubtitles() {
        model.preferences.writesSubtitles.toggle()
        actions?.optionsChanged()
    }

    @objc private func toggleByFolder() {
        model.preferences.groupsByFolder.toggle()
        actions?.optionsChanged()
    }

    @objc private func toggleLinks() {
        model.preferences.links = model.preferences.links == .obsidian ? .markdown : .obsidian
        actions?.optionsChanged()
    }
}
