import Foundation

/// The `memo-export` command line tool: list memos, print one, or export them all to a folder.
/// It does the same as the app, for scripts, cron jobs and Shortcuts.
public enum Command: Equatable {
    case list(json: Bool)
    case show(String, timestamps: Bool)
    case export(folder: String, options: ExportOptions)
    case help
    case version

    public static let toolVersion = "0.1.0"

    public static let usage = """
        memo-export \(toolVersion): export Voice Memos transcripts as Markdown, with the audio.

        Usage:
          memo-export list [--json]          List memos, newest first
          memo-export show <memo>            Print a memo's note (by title or ID)
          memo-export show <memo> --text     Print just its transcript, one paragraph per line
          memo-export export <folder>        Export new memos into <folder>

        Export options:
          --srt              Also write SRT subtitles
          --no-audio         Don't copy the audio, only write the notes
          --markdown-links   Link the audio with [Audio](<file>), not Obsidian's ![[file]]
          --by-folder        Put memos in subfolders named after their Voice Memos folders

          --library <folder> Read another Voice Memos library folder, like a backup
          --help, --version

        Reading Voice Memos needs Full Disk Access for your terminal app, in System Settings →
        Privacy & Security → Full Disk Access. Nothing in Voice Memos is ever changed.
        """

    public enum ParseError: Error, Equatable {
        case message(String)
    }

