import CoreGraphics

struct FrameGeometry: Equatable, Sendable {
    let display: CGDirectDisplayID
    let size: CGSize
    let scale: CGFloat

    var width: Int { Int((size.width * scale).rounded()) }
    var height: Int { Int((size.height * scale).rounded()) }

    /// Maps display-local AppKit points into the y-up bitmap's pixel coordinates.
    var bitmapTransform: CGAffineTransform {
        CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                          tx: 0, ty: CGFloat(height) - size.height * scale)
    }
}
