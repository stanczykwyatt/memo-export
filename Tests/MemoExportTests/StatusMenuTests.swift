import AppKit
import Foundation
import Testing
@testable import MemoCore
@testable import MemoExport

@MainActor
final class RecordedActions: StatusMenuActions {
    var calls: [String] = []
    func exportNow() { calls.append("export") }
    func chooseFolder() { calls.append("choose") }
    func showFolder() { calls.append("show") }
    func openWindow(memo: String?) { calls.append("window:\(memo ?? "-")") }
    func openPrivacySettings() { calls.append("privacy") }
    func toggleOpenAtLogin() { calls.append("login") }
    func optionsChanged() { calls.append("options") }
    func showAbout() { calls.append("about") }
}

/// The menu, built into an NSMenu that's never shown.
@MainActor
@Suite("Menu")
struct StatusMenuTests {
    let folder = TestFolder()
    let actions = RecordedActions()

    private func build(_ model: MemoModel) -> NSMenu {
        let statusMenu = StatusMenu(model: model, actions: actions)
        statusMenu.now = { Gallery.now }
        statusMenu.opensAtLogin = { true }
        statusMenu.home = folder.url
        let menu = NSMenu()
        statusMenu.build(into: menu)
        // Keeps the builder alive for the menu's targets, as the app delegate does.
        objc_setAssociatedObject(menu, "builder", statusMenu, .OBJC_ASSOCIATION_RETAIN)
        return menu
    }

    private func titles(_ menu: NSMenu?) -> [String] {
        menu?.items.map { $0.isSeparatorItem ? "—" : ($0.attributedTitle?.string ?? $0.title) } ?? []
    }

    private func item(_ menu: NSMenu?, _ title: String) throws -> NSMenuItem {
        try #require(menu?.items.first { ($0.attributedTitle?.string ?? $0.title).components(separatedBy: "\n")[0] == title }, "No item titled \(title)")
    }

    private func click(_ item: NSMenuItem) {
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
    }

    @Test func beforeChoosingAFolder() async throws {
        let menu = build(try await Gallery.model(in: folder))
        #expect(titles(menu).first == "6 memos · 4 with transcripts")
        let choose = try item(menu, "Choose Export Folder…")
        #expect(choose.isEnabled)
        #expect(choose.keyEquivalent == "e")
        click(choose)
        #expect(actions.calls == ["choose"])
        #expect(!titles(menu).contains { $0.hasPrefix("Export Folder") })
    }

    @Test func withAFolder() async throws {
        let model = try await Gallery.model(in: folder, exportTo: folder.sub("Notes/Memos"))
        let menu = build(model)
        let export = try item(menu, "Export 5 New Memos")
        click(export)
        let folderItem = try item(menu, "Export Folder: ~/Notes/Memos")
        click(try item(folderItem.submenu, "Show in Finder"))
        click(try item(folderItem.submenu, "Choose Another Folder…"))
        #expect(actions.calls == ["export", "show", "choose"])
    }

    @Test func afterAnExport() async throws {
        let model = try await Gallery.model(in: folder, exportTo: folder.sub("Notes"))
        _ = await model.export(now: Gallery.now.addingTimeInterval(-300))
        let menu = build(model)
        #expect(titles(menu).contains("Last export 5 min ago: exported 5 new memos, 1 waiting for iCloud"))
        #expect(try item(menu, "Export New Memos").isEnabled)
    }

    @Test func recentMemos() async throws {
        let menu = build(try await Gallery.model(in: folder))
        let recent = try item(menu, "Recent Memos").submenu
        let titles = titles(recent)
        #expect(titles.count == 7)
        #expect(titles[1] == "Lecture: synaptic plasticity\n1 hr ago · 18:42")
        #expect(titles.contains("Melody for the bridge\n2 days ago · 0:41 · no transcript"))
        #expect(titles.contains("Voice note from the walk home\n4 days ago · 3:28 · not downloaded"))
        click(try item(recent, "Grocery idea"))
        #expect(actions.calls == ["window:MEMO-3"])
    }

    @Test func options() async throws {
        let model = try await Gallery.model(in: folder)
        let menu = build(model)
        let options = try item(menu, "Export Options").submenu
        #expect(try item(options, "Copy the Audio").state == .on)
        #expect(try item(options, "Save Subtitles (.srt)").state == .off)
        #expect(try item(options, "Obsidian Audio Links").state == .on)
        click(try item(options, "Save Subtitles (.srt)"))
        click(try item(options, "Obsidian Audio Links"))
        click(try item(options, "Group by Voice Memos Folder"))
        click(try item(options, "Copy the Audio"))
        #expect(model.preferences.writesSubtitles)
        #expect(model.preferences.links == .markdown)
        #expect(model.preferences.groupsByFolder)
        #expect(!model.preferences.copiesAudio)
        let automatic = try item(menu, "Export New Memos Automatically")
        #expect(automatic.state == .off)
        click(automatic)
        #expect(model.preferences.exportsAutomatically)
        #expect(actions.calls == Array(repeating: "options", count: 5))
        #expect(try item(build(model), "Export New Memos Automatically").state == .on)
    }

    @Test func needingFullDiskAccess() async throws {
        let library = folder.sub("Locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: library.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: library.path) }
        let model = MemoModel(library: VoiceMemosLibrary(folder: library), preferences: testPreferences(), scratch: folder.sub("s"))
        await model.reload()
        let menu = build(model)
        #expect(titles(menu).first == "Needs Full Disk Access")
        #expect(try !item(menu, "Choose Export Folder…").isEnabled)
        click(try item(menu, "Open Privacy & Security Settings…"))
        #expect(actions.calls == ["privacy"])
    }

    @Test func anEmptyOrMissingLibrary() async throws {
        let model = MemoModel(library: VoiceMemosLibrary(folder: folder.url.appendingPathComponent("none")), preferences: testPreferences(), scratch: folder.sub("s"))
        await model.reload()
        let menu = build(model)
        #expect(titles(menu).first == "Can't read Voice Memos")
        #expect(try !item(menu, "Recent Memos").isEnabled)
    }

    @Test func theRest() async throws {
        let menu = build(try await Gallery.model(in: folder))
        #expect(try item(menu, "Open at Login").state == .on)
        click(try item(menu, "Open at Login"))
        click(try item(menu, "Open Memo Export…"))
        click(try item(menu, "About Memo Export"))
        #expect(actions.calls == ["login", "window:-", "about"])
        #expect(try item(menu, "Quit Memo Export").keyEquivalent == "q")
    }
}
