import AppKit
import ScreenCaptureKit
import os

enum CaptureOutcome: Sendable {
    case image(CGImage)
    case permissionNeeded
    case unavailable
    case timedOut
}

@MainActor
enum Capture {
    private static let log = Logger(subsystem: "org.pilcrow.app", category: "capture")

    static func probe() async -> Bool {
        guard !Task.isCancelled, CGPreflightScreenCaptureAccess() else { return false }
        let displayID = CGMainDisplayID()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard !Task.isCancelled, CGPreflightScreenCaptureAccess() else { return false }
            guard let display = content.displays.first(where: { $0.displayID == displayID }),
                  let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
                log.notice("Main display missing for Screen Recording probe")
                return false
            }
            let configuration = SCStreamConfiguration()
            let region = CGRect(x: 0, y: 0, width: 16, height: 16)
            configuration.sourceRect = region
            configuration.width = Int((region.width * screen.backingScaleFactor).rounded())
            configuration.height = Int((region.height * screen.backingScaleFactor).rounded())
            configuration.showsCursor = false
            _ = try await SCScreenshotManager.captureImage(contentFilter: filter(for: display, in: content),
                                                           configuration: configuration)
            return !Task.isCancelled
        } catch {
            _ = failure(at: "Screen Recording probe", error: error)
            return false
        }
    }

    static func frame(_ geometry: FrameGeometry) async -> CaptureOutcome {
        guard !Task.isCancelled else { return .unavailable }
        guard CGPreflightScreenCaptureAccess() else {
            log.notice("Frame Screen Recording preflight denied")
            return .permissionNeeded
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            return failure(at: "SCShareableContent", error: error)
        }
        guard !Task.isCancelled else { return .unavailable }
        guard let display = content.displays.first(where: { $0.displayID == geometry.display }) else {
            log.notice("Marked display missing from shareable content")
            return .unavailable
        }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == geometry.display }),
              screen.frame.size == geometry.size, screen.backingScaleFactor == geometry.scale else {
            log.notice("Display geometry changed before capture")
            return .unavailable
        }

        let filter = filter(for: display, in: content)
        // Newly created filters may report incomplete metadata. Use the live display
        // geometry above and check the image itself before exporting.
        if filter.contentRect.size != geometry.size { log.notice("Filter content rectangle size differs") }
        if CGFloat(filter.pointPixelScale) != geometry.scale { log.notice("Filter pixel scale differs") }

        let configuration = SCStreamConfiguration()
        configuration.width = geometry.width
        configuration.height = geometry.height
        configuration.showsCursor = false
        configuration.captureResolution = .best
        if let name = CGDisplayCopyColorSpace(geometry.display).name {
            configuration.colorSpaceName = name
        }
        guard !Task.isCancelled else { return .unavailable }
        guard CGPreflightScreenCaptureAccess() else { return .permissionNeeded }
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            return failure(at: "captureImage", error: error)
        }
        guard !Task.isCancelled else { return .unavailable }
        guard image.width == geometry.width, image.height == geometry.height else {
            log.notice("Captured image dimensions differ")
            return .unavailable
        }
        return .image(image)
    }

    private static func filter(for display: SCDisplay, in content: SCShareableContent) -> SCContentFilter {
        let pid = ProcessInfo.processInfo.processIdentifier
        if let app = content.applications.first(where: { $0.processID == pid }) {
            return SCContentFilter(display: display, excludingApplications: [app], exceptingWindows: [])
        }
        log.info("Pilcrow missing from shareable applications; excluding its windows by process")
        let ownWindowIDs = Set(NSApp.windows.compactMap { CGWindowID(exactly: $0.windowNumber) })
        let windows = content.windows.filter {
            $0.owningApplication?.processID == pid || ownWindowIDs.contains($0.windowID)
        }
        return SCContentFilter(display: display, excludingWindows: windows)
    }

    private static func failure(at step: String, error: Error) -> CaptureOutcome {
        guard !Task.isCancelled else { return .unavailable }
        if let streamError = error as? SCStreamError {
            log.notice("\(step, privacy: .public) failed with SCStreamError \(streamError.code.rawValue, privacy: .public)")
            if streamError.code == .userDeclined { return .permissionNeeded }
        } else {
            let error = error as NSError
            log.notice("\(step, privacy: .public) failed with \(error.domain, privacy: .public) code \(error.code, privacy: .public)")
        }
        return CGPreflightScreenCaptureAccess() ? .unavailable : .permissionNeeded
    }
}
