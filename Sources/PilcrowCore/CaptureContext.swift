import Foundation

/// Optional provenance for a captured frame. No URLs or Accessibility data.
public struct FrameContext: Sendable, Equatable, Hashable, Codable {
    public var appName: String?
    public var windowTitle: String?
    public var bundleID: String?

    public init(appName: String? = nil, windowTitle: String? = nil, bundleID: String? = nil) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.bundleID = bundleID
    }

    var messageLabel: String? {
        let app = appName.flatMap(VisibleText.singleLine).map(TextSanitizer.markdownQuoted)
        let title = windowTitle.flatMap(VisibleText.singleLine).map { "\"\(TextSanitizer.markdownQuoted($0))\"" }
        let parts = [app, title].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

public enum VisibleText {
    static func singleLine(_ text: String) -> String? {
        let clean = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return clean.isEmpty ? nil : clean
    }

    /// Limit by grapheme clusters, including the final ellipsis.
    public static func concise(_ text: String) -> String? {
        guard let clean = singleLine(text) else { return nil }
        return clean.count > 80 ? String(clean.prefix(79)) + "…" : clean
    }
}
