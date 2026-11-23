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

    @MainActor
    func testCopyNoticeExpiryLeavesNewerErrorsVisible() throws {
        let delegate = AppDelegate()
        let menu = delegate.makeStatusMenu()
        let row = try XCTUnwrap(menu.items.first { $0.title.isEmpty && !$0.isSeparatorItem })

        let firstCopy = delegate.showResult("Copied · ⌘V")
        XCTAssertFalse(row.isHidden)
        delegate.expireResult(firstCopy)
        XCTAssertTrue(row.isHidden)

        let secondCopy = delegate.showResult("Copied · ⌘V")
        XCTAssertFalse(row.isHidden)
        delegate.showResult("Couldn’t remove capture")
        delegate.expireResult(secondCopy)
        XCTAssertFalse(row.isHidden)
        XCTAssertEqual(row.title, "Couldn’t remove capture")
    }

    @MainActor
    func testUnavailableSpeechModelShowsReasonWithoutAnAction() {
        let model = SettingsPresentation()
        model.updateAccess(screenRecording: true, microphone: .undetermined, canStart: true,
                           voiceStatus: "Speech model unavailable", voiceAction: nil, voiceActionEnabled: false)
        XCTAssertEqual(model.voiceNote, "Speech model unavailable")
        XCTAssertNil(model.voiceAction)
        model.updateAccess(screenRecording: true, microphone: .undetermined, canStart: true,
                           voiceStatus: "Uses the microphone during annotation", voiceAction: "Turn On…", voiceActionEnabled: true)
        XCTAssertEqual(model.voiceAction, "Turn On…")
        model.updateAccess(screenRecording: false, microphone: .undetermined, canStart: false,
                           voiceStatus: "Uses the microphone during annotation", voiceAction: "Turn On…", voiceActionEnabled: false)
        XCTAssertNil(model.voiceAction)
    }

    func testSettingsNumeralsUseActualLightAndDarkAccentFills() {
        for dark in [false, true] {
            for colour in PilcrowColour.allCases {
                let fill = colour.accent(dark: dark)
                let foreground = PilcrowColour.settingsNumeral(on: fill)
                let components = fill.components!
                func linear(_ value: CGFloat) -> CGFloat {
                    value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                }
                let luminance = 0.2126 * linear(components[0]) + 0.7152 * linear(components[1]) + 0.0722 * linear(components[2])
                let contrast = foreground.components?.first == 1 ? 1.05 / (luminance + 0.05) : (luminance + 0.05) / 0.05
                XCTAssertGreaterThanOrEqual(contrast, 3, "\(colour), dark: \(dark)")
            }
        }
        for colour in [PilcrowColour.teal, .green] {
            XCTAssertEqual(PilcrowColour.settingsNumeral(on: colour.accent(dark: false)).components?.first, 1)
            XCTAssertEqual(PilcrowColour.settingsNumeral(on: colour.accent(dark: true)).components?.first, 0)
        }
    }

    func testSetupCommandsUseTheSuppliedBundlePath() {
        let bundle = URL(fileURLWithPath: "/Volumes/Tools/Pilcrow.app")
        XCTAssertEqual(MCPSetupCommand.build(for: .claude, bundleURL: bundle),
                       "claude mcp add --scope user --transport stdio pilcrow -- '/Volumes/Tools/Pilcrow.app/Contents/MacOS/pilcrow-mcp'")
        XCTAssertEqual(MCPSetupCommand.build(for: .codex, bundleURL: bundle),
                       "codex mcp add pilcrow -- '/Volumes/Tools/Pilcrow.app/Contents/MacOS/pilcrow-mcp'")
        XCTAssertEqual(MCPSetupCommand.build(for: .codex), MCPSetupCommand.build(for: .codex, bundleURL: Bundle.main.bundleURL))
    }

    func testSetupCommandQuotesSpacesApostrophesAndShellMetacharactersAsOneArgument() throws {
        let bundle = URL(fileURLWithPath: "/Volumes/Umar's Tools/$(do-not-run); Pilcrow.app")
        for agent in MCPSetupAgent.allCases {
            let command = MCPSetupCommand.build(for: agent, bundleURL: bundle)
            let prefix = agent == .claude ? "claude mcp add --scope user --transport stdio pilcrow -- " : "codex mcp add pilcrow -- "
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

    func testAccessStatesForEveryPermissionCombination() {
        let screenOff = SettingsAccessLine(text: "Pilcrow can’t capture without it.", action: .screen)
        let micOff = SettingsAccessLine(text: "Microphone is off. Marks work, voice won’t.", action: .microphone)
        let bothOff = SettingsAccessLine(text: "Microphone is off.", action: .microphone)
        for microphone in SettingsMicrophoneAccess.allCases {
            XCTAssertEqual(SettingsAccessLine.lines(screenRecording: true, microphone: microphone),
                           microphone == .on ? [SettingsAccessLine(text: "Screen Recording and Microphone are on.", action: nil)] : [micOff])
            XCTAssertEqual(SettingsAccessLine.lines(screenRecording: false, microphone: microphone),
                           microphone == .on ? [screenOff] : [screenOff, bothOff])
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
