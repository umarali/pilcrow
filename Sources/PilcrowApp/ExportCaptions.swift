import Foundation
import CoreGraphics
import CoreText
import PilcrowCore

/// Pixel-based layout. Captions are never downsampled with the screenshot.
enum ExportCaptions {
    static let fontSize: CGFloat = 16
    static let lineHeight: CGFloat = 22
    static let truncationNote = "(full words in the message)"
    private static let padding: CGFloat = 16
    private static let gap: CGFloat = 8
    private static let grey = CGColor(gray: 0.40, alpha: 1)

    struct Row {
        let mark: MarkID
        let lines: [CTLine]
        let height: CGFloat
    }

    struct Layout {
        let size: PixelSize
        let screenshot: PixelSize
        let badgeHeight: CGFloat
        let rows: [Row]
        var panelHeight: Int { size.height - screenshot.height }
    }

    static func layout(size: PixelSize, items: [FixItem], badgeHeight: CGFloat, frame: Bool) throws -> Layout {
        precondition(!items.isEmpty)
        let widestBadge = items.map { MarkBadgeGeometry.numberedBadgeWidth(id: $0.mark, height: badgeHeight) }.max() ?? badgeHeight
        let note = CTLineCreateWithAttributedString(NSAttributedString(string: "… " + truncationNote,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)]))
        let minimumWidth = Int(ceil(2 * padding + widestBadge + 12 + CTLineGetTypographicBounds(note, nil, nil, nil)))
        // Search largest screenshot first, leaving font and badge sizes unchanged.
        // Only the source image is shrunk, with its original aspect and crop rectangle.
        for percent in stride(from: 100, through: 1, by: -1) {
            let scale = Double(percent) / 100
            let screenshot = PixelSize(width: max(1, Int(Double(size.width) * scale)),
                                       height: max(1, Int(Double(size.height) * scale)))
            let width = max(320, screenshot.width, minimumWidth)
            let budget = frame ? floor(CGFloat(screenshot.height) * 2 / 3) : 2 * padding + 8 * lineHeight
            let perRow = (budget - 2 * padding - gap * CGFloat(items.count - 1)) / CGFloat(items.count)
            guard perRow >= badgeHeight else { continue }
            let maxLines = frame ? Int(perRow / lineHeight) : min(8, Int(perRow / lineHeight))
            guard maxLines >= 1 else { continue }
            let rows = items.map { item -> Row in
                let badgeWidth = MarkBadgeGeometry.numberedBadgeWidth(id: item.mark, height: badgeHeight)
                let textWidth = CGFloat(width) - 2 * padding - badgeWidth - 12
                let lines = wrapped(item, width: textWidth, maxLines: maxLines)
                return Row(mark: item.mark, lines: lines, height: max(badgeHeight, CGFloat(lines.count) * lineHeight))
            }
            let panel = Int(ceil(2 * padding + rows.reduce(0) { $0 + $1.height } + gap * CGFloat(rows.count - 1)))
            let height = screenshot.height + panel
            guard width <= Int(ImageLimits.maxLongEdge), height <= Int(ImageLimits.maxLongEdge),
                  width * height <= Int(ImageLimits.maxPixels),
                  !frame || Double(panel) <= Double(height) * 0.4 else { continue }
            return Layout(size: PixelSize(width: width, height: height), screenshot: screenshot,
                          badgeHeight: badgeHeight, rows: rows)
        }
        throw Export.Failure.render
    }

    private static func wrapped(_ item: FixItem, width: CGFloat, maxLines: Int) -> [CTLine] {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colourKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let kind = item.kindLabel.trimmingCharacters(in: .whitespaces)
        let text = NSMutableAttributedString(string: kind.isEmpty ? "" : kind + " ",
                                            attributes: [fontKey: font, colourKey: grey])
        text.append(NSAttributedString(string: item.words, attributes: [fontKey: font,
            colourKey: CGColor(srgbRed: 29 / 255, green: 29 / 255, blue: 31 / 255, alpha: 1)]))
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        var offset = 0
        var lines: [CTLine] = []
        while offset < text.length && lines.count < maxLines {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, offset, Double(width)))
            if lines.count == maxLines - 1 && offset + count < text.length {
                let remainder = CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: text.length - offset))
                let suffix = NSMutableAttributedString(string: "… ", attributes: [fontKey: font, colourKey: grey])
                suffix.append(NSAttributedString(string: truncationNote, attributes: [fontKey: font, colourKey: grey]))
                let token = CTLineCreateWithAttributedString(suffix)
                lines.append(CTLineCreateTruncatedLine(remainder, Double(width), .end, token) ?? token)
                break
            }
            lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: count)))
            offset += count
        }
        return lines
    }

    static func render(_ image: CGImage, layout: Layout, colour: PilcrowColour) throws -> CGImage {
        let space = image.colorSpace?.model == .rgb ? image.colorSpace : CGColorSpace(name: CGColorSpace.sRGB)
        guard let space,
              let context = CGContext(data: nil, width: layout.size.width, height: layout.size.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Export.Failure.render }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: layout.size.width, height: layout.size.height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (layout.size.width - layout.screenshot.width) / 2,
            y: layout.panelHeight, width: layout.screenshot.width, height: layout.screenshot.height))
        context.setFillColor(CGColor(gray: 0.84, alpha: 1))
        context.fill(CGRect(x: 0, y: layout.panelHeight - 1, width: layout.size.width, height: 1))
        var top = CGFloat(layout.panelHeight) - padding
        for row in layout.rows {
            let width = MarkBadgeGeometry.numberedBadgeWidth(id: row.mark, height: layout.badgeHeight)
            MarkRenderer.drawNumberedBadge(row.mark,
                in: CGRect(x: padding, y: top - layout.badgeHeight, width: width, height: layout.badgeHeight),
                context: context, colour: colour)
            context.textMatrix = .identity
            for (index, line) in row.lines.enumerated() {
                context.textPosition = CGPoint(x: padding + width + 12, y: top - 17 - CGFloat(index) * lineHeight)
                CTLineDraw(line, context)
            }
            top -= row.height + gap
        }
        guard let result = context.makeImage() else { throw Export.Failure.render }
        return result
    }
}
