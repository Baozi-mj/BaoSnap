import AppKit

/// A floating, always-on-top image window ("贴图"). Drag to move, scroll to zoom,
/// double-click to hide, right-click for actions. Esc / ⌘W closes when focused.
final class PinWindow: NSPanel {
    static var all: [PinWindow] = []
    static var hidden = false

    let image: NSImage
    private let imageView: PinImageView
    private var scale: CGFloat = 1
    private let baseSize: NSSize
    private var opacity: CGFloat = 1

    init(image: NSImage, at screenPoint: NSPoint? = nil, sourceRect: NSRect? = nil, backingScale: CGFloat? = nil) {
        self.image = image
        let px = image.pixelSize
        let screen = Self.screen(for: sourceRect, point: screenPoint)
        let bsf = backingScale ?? screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        // display at 1:1 logical points of the source (pixels / backing scale)
        baseSize = NSSize(width: px.width / bsf, height: px.height / bsf)
        let vf = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let maxW = vf.width * 0.8
        let maxH = vf.height * 0.8
        let fit = min(1, maxW / baseSize.width, maxH / baseSize.height)
        scale = fit
        let size = NSSize(width: baseSize.width * fit, height: baseSize.height * fit)

        var origin: NSPoint
        if let r = sourceRect {
            origin = r.origin
        } else if let p = screenPoint {
            origin = NSPoint(x: p.x - size.width / 2, y: p.y - size.height / 2)
        } else {
            let vf = NSScreen.main?.visibleFrame ?? .zero
            origin = NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2)
        }
        imageView = PinImageView(image: image)

        super.init(contentRect: NSRect(origin: origin, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = Settings.shared.pinShadow
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        minSize = NSSize(width: 40, height: 40)

        imageView.pin = self
        imageView.frame = NSRect(origin: .zero, size: size)
        imageView.autoresizingMask = [.width, .height]
        contentView = imageView

        PinWindow.all.append(self)
        if PinWindow.hidden { PinWindow.hidden = false; PinWindow.all.forEach { $0.orderFront(nil) } }
        alphaValue = 0
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            animator().alphaValue = 1
        }
    }

    override var canBecomeKey: Bool { true }

    /// Prefer the screen where the capture came from — not `NSScreen.main`, which may be a different display in multi-monitor setups.
    private static func screen(for sourceRect: NSRect?, point: NSPoint?) -> NSScreen? {
        if let r = sourceRect, let s = NSScreen.screens.first(where: { $0.frame.intersects(r) }) { return s }
        if let p = point, let s = NSScreen.screens.first(where: { $0.frame.contains(p) }) { return s }
        return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    // MARK: actions
    func zoom(by factor: CGFloat, anchor: NSPoint? = nil) {
        let newScale = max(0.1, min(8, scale * factor))
        setScale(newScale, anchor: anchor)
    }

    func setScale(_ s: CGFloat, anchor: NSPoint? = nil) {
        let old = frame
        let size = NSSize(width: baseSize.width * s, height: baseSize.height * s)
        var origin = old.origin
        if let a = anchor { // keep the point under cursor fixed
            let rx = (a.x - old.minX) / old.width, ry = (a.y - old.minY) / old.height
            origin = NSPoint(x: a.x - size.width * rx, y: a.y - size.height * ry)
        } else {
            origin = NSPoint(x: old.midX - size.width / 2, y: old.midY - size.height / 2)
        }
        scale = s
        setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
        imageView.showBadge(String(format: "%d%%", Int(s * 100)))
    }

    func setOpacity(_ v: CGFloat) {
        opacity = max(0.15, min(1, v))
        alphaValue = opacity
        imageView.showBadge(String(format: "透明度 %d%%", Int(opacity * 100)))
    }

    func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        imageView.showBadge("已复制")
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Baozi_\(DateFormatter.fileStamp.string(from: Date())).png"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url, let data = self?.image.pngData else { return }
            try? data.write(to: url)
        }
    }

    func closeAnimated() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [self] in
            PinWindow.all.removeAll { $0 === self }
            close()
        })
    }

    static func toggleAllHidden() {
        hidden.toggle()
        all.forEach { hidden ? $0.orderOut(nil) : $0.orderFront(nil) }
    }

    static func closeAll() { all.forEach { $0.closeAnimated() } }

    /// Bring this pin to the front with a visible pulse so it's easy to spot on screen.
    func flashLocate() {
        if PinWindow.hidden {
            PinWindow.hidden = false
            PinWindow.all.forEach { $0.orderFront(nil) }
        }
        orderFront(nil)
        makeKey()
        NSApp.activate(ignoringOtherApps: true)

        let savedLevel = level
        level = .screenSaver
        imageView.flashLocate()
        imageView.showBadge("在这里")

        let original = frame
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(original.insetBy(dx: -8, dy: -8), display: true)
        } completionHandler: { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrame(original, display: true)
            } completionHandler: { [weak self] in
                self?.level = savedLevel
            }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 13, event.modifierFlags.contains(.command) {
            closeAnimated()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: closeAnimated()                                     // esc
        case 13 where event.modifierFlags.contains(.command): closeAnimated() // ⌘W
        case 8 where event.modifierFlags.contains(.command): copyToClipboard() // ⌘C
        case 1 where event.modifierFlags.contains(.command): saveAs()         // ⌘S
        case 24, 69: zoom(by: 1.1)                                    // = / +
        case 27, 78: zoom(by: 1 / 1.1)                                // -
        case 29: setScale(1)                                          // 0
        default: super.keyDown(with: event)
        }
    }
}

