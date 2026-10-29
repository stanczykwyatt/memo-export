import Foundation
import Testing
@testable import MemoCore

@Suite("Notes and subtitles")
struct RenderTests {
    let renderer = Fixtures.renderer
    let transcript = Transcript(words: Fixtures.lecture.map { Word($0.0, start: $0.1, end: $0.2) }, locale: "en_US")

    @Test func theWholeNote() {
        let memo = Fixtures.memo(folder: "Neuro 3101")
        let note = renderer.markdown(memo, transcript: transcript, audioFile: "2026-04-30 Lecture synaptic plasticity.m4a")
        #expect(note == """
            ---
            title: "Lecture: synaptic plasticity"
            date: 2026-04-30T09:41:00-05:00
            duration: "0:09"
            folder: "Neuro 3101"
            audio: "2026-04-30 Lecture synaptic plasticity.m4a"
            language: "en_US"
            source: Voice Memos
            voice-memo-id: "A1"
            tags:
              - voice-memo
            ---

            # Lecture: synaptic plasticity

            Thursday, April 30, 2026 at 9:41\u{202F}AM · 0:09 · Neuro 3101

            ![[2026-04-30 Lecture synaptic plasticity.m4a]]

            **0:00** Today we're looking at long-term potentiation.

            **0:05** When two neurons fire together, the synapse between them gets stronger.

            """)
    }

    @Test func standardMarkdownLinks() {
        var renderer = renderer
        renderer.links = .markdown
        let note = renderer.markdown(Fixtures.memo(), transcript: transcript, audioFile: "2026-04-30 Lecture.m4a")
        #expect(note.contains("\n[Audio](<2026-04-30 Lecture.m4a>)\n"))
        #expect(!note.contains("![["))
    }

    @Test func withoutAudioOrTranscript() {
        let note = renderer.markdown(Fixtures.memo(), transcript: nil, audioFile: nil)
        #expect(!note.contains("audio:"))
        #expect(!note.contains("language:"))
        #expect(!note.contains("folder:"))
        #expect(!note.contains("![["))
        #expect(note.contains("*No transcript yet."))
    }

    @Test func longMemosUseHoursEverywhere() {
        var words = transcript.words
        words.append(Word(" Finally.", start: 3700, end: 3701))
        let note = renderer.markdown(Fixtures.memo(duration: 3702), transcript: Transcript(words: words), audioFile: nil)
        #expect(note.contains("**0:00:00** Today"))
        #expect(note.contains("**1:01:40** Finally."))
        #expect(note.contains("duration: \"1:01:42\""))
    }

    @Test func titlesAreQuotedSafely() {
        let memo = Fixtures.memo(title: "She said \"hi\" \\ then\nleft\u{0007}\u{202E}")
        let note = renderer.markdown(memo, transcript: nil, audioFile: nil)
        #expect(note.contains(#"title: "She said \"hi\" \\ then\nleft\u0007\u202E""#))
        // Invisible direction marks are taken out of the text itself, so a title can't disguise itself.
        #expect(note.contains("# She said \"hi\" \\\\ then left\n"))
    }

    @Test func spokenWordsArentReadAsFormatting() {
        let words = [Word("Use", start: 0, end: 1), Word(" <b>", start: 1, end: 2), Word(" *really*", start: 2, end: 3), Word(" [link](x)", start: 3, end: 4), Word(" #tag", start: 4, end: 5)]
        let note = renderer.markdown(Fixtures.memo(), transcript: Transcript(words: words), audioFile: nil)
        #expect(note.contains(##"**0:00** Use \<b\> \*really\* \[link\](x) \#tag"##))
    }

    @Test func moreFormattingIsEscaped() {
        #expect(Renderer.escape("50% off, %%hidden%% ==marked== ~~gone~~ $x$ &amp; R&D") == #"50% off, \%\%hidden\%\% \=\=marked\=\= \~\~gone\~\~ \$x\$ \&amp; R&D"#)
    }

    @Test func foldersAreEscapedInTheNote() {
        let note = renderer.markdown(Fixtures.memo(folder: "<!-- hidden\n# Injected"), transcript: nil, audioFile: nil)
        #expect(note.contains("· \\<!-- hidden \\# Injected\n"))
        #expect(!note.contains("\n# Injected"))
    }

    @Test func yamlEscapesBeyondTheBasicPlane() {
        #expect(Renderer.yaml("a\u{E0001}b") == #""a\U000E0001b""#)
        #expect(Renderer.yaml("line\u{2028}break\u{2029}") == #""line\u2028break\u2029""#)
        #expect(Renderer.yaml("👩‍💻") == "\"👩\\u200D💻\"")
    }

    @Test func aHeadingThatIsOnlySpace() {
        #expect(Renderer.heading(" \n ") == "New Recording")
        #expect(Renderer.heading("# Not a heading") == "\\# Not a heading")
    }

    @Test func datesFollowTheTimeZone() {
        var tokyo = renderer
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        #expect(tokyo.isoDate(Fixtures.date) == "2026-04-30T23:41:00+09:00")
        #expect(tokyo.fileDate(Fixtures.date.addingTimeInterval(3 * 3600)) == "2026-05-01")
        #expect(renderer.fileDate(Fixtures.date.addingTimeInterval(3 * 3600)) == "2026-04-30")
    }

    // MARK: Subtitles

    @Test func subtitles() {
        let srt = renderer.subtitles(transcript)
        #expect(srt.hasPrefix("1\n00:00:00,000 --> 00:00:02,600\nToday we're looking at\nlong-term potentiation.\n\n2\n00:00:05,000 --> 00:00:09,000\n"))
        let blocks = srt.components(separatedBy: "\n\n")
        #expect(blocks.count >= 2)
        for (index, block) in blocks.enumerated() {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
            #expect(lines[0] == "\(index + 1)")
            #expect(lines[1].contains(" --> "))
            #expect(lines.count <= 5)
        }
    }

    @Test func aSubtitleIsShownForAtLeastHalfASecond() {
        let srt = renderer.subtitles(Transcript(words: [Word("Hi", start: 2, end: 2)]))
        #expect(srt == "1\n00:00:02,000 --> 00:00:02,500\nHi\n")
    }

    @Test func srtTimes() {
        #expect(Renderer.srtTime(0) == "00:00:00,000")
        #expect(Renderer.srtTime(61.2345) == "00:01:01,235")
        #expect(Renderer.srtTime(3 * 3600 + 5.5) == "03:00:05,500")
        #expect(Renderer.srtTime(-4) == "00:00:00,000")
    }

    @Test func wrapsIntoTwoEvenLines() {
        #expect(Renderer.wrap("Short line", width: 42) == ["Short line"])
        let lines = Renderer.wrap("When two neurons fire together, the synapse between them gets stronger", width: 42)
        #expect(lines.count == 2)
        #expect(abs(lines[0].count - lines[1].count) < 12)
        #expect(Renderer.wrap(String(repeating: "x", count: 60), width: 42) == [String(repeating: "x", count: 60)])
    }

    // MARK: File names

    @Test func baseNames() {
        #expect(renderer.baseName(Fixtures.memo()) == "2026-04-30 Lecture synaptic plasticity")
        #expect(renderer.baseName(Fixtures.memo(title: "a/b\\c:d*e?f\"g<h>i|j[k]l#m^n")) == "2026-04-30 a b c d e f g h i j k l m n")
    }

    @Test func safeNames() {
        #expect(Renderer.safeName("...hidden") == "hidden")
        #expect(Renderer.safeName("  ") == "New Recording")
        #expect(Renderer.safeName("../..") == "New Recording")
        #expect(Renderer.safeName("tab\there\u{0000}") == "tab here")
        #expect(Renderer.safeName("Ends with dots...") == "Ends with dots")
        #expect(Renderer.safeName("Café ☕️ notes") == "Café ☕️ notes")
        let long = Renderer.safeName(String(repeating: "é", count: 300))
        #expect(long.utf8.count <= 180)
        #expect(long.allSatisfy { $0 == "é" })
    }
}
