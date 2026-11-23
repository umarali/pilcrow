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
            return [Self(text: "Screen Recording and Microphone are on.", action: nil)]
        }
        var lines: [Self] = []
        if !screenRecording {
            lines.append(Self(text: "Pilcrow can’t capture without it.", action: .screen))
        }
        if microphone != .on {
            let detail = screenRecording ? "Microphone is off. Marks work, voice won’t." : "Microphone is off."
            lines.append(Self(text: detail, action: .microphone))
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
        let command = agent == .claude ? "claude mcp add --scope user --transport stdio pilcrow -- " : "codex mcp add pilcrow -- "
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
    @Published var reopenMessage: String?
    @Published var canReopen = false
    @Published var voiceNote = ""
    @Published var voiceAction: String?
    @Published var canClear = false
    @Published var copied: Set<MCPSetupAgent> = []
    @Published var copyError = ""
    @Published var colour: PilcrowColour = .coral
    var record: (HotKeys.Shortcut) -> Void = { _ in }
    var reset: (HotKeys.Shortcut) -> Void = { _ in }
    var defaultLabel: (HotKeys.Shortcut) -> String = { $0.defaultChord.glyph }
    var copy: (MCPSetupAgent) -> Void = { _ in }
    var screenAccess: () -> Void = {}
    var microphoneAccess: () -> Void = {}
    var reopen: () -> Void = {}
    var showCaptures: () -> Void = {}
    var clearCaptures: () -> Void = {}
    var colourChanged: (PilcrowColour) -> Void = { _ in }

    func updateAccess(screenRecording: Bool, microphone: SettingsMicrophoneAccess, canStart: Bool,
                      voiceStatus: String, voiceAction: String?, voiceActionEnabled: Bool) {
        access = SettingsAccessLine.lines(screenRecording: screenRecording, microphone: microphone)
        accessEnabled = canStart
        voiceNote = voiceStatus == "On" ? "" : voiceStatus
        self.voiceAction = voiceActionEnabled ? voiceAction : nil
    }

    func selectColour(_ choice: PilcrowColour) {
        guard colour != choice else { return }
        colour = choice
        colourChanged(choice)
    }
}

