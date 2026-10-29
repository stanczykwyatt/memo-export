import Foundation
import Testing
@testable import MemoCore

@Suite("Transcripts")
struct TranscriptTests {
    @Test func decodesWordsAndTimes() throws {
        let transcript = try Transcript.decode(Fixtures.transcriptJSON(Fixtures.lecture, locale: "en_GB"))
        #expect(transcript.locale == "en_GB")
        #expect(transcript.words.count == Fixtures.lecture.count)
        #expect(transcript.words[1] == Word(" we're", start: 0.4, end: 0.7))
        #expect(transcript.text == "Today we're looking at long-term potentiation. When two neurons fire together, the synapse between them gets stronger.")
    }

    @Test func keysCanComeInAnyOrder() throws {
        let json = #"{"attributedString":{"attributeTable":[{"timeRange":[0,1.5]}],"runs":["Hello",0]},"locale":{"current":1,"identifier":"en_US"}}"#
        let transcript = try Transcript.decode(Data(json.utf8))
        #expect(transcript.words == [Word("Hello", start: 0, end: 1.5)])
    }

    @Test func textWithoutTimingJoinsTheWordBefore() throws {
        // A run that points past the table, or at an entry with no time range, has no timing of its own.
        let json = #"{"attributedString":{"attributeTable":[{"timeRange":[0,1]},{"other":true}],"runs":["Wait",0,"!",1," Now",7]}}"#
        let transcript = try Transcript.decode(Data(json.utf8))
        #expect(transcript.words == [Word("Wait! Now", start: 0, end: 1)])
        #expect(transcript.locale == nil)
    }

    @Test func untimedTextAtTheStartIsKept() throws {
        let json = #"{"attributedString":{"attributeTable":[],"runs":["Intro",9]}}"#
        let transcript = try Transcript.decode(Data(json.utf8))
        #expect(transcript.text == "Intro")
    }

    @Test func badTimesAreIgnored() throws {
        let json = #"{"attributedString":{"attributeTable":[{"timeRange":[-1,2]},{"timeRange":[3]},{"timeRange":[5,4]}],"runs":["a",0,"b",1,"c",2]}}"#
        let transcript = try Transcript.decode(Data(json.utf8))
        // "a" has no usable time, so it starts at zero, and "b" joins it. An end before its start is clamped.
        #expect(transcript.words == [Word("ab", start: 0, end: 0), Word("c", start: 5, end: 5)])
    }

    @Test func rejectsWhatIsntATranscript() {
        for json in ["[]", "{}", #"{"attributedString":{}}"#, #"{"attributedString":{"runs":[1,2]}}"#, "not json"] {
            #expect(throws: TranscriptError.unrecognized) { try Transcript.decode(Data(json.utf8)) }
        }
    }

    @Test func anEmptyTranscript() throws {
        let transcript = try Transcript.decode(Data(#"{"attributedString":{"attributeTable":[{"timeRange":[0,1]}],"runs":["  ",0]}}"#.utf8))
        #expect(transcript.isEmpty)
        #expect(transcript.paragraphs.isEmpty)
        #expect(transcript.cues.isEmpty)
    }

    // MARK: Paragraphs

    /// A word every 0.4 seconds, with a full stop every `sentence` words.
    private func speech(words count: Int, sentence: Int = 10, start: Double = 0) -> [Word] {
        (0..<count).map { index in
            let time = start + Double(index) * 0.4
            return Word((index == 0 ? "" : " ") + "word\((index + 1) % sentence == 0 ? "." : "")", start: time, end: time + 0.35)
        }
    }

    @Test func aPauseStartsAParagraph() {
        let transcript = Transcript(words: Array(Fixtures.lecture.map { Word($0.0, start: $0.1, end: $0.2) }))
        let paragraphs = transcript.paragraphs
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0] == Passage(start: 0, end: 2.6, text: "Today we're looking at long-term potentiation."))
        #expect(paragraphs[1].start == 5.0)
        #expect(paragraphs[1].text.hasPrefix("When two neurons"))
    }

    @Test func longSpeechBreaksAtTheEndOfASentence() {
        // 100 words over 40 seconds with no pauses: one break once 25 seconds have passed, at a full stop.
        let paragraphs = Transcript(words: speech(words: 100)).paragraphs
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0].text.hasSuffix("."))
        #expect(paragraphs[0].end >= 25)
        #expect(paragraphs[1].start == 28.0)
    }

    @Test func speechWithNoFullStopsStillBreaks() {
        let paragraphs = Transcript(words: speech(words: 600, sentence: 100_000)).paragraphs
        #expect(paragraphs.count == 3)
        #expect(paragraphs.allSatisfy { $0.end - $0.start <= 90 })
        #expect(paragraphs.map(\.text).joined(separator: " ") == Transcript(words: speech(words: 600, sentence: 100_000)).text)
    }

    @Test func sentenceEndsInOtherLanguagesAndQuotes() {
        for ending in ["word.", "word?", "word!", "word…", "文。", "word.\"", "word.)", "¿qué?", "word.”"] {
            #expect(Word(ending, start: 0, end: 1).endsSentence, "\(ending)")
        }
        for ending in ["word,", "word", "e.g", ""] {
            #expect(!Word(ending, start: 0, end: 1).endsSentence, "\(ending)")
        }
    }

    // MARK: Subtitles

    @Test func cuesAreShort() {
        let cues = Transcript(words: speech(words: 200, sentence: 7)).cues
        #expect(cues.count > 15)
        for cue in cues {
            #expect(cue.end - cue.start <= 6.4)
            #expect(cue.text.count <= 90)
        }
    }

    @Test func cuesBreakAtPausesAndSentences() {
        let transcript = Transcript(words: Fixtures.lecture.map { Word($0.0, start: $0.1, end: $0.2) })
        let cues = transcript.cues
        #expect(cues.first?.text == "Today we're looking at long-term potentiation.")
        #expect(cues.count >= 2)
        #expect(cues.map(\.text).joined(separator: " ") == transcript.text)
    }

    @Test func whitespaceIsTidied() {
        let transcript = Transcript(words: [Word("  Hello ", start: 0, end: 1), Word("\n\tthere ", start: 1, end: 2)])
        #expect(transcript.text == "Hello there")
    }
}
