import AppKit
import SwiftUI

/// Small transient HUD shown after a capture.
final class Toast {
    private static var current: NSPanel?

    static func show(_ text: String, image: NSImage? = nil, systemImage: String = "checkmark.circle.fill") {
        guard Settings.shared.showToast else { return }
        current?.orderOut(nil)

        let view = ToastView(text: text, thumb: image, symbol: systemImage)
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: host.frame.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vf.midX - host.frame.width / 2, y: vf.maxY - host.frame.height - 24))
        panel.alphaValue = 0
        panel.orderFront(nil)
        current = panel
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            guard current === panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil); if current === panel { current = nil } })
        }
    }
}

private struct ToastView: View {
    let text: String
    let thumb: NSImage?
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            if let thumb {
                Image(nsImage: thumb)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.25)))
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.green)
            }
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.black.opacity(0.72), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        .padding(12)
    }
}
