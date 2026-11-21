import Darwin
import Foundation
import CoreGraphics
import PilcrowCore

extension Destination {
    var title: String {
        switch self {
        case .clipboard: "Copy to clipboard"
        case .codexCLI: "Codex"
        case .claudeCode: "Claude Code"
        case .mcp: "MCP"
        }
    }

    var command: String? {
        switch self {
        case .codexCLI: "codex"
        case .claudeCode: "claude"
        case .clipboard, .mcp: nil
        }
    }
}

/// These helpers deliberately have no AppKit or filesystem side effects.
enum DeliveryText {
    static func approved(coreText: String, failedImages: [String]) -> String {
        guard !failedImages.isEmpty else { return coreText }
        return coreText + "\n\nThese images could not be saved: " + failedImages.joined(separator: ", ")
    }

    static func message(approvedText: String, imagePaths: [String]) -> String {
        guard !imagePaths.isEmpty else { return approvedText }
        return approvedText + "\n\nImages (read these first):" + imagePaths.map { "\n" + $0 }.joined()
    }

    /// Only the agent file gets this hint; the clipboard message keeps its existing form.
    static func fileMessage(approvedText: String, imagePaths: [String]) -> String {
        let message = message(approvedText: approvedText, imagePaths: imagePaths)
        guard !imagePaths.isEmpty else { return message }
        return message + "\n\nThe images also contain each mark's words under its badge."
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func script(destination: Destination, projectPath: String, imagePaths: [String], messagePath: String,
                       shellPath: String = LoginShell.path) -> String? {
        guard let command = destination.command else { return nil }
        let images: String
        if destination == .codexCLI, !imagePaths.isEmpty, !imagePaths.contains(where: { $0.contains(",") }) {
            images = " -i " + shellQuote(imagePaths.joined(separator: ","))
        } else {
            images = ""
        }
        // Change directory after shell startup too: a startup file may itself cd.
        let invocation = "cd " + shellQuote(projectPath) + " || exit $?\n"
            + "pilcrow_executable=$(" + executableLookup(command, shellPath: shellPath) + ") || exit $?\n"
            + "case \"$pilcrow_executable\" in /*) ;; *) exit 127 ;; esac\n"
            + "exec \"$pilcrow_executable\"" + images
            + " -- \"$(/bin/cat " + shellQuote(messagePath) + ")\""
        return "#!/bin/sh\nexec " + shellQuote(LoginShell.allowed(shellPath)) + " -ilc " + shellQuote(invocation) + "\n"
    }

    static func executableLookup(_ command: String, shellPath: String) -> String {
        let lookup: String
        switch URL(fileURLWithPath: LoginShell.allowed(shellPath)).lastPathComponent {
        case "zsh": lookup = "whence -p "
        case "bash": lookup = "type -P "
        default: lookup = "command -v "
        }
        return lookup + shellQuote(command)
    }

    struct RetentionCandidate {
        let name: String
        let isDirectory: Bool
        let isSymlink: Bool
        let isOwnedByUser: Bool
        let createdAt: Date
    }

    static func shouldRemove(_ item: RetentionCandidate, now: Date, clearAll: Bool = false) -> Bool {
        guard UUID(uuidString: item.name) != nil, item.isDirectory,
              !item.isSymlink, item.isOwnedByUser else { return false }
        return clearAll || now.timeIntervalSince(item.createdAt) > 24 * 60 * 60
    }
}

struct ApprovalExport: Sendable {
    struct Mark: Sendable {
        let number: Int
        let words: String
        let thumbnail: CGImage?
    }

    let id: UUID
    let folder: URL
    let text: String
    let attachments: [OutboxManifest.Attachment]
    let imageData: [Data]
    let marks: [Mark]
    let spokenSummary: String
    let hudAnchor: CGRect
    /// Uptime when Finish was pressed, before voice drain or capture wait.
    let finishStartedAt: TimeInterval

    func relocated(to folder: URL) -> ApprovalExport {
        ApprovalExport(id: id, folder: folder, text: text, attachments: attachments,
            imageData: imageData, marks: marks, spokenSummary: spokenSummary,
            hudAnchor: hudAnchor, finishStartedAt: finishStartedAt)
    }

    func imageURLs(in folder: URL) -> [URL] {
        attachments.map { folder.appendingPathComponent($0.name) }
    }
}

/// Resolve once for Preview so discovery and the generated script use the same shell.
enum LoginShell {
    static func allowed(_ candidate: String) -> String {
        let names = ["zsh", "bash", "sh", "ksh", "dash"]
        guard candidate.hasPrefix("/"), names.contains(URL(fileURLWithPath: candidate).lastPathComponent),
              FileManager.default.isExecutableFile(atPath: candidate) else { return "/bin/zsh" }
        return candidate
    }

