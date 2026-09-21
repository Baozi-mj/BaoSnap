import AppKit
import SwiftUI
import AudioToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var mainWindow: NSWindow?
    private var selection: SelectionSession?
    private var frozenScreens: [CGDirectDisplayID: CGImage]?
    private var menuBarIcon: NSImage?
    private var menuBarAppearanceObservers: [NSObjectProtocol] = []
    /// Set only when quitting via the menu-bar status item; dock / ⌘Q hide to tray instead.
    private var shouldFullyTerminate = false

    // MARK: lifecycle
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupMainMenu()
        HotkeyManager.shared.handler = { [weak self] action in
            self?.perform(action)
        }
        HotkeyManager.shared.registerAll()
        showMainWindow()
        if !CaptureEngine.hasPermission() { CaptureEngine.requestPermission() }
        devSnapshotIfRequested()
    }

    /// Dev aid: `BAOZI_SNAPSHOT=/tmp/x.png` renders the main window to disk after launch.
    private func devSnapshotIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["BAOZI_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let view = self?.mainWindow?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            if ProcessInfo.processInfo.environment["BAOZI_SNAPSHOT_QUIT"] != nil {
                self?.shouldFullyTerminate = true
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock quit / app-menu ⌘Q → hide from dock, keep menu-bar agent alive; status-item quit → exit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard shouldFullyTerminate else {
            hideFromDock()
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(); return true
    }

    // MARK: actions
    func perform(_ action: HotkeyManager.Action) {
        switch action {
        case .captureArea: startSelection()
        case .captureFullScreen: captureFullScreen()
        case .pinFromClipboard: pinFromClipboard()
        case .toggleHistory: toggleMainWindow()
        case .hideAllPins: PinWindow.toggleAllHidden()
        }
    }

    @objc func captureAreaAction() { startSelection() }
    @objc func captureFullScreenAction() { captureFullScreen() }
    @objc func pinFromClipboardAction() { pinFromClipboard() }
    @objc func showHistoryAction() { showMainWindow() }
    @objc func hidePinsAction() { PinWindow.toggleAllHidden() }
    @objc func closePinsAction() { PinWindow.closeAll() }
    @objc func quitAction() {
        shouldFullyTerminate = true
        NSApp.terminate(nil)
    }

    /// Left click → main window; right click → status menu.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
        } else {
            showMainWindow()
        }
    }

    // MARK: capture flows
    private func ensurePermission() -> Bool {
        if CaptureEngine.hasPermission() { return true }
        CaptureEngine.requestPermission()
        let alert = NSAlert()
        alert.messageText = "需要「屏幕录制」权限"
        alert.informativeText = "请在 系统设置 → 隐私与安全性 → 屏幕录制 中允许 BaoSnap，然后重新打开应用。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    func startSelection() {
        guard selection == nil, ensurePermission() else { return }
        if frozenScreens == nil {
            frozenScreens = HotkeyManager.shared.consumePendingFrozen() ?? CaptureEngine.freezeAllScreens()
        }
        let frozen = frozenScreens ?? [:]
        let initialWindows = CaptureEngine.quickPickableWindows()
        selection = SelectionSession(windowsToPick: initialWindows, frozenScreens: frozen) { [weak self] result in
            guard let self else { return }
            self.selection = nil
            let snap = self.frozenScreens
            self.frozenScreens = nil
            switch result {
            case .cancelled: break
            case .area(let rect): self.captureArea(rect, frozen: snap)
            case .window(let info): self.captureWindow(info, frozen: snap)
            }
        }
        Task { @MainActor in
            let content = try? await CaptureEngine.shareableContent()
            let windows = content.map(CaptureEngine.pickableWindows) ?? []
            if !windows.isEmpty {
                selection?.updateWindows(windows)
            }
        }
    }

    private func captureArea(_ rect: NSRect, frozen: [CGDirectDisplayID: CGImage]? = nil) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main else { return }
        let local = rect.intersection(screen.frame)
        let scale = screen.backingScaleFactor
        if let frozenImg = CaptureEngine.frozenImage(for: screen, in: frozen ?? [:]),
           let cropped = CaptureEngine.crop(frozenImg, rect: rect, on: screen) {
            finish(cropped.nsImage, kind: .area, sourceRect: local, backingScale: scale)
            return
        }
        Task { @MainActor in
            do {
                let content = try await CaptureEngine.shareableContent()
                guard let display = CaptureEngine.display(for: screen, in: content) else { return }
                let src = CGRect(x: local.minX - screen.frame.minX,
                                 y: screen.frame.maxY - local.maxY,
                                 width: local.width, height: local.height)
                let cg = try await CaptureEngine.capture(rect: src, display: display, content: content,
                                                         scale: screen.backingScaleFactor)
                finish(cg.nsImage, kind: .area, sourceRect: local, backingScale: screen.backingScaleFactor)
            } catch { NSLog("area capture failed: \(error)") }
        }
    }

    private func captureWindow(_ info: CaptureEngine.WindowInfo, frozen: [CGDirectDisplayID: CGImage]? = nil) {
        let rect = CoordSpace.toAppKit(info.frame)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main else { return }
        let scale = screen.backingScaleFactor
        if let frozenImg = CaptureEngine.frozenImage(for: screen, in: frozen ?? [:]),
           let cropped = CaptureEngine.crop(frozenImg, rect: rect, on: screen) {
            finish(cropped.nsImage, kind: .window, sourceRect: rect.intersection(screen.frame), backingScale: scale)
            return
        }
        if let scWindow = info.window {
            Task { @MainActor in
                do {
                    let bsf = screen.backingScaleFactor
                    let cg = try await CaptureEngine.capture(window: scWindow, scale: bsf)
                    finish(cg.nsImage, kind: .window, sourceRect: rect, backingScale: bsf)
                } catch { NSLog("window capture failed: \(error)") }
            }
        } else {
            captureArea(rect, frozen: frozen)
        }
    }

    private func captureFullScreen() {
        guard ensurePermission() else { return }
        Task { @MainActor in
            do {
                let content = try await CaptureEngine.shareableContent()
                let mouse = NSEvent.mouseLocation
                let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
                guard let display = CaptureEngine.display(for: screen, in: content) else { return }
                let cg = try await CaptureEngine.capture(display: display, content: content, scale: screen.backingScaleFactor)
                finish(cg.nsImage, kind: .fullscreen, sourceRect: screen.frame, backingScale: screen.backingScaleFactor)
            } catch { NSLog("fullscreen capture failed: \(error)") }
        }
    }

    private func finish(_ image: NSImage, kind: HistoryItem.Kind, sourceRect: NSRect?, backingScale: CGFloat) {
        let settings = Settings.shared
        let item = HistoryStore.shared.add(image: image, kind: kind, scale: backingScale)
        if settings.copyToClipboard {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
        }
        if settings.playSound { AudioServicesPlaySystemSound(1108) } // camera shutter
        _ = PinWindow(image: image, sourceRect: sourceRect, backingScale: backingScale)
        let px = image.pixelSize
        let msg = settings.copyToClipboard ? "已复制到剪贴板 · \(Int(px.width))×\(Int(px.height))" : "已保存 · \(Int(px.width))×\(Int(px.height))"
        Toast.show(msg, image: item.flatMap { HistoryStore.shared.thumbnail(for: $0, maxSide: 88) })
    }

    func pinFromClipboard() {
        let pb = NSPasteboard.general
        guard let image = (pb.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.first else {
            Toast.show("剪贴板里没有图片", systemImage: "exclamationmark.triangle.fill")
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let bsf = screen?.backingScaleFactor ?? 2
        HistoryStore.shared.add(image: image, kind: .clipboard, scale: bsf)
        _ = PinWindow(image: image, at: mouse, backingScale: bsf)
    }

    func pin(_ item: HistoryItem) {
        guard let img = HistoryStore.shared.image(for: item) else { return }
        _ = PinWindow(image: img, backingScale: CGFloat(item.scale))
    }

    // MARK: windows
    private func hideFromDock() {
        mainWindow?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if mainWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "BaoSnap"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.toolbarStyle = .unified
            w.minSize = NSSize(width: 720, height: 460)
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("BaoziMain")
            w.delegate = self
            w.contentView = NSHostingView(rootView: MainView().environmentObject(HistoryStore.shared).environmentObject(Settings.shared))
            mainWindow = w
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggleMainWindow() {
        if let w = mainWindow, w.isVisible, w.isKeyWindow { w.orderOut(nil) } else { showMainWindow() }
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Black MenuIcon at @1x/@2x/@3x, rendered as a template so macOS tints it for the
    /// actual menu-bar background (light wallpaper → black, dark wallpaper → white).
    private static func loadMenuBarIcon() -> NSImage? {
        guard let dir = Bundle.main.resourceURL else { return nil }
        let img = NSImage(size: NSSize(width: 18, height: 18))
        var added = false
        for (name, _) in [("MenuIcon.png", 1), ("MenuIcon@2x.png", 2), ("MenuIcon@3x.png", 3)] {
            let url = dir.appendingPathComponent(name)
            guard let image = NSImage(contentsOf: url),
                  let rep = image.representations.first as? NSBitmapImageRep else { continue }
            rep.size = NSSize(width: 18, height: 18)
            img.addRepresentation(rep)
            added = true
        }
        guard added else { return nil }
        img.isTemplate = true
        return img
    }

    private func updateStatusItemIcon() {
        guard let btn = statusItem.button else { return }
        if let img = menuBarIcon {
            btn.image = img
            btn.contentTintColor = nil
        } else {
            btn.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "BaoSnap")
            btn.image?.isTemplate = true
        }
    }

    /// Wallpaper / display changes can alter the menu-bar tint without toggling dark mode.
    private func observeMenuBarAppearanceChanges() {
        let refresh = { [weak self] in self?.updateStatusItemIcon() }
        let dnc = DistributedNotificationCenter.default()
        let nc = NotificationCenter.default
        let wnc = NSWorkspace.shared.notificationCenter
        menuBarAppearanceObservers = [
            dnc.addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                            object: nil, queue: .main, using: { _ in refresh() }),
            nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                           object: nil, queue: .main, using: { _ in refresh() }),
            wnc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                            object: nil, queue: .main, using: { _ in refresh() }),
        ]
    }

    // MARK: menus
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menuBarIcon = Self.loadMenuBarIcon()
        if let btn = statusItem.button {
            updateStatusItemIcon()
            btn.action = #selector(statusItemClicked(_:))
            btn.target = self
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        observeMenuBarAppearanceChanges()
        rebuildStatusMenu()
        HotkeyManager.shared.onChange = { [weak self] in self?.rebuildStatusMenu() }
    }

    private func rebuildStatusMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ sel: Selector, _ action: HotkeyManager.Action? = nil, _ key: String = "", _ mods: NSEvent.ModifierFlags = []) {
            var label = title
            if let action, let sc = HotkeyManager.shared.shortcut(for: action)?.display {
                label += "\t\(sc)"
            }
            let it = NSMenuItem(title: label, action: sel, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            it.target = self
            menu.addItem(it)
        }
        add("全屏截图", #selector(captureFullScreenAction), .captureFullScreen)
        add("截图（区域 / 窗口）", #selector(captureAreaAction), .captureArea)
        menu.addItem(.separator())
        add("贴图剪贴板图片", #selector(pinFromClipboardAction), .pinFromClipboard)
        add("隐藏 / 显示所有贴图", #selector(hidePinsAction), .hideAllPins)
        add("关闭所有贴图", #selector(closePinsAction))
        menu.addItem(.separator())
        add("截图历史…", #selector(showHistoryAction), .toggleHistory)
        menu.addItem(.separator())
        add("退出 BaoSnap", #selector(quitAction), nil, "q", .command)
        statusMenu = menu
    }

    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 BaoSnap", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 BaoSnap", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 BaoSnap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "窗口")
        win.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        NSApp.mainMenu = main
    }
}