    /// The command, and the library folder if one was given.
    public static func parse(_ arguments: [String]) throws -> (Command, library: String?) {
        var rest: [String] = []
        var library: String?
        var flags = Set<String>()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--library" {
                guard index + 1 < arguments.count else { throw ParseError.message("--library needs a folder.") }
                library = arguments[index + 1]
                index += 2
                continue
            }
            if argument.hasPrefix("--") { flags.insert(argument) } else if argument == "-h" { flags.insert("--help") } else { rest.append(argument) }
            index += 1
        }
        if flags.contains("--help") { return (.help, library) }
        if flags.contains("--version") { return (.version, library) }
        guard let name = rest.first else { return (.help, library) }

        func allow(_ allowed: Set<String>) throws {
            if let unknown = flags.subtracting(allowed).sorted().first {
                throw ParseError.message("Unknown option \(unknown) for \(name). See memo-export --help.")
            }
        }
        switch name {
        case "list":
            try allow(["--json"])
            guard rest.count == 1 else { throw ParseError.message("list takes no arguments.") }
            return (.list(json: flags.contains("--json")), library)
        case "show":
            try allow(["--text"])
            guard rest.count >= 2 else { throw ParseError.message("show needs a memo's title or ID.") }
            return (.show(rest.dropFirst().joined(separator: " "), timestamps: !flags.contains("--text")), library)
        case "export":
            try allow(["--srt", "--no-audio", "--markdown-links", "--by-folder"])
            guard rest.count == 2 else { throw ParseError.message("export needs one folder to export into.") }
            let options = ExportOptions(
                audio: !flags.contains("--no-audio"),
                subtitles: flags.contains("--srt"),
                byFolder: flags.contains("--by-folder"),
                renderer: Renderer(links: flags.contains("--markdown-links") ? .markdown : .obsidian)
            )
            return (.export(folder: rest[1], options: options), library)
        default:
            throw ParseError.message("Unknown command \(name). See memo-export --help.")
        }
    }

    /// Runs the tool. Returns the exit status: 0 on success, 1 when something failed, 2 for a mistake in the arguments.
    public static func run(
        _ arguments: [String], home: URL = VoiceMemosLibrary.realHome, workingDirectory: URL,
        scratch: URL = FileManager.default.temporaryDirectory.appendingPathComponent("memo-export", isDirectory: true),
        renderer: Renderer = Renderer(), now: Date = Date(),
        out: (String) -> Void, err: (String) -> Void
    ) -> Int32 {
        let command: Command, libraryPath: String?
        do {
            (command, libraryPath) = try parse(arguments)
        } catch ParseError.message(let message) {
            err(message)
            return 2
        } catch {
            return 2
        }
        func resolve(_ path: String) -> URL {
            let expanded = path == "~" ? home.path : path.hasPrefix("~/") ? home.path + path.dropFirst(1) : path
            return URL(fileURLWithPath: expanded, relativeTo: workingDirectory).standardizedFileURL
        }
        let library = libraryPath.map { VoiceMemosLibrary(folder: resolve($0)) } ?? VoiceMemosLibrary(home: home)

        switch command {
        case .help:
            out(usage)
            return 0
        case .version:
            out("memo-export \(toolVersion)")
            return 0
        default:
            break
        }

        let memos: [Memo]
        do {
            memos = try library.memos(scratch: scratch)
        } catch let error as LibraryError {
            err(error == .noPermission
                ? "Your terminal needs Full Disk Access to read Voice Memos. Turn it on in System Settings → Privacy & Security → Full Disk Access, then open a new terminal window."
                : Describe.problem(error))
            return 1
        } catch {
            err(error.localizedDescription)
            return 1
        }

        switch command {
        case .list(let json):
            if json {
                let items = memos.map { memo in
                    [
                        "id": memo.id, "title": memo.title, "date": renderer.isoDate(memo.date),
                        "duration": memo.duration, "folder": memo.folder as Any? ?? NSNull(),
                        "downloaded": library.audioURL(for: memo) != nil,
                        "transcript": ((try? library.transcript(for: memo)) ?? nil) != nil,
                    ] as [String: Any]
                }
                let data = (try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("[]".utf8)
                out(String(decoding: data, as: UTF8.self))
                return 0
            }
            if memos.isEmpty {
                out("No memos.")
                return 0
            }
            for memo in memos {
                var marks: [String] = []
                if library.audioURL(for: memo) == nil {
                    marks.append("not downloaded")
                } else if ((try? library.transcript(for: memo)) ?? nil) == nil {
                    marks.append("no transcript")
                }
                if let folder = memo.folder { marks.insert(folder, at: 0) }
                let detail = marks.isEmpty ? "" : "  (\(marks.joined(separator: ", ")))"
                out("\(renderer.fileDate(memo.date))  \(Describe.duration(memo.duration).leftPad(7))  \(memo.title)\(detail)")
            }
            return 0

        case .show(let query, let timestamps):
            let matches = memos.filter { $0.id == query }
            let found = matches.isEmpty ? memos.filter { $0.title.localizedCaseInsensitiveCompare(query) == .orderedSame } : matches
            guard let memo = found.first else {
                err("No memo called \"\(query)\". Run memo-export list to see them.")
                return 1
            }
            if found.count > 1 { err("\(found.count) memos are called \"\(query)\"; showing the newest. Use its ID for another.") }
            let transcript: Transcript?
            do {
                transcript = try library.transcript(for: memo)
            } catch {
                err("Couldn't read the transcript of \"\(memo.title)\".")
                return 1
            }
            if timestamps {
                out(renderer.markdown(memo, transcript: transcript, audioFile: nil))
            } else if let transcript {
                out(transcript.paragraphs.map(\.text).joined(separator: "\n\n"))
            } else {
                err("\"\(memo.title)\" has no transcript yet.")
                return 1
            }
            return 0

        case .export(let folder, var options):
            options.renderer = Renderer(timeZone: renderer.timeZone, locale: renderer.locale, links: options.renderer.links)
            let exporter = Exporter(destination: resolve(folder), options: options)
            do {
                // Never into the library being read, or the real one when reading a copy.
                let protected = [library.folder, VoiceMemosLibrary(home: home).folder]
                let report = try exporter.export(memos, from: library, protected: protected, now: now)
                out(Describe.summary(report) + ".")
                for title in report.exported { out("  + \(title)") }
                for title in report.updated { out("  ~ \(title)") }
                for title in report.waiting { out("  … \(title): not downloaded from iCloud yet") }
                for failure in report.failed { err("  ! \(failure.title): \(failure.reason)") }
                return report.failed.isEmpty ? 0 : 1
            } catch let error as ExportError {
                err(Describe.problem(error))
                return 1
            } catch {
                err(error.localizedDescription)
                return 1
            }

        case .help, .version:
            return 0
        }
    }
}

extension Describe {
    public static func problem(_ error: ExportError) -> String {
        switch error {
        case .insideLibrary: "Choose a folder outside the Voice Memos library. Nothing is ever written there."
        case .unreadableRecord: "The folder's \(Exporter.recordName) can't be read, so exporting could duplicate your memos. Move it out of the folder to start over."
        case .newerRecord: "This folder was exported by a newer version of Memo Export. Update to keep exporting to it."
        case .busy: "Another export into this folder is running. Try again once it's done."
        case .cannotWrite(let detail): "Couldn't write to the export folder: \(detail)"
        }
    }
}

extension String {
    func leftPad(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
