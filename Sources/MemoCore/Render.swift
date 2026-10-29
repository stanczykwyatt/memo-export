import Foundation

/// How the Markdown note links to its audio.
public enum LinkStyle: String, CaseIterable, Codable, Sendable {
    /// `![[file.m4a]]`, which Obsidian shows as a player.
    case obsidian
    /// `[Audio](<file.m4a>)`, which works in any Markdown app.
    case markdown
}

/// Turns a memo and its transcript into the files that are written: a Markdown note and SRT
/// subtitles.
public struct Renderer: Sendable {
    public var timeZone: TimeZone
    public var locale: Locale
    public var links: LinkStyle

    public init(timeZone: TimeZone = .current, locale: Locale = .current, links: LinkStyle = .obsidian) {
        self.timeZone = timeZone
        self.locale = locale
        self.links = links
    }

    /// The note: front matter for Obsidian and other note apps, the title, a link to the audio,
    /// then the transcript in paragraphs, each starting with when it was said.
    public func markdown(_ memo: Memo, transcript: Transcript?, audioFile: String?) -> String {
        var lines = ["---"]
        lines.append("title: \(Self.yaml(memo.title))")
        lines.append("date: \(isoDate(memo.date))")
        lines.append("duration: \(Self.yaml(Describe.duration(memo.duration)))")
        if let folder = memo.folder { lines.append("folder: \(Self.yaml(folder))") }
        if let audioFile { lines.append("audio: \(Self.yaml(audioFile))") }
        if let locale = transcript?.locale { lines.append("language: \(Self.yaml(locale))") }
        lines.append("source: Voice Memos")
        lines.append("voice-memo-id: \(Self.yaml(memo.id))")
        lines.append("tags:")
        lines.append("  - voice-memo")
        lines.append("---")
        lines.append("")
        lines.append("# \(Self.heading(memo.title))")
        lines.append("")
        var details = [longDate(memo.date), Describe.duration(memo.duration)]
        if let folder = memo.folder { details.append(Self.inline(folder)) }
        lines.append(details.joined(separator: " · "))
        lines.append("")
        if let audioFile {
            switch links {
            case .obsidian: lines.append("![[\(audioFile)]]")
            case .markdown: lines.append("[Audio](<\(audioFile)>)")
            }
            lines.append("")
        }
        if let transcript, !transcript.isEmpty {
            let hours = memo.duration >= 3600 || (transcript.words.last?.end ?? 0) >= 3600
            for paragraph in transcript.paragraphs {
                lines.append("**\(Describe.timestamp(paragraph.start, hours: hours))** \(Self.escape(paragraph.text))")
                lines.append("")
            }
        } else {
            lines.append("*No transcript yet. Open the recording in Voice Memos and click the transcript button to make one; the next export adds it here.*")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// The transcript as SubRip subtitles, which video and audio players can show alongside the recording.
    public func subtitles(_ transcript: Transcript) -> String {
        var blocks: [String] = []
        for (index, cue) in transcript.cues.enumerated() {
            let end = max(cue.end, cue.start + 0.5)
            blocks.append("\(index + 1)\n\(Self.srtTime(cue.start)) --> \(Self.srtTime(end))\n\(Self.wrap(Self.visible(cue.text), width: 42).joined(separator: "\n"))\n")
        }
        return blocks.joined(separator: "\n")
    }

    // MARK: Dates

    func isoDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    func longDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// The date part of a file name, which sorts in recording order.
    public func fileDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: Text

    /// A double-quoted YAML string, safe for any title.
    static func yaml(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default:
                // Control and invisible formatting characters are written as escapes, so nothing
                // hides in the front matter. YAML reads them back as they were.
                if [.control, .format, .lineSeparator, .paragraphSeparator].contains(scalar.properties.generalCategory) {
                    out += scalar.value > 0xFFFF ? String(format: "\\U%08X", scalar.value) : String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// A title on one line, for a Markdown heading.
    static func heading(_ title: String) -> String {
        let flat = inline(title)
        return flat.isEmpty ? "New Recording" : flat
    }

    /// Text on one line, escaped for Markdown.
    static func inline(_ text: String) -> String {
        escape(visible(text).components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces))
    }

    /// Escapes what Markdown would otherwise read as formatting or HTML, so spoken words come out
    /// as written. Only characters that can start formatting are escaped, to keep the text readable.
    static func escape(_ text: String) -> String {
        let characters = Array(visible(text))
        var out = ""
        for (index, character) in characters.enumerated() {
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let previous = index > 0 ? characters[index - 1] : nil
            // Single characters that start formatting, and the pairs Obsidian reads as comments,
            // highlights and strikethrough. An ampersand only when it could start an entity.
            let pair = "%=~".contains(character) && (next == character || previous == character)
            let entity = character == "&" && Self.startsEntity(characters[(index + 1)...])
            if "\\`*_<>[]#$".contains(character) || pair || entity { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// Whether what follows an ampersand would make it an HTML entity, like `&amp;` or `&#38;`.
    static func startsEntity(_ rest: ArraySlice<Character>) -> Bool {
        let name = rest.prefix(12).prefix { $0.isLetter || $0.isNumber || $0 == "#" }
        return !name.isEmpty && rest.dropFirst(name.count).first == ";"
    }

    /// Text without control characters or the invisible marks that flip its direction, which
    /// could make words read differently from what's there.
    static func visible(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !isHidden(scalar) || scalar == "\n" {
            out.append(scalar)
        }
        return String(out)
    }

    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control
            || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
            || scalar.value == 0x200E || scalar.value == 0x200F || scalar.value == 0x061C
    }

    static func srtTime(_ seconds: Double) -> String {
        let millis = Int((min(max(0, seconds.isFinite ? seconds : 0), Transcript.longest) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", millis / 3_600_000, millis / 60000 % 60, millis / 1000 % 60, millis % 1000)
    }

    /// Breaks text into lines of about `width` characters, at most two, splitting the text evenly.
    static func wrap(_ text: String, width: Int) -> [String] {
        guard text.count > width else { return [text] }
        let words = text.split(separator: " ").map(String.init)
        var best = [text]
        var bestScore = Int.max
        for split in 1..<max(words.count, 2) where split < words.count {
            let first = words[..<split].joined(separator: " "), second = words[split...].joined(separator: " ")
            let score = abs(first.count - second.count)
            if score < bestScore {
                bestScore = score
                best = [first, second]
            }
        }
        return best
    }

    // MARK: File names

    /// The base name for a memo's files, without an extension: its date and title, with anything
    /// a file name or a wiki link can't hold taken out.
    public func baseName(_ memo: Memo) -> String {
        "\(fileDate(memo.date)) \(Self.safeName(memo.title))"
    }

    /// A name that's safe as a file or folder name on any Mac, and inside an Obsidian `[[link]]`.
    public static func safeName(_ name: String, fallback: String = "New Recording") -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            if "/\\:*?\"<>|[]#^".unicodeScalars.contains(scalar) || isHidden(scalar) {
                out += " "
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        var cleaned = out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        // File names are limited to 255 bytes, and the date, a number and an extension come too.
        while cleaned.utf8.count > 180 { cleaned.removeLast() }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? fallback : cleaned
    }
}
