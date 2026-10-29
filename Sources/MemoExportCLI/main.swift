import Foundation
import MemoCore

let status = Command.run(
    Array(CommandLine.arguments.dropFirst()),
    workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
    out: { print($0) },
    err: { fputs($0 + "\n", stderr) }
)
exit(status)
