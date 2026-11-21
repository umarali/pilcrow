import AppKit
import SwiftUI

/// Display text is independent of TCC, so every access combination is testable.
enum SettingsMicrophoneAccess: CaseIterable { case on, undetermined, denied, restricted }

struct SettingsAccessLine: Equatable {
    enum Action { case screen, microphone }
    let text: String
    let action: Action?

    static func lines(screenRecording: Bool, microphone: SettingsMicrophoneAccess) -> [Self] {
        if screenRecording && microphone == .on {
            return [Self(text: "✓ Screen Recording and Microphone are on.", action: nil)]
        }
        var lines: [Self] = []
        if !screenRecording {
            lines.append(Self(text: "Screen Recording is off. Pilcrow needs it to see your screen.", action: .screen))
        }
        if microphone != .on {
            lines.append(Self(text: "Microphone is off. Marks still work; Pilcrow can't hear you.", action: .microphone))
        }
        return lines
    }
}

enum MCPSetupAgent: String, CaseIterable { case claude = "Claude Code", codex = "Codex" }

enum MCPSetupCommand {
    static func build(for agent: MCPSetupAgent, bundleURL: URL = Bundle.main.bundleURL) -> String {
        let path = bundleURL.appendingPathComponent("Contents/MacOS/pilcrow-mcp").path
        // Always quote, including apostrophes and shell metacharacters, not just spaces.
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let command = agent == .claude ? "claude mcp add --transport stdio pilcrow -- " : "codex mcp add pilcrow -- "
        return command + quoted
    }
}

struct SettingsRejection {
    let shortcut: HotKeys.Shortcut
    let glyph: String
    let reason: String
}

@MainActor
final class SettingsPresentation: ObservableObject {
    @Published var start = ""
    @Published var undo = ""
    @Published var recording: HotKeys.Shortcut?
    @Published var rejection: SettingsRejection?
    @Published var recorderNote = ""
    @Published var access: [SettingsAccessLine] = []
    @Published var accessEnabled = true
    @Published var microphoneEnabled = true
    @Published var reopenMessage: String?
    @Published var canReopen = false
    @Published var voiceNote = ""
    @Published var voiceAction: String?
    @Published var canClear = false
    @Published var copied: Set<MCPSetupAgent> = []
    @Published var copyError = ""
    var icon: NSImage = NSApp.applicationIconImage
    var record: (HotKeys.Shortcut) -> Void = { _ in }
    var reset: (HotKeys.Shortcut) -> Void = { _ in }
    var defaultLabel: (HotKeys.Shortcut) -> String = { $0.defaultChord.glyph }
    var copy: (MCPSetupAgent) -> Void = { _ in }
    var screenAccess: () -> Void = {}
    var microphoneAccess: () -> Void = {}
    var reopen: () -> Void = {}
    var showCaptures: () -> Void = {}
    var clearCaptures: () -> Void = {}
}

