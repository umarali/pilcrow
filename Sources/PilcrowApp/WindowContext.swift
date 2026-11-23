import AppKit
import PilcrowCore

/// CGWindowList returns front-to-back windows in Quartz's global top-left coordinates.
enum WindowContext {
    static func capture(displayID: CGDirectDisplayID, point: NormalizedPoint) -> FrameContext? {
        let display = CGDisplayBounds(displayID)
        let location = CGPoint(x: display.minX + point.x * display.width,
                               y: display.minY + point.y * display.height)
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]],
              let window = select(windows, point: location, display: display,
                                  excludingPID: ProcessInfo.processInfo.processIdentifier) else { return nil }
        let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        let bundle = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        let app = window[kCGWindowOwnerName as String] as? String
        let title = window[kCGWindowName as String] as? String
        guard app?.isEmpty == false || title?.isEmpty == false else { return nil }
        return FrameContext(appName: app, windowTitle: title, bundleID: bundle)
    }

    static func select(_ windows: [[String: Any]], point: CGPoint, display: CGRect,
                       excludingPID: Int32) -> [String: Any]? {
        let normal = windows.filter { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? NSNumber, pid.int32Value != excludingPID,
                  let layer = window[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue != 0,
                  let rect = bounds(window), rect.width > 0, rect.height > 0 else { return false }
            return rect.intersects(display)
        }
        return normal.first { bounds($0)?.contains(point) == true } ?? normal.first
    }

    private static func bounds(_ window: [String: Any]) -> CGRect? {
        guard let dictionary = window[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }
}
