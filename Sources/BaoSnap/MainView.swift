import SwiftUI
import AppKit

enum SidebarItem: Hashable {
    case all, favorites, pinned, settings
}

private var appDelegate: AppDelegate { NSApp.delegate as! AppDelegate }

/// Loads the bundled logo (works both inside the .app and under `swift run`).
let appLogo: NSImage? = {
    if let url = Bundle.main.resourceURL?.appendingPathComponent("logo_ui.png"), let i = NSImage(contentsOf: url) { return i }
    let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/logo_ui.png")
    return NSImage(contentsOf: dev)
}()

struct MainView: View {
    @EnvironmentObject var store: HistoryStore
    @State private var section: SidebarItem = .all
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            Sidebar(section: $section)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            switch section {
            case .settings: SettingsView()
            case .pinned: PinnedView()
            case .all, .favorites: HistoryView(section: section, search: $search)
            }
        }
        .frame(minWidth: 720, minHeight: 460)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Binding var section: SidebarItem
    @EnvironmentObject var store: HistoryStore
    @ObservedObject private var hotkeys = HotkeyManager.shared

    var body: some View {
        List(selection: $section) {
            VStack(alignment: .leading, spacing: 2) {
                Text("BaoSnap").font(.system(size: 16, weight: .bold))
                Text("截图 · 贴图 · 历史").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)

            Section("图库") {
                Label("全部截图", systemImage: "photo.on.rectangle.angled")
                    .badge(store.items.count).tag(SidebarItem.all)
                Label("收藏", systemImage: "star")
                    .badge(store.items.filter(\.isFavorite).count).tag(SidebarItem.favorites)
                Label("贴图中", systemImage: "pin").tag(SidebarItem.pinned)
            }
            Section {
                Label("设置", systemImage: "gearshape").tag(SidebarItem.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                CaptureButton(title: "全屏截图", symbol: "rectangle.dashed", key: HotkeyManager.Action.captureFullScreen.displayShortcut, primary: true) {
                    appDelegate.captureFullScreenAction()
                }
                CaptureButton(title: "区域 / 窗口截图", symbol: "crop", key: HotkeyManager.Action.captureArea.displayShortcut, primary: false) {
                    appDelegate.startSelection()
                }
            }
            .padding(12)
        }
    }
}