struct SettingsStoryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: SettingsPresentation
    private let markRed = Color(red: 227 / 255, green: 20 / 255, blue: 31 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: model.icon).resizable().frame(width: 46, height: 46)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pilcrow").font(.system(size: 21, weight: .semibold))
                    Text("Point at it. Say it. Paste it.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 30).padding(.top, 24)

            VStack(alignment: .leading, spacing: 15) {
                step(1) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("Press")
                        keycap(.annotate)
                        Text("anywhere to start.")
                    }
                }
                if model.rejection?.shortcut == .annotate { rejectionBubble(.annotate) }
                step(2) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Hold **⇧** and draw while you talk.")
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            keycap(.undo, small: true)
                            Text("takes back the last mark.").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                }
                if model.rejection?.shortcut == .undo { rejectionBubble(.undo) }
                step(3) { Text("Press **esc**, then **⌘V** into your agent.") }
            }
            .font(.system(size: 15)).padding(.horizontal, 30).padding(.top, 26)

            if model.rejection == nil {
                Text(model.recording != nil ? (model.recorderNote.isEmpty ? "Esc cancels · Delete resets · Press fn with the F-key" : model.recorderNote) :
                        (model.recorderNote.isEmpty ? "Click a key to change it." : model.recorderNote))
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 65).padding(.trailing, 30).padding(.top, 14)
            }

            agentCard.padding(.horizontal, 20).padding(.top, 26)
            footer.padding(.horizontal, 30).padding(.top, 18).padding(.bottom, 24)
        }
        .frame(width: 440, alignment: .leading)
        .background {
            Color(nsColor: .windowBackgroundColor)
            if colorScheme == .light { Color.primary.opacity(0.03) }
        }
    }

    private var cardSurface: Color {
        colorScheme == .dark ? Color.primary.opacity(0.055) : Color(nsColor: .textBackgroundColor)
    }

    private func step<Content: View>(_ number: Int, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text(String(number)).font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white).frame(width: 22, height: 22).background(markRed, in: Circle())
                .padding(.top, 2).accessibilityLabel("Step \(number)")
            content().frame(minHeight: 26, alignment: .leading)
        }
    }

    private func keycap(_ shortcut: HotKeys.Shortcut, small: Bool = false) -> some View {
        let rejected = model.rejection?.shortcut == shortcut
        let recording = model.recording == shortcut
        let glyph = rejected ? model.rejection!.glyph : (recording ? "Press a shortcut…" : (shortcut == .annotate ? model.start : model.undo))
        return Button { model.record(shortcut) } label: {
            Text(glyph).font(.system(size: small ? 12.5 : 14, weight: .medium))
                .foregroundStyle(rejected ? markRed : Color.primary)
                .padding(.horizontal, 8).frame(minWidth: small ? 36 : 40, minHeight: small ? 22 : 26)
                .background(LinearGradient(colors: colorScheme == .dark
                    ? [Color.primary.opacity(0.14), Color.primary.opacity(0.09)]
                    : [Color(nsColor: .textBackgroundColor), Color.primary.opacity(0.035)],
                    startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: small ? 6 : 7))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: small ? 6 : 7))
                .overlay(RoundedRectangle(cornerRadius: small ? 6 : 7)
                    .strokeBorder(rejected ? markRed : Color.primary.opacity(0.15), lineWidth: rejected ? 1.5 : 0.5))
                .shadow(color: rejected ? markRed.opacity(0.18) : .black.opacity(0.10), radius: rejected ? 3 : 0, y: 1)
        }
        .buttonStyle(.plain).fixedSize()
        .accessibilityLabel(shortcut == .annotate ? "Start / finish shortcut" : "Undo mark shortcut")
        .accessibilityValue(glyph)
        .help("Click to record. Esc cancels; Delete resets the default. Press fn with the F-key.")
    }

    private func rejectionBubble(_ shortcut: HotKeys.Shortcut) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(markRed)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.rejection?.reason ?? "").font(.system(size: 12.5, weight: .semibold))
                Text(model.recording == nil ? "Click the key to try another shortcut." : "Press another shortcut.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
            Button { model.reset(shortcut) } label: {
                Label("Reset to \(model.defaultLabel(shortcut))", systemImage: "return")
            }.buttonStyle(.bordered).controlSize(.small).fixedSize()
        }
        .padding(12).background(cardSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        .padding(.leading, 35)
    }

    private var agentCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "terminal").font(.system(size: 15)).frame(width: 30, height: 30)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 0) {
                Text("Let your agent fetch captures").font(.system(size: 13, weight: .semibold))
                Text("Paste one command into your terminal, once. After that, ask your agent to look instead of pasting.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                HStack(spacing: 8) {
                    Text("Copy for").foregroundStyle(.secondary)
                    ForEach(MCPSetupAgent.allCases, id: \.self) { agent in
                        Button { model.copy(agent) } label: {
                            Label(model.copied.contains(agent) ? "Copied" : agent.rawValue,
                                  systemImage: model.copied.contains(agent) ? "checkmark" : "doc.on.doc")
                        }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                            .help("Copy the \(agent.rawValue) setup command for this Pilcrow bundle")
                    }
                }.font(.system(size: 12)).padding(.top, 12).fixedSize()
                if !model.copyError.isEmpty { Text(model.copyError).font(.system(size: 11.5)).foregroundStyle(markRed).padding(.top, 8) }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(cardSurface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(model.access.enumerated()), id: \.offset) { _, line in
                if let action = line.action {
                    let enabled = action == .microphone ? model.microphoneEnabled : model.accessEnabled
                    let label = action == .screen ? "Open Settings" : "Turn On…"
                    Text(.init(line.text + " [" + label + "](pilcrow-settings://access)"))
                        .fixedSize(horizontal: false, vertical: true)
                        .environment(\.openURL, OpenURLAction { _ in
                            guard enabled else { return .handled }
                            if action == .screen { model.screenAccess() } else { model.microphoneAccess() }
                            return .handled
                        })
                        .disabled(!enabled)
                } else { Text(line.text) }
            }
            if let message = model.reopenMessage {
                HStack {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    if model.canReopen { Button("Quit & Reopen", action: model.reopen) }
                }
            }
            if !model.voiceNote.isEmpty {
                HStack {
                    Text(model.voiceNote).fixedSize(horizontal: false, vertical: true)
                    if let action = model.voiceAction {
                        Button(action, action: model.microphoneAccess).disabled(!model.microphoneEnabled)
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "clock").foregroundStyle(.tertiary)
                Text("Captures stay on this Mac for 24 hours.")
                Button("Show", action: model.showCaptures).foregroundStyle(.primary).help("Show the outbox folder in Finder")
                Text("·").foregroundStyle(.tertiary)
                Button("Clear", action: model.clearCaptures).foregroundStyle(.primary).disabled(!model.canClear).opacity(model.canClear ? 1 : 0.35)
            }.fixedSize()
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .buttonStyle(.plain).tint(.primary)
    }
}
