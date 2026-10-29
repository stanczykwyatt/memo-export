import Foundation
import Testing
@testable import MemoCore

@Suite("Search")
struct SearchTests {
    let lecture = Fixtures.memo("A1")
    let groceries = Fixtures.memo("B2", title: "Grocery idea")
    let silent = Fixtures.memo("C3", title: "Café notes")
    var transcripts: [String: Transcript] {
        [
            "A1": Transcript(words: Fixtures.lecture.map { Word($0.0, start: $0.1, end: $0.2) }),
            "B2": Transcript(words: [Word("Buy", start: 0, end: 1), Word(" oat", start: 1, end: 2), Word(" milk.", start: 2, end: 3)]),
        ]
    }

    @Test func anEmptyQueryListsEverything() {
        let results = Search.run("  ", in: [lecture, groceries], transcripts: transcripts)
        #expect(results.map(\.memo.id) == ["A1", "B2"])
        #expect(results.allSatisfy { $0.passages.isEmpty })
    }

    @Test func findsWordsInTranscripts() {
        let results = Search.run("NEURONS", in: [lecture, groceries, silent], transcripts: transcripts)
        #expect(results.map(\.memo.id) == ["A1"])
        #expect(results[0].passages.map(\.start) == [5.0])
        #expect(!results[0].titleMatches)
    }

    @Test func everyWordMustBeThere() {
        #expect(Search.run("neurons milk", in: [lecture, groceries], transcripts: transcripts).isEmpty)
        // Spread over two paragraphs, the memo still matches, showing both.
        let spread = Search.run("potentiation synapse", in: [lecture], transcripts: transcripts)
        #expect(spread.first?.passages.count == 2)
    }

    @Test func titlesCountAndAccentsDont() {
        let results = Search.run("cafe", in: [lecture, groceries, silent], transcripts: transcripts)
        #expect(results.map(\.memo.id) == ["C3"])
        #expect(results[0].titleMatches)
        #expect(results[0].passages.isEmpty)
    }

    @Test func highlightRanges() {
        let text = "Neurons fire; the neuron rests."
        let ranges = Search.ranges(of: "neuron fire", in: text)
        #expect(ranges.map { String(text[$0]) } == ["Neuron", "fire", "neuron"])
        #expect(Search.ranges(of: "", in: text).isEmpty)
    }

    @Test func copiedTextKeepsParagraphs() {
        let transcript = transcripts["A1"]!
        #expect(Search.copyText(transcript, timestamps: false) == "Today we're looking at long-term potentiation.\n\nWhen two neurons fire together, the synapse between them gets stronger.")
        #expect(Search.copyText(transcript, timestamps: true).hasPrefix("[0:00] Today"))
        #expect(Search.copyText(transcript, timestamps: true, hours: true).contains("\n\n[0:00:05] When"))
    }
}
