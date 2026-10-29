import Foundation

/// The folder memos are exported to. The App Sandbox only lets the app write to a folder you
/// picked, so it's kept as a security-scoped bookmark and opened for the length of each export.
struct ExportFolder: Sendable {
    let url: URL
    /// Whether macOS has to be asked for access first. False for the folders tests make.
    let scoped: Bool

    init(url: URL, scoped: Bool) {
        self.url = url
        self.scoped = scoped
    }

    /// The folder a bookmark points to, and a fresh bookmark if macOS says the old one is stale,
    /// like after the folder was moved.
    static func resolve(_ bookmark: Data) -> (folder: ExportFolder, refreshed: Data?)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale) else {
            return nil
        }
        let folder = ExportFolder(url: url, scoped: true)
        guard stale else { return (folder, nil) }
        return (folder, folder.access { try? $0.bookmarkData(options: .withSecurityScope) })
    }

    static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope)
    }

    /// Runs `body` with the folder open to the app.
    func access<T>(_ body: (URL) throws -> T) rethrows -> T {
        let started = scoped && url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }
}
