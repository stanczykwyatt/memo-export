import Foundation
import Testing
@testable import MemoCore

@Suite("Atoms")
struct AtomTests {
    let json = Fixtures.transcriptJSON(Fixtures.lecture)

    @Test func findsTheTranscriptInTheTrack() throws {
        let file = Fixtures.recording(transcript: json)
        #expect(try Atoms.transcriptData(in: DataSource(file)) == json)
    }

    @Test func findsTheTranscriptInTheMoviesUserData() throws {
        let file = Fixtures.recording(transcript: json, inTrack: false)
        #expect(try Atoms.transcriptData(in: DataSource(file)) == json)
    }

    @Test func aRecordingWithoutATranscript() throws {
        #expect(try Atoms.transcriptData(in: DataSource(Fixtures.recording(transcript: nil))) == nil)
    }

    @Test func aFileWithNoMovie() throws {
        let file = Fixtures.box("ftyp", Data(count: 12)) + Fixtures.box("mdat", Data(count: 64))
        #expect(try Atoms.transcriptData(in: DataSource(file)) == nil)
        #expect(try Atoms.transcriptData(in: DataSource(Data())) == nil)
    }

    @Test func readsSixtyFourBitSizes() throws {
        // A box whose size is 1 has its real size in the next eight bytes, as long recordings' audio does.
        var big = Data()
        withUnsafeBytes(of: UInt32(1).bigEndian) { big.append(contentsOf: $0) }
        big.append(Data("mdat".utf8))
        withUnsafeBytes(of: UInt64(16 + 32).bigEndian) { big.append(contentsOf: $0) }
        big.append(Data(count: 32))
        let movie = Fixtures.box("moov", [Fixtures.box("udta", [Fixtures.box("tsrp", json)])])
        let atoms = try Atoms.children(of: DataSource(big + movie), from: 0, to: UInt64(big.count + movie.count))
        #expect(atoms.map(\.type) == ["mdat", "moov"])
        #expect(atoms[0].headerSize == 16)
        #expect(atoms[0].size == 48)
        #expect(try Atoms.transcriptData(in: DataSource(big + movie)) == json)
    }

    @Test func aZeroSizeRunsToTheEnd() throws {
        var open = Data()
        withUnsafeBytes(of: UInt32(0).bigEndian) { open.append(contentsOf: $0) }
        open.append(Data("mdat".utf8))
        open.append(Data(count: 20))
        let atoms = try Atoms.children(of: DataSource(open), from: 0, to: UInt64(open.count))
        #expect(atoms == [Atom(type: "mdat", offset: 0, headerSize: 8, size: 28)])
    }

    @Test func rejectsBoxesBiggerThanTheirFile() {
        var lying = Data()
        withUnsafeBytes(of: UInt32(10_000).bigEndian) { lying.append(contentsOf: $0) }
        lying.append(Data("moov".utf8))
        lying.append(Data(count: 16))
        #expect(throws: AtomError.truncated) { try Atoms.transcriptData(in: DataSource(lying)) }
    }

    @Test func rejectsBoxesSmallerThanTheirHeader() {
        var lying = Data()
        withUnsafeBytes(of: UInt32(4).bigEndian) { lying.append(contentsOf: $0) }
        lying.append(Data("moov".utf8))
        #expect(throws: AtomError.truncated) { try Atoms.children(of: DataSource(lying), from: 0, to: 8) }
    }

    @Test func ignoresATrailingFragment() throws {
        // A few stray bytes after the last box aren't a box.
        let file = Fixtures.recording(transcript: json) + Data([0, 0, 1])
        #expect(try Atoms.transcriptData(in: DataSource(file)) == json)
    }

    @Test func refusesATranscriptPastTheLimit() {
        struct Huge: ByteSource {
            // A movie box claiming to hold a 20 MB transcript, without allocating it.
            let header: Data = {
                let size = UInt32(8 + 8 + 8 + 20_000_000)
                var data = Data()
                for (value, type) in [(size, "moov"), (size - 8, "udta"), (size - 16, "tsrp")] {
                    withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
                    data.append(Data(type.utf8))
                }
                return data
            }()
            var count: UInt64 { 8 + 8 + 8 + 20_000_000 }
            func read(at offset: UInt64, length: Int) throws -> Data {
                guard offset + UInt64(length) <= UInt64(header.count) else { return Data(count: length) }
                return header.subdata(in: Int(offset)..<Int(offset) + length)
            }
        }
        #expect(throws: AtomError.tooLarge) { try Atoms.transcriptData(in: Huge()) }
    }

    @Test func readsOnlyHeadersOnTheWay() throws {
        final class Counting: ByteSource {
            let inner: DataSource
            var bytes = 0
            init(_ data: Data) { inner = DataSource(data) }
            var count: UInt64 { inner.count }
            func read(at offset: UInt64, length: Int) throws -> Data {
                bytes += length
                return try inner.read(at: offset, length: length)
            }
        }
        let source = Counting(Fixtures.recording(transcript: json, audioBytes: 5_000_000))
        _ = try Atoms.transcriptData(in: source)
        #expect(source.bytes < json.count + 400)
    }

    @Test func dataSourceBounds() {
        let source = DataSource(Data([1, 2, 3]))
        #expect(throws: AtomError.truncated) { try source.read(at: 2, length: 2) }
        #expect(throws: AtomError.truncated) { try source.read(at: 4, length: 0) }
        #expect((try? source.read(at: 1, length: 2)) == Data([2, 3]))
    }
}
