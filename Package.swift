// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemoExport",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MemoExport", targets: ["MemoExport"]),
        .executable(name: "memo-export", targets: ["MemoExportCLI"]),
    ],
    targets: [
        // Reading the Voice Memos library and recordings, and writing the Markdown, subtitles and
        // export record, with nothing tied to the app, so it can be tested against made-up
        // libraries in throwaway folders.
        .target(name: "MemoCore"),
        .executableTarget(name: "MemoExport", dependencies: ["MemoCore"]),
        .executableTarget(name: "MemoExportCLI", dependencies: ["MemoCore"]),
        .testTarget(name: "MemoCoreTests", dependencies: ["MemoCore"]),
        // The app's glue, tested with a made-up library and windows that are never shown.
        .testTarget(name: "MemoExportTests", dependencies: ["MemoExport", "MemoCore"]),
    ]
)
