import AppKit
import ScreenCaptureKit

/// Wraps ScreenCaptureKit screenshot APIs. Needs Screen Recording permission.
enum CaptureEngine {
    struct WindowInfo {
        let windowID: CGWindowID?
        let window: SCWindow?
        let frame: CGRect   // in global (top-left origin) coordinates
        let title: String
        let app: String
    }

    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() { CGRequestScreenCaptureAccess() }

    /// Synchronous capture of what's on screen right now (includes open menus / popovers).
    static func freezeAllScreens() -> [CGDirectDisplayID: CGImage] {
        var out: [CGDirectDisplayID: CGImage] = [:]
        for screen in NSScreen.screens {
            guard let id = displayID(for: screen) else { continue }
            let q = CoordSpace.toQuartz(screen.frame)
            if let img = CGWindowListCreateImage(q, .optionAll, kCGNullWindowID, [.bestResolution]) {
                out[id] = img
            }
        }
        return out
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func frozenImage(for screen: NSScreen, in frames: [CGDirectDisplayID: CGImage]) -> CGImage? {
        guard let id = displayID(for: screen) else { return nil }
        return frames[id]
    }

    /// NSImage for on-screen preview (CGImage from CGWindowListCreateImage doesn't always render in CALayer).
    static func previewImage(from cgImage: CGImage, logicalSize: NSSize) -> NSImage {
        let img = NSImage(size: logicalSize)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = logicalSize
        img.addRepresentation(rep)
        return img
    }

    /// Crop a frozen display capture (AppKit-global rect) to pixel coordinates.
    static func crop(_ image: CGImage, rect: NSRect, on screen: NSScreen) -> CGImage? {
        let local = rect.intersection(screen.frame)
        guard local.width > 0, local.height > 0 else { return nil }
        let scale = CGFloat(image.width) / screen.frame.width
        let src = CGRect(x: (local.minX - screen.frame.minX) * scale,
                         y: (screen.frame.maxY - local.maxY) * scale,
                         width: local.width * scale,
                         height: local.height * scale)
        return image.cropping(to: src)
    }

    static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    static func display(for screen: NSScreen, in content: SCShareableContent) -> SCDisplay? {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }
        return content.displays.first { $0.displayID == id }
    }

    private static func excludedWindows(_ content: SCShareableContent) -> [SCWindow] {
        let me = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        return content.windows.filter { $0.owningApplication?.bundleIdentifier == me || $0.owningApplication?.applicationName == "BaoSnap" }
    }

    /// Capture a whole display at native pixel scale.
    static func capture(display: SCDisplay, content: SCShareableContent, scale: CGFloat) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows(content))
        let cfg = SCStreamConfiguration()
        cfg.width = Int(CGFloat(display.width) * scale)
        cfg.height = Int(CGFloat(display.height) * scale)
        cfg.showsCursor = false
        cfg.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    /// Capture a region (display-local points, top-left origin) of a display.
    static func capture(rect: CGRect, display: SCDisplay, content: SCShareableContent, scale: CGFloat) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows(content))
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = rect
        cfg.width = Int(rect.width * scale)
        cfg.height = Int(rect.height * scale)
        cfg.showsCursor = false
        cfg.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    /// Capture a single window (with its shadow trimmed).
    static func capture(window: SCWindow, scale: CGFloat) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cfg = SCStreamConfiguration()
        cfg.width = Int(window.frame.width * scale)
        cfg.height = Int(window.frame.height * scale)
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        cfg.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    /// Synchronous candidate window retrieval via CGWindowList (<1ms, no async delay).
    static func quickPickableWindows() -> [WindowInfo] {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let me = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        var result: [WindowInfo] = []
        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            guard frame.width > 40, frame.height > 40 else { continue }
            let app = info[kCGWindowOwnerName as String] as? String ?? ""
            if app == "BaoSnap" || app == me { continue }
            let title = info[kCGWindowName as String] as? String ?? ""
            let id = info[kCGWindowNumber as String] as? CGWindowID
            result.append(WindowInfo(windowID: id, window: nil, frame: frame, title: title, app: app))
        }
        return result
    }

    /// Candidate windows for window-mode picking, front-most first.
    static func pickableWindows(_ content: SCShareableContent) -> [WindowInfo] {
        let excluded = Set(excludedWindows(content).map(\.windowID))
        return content.windows
            .filter { w in
                !excluded.contains(w.windowID)
                    && w.windowLayer == 0
                    && w.frame.width > 40 && w.frame.height > 40
                    && w.isOnScreen
                    && w.owningApplication != nil
            }
            .map { WindowInfo(windowID: $0.windowID, window: $0, frame: $0.frame, title: $0.title ?? "",
                              app: $0.owningApplication?.applicationName ?? "") }
    }
}

extension CGImage {
    var nsImage: NSImage { NSImage(cgImage: self, size: NSSize(width: width, height: height)) }
}

/// Convert AppKit (bottom-left origin) screen rects to Quartz global (top-left origin) and back.
enum CoordSpace {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func toQuartz(_ r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func toAppKit(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}
