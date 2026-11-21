import Foundation

let root = ProcessInfo.processInfo.environment["PILCROW_OUTBOX_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pilcrow/Outbox", isDirectory: true)
let server = Server(root: root)
while let line = readLine() {
    if let response = server.handle(Data(line.utf8)) {
        FileHandle.standardOutput.write(response)
        FileHandle.standardOutput.write(Data([0x0a]))
    }
}