final class PinImageView: NSView {
    weak var pin: PinWindow?
    private let image: NSImage
    private let badge = NSTextField(labelWithString: "")
    private var badgeTimer: Timer?
    private var hovering = false
    private var locateTicks = 0
    private var locateTimer: Timer?
    private var trackingArea: NSTrackingArea?

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        badge.layer?.cornerRadius = 6
        badge.alphaValue = 0
        addSubview(badge)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t); trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        if hovering {
            drawBorder(inset: 1, width: 2, alpha: 0.9)
        }
        if locateTicks > 0 {
            let pulse = locateTicks % 2 == 1
            drawBorder(inset: pulse ? -3 : -1, width: pulse ? 5 : 3, alpha: pulse ? 1 : 0.45)
            if pulse {
                let glow = NSBezierPath(roundedRect: bounds.insetBy(dx: -6, dy: -6), xRadius: 10, yRadius: 10)
                NSColor(srgbRed: 0.16, green: 0.55, blue: 1.0, alpha: 0.25).setStroke()
                glow.lineWidth = 8
                glow.stroke()
            }
        }
    }

    private func drawBorder(inset: CGFloat, width: CGFloat, alpha: CGFloat) {
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: 8, yRadius: 8)
        NSColor(srgbRed: 0.16, green: 0.55, blue: 1.0, alpha: alpha).setStroke()
        border.lineWidth = width
        border.stroke()
    }

    func flashLocate() {
        locateTimer?.invalidate()
        locateTicks = 8
        layer?.masksToBounds = false
        needsDisplay = true
        locateTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.locateTicks -= 1
            self.needsDisplay = true
            if self.locateTicks <= 0 {
                t.invalidate()
                self.locateTimer = nil
                self.layer?.masksToBounds = true
            }
        }
    }

    func showBadge(_ text: String) {
        badge.stringValue = "  \(text)  "
        badge.sizeToFit()
        badge.frame.size.height += 6
        badge.frame.origin = NSPoint(x: bounds.midX - badge.frame.width / 2, y: 10)
        badgeTimer?.invalidate()
        badge.animator().alphaValue = 1
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in
            self?.badge.animator().alphaValue = 0
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let pin else { return }
        let anchor = NSEvent.mouseLocation
        if event.modifierFlags.contains(.option) {
            pin.setOpacity(pin.alphaValue + (event.scrollingDeltaY > 0 ? 0.05 : -0.05))
        } else {
            let delta = event.scrollingDeltaY
            guard abs(delta) > 0.1 else { return }
            pin.zoom(by: delta > 0 ? 1.06 : 1 / 1.06, anchor: anchor)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { pin?.closeAnimated(); return }
        pin?.makeKey()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let pin else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "复制图片  ⌘C", action: #selector(copyImg), keyEquivalent: "").target = self
        menu.addItem(withTitle: "另存为…  ⌘S", action: #selector(save), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "实际大小  0", action: #selector(resetZoom), keyEquivalent: "").target = self
        let op = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in [100, 80, 60, 40, 20] {
            let it = NSMenuItem(title: "\(v)%", action: #selector(setOp(_:)), keyEquivalent: "")
            it.tag = v; it.target = self
            it.state = Int(pin.alphaValue * 100) == v ? .on : .off
            sub.addItem(it)
        }
        op.submenu = sub
        menu.addItem(op)
        menu.addItem(.separator())
        let close = NSMenuItem(title: "关闭贴图", action: #selector(closePin), keyEquivalent: "w")
        close.keyEquivalentModifierMask = .command
        close.target = self
        menu.addItem(close)
        menu.addItem(withTitle: "关闭所有贴图", action: #selector(closeAll), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func copyImg() { pin?.copyToClipboard() }
    @objc private func save() { pin?.saveAs() }
    @objc private func resetZoom() { pin?.setScale(1) }
    @objc private func setOp(_ s: NSMenuItem) { pin?.setOpacity(CGFloat(s.tag) / 100) }
    @objc private func closePin() { pin?.closeAnimated() }
    @objc private func closeAll() { PinWindow.closeAll() }
}

extension DateFormatter {
    static let fileStamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"; return f
    }()
}
