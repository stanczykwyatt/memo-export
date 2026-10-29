import Foundation

/// The wording shown in the menu, the window, the command line and the notes.
public enum Describe {
    /// A recording's length, like `0:55` or `1:02:05`.
    public static func duration(_ seconds: Double) -> String {
        timestamp(seconds.rounded(), hours: seconds.rounded() >= 3600)
    }

    /// A moment in a recording, like `2:05`, or `0:02:05` when the recording runs over an hour,
    /// so every timestamp in a note lines up.
    public static func timestamp(_ seconds: Double, hours: Bool = false) -> String {
        let total = Int(min(max(0, seconds.isFinite ? seconds : 0), Transcript.longest))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        if hours || h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    public static func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(value) \(value == 1 ? singular : plural ?? singular + "s")"
    }

    /// How long ago, in the menu's words: "just now", "5 min ago", "3 hr ago", "yesterday", "4 days ago".
    public static func relative(_ date: Date, now: Date) -> String {
        let seconds = min(now.timeIntervalSince(date), 1e11)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) hr ago" }
        let days = Int(seconds / 86400)
        return days == 1 ? "yesterday" : "\(days) days ago"
    }

    /// A path with the home folder written as `~`.
    public static func path(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path, base = home.standardizedFileURL.path
        if path == base { return "~" }
        if path.hasPrefix(base + "/") { return "~" + path.dropFirst(base.count) }
        return path
    }

    /// What an export did, in one line.
    public static func summary(_ report: ExportReport) -> String {
        var parts: [String] = []
        if !report.exported.isEmpty { parts.append("Exported \(count(report.exported.count, "new memo"))") }
        if !report.updated.isEmpty { parts.append("updated \(count(report.updated.count, "note"))") }
        if !report.waiting.isEmpty { parts.append("\(report.waiting.count) waiting for iCloud") }
        if !report.failed.isEmpty { parts.append("\(report.failed.count) failed") }
        if parts.isEmpty { return "No new memos" }
        var line = parts.joined(separator: ", ")
        line.replaceSubrange(line.startIndex...line.startIndex, with: line.prefix(1).uppercased())
        return line
    }

    public static func problem(_ error: LibraryError) -> String {
        switch error {
        case .notFound: "No Voice Memos library on this Mac yet. Record a memo, or turn on Voice Memos in iCloud settings."
        case .noPermission: "Memo Export needs Full Disk Access to read your Voice Memos."
        case .unrecognized(let detail): detail
        }
    }
}
