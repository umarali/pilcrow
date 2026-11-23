import Foundation

/// Where an approved message was sent. See docs/delivery.md and D-20, D-21.
public enum Destination: String, Sendable, Codable, Equatable, CaseIterable {
    case clipboard
    case codexCLI = "codex-cli"
    case claudeCode = "claude-code"
    case mcp
}

/// The manifest Pilcrow writes as `manifest.json` in each outbox item
/// (`~/Library/Application Support/Pilcrow/Outbox/<id>/`) after the user approves a message.
/// The App writes it; `pilcrow-mcp` only reads it. Version 1.
public struct OutboxManifest: Sendable, Codable, Equatable {
    public struct Attachment: Sendable, Codable, Equatable {
        public enum Kind: String, Sendable, Codable, Equatable { case frame, crop }
        /// File name inside the outbox item folder, e.g. `frame-1.png` or `mark-3.png`.
        public var name: String
        public var kind: Kind
        /// The mark number for a crop; nil for a whole frame.
        public var mark: Int?
        public var context: FrameContext?
        public var visibleText: String?

        public init(name: String, kind: Kind, mark: Int? = nil, context: FrameContext? = nil, visibleText: String? = nil) {
            self.name = name
            self.kind = kind
            self.mark = mark
            self.context = context
            self.visibleText = visibleText.flatMap(VisibleText.concise)
        }
    }

    public static let currentVersion = 1

    public var version: Int
    public var id: UUID
    /// When the user approved the message.
    public var createdAt: Date
    public var destination: Destination
    /// The message text exactly as approved, without image paths: Core's `OutgoingMessage.text`,
    /// plus the App's short note naming any images that could not be saved.
    public var text: String
    /// Only files that were actually written into the item folder, in message order.
    public var attachments: [Attachment]

    public init(id: UUID = UUID(), createdAt: Date, destination: Destination, text: String, attachments: [Attachment]) {
        self.version = Self.currentVersion
        self.id = id
        self.createdAt = createdAt
        self.destination = destination
        self.text = text
        self.attachments = attachments
    }

    /// Encoder settings both writer and reader use: ISO 8601 dates, sorted keys.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
