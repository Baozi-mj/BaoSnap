import AppKit
import XCTest
@testable import BaoSnap

@MainActor
final class SelectionOverlayTests: XCTestCase {
    func testFrozenBackgroundPassesFirstClickToSelectionView() throws {
        let window = try makeWindow(windows: []) { _ in }
        let view = try XCTUnwrap(window.contentView as? SelectionView)
        let target = view.hitTest(NSPoint(x: 80, y: 80))

        XCTAssertTrue(target === view)
        XCTAssertEqual(target?.acceptsFirstMouse(for: nil), true)
    }

    func testClickSelectsWindowWithoutPriorMouseMovement() throws {
        let candidate = try candidate(id: 1, localFrame: NSRect(x: 40, y: 40, width: 200, height: 200))
        for frozen in [true, false] {
            var result: SelectionResult?
            let window = try makeWindow(windows: [candidate], frozen: frozen) { result = $0 }
            let view = try XCTUnwrap(window.contentView as? SelectionView)

            view.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 80, y: 80), in: window))
            view.mouseUp(with: try event(.leftMouseUp, at: NSPoint(x: 80, y: 80), in: window))

            guard case .window(let picked) = result else {
                XCTFail("The first click should select the window, frozen: \(frozen)")
                continue
            }
            XCTAssertEqual(picked.windowID, candidate.windowID)
        }
    }

    func testClickUsesCurrentPositionInsteadOfPreviousHover() throws {
        let first = try candidate(id: 1, localFrame: NSRect(x: 40, y: 40, width: 160, height: 160))
        let second = try candidate(id: 2, localFrame: NSRect(x: 260, y: 40, width: 160, height: 160))
        var result: SelectionResult?
        let window = try makeWindow(windows: [first, second]) { result = $0 }
        let view = try XCTUnwrap(window.contentView as? SelectionView)

        view.mouseMoved(with: try event(.mouseMoved, at: NSPoint(x: 80, y: 80), in: window))
        view.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 300, y: 80), in: window))
        view.mouseUp(with: try event(.leftMouseUp, at: NSPoint(x: 300, y: 80), in: window))

        guard case .window(let picked) = result else { return XCTFail("Expected a window selection") }
        XCTAssertEqual(picked.windowID, second.windowID)
    }

    func testClickUsesUpdatedCandidatesWithoutAnotherMouseMove() throws {
        let first = try candidate(id: 1, localFrame: NSRect(x: 40, y: 40, width: 200, height: 200))
        let second = try candidate(id: 2, localFrame: NSRect(x: 40, y: 40, width: 200, height: 200))
        var result: SelectionResult?
        let window = try makeWindow(windows: [first]) { result = $0 }
        let view = try XCTUnwrap(window.contentView as? SelectionView)

        view.mouseMoved(with: try event(.mouseMoved, at: NSPoint(x: 80, y: 80), in: window))
        window.updateWindows([second])
        view.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 80, y: 80), in: window))
        view.mouseUp(with: try event(.leftMouseUp, at: NSPoint(x: 80, y: 80), in: window))

        guard case .window(let picked) = result else { return XCTFail("Expected a window selection") }
        XCTAssertEqual(picked.windowID, second.windowID)
    }

    func testDragIncludesFinalMouseUpPosition() throws {
        var result: SelectionResult?
        let window = try makeWindow(windows: []) { result = $0 }
        let view = try XCTUnwrap(window.contentView as? SelectionView)
        let screen = try XCTUnwrap(NSScreen.screens.first)

        view.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 40, y: 50), in: window))
        view.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: 80, y: 90), in: window))
        view.mouseUp(with: try event(.leftMouseUp, at: NSPoint(x: 180, y: 150), in: window))

        guard case .area(let rect) = result else { return XCTFail("Expected an area selection") }
        XCTAssertEqual(rect, NSRect(x: screen.frame.minX + 40, y: screen.frame.minY + 50,
                                    width: 140, height: 100))
    }

    func testMouseUpWithoutMouseDownDoesNotCapture() throws {
        var result: SelectionResult?
        let window = try makeWindow(windows: []) { result = $0 }
        let view = try XCTUnwrap(window.contentView as? SelectionView)

        view.mouseUp(with: try event(.leftMouseUp, at: NSPoint(x: 80, y: 80), in: window))

        XCTAssertNil(result)
    }

    func testRightClickCancels() throws {
        var result: SelectionResult?
        let window = try makeWindow(windows: []) { result = $0 }
        let view = try XCTUnwrap(window.contentView as? SelectionView)

        view.rightMouseDown(with: try event(.rightMouseDown, at: NSPoint(x: 80, y: 80), in: window))

        guard case .cancelled = result else { return XCTFail("Expected cancellation") }
    }

    private func candidate(id: CGWindowID, localFrame: NSRect) throws -> CaptureEngine.WindowInfo {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let global = localFrame.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        return CaptureEngine.WindowInfo(windowID: id, window: nil, frame: CoordSpace.toQuartz(global),
                                        title: "Test", app: "Test App")
    }

    private func makeWindow(windows: [CaptureEngine.WindowInfo], frozen: Bool = true,
                            onDone: @escaping (SelectionResult) -> Void) throws -> SelectionWindow {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let image = try XCTUnwrap(context.makeImage())
        let window = SelectionWindow(screen: screen, windows: windows, frozenImage: frozen ? image : nil,
                                     onDone: onDone)
        window.isReleasedWhenClosed = false
        return window
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                         timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                         eventNumber: 0, clickCount: 1, pressure: 1))
    }
}