private struct CaptureButton: View {
    let title: String; let symbol: String; let key: String?; let primary: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 12.5, weight: .semibold))
                if let key { Spacer(); Text(key).font(.system(size: 10.5, weight: .medium, design: .rounded)).opacity(0.7) }
            }
            .padding(.horizontal, 10).frame(maxWidth: .infinity).frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(primary ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.30, green: 0.62, blue: 1.0), Color(red: 0.16, green: 0.50, blue: 0.98)], startPoint: .top, endPoint: .bottom))
                                  : AnyShapeStyle(Color.primary.opacity(hover ? 0.10 : 0.06)))
            )
            .foregroundStyle(primary ? .white : .primary)
            .shadow(color: primary ? Color.blue.opacity(hover ? 0.35 : 0.2) : .clear, radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - History grid

private struct HistoryView: View {
    let section: SidebarItem
    @Binding var search: String
    @EnvironmentObject var store: HistoryStore
    @State private var selected: HistoryItem?
    @State private var preview: HistoryItem?
    @State private var noteEdit: HistoryItem?
    @State private var permission = CaptureEngine.hasPermission()

    private var items: [HistoryItem] {
        var list = store.items
        if section == .favorites { list = list.filter(\.isFavorite) }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            list = list.filter { $0.note.localizedCaseInsensitiveContains(q) }
        }
        return list
    }

    private var grouped: [(String, [HistoryItem])] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: items) { item -> String in
            if cal.isDateInToday(item.date) { return "今天" }
            if cal.isDateInYesterday(item.date) { return "昨天" }
            return DateFormatter.dayHeader.string(from: item.date)
        }
        return dict.sorted { ($0.value.first?.date ?? .distantPast) > ($1.value.first?.date ?? .distantPast) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !permission { permissionBanner }
            if items.isEmpty {
                if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "text.magnifyingglass").font(.system(size: 40)).foregroundStyle(.tertiary)
                        Text("没有匹配的备注").font(.headline)
                        Text("试试其他关键词").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyState(section: section)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                        ForEach(grouped, id: \.0) { title, list in
                            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 16)], spacing: 16) {
                                ForEach(list) { item in
                                    HistoryCard(item: item, selected: selected == item, onEditNote: { noteEdit = item })
                                        .onTapGesture(count: 2) { appDelegate.pin(item) }
                                        .onTapGesture { selected = item }
                                        .contextMenu { contextMenu(item) }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permission = CaptureEngine.hasPermission()
        }
        .sheet(item: $preview) { PreviewSheet(item: $0) }
        .sheet(item: $noteEdit) { NoteEditorSheet(item: $0) }
        .background(KeyHandler(onKey: handleKey))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(section == .favorites ? "收藏" : "全部截图").font(.system(size: 20, weight: .bold))
            Text("\(items.count) 张").font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索备注", text: $search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).frame(width: 200, height: 28)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Menu {
                Button("清空历史（保留收藏）") { store.clearAll(keepFavorites: true) }
                Button("清空全部", role: .destructive) { store.clearAll(keepFavorites: false) }
                Divider()
                Button("在 Finder 中打开存储目录") { NSWorkspace.shared.open(store.directory) }
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 16)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
    }

    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
            Text("尚未授予「屏幕录制」权限，截图功能不可用。").font(.system(size: 12.5))
            Spacer()
            Button("打开系统设置") {
                CaptureEngine.requestPermission()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
            }.controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 20).padding(.bottom, 8)
    }

    @ViewBuilder private func contextMenu(_ item: HistoryItem) -> some View {
        Button("贴图") { appDelegate.pin(item) }
        Button("复制图片") { copy(item) }
        Button("预览") { preview = item }
        Button("编辑备注…") { noteEdit = item }
        Button(item.isFavorite ? "取消收藏" : "收藏") { store.toggleFavorite(item) }
        Divider()
        Button("另存为…") { export(item) }
        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Divider()
        Button("删除", role: .destructive) { store.delete(item) }
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        guard let sel = selected else { return false }
        switch e.keyCode {
        case 51, 117: store.delete(sel); selected = nil; return true       // delete
        case 49: preview = preview == nil ? sel : nil; return true          // space
        case 36: appDelegate.pin(sel); return true                          // return
        case 8 where e.modifierFlags.contains(.command): copy(sel); return true
        default: return false
        }
    }

    private func copy(_ item: HistoryItem) {
        guard let img = store.image(for: item) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        Toast.show("已复制到剪贴板")
    }

    private func export(_ item: HistoryItem) {
        let p = NSSavePanel()
        p.allowedContentTypes = [.png]
        p.nameFieldStringValue = "Baozi_\(DateFormatter.fileStamp.string(from: item.date)).png"
        p.begin { r in
            guard r == .OK, let url = p.url else { return }
            try? FileManager.default.copyItem(at: item.url, to: url)
        }
    }
}

private struct HistoryCard: View {
    let item: HistoryItem
    let selected: Bool
    var onEditNote: () -> Void = {}
    @EnvironmentObject var store: HistoryStore
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Checkerboard().opacity(0.5)
                if let thumb = store.thumbnail(for: item) {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit).padding(6)
                }
                if hover {
                    HStack(spacing: 6) {
                        CardAction(symbol: "pin.fill", help: "贴图") { appDelegate.pin(item) }
                        CardAction(symbol: "doc.on.doc", help: "复制") {
                            if let img = store.image(for: item) { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([img]); Toast.show("已复制到剪贴板") }
                        }
                        CardAction(symbol: item.isFavorite ? "star.fill" : "star", help: "收藏") { store.toggleFavorite(item) }
                        CardAction(symbol: "text.quote", help: "备注") { onEditNote() }
                        CardAction(symbol: "trash", help: "删除") { store.delete(item) }
                    }
                    .padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if item.isFavorite {
                    Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.yellow)
                        .padding(5).background(.black.opacity(0.45), in: Circle()).padding(6)
                }
            }
            HStack {
                Text(item.kindLabel).font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                Text("\(String(item.width)) × \(String(item.height))").font(.system(size: 11.5, design: .rounded)).foregroundStyle(.secondary)
                Spacer()
                Text(item.date, style: .time).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)
            if !item.note.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "text.quote").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text(item.note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(hover ? 0.12 : 0.05), radius: hover ? 10 : 4, y: hover ? 4 : 1)
        )
        .scaleEffect(hover ? 1.015 : 1)
        .animation(.easeOut(duration: 0.15), value: hover)
        .onHover { hover = $0 }
    }
}

