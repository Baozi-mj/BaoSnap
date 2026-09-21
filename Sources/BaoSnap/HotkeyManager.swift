import AppKit
import Carbon

/// A keyboard shortcut: Carbon virtual key code + Carbon modifier mask.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Shortcut.keyName(keyCode)
    }

    /// Menu key equivalent (character + NSEvent modifiers); nil for keys with no character.
    var menuEquivalent: (String, NSEvent.ModifierFlags)? {
        guard let ch = Shortcut.menuChar(keyCode) else { return nil }
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        return (ch, f)
    }

    static func from(event e: NSEvent) -> Shortcut? {
        var m: UInt32 = 0
        if e.modifierFlags.contains(.control) { m |= UInt32(controlKey) }
        if e.modifierFlags.contains(.option) { m |= UInt32(optionKey) }
        if e.modifierFlags.contains(.shift) { m |= UInt32(shiftKey) }
        if e.modifierFlags.contains(.command) { m |= UInt32(cmdKey) }
        let code = UInt32(e.keyCode)
        let isFKey = fKeys.contains(Int(e.keyCode))
        // require at least one of ⌘/⌃/⌥ unless it's an F-key
        guard isFKey || m & UInt32(cmdKey | controlKey | optionKey) != 0 else { return nil }
        return Shortcut(keyCode: code, modifiers: m)
    }

    private static let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]

    private static let names: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    static func keyName(_ code: UInt32) -> String { names[Int(code)] ?? "Key\(code)" }

    private static func menuChar(_ code: UInt32) -> String? {
        let n = names[Int(code)] ?? ""
        if n.count == 1 { return n.lowercased() }
        switch Int(code) {
        case kVK_Space: return " "
        case kVK_Return: return "\r"
        case kVK_Delete: return "\u{8}"
        case kVK_LeftArrow: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case kVK_RightArrow: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case kVK_UpArrow: return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case kVK_DownArrow: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        default:
            if let i = fKeys.firstIndex(of: Int(code)) { return String(UnicodeScalar(NSF1FunctionKey + i)!) }
            return nil
        }
    }
}

/// Global hotkeys via Carbon RegisterEventHotKey — works without Accessibility permission.
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    enum Action: UInt32, CaseIterable {
        case captureFullScreen = 1
        case captureArea = 2
        case pinFromClipboard = 3
        case toggleHistory = 4
        case hideAllPins = 5

        var title: String {
            switch self {
            case .captureFullScreen: return "全屏截图"
            case .captureArea: return "截图（区域 / 窗口）"
            case .pinFromClipboard: return "贴图剪贴板图片"
            case .toggleHistory: return "打开 / 隐藏历史"
            case .hideAllPins: return "隐藏 / 显示所有贴图"
            }
        }

        var defaultShortcut: Shortcut {
            let cs = UInt32(cmdKey | shiftKey)
            switch self {
            case .captureFullScreen: return Shortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: cs)
            case .captureArea: return Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: cs)
            case .pinFromClipboard: return Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: cs)
            case .toggleHistory: return Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: cs)
            case .hideAllPins: return Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: cs)
            }
        }

        var displayShortcut: String { HotkeyManager.shared.shortcut(for: self)?.display ?? "未设置" }
        fileprivate var key: String { "hotkey.\(rawValue)" }
    }

    var handler: ((Action) -> Void)?
    /// Screen snapshot taken at hotkey press, before menus dismiss.
    private(set) var pendingFrozen: [CGDirectDisplayID: CGImage]?
    /// Called after any shortcut change so menus can refresh.
    var onChange: (() -> Void)?

    @Published private(set) var shortcuts: [Action: Shortcut?] = [:]
    private var refs: [Action: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var paused = false

    private init() {
        for a in Action.allCases {
            if let data = UserDefaults.standard.data(forKey: a.key) {
                shortcuts[a] = try? JSONDecoder().decode(Shortcut?.self, from: data)
            } else {
                shortcuts[a] = a.defaultShortcut
            }
        }
    }

    func shortcut(for a: Action) -> Shortcut? { shortcuts[a] ?? nil }

    func set(_ s: Shortcut?, for a: Action) {
        // steal from any other action using the same combo
        if let s { for (o, v) in shortcuts where o != a && v == s { shortcuts[o] = .some(nil); persist(o) } }
        shortcuts[a] = s
        persist(a)
        registerAll()
        onChange?()
    }

    func resetAll() {
        for a in Action.allCases { shortcuts[a] = a.defaultShortcut; UserDefaults.standard.removeObject(forKey: a.key) }
        registerAll(); onChange?()
    }

    private func persist(_ a: Action) {
        UserDefaults.standard.set(try? JSONEncoder().encode(shortcuts[a] ?? nil), forKey: a.key)
    }

    func consumePendingFrozen() -> [CGDirectDisplayID: CGImage]? {
        defer { pendingFrozen = nil }
        return pendingFrozen
    }

    /// Temporarily unregister (while recording a new shortcut) so the keypress reaches the recorder.
    func pause(_ on: Bool) {
        paused = on
        if on { unregister() } else { registerAll() }
    }

    func registerAll() {
        unregister()
        if paused { return }
        if eventHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
                var hkID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                if let action = Action(rawValue: hkID.id) {
                    let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData!).takeUnretainedValue()
                    let snap = action == .captureArea ? CaptureEngine.freezeAllScreens() : nil
                    DispatchQueue.main.async {
                        mgr.pendingFrozen = snap
                        mgr.handler?(action)
                    }
                }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        }
        for action in Action.allCases {
            guard let s = shortcut(for: action) else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x42414F5A) /* 'BAOZ' */, id: action.rawValue)
            let status = RegisterEventHotKey(s.keyCode, s.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs[action] = ref }
            else { NSLog("hotkey register failed for \(action): \(status)") }
        }
    }

    private func unregister() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }
}
