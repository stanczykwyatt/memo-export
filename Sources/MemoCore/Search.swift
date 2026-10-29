import Foundation

/// Finds memos by what was said in them, which Voice Memos can't do.
public enum Search {
    public struct Result: Equatable, Sendable {
        public var memo: Memo
        public var titleMatches: Bool
        /// The paragraphs that contain the words, in order.
        public var passages: [Passage]
    }

    /// Memos whose title or transcript contains every word of `query`, ignoring case and accents,
    /// in the order given. A paragraph counts if it has all the words; a memo whose words are spread
    /// across paragraphs still matches, with the paragraphs that have any of them.
    public static func run(_ query: String, in memos: [Memo], transcripts: [String: Transcript]) -> [Result] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return memos.map { Result(memo: $0, titleMatches: false, passages: []) } }
        return memos.compactMap { memo in
            let paragraphs = transcripts[memo.id]?.paragraphs ?? []
            let haystack = memo.title + "\n" + paragraphs.map(\.text).joined(separator: "\n")
            guard terms.allSatisfy({ contains(haystack, $0) }) else { return nil }
            let complete = paragraphs.filter { paragraph in terms.allSatisfy { contains(paragraph.text, $0) } }
            let partial = complete.isEmpty ? paragraphs.filter { paragraph in terms.contains { contains(paragraph.text, $0) } } : complete
            return Result(memo: memo, titleMatches: terms.allSatisfy { contains(memo.title, $0) }, passages: partial)
        }
    }

    static func contains(_ text: String, _ term: String) -> Bool {
        text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }

    /// Where each word of `query` appears in `text`, for highlighting.
    public static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        for term in query.split(whereSeparator: \.isWhitespace) {
            var start = text.startIndex
            while start < text.endIndex, let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: start..<text.endIndex) {
                found.append(range)
                start = range.upperBound
            }
        }
        return found.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// A transcript as text to paste anywhere: a blank line between paragraphs, optionally each
    /// starting with its time. Copying from Voice Memos loses the line breaks; this keeps them.
    public static func copyText(_ transcript: Transcript, timestamps: Bool, hours: Bool = false) -> String {
        transcript.paragraphs.map { paragraph in
            timestamps ? "[\(Describe.timestamp(paragraph.start, hours: hours))] \(paragraph.text)" : paragraph.text
        }.joined(separator: "\n\n")
    }
}
