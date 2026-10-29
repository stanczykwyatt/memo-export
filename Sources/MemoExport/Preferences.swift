import Foundation
import MemoCore

/// Settings, kept in the app's sandbox container.
struct Preferences {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let folder = "exportFolderBookmark"
        static let audio = "copiesAudio"
        static let subtitles = "writesSubtitles"
        static let byFolder = "groupsByFolder"
        static let links = "linkStyle"
        static let automatic = "exportsAutomatically"
        static let launchedBefore = "launchedBefore"
        static let lastExport = "lastExport"
        static let lastSummary = "lastExportSummary"
    }

    /// A security-scoped bookmark to the folder you chose, so the sandbox lets the app back in later.
    var folderBookmark: Data? {
        get { defaults.data(forKey: Key.folder) }
        nonmutating set { defaults.set(newValue, forKey: Key.folder) }
    }

    var copiesAudio: Bool {
        get { defaults.object(forKey: Key.audio) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.audio) }
    }

    var writesSubtitles: Bool {
        get { defaults.bool(forKey: Key.subtitles) }
        nonmutating set { defaults.set(newValue, forKey: Key.subtitles) }
    }

    var groupsByFolder: Bool {
        get { defaults.bool(forKey: Key.byFolder) }
        nonmutating set { defaults.set(newValue, forKey: Key.byFolder) }
    }

    var links: LinkStyle {
        get { defaults.string(forKey: Key.links).flatMap(LinkStyle.init(rawValue:)) ?? .obsidian }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.links) }
    }

    /// Export new memos as they appear, without being asked. Off until turned on.
    var exportsAutomatically: Bool {
        get { defaults.bool(forKey: Key.automatic) }
        nonmutating set { defaults.set(newValue, forKey: Key.automatic) }
    }

    var launchedBefore: Bool {
        get { defaults.bool(forKey: Key.launchedBefore) }
        nonmutating set { defaults.set(newValue, forKey: Key.launchedBefore) }
    }

    /// When the last export finished, and what it did.
    var lastExport: (date: Date, summary: String)? {
        get {
            guard let date = defaults.object(forKey: Key.lastExport) as? Date, let summary = defaults.string(forKey: Key.lastSummary) else { return nil }
            return (date, summary)
        }
        nonmutating set {
            defaults.set(newValue?.date, forKey: Key.lastExport)
            defaults.set(newValue?.summary, forKey: Key.lastSummary)
        }
    }

    var options: ExportOptions {
        ExportOptions(audio: copiesAudio, subtitles: writesSubtitles, byFolder: groupsByFolder, renderer: Renderer(links: links))
    }
}