struct SettingsStoryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var focusedShortcut: HotKeys.Shortcut?
    @ObservedObject var model: SettingsPresentation
    private var dark: Bool { colorScheme == .dark }
    private var accent: Color { Color(cgColor: model.colour.accent(dark: dark)) }
    private var opaqueSurface: Color { dark ? Color(white: 0.16) : Color(white: 0.98) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header.padding(.horizontal, 8).padding(.bottom, 3)
            // No GlassEffectContainer: live windows composite its merged glass over the cards' content.
            VStack(alignment: .leading, spacing: 10) {
                if let screen = model.access.first(where: { $0.action == .screen }) {
                    screenCard(screen.text)
                }
                if let microphone = model.access.first(where: { $0.action == .microphone }) {
                    microphonePill(microphone.text)
                }
                glassGroup { steps }
                glassGroup { agentCard }
                glassGroup { colourPicker }
            }
            footer.padding(.horizontal, 12)
        }
        .padding(.horizontal, 16).padding(.top, 38).padding(.bottom, 18)
        .frame(width: 440, alignment: .leading)
        .background {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(stops: [
                .init(color: accent.opacity(dark ? 0.26 : 0.30), location: 0),
                .init(color: accent.opacity(dark ? 0.08 : 0.12), location: 0.28),
                .init(color: .clear, location: 0.63),
                .init(color: accent.opacity(0.07), location: 1)
            ], startPoint: .topLeading, endPoint: .bottom)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            glyph(size: 36).frame(width: 54, height: 54)
                .background(LinearGradient(colors: [.white, Color(white: 0.93)],
                    startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 13))
                .shadow(color: .black.opacity(dark ? 0.24 : 0.12), radius: 5, y: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("Pilcrow").font(.system(size: 21, weight: .semibold))
                Text("Point at it. Say it. Paste it.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
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
            .font(.system(size: 15)).padding(16)

            if model.rejection == nil {
                Rectangle().fill(.primary.opacity(0.10)).frame(height: 0.5)
                Text(model.recording != nil ? (model.recorderNote.isEmpty ? "Esc cancels · Delete resets · Press fn with the F-key" : model.recorderNote) :
                        (model.recorderNote.isEmpty ? "Click a key to change it." : model.recorderNote))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 51).padding(.trailing, 16).padding(.vertical, 10)
            }
        }
    }

    private func step<Content: View>(_ number: Int, @ViewBuilder content: () -> Content) -> some View {
        let blocked = model.access.contains { $0.action == .screen }
        var fill = model.colour.accent(dark: dark)
        if blocked {
            NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                fill = NSColor.systemGray.cgColor
            }
        }
        return HStack(alignment: .top, spacing: 13) {
            Text(String(number)).font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color(cgColor: PilcrowColour.settingsNumeral(on: fill)))
                .frame(width: 22, height: 22)
                .background(Color(cgColor: fill), in: Circle())
                .padding(.top, 2).accessibilityLabel("Step \(number)")
            content().frame(minHeight: 26, alignment: .leading)
        }
    }

    private func keycap(_ shortcut: HotKeys.Shortcut, small: Bool = false) -> some View {
        let rejected = model.rejection?.shortcut == shortcut
        let recording = model.recording == shortcut
        let focused = recording || focusedShortcut == shortcut
        let glyph = rejected ? model.rejection!.glyph : (recording ? "Press a shortcut…" : (shortcut == .annotate ? model.start : model.undo))
        let shape = RoundedRectangle(cornerRadius: small ? 6 : 7)
        return Button { model.record(shortcut) } label: {
            Text(glyph).font(.system(size: small ? 12.5 : 14, weight: .medium))
                .foregroundStyle(rejected ? Color.red : Color.primary)
                .padding(.horizontal, 8).frame(minWidth: small ? 36 : 40, minHeight: small ? 22 : 26)
                .background(LinearGradient(colors: dark ? [Color(white: 0.26), Color(white: 0.19)]
                    : [.white, Color(white: 0.94)], startPoint: .top, endPoint: .bottom), in: shape)
                .overlay(shape.strokeBorder(rejected ? .red : (focused ? accent : .primary.opacity(0.15)),
                                            lineWidth: rejected || focused ? 1.5 : 0.5))
                .shadow(color: rejected ? .red.opacity(0.18) : (focused ? accent.opacity(0.4) : .black.opacity(0.10)),
                        radius: rejected || focused ? 3 : 0, y: 1)
        }
        .buttonStyle(.plain).fixedSize()
        .focused($focusedShortcut, equals: shortcut)
        .focusEffectDisabled()
        .accessibilityLabel(shortcut == .annotate ? "Start / finish shortcut" : "Undo mark shortcut")
        .accessibilityValue(glyph)
        .help("Click to record. Esc cancels; Delete resets the default. Press fn with the F-key.")
    }

    private func rejectionBubble(_ shortcut: HotKeys.Shortcut) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.rejection?.reason ?? "").font(.system(size: 12.5, weight: .semibold))
                Text(model.recording == nil ? "Click the key to try another shortcut." : "Press another shortcut.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
            Button { model.reset(shortcut) } label: {
                Label("Reset to \(model.defaultLabel(shortcut))", systemImage: "return")
            }.buttonStyle(.bordered).controlSize(.small).fixedSize()
        }
        .padding(12).background(opaqueSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        .padding(.leading, 35)
    }

    private var agentCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "terminal").font(.system(size: 15)).frame(width: 30, height: 30)
                .foregroundStyle(accent).background(accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
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
                if !model.copyError.isEmpty { Text(model.copyError).font(.system(size: 11.5)).foregroundStyle(.red).padding(.top, 8) }
            }
        }
        .padding(16)
    }

    private func glyph(size: CGFloat) -> some View {
        Image(nsImage: StatusIcon.image(.annotating, colour: model.colour, dark: dark))
            .resizable().frame(width: size, height: size).accessibilityHidden(true)
    }

    private var colourPicker: some View {
        HStack(spacing: 12) {
            glyph(size: 18).frame(width: 30, height: 30)
                .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text("Colour · \(model.colour.name)").font(.system(size: 13, weight: .semibold))
                Text("Menu bar, marks and badges").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                ForEach(PilcrowColour.allCases, id: \.self) { colour in
                    let selected = model.colour == colour
                    let swatch = Color(cgColor: colour.accent(dark: dark))
                    Button { model.selectColour(colour) } label: {
                        Circle().fill(swatch).frame(width: 16, height: 16)
                            .frame(width: 22, height: 26)
                            .overlay {
                                if selected {
                                    Circle().strokeBorder(swatch, lineWidth: 1.5).frame(width: 22, height: 22)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(colour.name)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .help(colour.name)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pilcrow colour")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func glassGroup<Content: View>(radius: CGFloat = 20, @ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        let base = content().frame(maxWidth: .infinity, alignment: .leading)
        return Group {
            if reduceTransparency {
                base.background(shape.fill(opaqueSurface))
            } else {
                // Glass applied to the content itself sits behind it; the white wash keeps text crisp.
                base.background(shape.fill(.white.opacity(dark ? 0.05 : 0.40)))
                    .glassEffect(.regular, in: shape)
            }
        }
        .overlay(shape.strokeBorder(.primary.opacity(0.11), lineWidth: 0.5).allowsHitTesting(false))
    }

    private func screenCard(_ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.slash").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white).frame(width: 32, height: 32)
                .background(.red, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Screen Recording is off").font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(action: model.screenAccess) {
                HStack(spacing: 5) {
                    Text("Open Settings")
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                }
                .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(.red)
            .disabled(!model.accessEnabled).fixedSize()
        }
        .padding(12)
        .background {
            let shape = RoundedRectangle(cornerRadius: 16)
            shape.fill(opaqueSurface)
                .overlay(shape.fill(.red.opacity(dark ? 0.20 : 0.09)))
                .overlay(shape.strokeBorder(.red.opacity(0.35), lineWidth: 0.75))
        }
    }

    private func microphonePill(_ detail: String) -> some View {
        glassGroup(radius: 22) {
            HStack(spacing: 8) {
                Image(systemName: "mic.slash").foregroundStyle(.orange).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(detail)
                    if !model.voiceNote.isEmpty { Text(model.voiceNote).foregroundStyle(.secondary) }
                }
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let action = model.voiceAction {
                    Button(action, action: model.microphoneAccess)
                        .fontWeight(.semibold)
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                        .tint(.primary).background(.orange.opacity(0.14), in: Capsule())
                        .fixedSize()
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let access = model.access.first(where: { $0.action == nil }) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                    Text(access.text)
                }
            }
            if let message = model.reopenMessage {
                HStack {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    if model.canReopen { Button("Quit & Reopen", action: model.reopen) }
                }
            }
            if !model.access.contains(where: { $0.action == .microphone }), !model.voiceNote.isEmpty {
                HStack {
                    Text(model.voiceNote).fixedSize(horizontal: false, vertical: true)
                    if let action = model.voiceAction {
                        Button(action, action: model.microphoneAccess)
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
