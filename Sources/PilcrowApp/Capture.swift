import AppKit
import PilcrowCore
import ScreenCaptureKit
import os

enum CaptureFailure: String, Sendable {
    case permissionNeeded = "permission needed"
    case unavailable
    case cancelled
    case timedOut = "timed out"
    case invalidCapture = "capture validation failed"
}

enum CaptureOutcome: Sendable {
    case image(CGImage, uptime: TimeInterval)
    case failed(CaptureFailure)
}

@MainActor
final class CaptureTask {
    private static let timeout: Duration = .seconds(5)
    private var completion: ((CaptureOutcome) -> Void)?
    private var capture: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    init(frame: Frame, scale: CGFloat, completion: @escaping (CaptureOutcome) -> Void) {
        self.completion = completion
        let expires = ContinuousClock.now + Self.timeout
        capture = Task { [weak self] in
            let outcome = await Capture.frame(frame, scale: scale)
            guard !Task.isCancelled else { return }
            self?.resolve(ContinuousClock.now < expires ? outcome : .failed(.timedOut))
        }
        // ScreenCaptureKit may stay suspended after cancellation. Finish waits for
        // the resolved outcome, which the deadline supplies even if capture is stuck.
        deadline = Task { [weak self] in
            do { try await Task.sleep(until: expires, clock: .continuous) }
            catch { return }
            self?.resolve(.failed(.timedOut))
        }
    }

    func cancel() {
        resolve(.failed(.cancelled))
    }

    func wait() async {
        guard completion != nil else { return }
        await withCheckedContinuation {
            precondition(waiter == nil, "A capture supports one waiter")
            waiter = $0
        }
    }

    private func resolve(_ outcome: CaptureOutcome) {
        guard let completion else { return }
        self.completion = nil
        capture?.cancel()
        capture = nil
        deadline?.cancel()
        deadline = nil
        completion(outcome)
        waiter?.resume()
        waiter = nil
    }
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

    static func frame(_ frame: Frame, scale: CGFloat) async -> CaptureOutcome {
        let size = CGSize(width: frame.boundsInPoints.width, height: frame.boundsInPoints.height)
        guard !Task.isCancelled else { return .failed(.cancelled) }
        guard CGPreflightScreenCaptureAccess() else {
            log.notice("Frame Screen Recording preflight denied")
            return .failed(.permissionNeeded)
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            return failure(at: "SCShareableContent", error: error)
        }
        guard !Task.isCancelled else { return .failed(.cancelled) }
        guard let display = content.displays.first(where: { $0.displayID == frame.displayID }) else {
            log.notice("Marked display missing from shareable content")
            return .failed(.unavailable)
        }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == frame.displayID }),
              screen.frame.size == size, screen.backingScaleFactor == scale else {
            log.notice("Display geometry changed before capture")
            return .failed(.unavailable)
        }

        let filter = filter(for: display, in: content)
        // Newly created filters may report incomplete metadata. Configure from the
        // display geometry and let Core validate the resulting image's aspect ratio.
        if filter.contentRect.size != size { log.notice("Filter content rectangle size differs") }
        if CGFloat(filter.pointPixelScale) != scale { log.notice("Filter pixel scale differs") }

        let configuration = SCStreamConfiguration()
        configuration.width = Int((size.width * scale).rounded())
        configuration.height = Int((size.height * scale).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best
        if let name = CGDisplayCopyColorSpace(frame.displayID).name {
            configuration.colorSpaceName = name
        }
        guard !Task.isCancelled else { return .failed(.cancelled) }
        guard CGPreflightScreenCaptureAccess() else { return .failed(.permissionNeeded) }
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            return failure(at: "captureImage", error: error)
        }
        guard !Task.isCancelled else { return .failed(.cancelled) }
        return .image(image, uptime: ProcessInfo.processInfo.systemUptime)
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
        guard !Task.isCancelled else { return .failed(.cancelled) }
        if let streamError = error as? SCStreamError {
            log.notice("\(step, privacy: .public) failed with SCStreamError \(streamError.code.rawValue, privacy: .public)")
            if streamError.code == .userDeclined { return .failed(.permissionNeeded) }
        } else {
            let error = error as NSError
            log.notice("\(step, privacy: .public) failed with \(error.domain, privacy: .public) code \(error.code, privacy: .public)")
        }
        return .failed(CGPreflightScreenCaptureAccess() ? .unavailable : .permissionNeeded)
    }
}
