import AppKit

/// Result of an interactive selection session.
enum SelectionResult {
    case area(NSRect)                    // AppKit global coords
    case window(CaptureEngine.WindowInfo)
    case cancelled
}

/// Full-screen transparent overlay per display. Drag to select an area; when
/// not dragging, the window under the cursor is highlighted and a click grabs it.
final class SelectionSession {
    private var windows: [SelectionWindow] = []
    private let completion: (SelectionResult) -> Void
    private var finished = false
    private var monitor: Any?

    init(windowsToPick: [CaptureEngine.WindowInfo], frozenScreens: [CGDirectDisplayID: CGImage],
         completion: @escaping (SelectionResult) -> Void) {
        self.completion = completion
        for screen in NSScreen.screens {
            let frozen = CaptureEngine.frozenImage(for: screen, in: frozenScreens)
            let w = SelectionWindow(screen: screen, windows: windowsToPick,
                                    frozenImage: frozen) { [weak self] r in self?.finish(r) }
            windows.append(w)
        }
        windows.forEach { $0.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.push()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.finish(.cancelled); return nil }
            return e
        }
    }

    func updateWindows(_ list: [CaptureEngine.WindowInfo]) {
        windows.forEach { $0.updateWindows(list) }
    }

    private func finish(_ r: SelectionResult) {
        guard !finished else { return }
        finished = true
        NSCursor.pop()
        if let monitor { NSEvent.removeMonitor(monitor) }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        DispatchQueue.main.async { self.completion(r) }
    }
}

final class SelectionWindow: NSPanel {
    private let selectionView: SelectionView

    init(screen: NSScreen, windows: [CaptureEngine.WindowInfo], frozenImage: CGImage?,
         onDone: @escaping (SelectionResult) -> Void) {
        selectionView = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), screen: screen,
                                      windows: windows, frozenImage: frozenImage, onDone: onDone)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = frozenImage != nil
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = selectionView
    }

    func updateWindows(_ list: [CaptureEngine.WindowInfo]) { selectionView.updateWindows(list) }

    override var canBecomeKey: Bool { true }
}

// MARK: - frozen snapshot (NSImageView — reliable menu preview)

