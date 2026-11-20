import Foundation

/// An executable crop plan in original captured pixels, before any whole-frame downscaling.
public struct CropPlan: Sendable, Equatable, Hashable, Codable {
    /// Nil only for legacy decoded plans. Rebuild those plans from the session before exporting.
    public let sourceFrameID: Frame.ID?
    public let sourceFrameName: String
    public let sourcePixelRect: PixelRect
    public let outputSize: PixelSize
    public let cropName: String
}

/// A complete marked frame fitted to the export limits.
public struct FramePlan: Sendable, Equatable, Hashable, Codable {
    public let frameID: Frame.ID
    public let outputName: String
    public let outputSize: PixelSize
}

/// The previewed message. `isEmpty` is derived from `text` and `attachments`.
public struct OutgoingMessage: Sendable, Equatable, Hashable, Codable {
    public var text: String
    /// Complete frames in first-stroke order, then available crops in live-mark order.
    public var attachments: [String]
    public var cropPlans: [CropPlan]
    /// Marked frames without an image, in first-stroke order.
    public var pendingImages: [Frame.ID]
    public var failedImages: [Frame.ID]
    public var framePlans: [FramePlan]
    /// Compatibility view. New callers should use the separate outcome arrays.
    public var missingImages: [Frame.ID] { pendingImages + failedImages }
    /// Kept for the preview. Not written into `text`.
    public var destinationHint: String?

    public var isEmpty: Bool {
        text.isEmpty && attachments.isEmpty
    }

    public init(text: String, attachments: [String], missingImages: [Frame.ID] = [], cropPlans: [CropPlan] = [], pendingImages: [Frame.ID] = [], failedImages: [Frame.ID] = [], framePlans: [FramePlan] = [], destinationHint: String? = nil) {
        self.text = text
        self.attachments = attachments
        self.pendingImages = pendingImages
        self.failedImages = failedImages + missingImages.filter { !failedImages.contains($0) && !pendingImages.contains($0) }
        self.framePlans = framePlans
        self.cropPlans = cropPlans
        self.destinationHint = destinationHint
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case attachments
        case missingImages
        case cropPlans
        case destinationHint
        case pendingImages, failedImages, framePlans
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(pendingImages, forKey: .pendingImages)
        try container.encode(failedImages, forKey: .failedImages)
        try container.encode(missingImages, forKey: .missingImages)
        try container.encode(cropPlans, forKey: .cropPlans)
        try container.encode(framePlans, forKey: .framePlans)
        try container.encodeIfPresent(destinationHint, forKey: .destinationHint)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        attachments = try container.decode([String].self, forKey: .attachments)
        let decodedPending = try container.decodeIfPresent([Frame.ID].self, forKey: .pendingImages) ?? []
        pendingImages = decodedPending
        let legacyMissing = try container.decodeIfPresent([Frame.ID].self, forKey: .missingImages) ?? []
        failedImages = try container.decodeIfPresent([Frame.ID].self, forKey: .failedImages)
            ?? legacyMissing.filter { !decodedPending.contains($0) }
        framePlans = try container.decodeIfPresent([FramePlan].self, forKey: .framePlans) ?? []
        cropPlans = try container.decodeIfPresent([CropPlan].self, forKey: .cropPlans) ?? []
        destinationHint = try container.decodeIfPresent(String.self, forKey: .destinationHint)
    }
}

/// Assembles the transcript, per-mark fix list, and executable image plan for one session.
public enum MessageBuilder {
    /// Names marked frames in first-stroke order, including pending frames.
    public static func filenames(for session: Session) -> [Frame.ID: String] {
        Dictionary(uniqueKeysWithValues: session.framesWithMarks.enumerated().map {
            ($0.element.id, "frame-\($0.offset + 1).png")
        })
    }

    public static func build(
        session: Session,
        destinationHint: String? = nil,
        onlyFinal: Bool = false
    ) -> OutgoingMessage {
        let names = filenames(for: session)
        let list = FixList.build(session: session, onlyFinal: onlyFinal)
        let frames = session.framesWithMarks
        let cropPlans = list.items.compactMap { item -> CropPlan? in
            guard let rect = item.cropRect, let output = item.outputSize else { return nil }
            return CropPlan(sourceFrameID: item.frameID, sourceFrameName: item.imageName, sourcePixelRect: rect,
                            outputSize: output, cropName: item.cropName)
        }
        let framePlans = frames.compactMap { frame -> FramePlan? in
            guard frame.isComplete, let pixels = frame.pixelSize, let name = names[frame.id],
                  let output = Geometry.fitPixels(width: pixels.width, height: pixels.height,
                                                  maxLongEdge: ImageLimits.maxLongEdge, maxPixels: ImageLimits.maxPixels) else { return nil }
            return FramePlan(frameID: frame.id, outputName: name,
                             outputSize: PixelSize(width: output.width, height: output.height))
        }
        let attachments = framePlans.map(\.outputName) + cropPlans.map(\.cropName)
        return OutgoingMessage(text: list.renderMarkdown(), attachments: attachments,
                               cropPlans: cropPlans,
                               pendingImages: frames.filter { !$0.isComplete && !$0.captureFailed }.map(\.id),
                               failedImages: frames.filter(\.captureFailed).map(\.id),
                               framePlans: framePlans, destinationHint: destinationHint)
    }
}
