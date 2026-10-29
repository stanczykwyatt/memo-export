import Foundation

/// Bytes that can be read a piece at a time: a recording on disk, or data in memory for tests.
public protocol ByteSource {
    var count: UInt64 { get }
    func read(at offset: UInt64, length: Int) throws -> Data
}

/// Data in memory, read like a file.
public struct DataSource: ByteSource {
    public let data: Data

    public init(_ data: Data) {
        self.data = data
    }

    public var count: UInt64 { UInt64(data.count) }

    public func read(at offset: UInt64, length: Int) throws -> Data {
        guard offset <= count, length >= 0, offset + UInt64(length) <= count else { throw AtomError.truncated }
        let start = data.startIndex + Int(offset)
        return data.subdata(in: start..<start + length)
    }
}

public enum AtomError: Error, Equatable {
    /// A box claims to be bigger than what holds it, or the file ends partway through one.
    case truncated
    /// The transcript is larger than any real one could be.
    case tooLarge
}

/// One box ("atom") of an MP4 or QuickTime file: four letters naming it, then its contents.
public struct Atom: Equatable, Sendable {
    public let type: String
    /// Where the box starts, header included.
    public let offset: UInt64
    public let headerSize: UInt64
    public let size: UInt64

    public var contentOffset: UInt64 { offset + headerSize }
    public var contentSize: UInt64 { size - headerSize }
}

/// Finds the transcript Voice Memos keeps inside each recording, in a `tsrp` box under the
/// movie's or a track's user data. Only box headers are read on the way, so a long recording's
/// audio is never loaded.
public enum Atoms {
    /// Real transcripts are tens of kilobytes an hour. Anything past this isn't one.
    public static let transcriptLimit: UInt64 = 16 * 1024 * 1024

    /// The boxes directly inside `range` of `source`.
    public static func children(of source: ByteSource, from start: UInt64, to end: UInt64) throws -> [Atom] {
        guard end <= source.count, start <= end else { throw AtomError.truncated }
        var atoms: [Atom] = []
        var offset = start
        while end - offset >= 8 {
            let header = try source.read(at: offset, length: 8)
            var size = UInt64(header.bigEndianUInt32(at: 0))
            let type = String(decoding: header[header.startIndex + 4..<header.startIndex + 8], as: UTF8.self)
            var headerSize: UInt64 = 8
            if size == 1 {
                guard end - offset >= 16 else { throw AtomError.truncated }
                size = try source.read(at: offset + 8, length: 8).bigEndianUInt64(at: 0)
                headerSize = 16
            } else if size == 0 {
                // Runs to the end of whatever holds it.
                size = end - offset
            }
            guard size >= headerSize, size <= end - offset else { throw AtomError.truncated }
            atoms.append(Atom(type: type, offset: offset, headerSize: headerSize, size: size))
            offset += size
        }
        return atoms
    }

    /// The transcript's raw contents, or nil if the recording has none.
    public static func transcriptData(in source: ByteSource) throws -> Data? {
        let top = try children(of: source, from: 0, to: source.count)
        guard let movie = top.first(where: { $0.type == "moov" }) else { return nil }
        let movieChildren = try children(of: source, from: movie.contentOffset, to: movie.offset + movie.size)
        // Voice Memos puts it in the audio track's user data. The movie's own is checked too.
        var holders = movieChildren.filter { $0.type == "udta" }
        for track in movieChildren where track.type == "trak" {
            holders += try children(of: source, from: track.contentOffset, to: track.offset + track.size).filter { $0.type == "udta" }
        }
        for holder in holders {
            let inside = try children(of: source, from: holder.contentOffset, to: holder.offset + holder.size)
            if let box = inside.first(where: { $0.type == "tsrp" }) {
                guard box.contentSize <= transcriptLimit else { throw AtomError.tooLarge }
                return try source.read(at: box.contentOffset, length: Int(box.contentSize))
            }
        }
        return nil
    }
}

extension Data {
    func bigEndianUInt32(at index: Int) -> UInt32 {
        let start = startIndex + index
        return self[start..<start + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    func bigEndianUInt64(at index: Int) -> UInt64 {
        let start = startIndex + index
        return self[start..<start + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