private final class FrozenSnapshotView: NSView {
    init(cgImage: CGImage, screen: NSScreen, frame: NSRect) {
        super.init(frame: frame)
        let iv = NSImageView(frame: bounds)
        iv.image = CaptureEngine.previewImage(from: cgImage, logicalSize: screen.frame.size)
        iv.imageScaling = .scaleAxesIndependently
        iv.autoresizingMask = [.width, .height]
        addSubview(iv)
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - selection chrome (never use .clear blend — it punches through to the live desktop)

private final class SelectionChromeView: NSView {
    struct State {
        var mouse: NSPoint = .zero
        var selectionRect: NSRect?
        var highlight: NSRect?
        var frozenMode = false
        var frozenImage: CGImage?
        var hoverWindow: CaptureEngine.WindowInfo?
        var screen: NSScreen!
    }

    var chromeState = State() { didSet { needsDisplay = true } }

    private let dimColor = NSColor.black.withAlphaComponent(0.40)
    private let accent = NSColor(srgbRed: 0.16, green: 0.55, blue: 1.0, alpha: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let s = chromeState
        let screen = s.screen ?? NSScreen.main ?? NSScreen.screens[0]

        // Smooth GPU cutout using even-odd fill (no CPU cropping / allocation churn)
        dimColor.setFill()
        if let r = s.highlight {
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(rect: r))
            path.windingRule = .evenOdd
            path.fill()
        } else {
            bounds.fill()
        }

        if let r = s.highlight {
            let path = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
            accent.setStroke()
            path.lineWidth = 1.5
            path.stroke()

            let hs: CGFloat = 6
            for (x, y) in [(r.minX, r.minY), (r.maxX, r.minY), (r.minX, r.maxY), (r.maxX, r.maxY)] {
                let dot = NSBezierPath(ovalIn: NSRect(x: x - hs / 2, y: y - hs / 2, width: hs, height: hs))
                NSColor.white.setFill(); dot.fill()
                accent.setStroke(); dot.lineWidth = 1.5; dot.stroke()
            }
            drawLabel(for: r, state: s, screen: screen)
        } else {
            drawCrosshair(at: s.mouse, screen: screen)
        }

        if s.selectionRect != nil { drawMagnifier(state: s, screen: screen) }
        drawHint(frozenMode: s.frozenMode)
    }

    private func drawLabel(for r: NSRect, state: State, screen: NSScreen) {
        let scale = screen.backingScaleFactor
        var text = "\(Int(r.width * scale)) × \(Int(r.height * scale))"
        if state.selectionRect == nil, let w = state.hoverWindow {
            let name = w.title.isEmpty ? w.app : "\(w.app) — \(w.title)"
            text = "\(name)   \(text)"
        }
        drawPill(text, at: NSPoint(x: r.minX, y: r.maxY + 8), anchorBottom: true)
    }

    private func drawPill(_ text: String, at origin: NSPoint, anchorBottom: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        var box = NSRect(x: origin.x, y: origin.y, width: size.width + 18, height: size.height + 8)
        if !anchorBottom { box.origin.y -= box.height }
        if box.maxY > bounds.maxY { box.origin.y = origin.y - box.height - 16 }
        if box.maxX > bounds.maxX { box.origin.x = bounds.maxX - box.width - 4 }
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + 9, y: box.minY + 4), withAttributes: attrs)
    }

    private func drawCrosshair(at mouse: NSPoint, screen: NSScreen) {
        accent.withAlphaComponent(0.85).setStroke()
        let p = NSBezierPath()
        p.move(to: NSPoint(x: mouse.x, y: 0)); p.line(to: NSPoint(x: mouse.x, y: bounds.height))
        p.move(to: NSPoint(x: 0, y: mouse.y)); p.line(to: NSPoint(x: bounds.width, y: mouse.y))
        p.lineWidth = 1.5; p.stroke()
        let scale = screen.backingScaleFactor
        drawPill("\(Int(mouse.x * scale)), \(Int((bounds.height - mouse.y) * scale))",
                 at: NSPoint(x: mouse.x + 14, y: mouse.y - 14), anchorBottom: false)
    }

    private func drawMagnifier(state: State, screen: NSScreen) {
        let size: CGFloat = 120, zoom: CGFloat = 8
        var origin = NSPoint(x: state.mouse.x + 20, y: state.mouse.y - size - 20)
        if origin.x + size > bounds.maxX { origin.x = state.mouse.x - size - 20 }
        if origin.y < 0 { origin.y = state.mouse.y + 20 }
        let box = NSRect(origin: origin, size: NSSize(width: size, height: size))

        let g = NSPoint(x: state.mouse.x + screen.frame.minX, y: state.mouse.y + screen.frame.minY)
        let sample = NSRect(x: g.x - size / zoom / 2, y: g.y - size / zoom / 2,
                            width: size / zoom, height: size / zoom)
        let cg: CGImage?
        if let frozenImage = state.frozenImage {
            cg = CaptureEngine.crop(frozenImage, rect: sample, on: screen)
        } else {
            let src = CGRect(x: sample.minX, y: CoordSpace.primaryHeight - sample.maxY,
                             width: sample.width, height: sample.height)
            cg = CGWindowListCreateImage(src, .optionOnScreenBelowWindow, kCGNullWindowID, [.bestResolution])
        }
        guard let cg else { return }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        let clip = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        clip.addClip()
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: box)
        ctx.restoreGState()

        accent.withAlphaComponent(0.8).setStroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: box.midX, y: box.minY)); cross.line(to: NSPoint(x: box.midX, y: box.maxY))
        cross.move(to: NSPoint(x: box.minX, y: box.midY)); cross.line(to: NSPoint(x: box.maxX, y: box.midY))
        cross.lineWidth = 1; cross.stroke()
        NSColor.white.setStroke(); clip.lineWidth = 2; clip.stroke()
    }

    private func drawHint(frozenMode: Bool) {
        let text = frozenMode
            ? "拖拽框选区域（画面已冻结，含菜单）· Esc 取消"
            : "拖拽选择区域 · 点击窗口截取 · Esc 取消"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let box = NSRect(x: bounds.midX - size.width / 2 - 20, y: bounds.maxY - 72,
                         width: size.width + 40, height: size.height + 18)
        NSColor(srgbRed: 0.10, green: 0.48, blue: 0.98, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + 20, y: box.minY + 9), withAttributes: attrs)
    }
}

