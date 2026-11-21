import AppKit
import Carbon
import XCTest
@testable import PilcrowApp

final class SettingsTests: XCTestCase {
    @MainActor
    func testStatusMenuHasFourActionsAndOnlyTransientWarningRows() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let menu = delegate.makeStatusMenu()
        let visible = menu.items.filter { !$0.isHidden }
        XCTAssertEqual(visible.map { $0.isSeparatorItem ? "separator" : $0.title },
                       ["Start annotating\t" + KeyChord.startDefault.glyph, "Review last capture…", "separator", "Settings…", "Quit Pilcrow"])
        XCTAssertFalse(try XCTUnwrap(visible.first { $0.title == "Review last capture…" }).isEnabled)
        let start = try XCTUnwrap(visible.first)
        XCTAssertEqual(start.keyEquivalent, "", "Carbon owns Start, so the menu must not fire it twice")
        XCTAssertTrue(start.attributedTitle?.string.hasSuffix("\t" + KeyChord.startDefault.glyph) == true)
        XCTAssertEqual(visible[3].keyEquivalent, ",")
        XCTAssertEqual(visible[3].keyEquivalentModifierMask, .command)
        XCTAssertEqual(visible[4].keyEquivalent, "q")
        let hidden = menu.items.filter(\.isHidden)
        XCTAssertEqual(hidden.map(\.title), ["Shortcut unavailable", "", "Screen Recording needed…"])
        XCTAssertTrue(hidden.prefix(2).allSatisfy { !$0.isEnabled && $0.action == nil })
        XCTAssertEqual(hidden.last?.action, visible[3].action, "The screen warning opens the same Settings window")
        XCTAssertTrue(menu.items.prefix(3).allSatisfy(\.isHidden), "Transient lines stay at the top")
        let command = try XCTUnwrap(delegate.makeApplicationMenu().items.first?.submenu?.items.first)
        XCTAssertEqual(command.keyEquivalent, ",")
        XCTAssertEqual(command.action, visible[3].action)
    }

    func testSetupCommandsUseTheSuppliedBundlePath() {
        let bundle = URL(fileURLWithPath: "/Volumes/Tools/Pilcrow.app")
        XCTAssertEqual(MCPSetupCommand.build(for: .claude, bundleURL: bundle),
                       "claude mcp add --transport stdio pilcrow -- '/Volumes/Tools/Pilcrow.app/Contents/MacOS/pilcrow-mcp'")
        XCTAssertEqual(MCPSetupCommand.build(for: .codex, bundleURL: bundle),
                       "codex mcp add pilcrow -- '/Volumes/Tools/Pilcrow.app/Contents/MacOS/pilcrow-mcp'")
        XCTAssertEqual(MCPSetupCommand.build(for: .codex), MCPSetupCommand.build(for: .codex, bundleURL: Bundle.main.bundleURL))
    }

    func testSetupCommandQuotesSpacesApostrophesAndShellMetacharactersAsOneArgument() throws {
        let bundle = URL(fileURLWithPath: "/Volumes/Umar's Tools/$(do-not-run); Pilcrow.app")
        for agent in MCPSetupAgent.allCases {
            let command = MCPSetupCommand.build(for: agent, bundleURL: bundle)
            let prefix = agent == .claude ? "claude mcp add --transport stdio pilcrow -- " : "codex mcp add pilcrow -- "
            XCTAssertTrue(command.hasPrefix(prefix))
            // Execute only the quoted argument with printf, never a real agent or setup command.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '%s' " + String(command.dropFirst(prefix.count))]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), bundle.appendingPathComponent("Contents/MacOS/pilcrow-mcp").path)
        }
    }

    func testAccessFooterForEveryPermissionCombination() {
        let screenOff = SettingsAccessLine(text: "Screen Recording is off. Pilcrow needs it to see your screen.", action: .screen)
        let micOff = SettingsAccessLine(text: "Microphone is off. Marks still work; Pilcrow can't hear you.", action: .microphone)
        for microphone in SettingsMicrophoneAccess.allCases {
            XCTAssertEqual(SettingsAccessLine.lines(screenRecording: true, microphone: microphone),
                           microphone == .on ? [SettingsAccessLine(text: "✓ Screen Recording and Microphone are on.", action: nil)] : [micOff])
            XCTAssertEqual(SettingsAccessLine.lines(screenRecording: false, microphone: microphone),
                           microphone == .on ? [screenOff] : [screenOff, micOff])
        }
    }

    func testClearAvailabilityUsesRealDisposableOutboxAndIgnoresUnsafeEntries() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pilcrow-settings-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("Pilcrow/Outbox")
        let store = OutboxStore(root: root)
        var available = await store.hasClearableCaptures()
        XCTAssertFalse(available)
        let id = UUID()
        _ = try await store.prepare(id)
        available = await store.hasClearableCaptures()
        XCTAssertFalse(available, "Locked exports cannot be cleared")
        await store.releaseExport(id)
        available = await store.hasClearableCaptures()
        XCTAssertTrue(available)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("keep-me"), withIntermediateDirectories: false)
        let target = scratch.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(UUID().uuidString), withDestinationURL: target)
        try await store.prune(clearAll: true)
        available = await store.hasClearableCaptures()
        XCTAssertFalse(available)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("keep-me").path))
    }
}
