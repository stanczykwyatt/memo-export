import Foundation

/// One word of a transcript, and when it was said, in seconds from the start of the recording.
public struct Word: Equatable, Sendable {
    /// The word as Voice Memos wrote it, usually with the space before it.
    public var text: String
    public var start: Double
    public var end: Double

    public init(_ text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }

    /// Ends a sentence, so it's a good place to start a new paragraph.
    var endsSentence: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]»"))
        guard let last = trimmed.last else { return false }
        return ".?!…。？！".contains(last)
    }
}

/// A stretch of a transcript shown together: a paragraph in Markdown, or one subtitle.
public struct Passage: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum TranscriptError: Error, Equatable {
    /// The box is there but isn't the JSON Voice Memos writes.
    case unrecognized
}

/// The transcript Voice Memos saves inside a recording: every word with its timing.
public struct Transcript: Equatable, Sendable {
    public let words: [Word]
    /// The language it was transcribed in, like `en_US`.
    public let locale: String?
    /// Paragraphs for reading: a new one after a pause, or at the end of a sentence once the
    /// current one has run a while, so a long memo doesn't come out as one wall of text. Worked
    /// out once, since search and the window read them often.
    public let paragraphs: [Passage]

    /// No recording runs anywhere near this long, in seconds. Times past it are damage.
    static let longest: Double = 10_000_000

    public init(words: [Word], locale: String? = nil) {
        self.words = words
        self.locale = locale
        paragraphs = Self.split(words) { start, _, previous, word in
            let gap = word.start - previous.end
            let length = word.end - start
            if gap >= 2 || word.text.hasPrefix("\n") { return true }
            if previous.endsSentence && length >= 25 { return true }
            return length >= 90
        }
    }

    /// Reads the JSON in a recording's `tsrp` box: an attributed string whose runs alternate
    /// between a piece of text and the index of its attributes, each holding a `timeRange`.
    public static func decode(_ data: Data) throws -> Transcript {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let string = root["attributedString"] as? [String: Any],
            let runs = string["runs"] as? [Any]
        else { throw TranscriptError.unrecognized }
        let table = string["attributeTable"] as? [Any] ?? []
        let locale = (root["locale"] as? [String: Any])?["identifier"] as? String

        var words: [Word] = []
        var index = 0
        while index < runs.count {
            guard let text = runs[index] as? String else { throw TranscriptError.unrecognized }
            let attributes = index + 1 < runs.count ? runs[index + 1] as? Int : nil
            index += 2
            if let range = attributes.flatMap({ timeRange(in: table, at: $0) }) {
                words.append(Word(text, start: range.start, end: range.end))
            } else if !words.isEmpty {
                // Text without timing, like punctuation on its own, belongs with the word before.
                words[words.count - 1].text += text
            } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                words.append(Word(text, start: 0, end: 0))
            }
        }
        return Transcript(words: words, locale: locale)
    }

    private static func timeRange(in table: [Any], at index: Int) -> (start: Double, end: Double)? {
        guard table.indices.contains(index),
              let entry = table[index] as? [String: Any],
              let range = entry["timeRange"] as? [Any], range.count == 2,
              let start = (range[0] as? NSNumber)?.doubleValue, let end = (range[1] as? NSNumber)?.doubleValue,
              start.isFinite, end.isFinite, start >= 0, start <= longest
        else { return nil }
        return (start, min(max(start, end), longest))
    }

    public var isEmpty: Bool { words.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    /// Every word, as one line of text.
    public var text: String { Self.join(words[...]) }

    /// Short stretches for subtitles: at most about six seconds and two lines each.
    public var cues: [Passage] {
        Self.split(words) { start, characters, previous, word in
            let gap = word.start - previous.end
            let length = word.end - start
            if gap >= 1 || word.text.hasPrefix("\n") { return true }
            if previous.endsSentence && length >= 1.5 { return true }
            return length > 6 || characters + word.text.count > 84
        }
    }

    /// Groups the words, starting a new group whenever `breaks` says to before a word. It's told
    /// when the group started and how many characters it has so far.
    private static func split(_ words: [Word], where breaks: (_ start: Double, _ characters: Int, _ previous: Word, _ word: Word) -> Bool) -> [Passage] {
        var passages: [Passage] = []
        var start = 0
        var characters = 0
        func close(_ end: Int) {
            let slice = words[start..<end]
            let text = join(slice)
            if !text.isEmpty, let first = slice.first, let last = slice.last {
                passages.append(Passage(start: first.start, end: last.end, text: text))
            }
            start = end
            characters = 0
        }
        for (index, word) in words.enumerated() {
            if index > start, breaks(words[start].start, characters, words[index - 1], word) {
                close(index)
            }
            characters += word.text.count
        }
        close(words.count)
        return passages
    }

    /// Joins words into text, with single spaces and no line breaks.
    static func join(_ words: ArraySlice<Word>) -> String {
        words.map(\.text).joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