    static var path: String {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: max(16_384, Int(sysconf(_SC_GETPW_R_SIZE_MAX))))
        let login = buffer.withUnsafeMutableBufferPointer { storage -> String? in
            guard getpwuid_r(getuid(), &entry, storage.baseAddress, storage.count, &result) == 0,
                  result != nil, let shell = entry.pw_shell else { return nil }
            return String(cString: shell)
        }
        for candidate in [login, ProcessInfo.processInfo.environment["SHELL"], "/bin/zsh"] {
            if let candidate { return allowed(candidate) }
        }
        return "/bin/zsh"
    }
}

/// Called only from a detached task. Retain only a bounded stdout tail, never log
/// shell output, and kill the whole startup process group if the deadline expires.
enum CommandDetection {
    static func isAvailable(_ command: String, shellPath: String = LoginShell.path) -> Bool {
        guard command == "codex" || command == "claude" else { return false }
        let shellPath = LoginShell.allowed(shellPath)
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { return false }
        defer { close(descriptors[0]); close(descriptors[1]) }
        let null = open("/dev/null", O_RDWR | O_CLOEXEC)
        guard null >= 0 else { return false }
        defer { close(null) }
        for fd in descriptors { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(descriptors[0], F_SETFL, O_NONBLOCK)

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return false }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return false }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_adddup2(&actions, null, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, null, STDERR_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, descriptors[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, descriptors[1]) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { return false }
        let sentinel = "PILCROW_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        // Leading newlines isolate both sentinels even when rc output has no newline.
        let script = "printf '\n" + sentinel + "_BEGIN\n'; " + DeliveryText.executableLookup(command, shellPath: shellPath)
            + "; pilcrow_status=$?; printf '\n" + sentinel + "_END\n'; exit \"$pilcrow_status\""
        let argumentStrings = [shellPath, "-ilc", script]
        let arguments = argumentStrings.map { value in value.withCString { strdup($0) } } + [nil]
        let environment = ProcessInfo.processInfo.environment.map { entry in
            (entry.key + "=" + entry.value).withCString { strdup($0) }
        } + [nil]
        defer {
            arguments.forEach { free($0) }
            environment.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = arguments.withUnsafeBufferPointer { argv in
            environment.withUnsafeBufferPointer { env in
                posix_spawn(&pid, shellPath, &actions, &attributes,
                            UnsafeMutablePointer(mutating: argv.baseAddress!),
                            UnsafeMutablePointer(mutating: env.baseAddress!))
            }
        }
        guard spawned == 0 else { return false }
        var tail = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        func drain() {
            // Bound each pass too, so noisy startup cannot outrun the deadline.
            for _ in 0..<16 {
                let count = read(descriptors[0], &bytes, bytes.count)
                guard count > 0 else { break }
                tail.append(contentsOf: bytes.prefix(count))
                if tail.count > 8192 { tail = Data(tail.suffix(8192)) }
            }
        }
        var status: Int32 = 0
        let deadline = ContinuousClock.now + .seconds(3)
        while true {
            drain()
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            if waited < 0 && errno != EINTR { return false }
            if ContinuousClock.now >= deadline {
                kill(-pid, SIGTERM)
                Thread.sleep(forTimeInterval: 0.5)
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                return false
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        drain()
        let lines = String(decoding: tail, as: UTF8.self).components(separatedBy: .newlines)
        guard let begin = lines.firstIndex(of: sentinel + "_BEGIN"),
              let end = lines.firstIndex(of: sentinel + "_END"), begin < end else { return false }
        let paths = lines[(begin + 1)..<end].filter { !$0.isEmpty }
        guard paths.count == 1, let lastLine = paths.first else { return false }
        var isDirectory: ObjCBool = false
        return status == 0 && lastLine.hasPrefix("/")
            && FileManager.default.fileExists(atPath: lastLine, isDirectory: &isDirectory)
            && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: lastLine)
    }
}

/// One coalesced detection per command and login shell for the app's lifetime.
actor CommandAvailability {
    static let shared = CommandAvailability()
    private struct Key: Hashable { let command: String; let shell: String }
    private var checks: [Key: Task<Bool, Never>] = [:]

    func available(_ command: String, shellPath: String, refresh: Bool = false) async -> Bool {
        let key = Key(command: command, shell: shellPath)
        if !refresh, let check = checks[key] { return await check.value }
        let check = Task.detached { CommandDetection.isAvailable(command, shellPath: shellPath) }
        checks[key] = check
        return await check.value
    }
}
