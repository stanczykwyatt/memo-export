import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MemoCore
@testable import MemoExport

/// Renders the window into a bitmap from a window that's never shown, so nothing appears on screen
/// or takes focus. Set SCREENSHOT_DIR to also save the renders as the README screenshots:
///
///   SCREENSHOT_DIR=docs swift test --filter "Window"
@MainActor
@Suite("Window")
struct WindowTests {
    let folder = TestFolder()
    static let size = NSSize(width: 980, height: 620)

    private func view(_ model: MemoModel, query: String = "") -> MemoView {
        MemoView(model: model, home: folder.url, now: { Gallery.now }, selectionColor: Color(red: 0.24, green: 0.47, blue: 0.86), query: query)
    }

    @Test func rendersTheMemos() async throws {
        let model = try await Gallery.model(in: folder, exportTo: folder.sub("Vault/Voice Memos"))
        model.preferences.lastExport = (Gallery.now.addingTimeInterval(-60 * 90), "Exported 4 new memos")
        let image = render(view(model), name: "screenshot-light", dark: false)
        #expect(image.pixelsWide >= Int(Self.size.width))
        #expect(colors(in: image) > 30)
    }

    @Test func rendersInDarkMode() async throws {
        let model = try await Gallery.model(in: folder, exportTo: folder.sub("Vault/Voice Memos"))
        model.preferences.lastExport = (Gallery.now.addingTimeInterval(-60 * 90), "Exported 4 new memos")
        #expect(colors(in: render(view(model), name: "screenshot-dark", dark: true)) > 30)
    }

    @Test func rendersASearch() async throws {
        let model = try await Gallery.model(in: folder, exportTo: folder.sub("Vault/Voice Memos"))
        let image = render(view(model, query: "receptor"), name: "screenshot-search", dark: false)
        #expect(colors(in: image) > 30)
    }

    @Test func rendersTheOtherStates() async throws {
        let empty = MemoModel(library: VoiceMemosLibrary(folder: folder.url.appendingPathComponent("none")), preferences: testPreferences(), scratch: folder.sub("s"))
        #expect(colors(in: render(view(empty), name: nil, dark: false)) > 4)
        await empty.reload()
        #expect(colors(in: render(view(empty), name: nil, dark: true)) > 4)
        let model = try await Gallery.model(in: folder)
        model.selection = "MEMO-4"
        #expect(colors(in: render(view(model), name: nil, dark: false)) > 4)
        #expect(colors(in: render(view(model, query: "nothing like this"), name: nil, dark: false)) > 4)
    }

    @Test func rendersTheAccessPrompt() async throws {
        let library = folder.sub("Locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: library.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: library.path) }
        let model = MemoModel(library: VoiceMemosLibrary(folder: library), preferences: testPreferences(), scratch: folder.sub("s"))
        await model.reload()
        #expect(colors(in: render(view(model), name: "screenshot-access", dark: false, size: NSSize(width: 820, height: 440))) > 8)
    }

    @Test func everySymbolExists() {
        for symbol in ["magnifyingglass", "xmark.circle.fill", "icloud.and.arrow.down", "text.badge.xmark", "lock.shield", "waveform.slash", "waveform", "text.quote", "folder", "folder.badge.plus", "exclamationmark.triangle.fill"] {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "Missing symbol \(symbol)")
        }
    }

    // MARK: Rendering

    private func render(_ view: MemoView, name: String?, dark: Bool, size: NSSize = WindowTests.size) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Never ordered front: it only gives the view a backing to draw into.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let image = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: image)
        if let name, let folder = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
            try? image.representation(using: .png, properties: [:])?.write(to: url)
        }
        return image
    }

    /// Distinct colors in a coarse grid: a blank or broken render has only a few.
    private func colors(in image: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        for x in stride(from: 0, to: image.pixelsWide, by: 7) {
            for y in stride(from: 0, to: image.pixelsHigh, by: 7) {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let r = UInt32(color.redComponent * 31), g = UInt32(color.greenComponent * 31), b = UInt32(color.blueComponent * 31)
                seen.insert(r << 10 | g << 5 | b)
            }
        }
        return seen.count
    }
}

/// The app's entitlements, checked against what the code expects.
@Suite("Entitlements")
struct EntitlementTests {
    static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/MemoExport.entitlements")

    @Test func onlyTheSandboxTheLibraryAndYourFolder() throws {
        let entitlements = try #require(NSDictionary(contentsOf: Self.file) as? [String: Any])
        #expect(Set(entitlements.keys) == [
            "com.apple.security.app-sandbox",
            "com.apple.security.temporary-exception.files.home-relative-path.read-only",
            "com.apple.security.files.user-selected.read-write",
            "com.apple.security.files.bookmarks.app-scope",
        ])
        #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
        let readOnly = entitlements["com.apple.security.temporary-exception.files.home-relative-path.read-only"] as? [String]
        #expect(readOnly == ["/" + VoiceMemosLibrary.relativePath + "/"])
    }
}