// MARK: - root view

final class SelectionView: NSView {
    private let screen: NSScreen
    private var windows: [CaptureEngine.WindowInfo]
    private let frozenImage: CGImage?
    private let chromeView: SelectionChromeView
    private let onDone: (SelectionResult) -> Void

    private var dragStart: NSPoint?
    private var current: NSPoint?
    private var hoverWindow: CaptureEngine.WindowInfo?
    private var mouse: NSPoint = .zero
    private var trackingArea: NSTrackingArea?

    init(frame: NSRect, screen: NSScreen, windows: [CaptureEngine.WindowInfo], frozenImage: CGImage?,
         onDone: @escaping (SelectionResult) -> Void) {
        self.screen = screen
        self.windows = windows
        self.frozenImage = frozenImage
        self.onDone = onDone
        chromeView = SelectionChromeView(frame: frame)
        super.init(frame: frame)

        if let frozenImage {
            let snap = FrozenSnapshotView(cgImage: frozenImage, screen: screen, frame: bounds)
            snap.autoresizingMask = [.width, .height]
            addSubview(snap)
        }

        chromeView.autoresizingMask = [.width, .height]
        chromeView.chromeState.screen = screen
        chromeView.chromeState.frozenMode = frozenImage != nil
        chromeView.chromeState.frozenImage = frozenImage
        addSubview(chromeView)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        syncChrome()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return self
    }

    func updateWindows(_ list: [CaptureEngine.WindowInfo]) {
        windows = list
        updateHover(mouse)
        syncChrome()
    }

    override func updateTrackingAreas() {
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(t); trackingArea = t
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func toGlobal(_ p: NSPoint) -> NSPoint {
        NSPoint(x: p.x + screen.frame.minX, y: p.y + screen.frame.minY)
    }

    private func toLocal(_ r: NSRect) -> NSRect {
        NSRect(x: r.minX - screen.frame.minX, y: r.minY - screen.frame.minY, width: r.width, height: r.height)
    }

    private var selectionRect: NSRect? {
        guard let s = dragStart, let c = current else { return nil }
        return NSRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y)).integral
    }

    private func updateHover(_ p: NSPoint) {
        let g = toGlobal(p)
        let q = CGPoint(x: g.x, y: CoordSpace.primaryHeight - g.y)
        hoverWindow = windows.first { $0.frame.contains(q) }
    }

    private func syncChrome() {
        let highlight: NSRect? = {
            return selectionRect ?? hoverWindow.map { toLocal(CoordSpace.toAppKit($0.frame)) }
        }()
        chromeView.chromeState = SelectionChromeView.State(
            mouse: mouse,
            selectionRect: selectionRect,
            highlight: highlight,
            frozenMode: frozenImage != nil,
            frozenImage: frozenImage,
            hoverWindow: hoverWindow,
            screen: screen
        )
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        updateHover(mouse)
        syncChrome()
    }

    override func mouseDown(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        updateHover(mouse)
        dragStart = mouse; current = mouse
        syncChrome()
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        mouse = current!
        syncChrome()
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        let end = convert(event.locationInWindow, from: nil)
        current = end
        mouse = end
        updateHover(end)
        defer { dragStart = nil; current = nil; syncChrome() }
        if let r = selectionRect, r.width >= 4, r.height >= 4 {
            onDone(.area(r.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)))
        } else if let w = hoverWindow {
            onDone(.window(w))
        } else {
            onDone(.area(screen.frame))
        }
    }

    override func rightMouseDown(with event: NSEvent) { onDone(.cancelled) }
}