private struct CardAction: View {
    let symbol: String; let help: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
        }
        .buttonStyle(.plain).help(help)
        .contentShape(Rectangle())
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where Int((x + y) / s) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.primary.opacity(0.06)))
                }
            }
        }
    }
}

private struct EmptyState: View {
    let section: SidebarItem
    var body: some View {
        VStack(spacing: 14) {
            if let logo = appLogo {
                Image(nsImage: logo).resizable().frame(width: 150, height: 150)
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
            }
            Text(section == .favorites ? "还没有收藏" : "还没有截图").font(.system(size: 18, weight: .semibold))
            Text(section == .favorites ? "在卡片上点 ☆ 即可收藏" : "按下快捷键开始你的第一张截图").foregroundStyle(.secondary)
            if section != .favorites {
                HStack(spacing: 10) {
                    ForEach([HotkeyManager.Action.captureFullScreen, .captureArea, .pinFromClipboard], id: \.self) { a in
                        VStack(spacing: 4) {
                            Text(a.displayShortcut).font(.system(size: 13, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            Text(a.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Note editor

private struct NoteEditorSheet: View {
    let item: HistoryItem
    @EnvironmentObject var store: HistoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑备注").font(.headline)
            TextField("输入备注，方便日后搜索", text: $text, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            text = store.items.first(where: { $0.id == item.id })?.note ?? item.note
            focused = true
        }
    }

    private func save() {
        store.updateNote(for: item.id, note: text)
        dismiss()
    }
}

// MARK: - Preview sheet

private struct PreviewSheet: View {
    let item: HistoryItem
    @EnvironmentObject var store: HistoryStore
    @Environment(\.dismiss) var dismiss
    @State private var note = ""

    var body: some View {
        VStack(spacing: 12) {
            if let img = store.image(for: item) {
                ZStack {
                    Checkerboard().opacity(0.5)
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "text.quote").foregroundStyle(.secondary)
                TextField("添加备注…", text: $note, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .onSubmit { store.updateNote(for: item.id, note: note) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack {
                Text("\(item.kindLabel) · \(String(item.width)) × \(String(item.height)) · \(item.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("贴图") { appDelegate.pin(item); dismiss() }
                Button("关闭") { saveAndDismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 480, idealWidth: 800, minHeight: 320, idealHeight: 560)
        .onAppear { note = store.items.first(where: { $0.id == item.id })?.note ?? item.note }
    }

    private func saveAndDismiss() {
        store.updateNote(for: item.id, note: note)
        dismiss()
    }
}

// MARK: - Pinned list

private struct PinnedView: View {
    @State private var tick = 0
    var body: some View {
        let pins = PinWindow.all
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("贴图中").font(.system(size: 20, weight: .bold))
                Text("\(pins.count) 个").foregroundStyle(.secondary)
                Spacer()
                Button("隐藏 / 显示") { PinWindow.toggleAllHidden(); tick += 1 }
                Button("全部关闭", role: .destructive) { PinWindow.closeAll(); tick += 1 }.disabled(pins.isEmpty)
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
            if pins.isEmpty {
                VStack(spacing: 10) {
                    if let logo = appLogo {
                        Image(nsImage: logo).resizable().frame(width: 150, height: 150)
                            .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
                    }
                    Text("当前没有贴图").font(.headline)
                    Text("在历史里双击一张截图，或按 \(HotkeyManager.Action.pinFromClipboard.displayShortcut) 贴图剪贴板图片").foregroundStyle(.secondary).font(.callout)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 16)], spacing: 16) {
                        ForEach(Array(pins.enumerated()), id: \.offset) { _, pin in
                            VStack(spacing: 6) {
                                Image(nsImage: pin.image).resizable().aspectRatio(contentMode: .fit).frame(height: 120)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                HStack {
                                    Button("定位") { pin.flashLocate() }
                                    Button("关闭") { pin.closeAnimated(); tick += 1 }
                                }.controlSize(.small)
                            }
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }.padding(20)
                }
            }
        }
        .id(tick)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in tick += 1 }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var store: HistoryStore

    var body: some View {
        Form {
            Section("截图后") {
                Toggle("复制到剪贴板", isOn: $settings.copyToClipboard)
                Toggle("显示提示气泡", isOn: $settings.showToast)
                Toggle("播放快门声", isOn: $settings.playSound)
            }
            Section("贴图") {
                Toggle("贴图窗口显示阴影", isOn: $settings.pinShadow)
                Text("滚轮缩放 · ⌥+滚轮 调整透明度 · 双击隐藏 · 右键更多操作")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("历史") {
                Stepper("最多保留 \(settings.historyLimit) 张", value: $settings.historyLimit, in: 20...2000, step: 20)
                LabeledContent("存储位置") {
                    HStack {
                        Text(store.directory.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("打开") { NSWorkspace.shared.open(store.directory) }.controlSize(.small)
                    }
                }
                LabeledContent("占用空间", value: ByteCountFormatter.string(fromByteCount: store.totalBytes, countStyle: .file))
            }
            Section {
                ForEach(HotkeyManager.Action.allCases, id: \.self) { a in
                    LabeledContent(a.title) { ShortcutRecorder(action: a) }
                }
            } header: {
                HStack {
                    Text("快捷键")
                    Spacer()
                    Button("恢复默认") { HotkeyManager.shared.resetAll() }.controlSize(.small).buttonStyle(.link)
                }
            } footer: {
                Text("点击后按下新的组合键（需包含 ⌘ / ⌃ / ⌥，或使用 F 键）；⌫ 清除。").font(.caption).foregroundStyle(.secondary)
            }
            Section("通用") {
                Toggle("登录时启动", isOn: $settings.launchAtLogin)
                LabeledContent("版本", value: "1.0")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - helpers

/// Bridges NSEvent keyDown into SwiftUI for the grid.
private struct KeyHandler: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.window == v.window, !(e.window?.firstResponder is NSTextView) else { return e }
            return onKey(e) ? nil : e
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coord { Coord() }
    final class Coord { var monitor: Any?; deinit { if let m = monitor { NSEvent.removeMonitor(m) } } }
}

extension DateFormatter {
    static let dayHeader: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 EEEE"; return f
    }()
}

// MARK: - Shortcut recorder

struct ShortcutRecorder: View {
    let action: HotkeyManager.Action
    @ObservedObject private var mgr = HotkeyManager.shared
    @State private var recording = false

    var body: some View {
        let s = mgr.shortcut(for: action)
        HStack(spacing: 6) {
            Button {
                recording.toggle()
                HotkeyManager.shared.pause(recording)
            } label: {
                Text(recording ? "按下组合键…" : (s?.display ?? "未设置"))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(recording ? Color.accentColor : (s == nil ? .secondary : .primary))
                    .frame(minWidth: 90).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.primary.opacity(recording ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(recording ? Color.accentColor : .clear, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            if s != nil && !recording {
                Button { mgr.set(nil, for: action) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).help("清除")
            }
        }
        .background(RecorderKeyCatcher(active: recording) { e in
            defer { recording = false; HotkeyManager.shared.pause(false) }
            if e.keyCode == 53 { return }                        // esc: cancel
            if e.keyCode == 51 { mgr.set(nil, for: action); return } // delete: clear
            if let sc = Shortcut.from(event: e) { mgr.set(sc, for: action) } else { NSSound.beep() }
        })
    }
}

private struct RecorderKeyCatcher: NSViewRepresentable {
    let active: Bool
    let onKey: (NSEvent) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        let c = context.coordinator
        if active, c.monitor == nil {
            c.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in onKey(e); return nil }
        } else if !active, let m = c.monitor {
            NSEvent.removeMonitor(m); c.monitor = nil
        }
    }
    func makeCoordinator() -> Coord { Coord() }
    final class Coord { var monitor: Any?; deinit { if let m = monitor { NSEvent.removeMonitor(m) } } }
}
