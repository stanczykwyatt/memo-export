import AppKit
import MemoCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, StatusMenuActions {
    private let preferences = Preferences()
    private let menu = NSMenu()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private lazy var model = MemoModel(
        library: VoiceMemosLibrary(home: VoiceMemosLibrary.realHome),
        preferences: preferences,
        scratch: FileManager.default.temporaryDirectory
    )
    private lazy var statusMenu = StatusMenu(model: model, actions: self)
    private lazy var window = MemoWindowController { [unowned self] in
        MemoView(
            model: model,
            export: { [unowned self] in exportNow() },
            chooseFolder: { [unowned self] in chooseFolder() },
            openPrivacySettings: { [unowned self] in openPrivacySettings() }
        )
    }

    /// How often to look for new memos. Looking is one file date unless something changed.
    static let checkInterval: TimeInterval = 2 * 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItem()

        // Gives the keyboard back to the app you were using.
        window.onClose = { NSApp.hide(nil) }
        // Coming back from System Settings after turning on access, or from recording a memo.
        window.onActivate = { [weak self] in self?.check() }

        check()
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // The first time, open at login like most menu bar utilities, and show the window so it's
        // clear what the app does and whether it needs Full Disk Access. Turn off login in the menu.
        if !preferences.launchedBefore {
            preferences.launchedBefore = true
            try? SMAppService.mainApp.register()
            openWindow(memo: nil)
        }
    }

    /// Reads the library if it changed, then exports if that's turned on: new memos, and
    /// transcripts or renames for ones exported before.
    private func check(force: Bool = false) {
        Task {
            let changed = await model.reload(force: force || model.status != .ready)
            if preferences.exportsAutomatically, changed || model.pending > 0 {
                await model.export()
            }
            updateStatusItem()
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let attention = model.status == .problem(.noPermission) || model.exportProblem != nil || !model.failures.isEmpty
        button.image = StatusIcon.image(alert: attention)
        var tip = "Memo Export"
        if model.status == .ready {
            tip += "\n\(Describe.count(model.memos.count, "memo")), \(model.withTranscripts) with transcripts."
            if model.pending > 0 { tip += "\n\(Describe.count(model.pending, "new memo")) to export." }
        } else if case .problem(let error) = model.status {
            tip += "\n" + Describe.problem(error)
        }
        button.toolTip = tip
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        statusMenu.build(into: menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        check()
    }

    // MARK: StatusMenuActions

    func exportNow() {
        guard model.folder != nil else {
            chooseFolder()
            return
        }
        Task {
            await model.reload()
            await model.export()
            updateStatusItem()
        }
    }

    func chooseFolder() {
        // Changing folders partway through an export would leave it half in each.
        guard !model.isExporting else { return }
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "Choose Where to Export Memos"
        panel.message = "Each memo is saved here as Markdown, with its audio. A folder in your Obsidian vault works well."
        panel.prompt = "Export Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.folder?.url ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            if Exporter.isInside(url, model.library.folder) {
                let alert = NSAlert()
                alert.messageText = "Choose a folder outside Voice Memos"
                alert.informativeText = "Memo Export never writes inside the Voice Memos library."
                alert.runModal()
            } else {
                model.setFolder(url)
                exportNow()
            }
        }
        if !window.isVisible {
            NSApp.hide(nil)
        }
    }

    func showFolder() {
        guard let url = model.folder?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openWindow(memo: String?) {
        if let memo { model.selection = memo }
        window.show()
    }

    func openPrivacySettings() {
        // The one page the app ever opens: where you turn on Full Disk Access.
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func toggleOpenAtLogin() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
    }

    func optionsChanged() {
        // New options can mean audio or subtitles to add to memos exported before.
        check(force: preferences.exportsAutomatically)
    }

    func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "Free and open source. No internet access.\ngithub.com/stanczykwyatt/memo-export",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            ),
        ])
    }
}
