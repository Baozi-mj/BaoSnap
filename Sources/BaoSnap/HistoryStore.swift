import AppKit
import Combine

struct HistoryItem: Identifiable, Codable, Hashable {
    enum Kind: String, Codable { case area, window, fullscreen, clipboard }

    let id: UUID
    let date: Date
    let kind: Kind
    let fileName: String
    let width: Int
    let height: Int
    /// Backing scale of the display at capture time (1 for 1080p, 2 for Retina).
    let scale: Double
    var isFavorite: Bool = false
    var note: String = ""

    enum CodingKeys: String, CodingKey {
        case id, date, kind, fileName, width, height, scale, isFavorite, note
    }

    init(id: UUID, date: Date, kind: Kind, fileName: String, width: Int, height: Int, scale: Double = 2, isFavorite: Bool = false, note: String = "") {
        self.id = id; self.date = date; self.kind = kind; self.fileName = fileName
        self.width = width; self.height = height; self.scale = scale; self.isFavorite = isFavorite
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        kind = try c.decode(Kind.self, forKey: .kind)
        fileName = try c.decode(String.self, forKey: .fileName)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 2
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(date, forKey: .date)
        try c.encode(kind, forKey: .kind)
        try c.encode(fileName, forKey: .fileName)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(scale, forKey: .scale)
        try c.encode(isFavorite, forKey: .isFavorite)
        try c.encode(note, forKey: .note)
    }

    var url: URL { HistoryStore.historyDirectory.appendingPathComponent(fileName) }

    var kindLabel: String {
        switch kind {
        case .area: return "区域"
        case .window: return "窗口"
        case .fullscreen: return "全屏"
        case .clipboard: return "剪贴板"
        }
    }
}

/// On-disk history of captures: PNG files + index.json in Application Support.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var items: [HistoryItem] = []

    static let historyDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BaoSnap/History", isDirectory: true)
    }()

    let directory: URL
    private let indexURL: URL
    private let thumbCache = NSCache<NSString, NSImage>()
    private let io = DispatchQueue(label: "baozi.history.io", qos: .utility)

    private init() {
        directory = HistoryStore.historyDirectory
        indexURL = directory.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        thumbCache.countLimit = 400
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) else { return }
        items = decoded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    private func save() {
        let snapshot = items
        io.async { [indexURL] in
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: indexURL, options: .atomic)
            }
        }
    }

    @discardableResult
    func add(image: NSImage, kind: HistoryItem.Kind, scale: CGFloat = 2) -> HistoryItem? {
        let id = UUID()
        let px = image.pixelSize
        let item = HistoryItem(id: id, date: Date(), kind: kind,
                               fileName: "\(id.uuidString).png",
                               width: Int(px.width), height: Int(px.height),
                               scale: Double(scale))
        
        // Fast in-memory thumbnail generation (<1ms) so UI (toast, history) updates instantly
        let maxSide: CGFloat = 480
        let s = max(1, scale)
        let thumbScale = min(1, (maxSide * 2) / max(px.width, px.height))
        let thumbPixelW = max(1, Int(px.width * thumbScale))
        let thumbPixelH = max(1, Int(px.height * thumbScale))
        let thumbLogicalSize = NSSize(width: CGFloat(thumbPixelW) / s, height: CGFloat(thumbPixelH) / s)
        
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let ctx = CGContext(data: nil, width: thumbPixelW, height: thumbPixelH,
                                   bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .medium
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: thumbPixelW, height: thumbPixelH))
                if let thumbCG = ctx.makeImage() {
                    let thumbImg = NSImage(cgImage: thumbCG, size: thumbLogicalSize)
                    thumbCache.setObject(thumbImg, forKey: id.uuidString as NSString)
                }
            }
        }

        items.insert(item, at: 0)
        trim()

        // Background PNG compression and disk persistence
        io.async { [weak self, item, image] in
            guard let png = image.pngData else { return }
            try? png.write(to: item.url, options: .atomic)
            self?.save()
        }

        return item
    }

    func toggleFavorite(_ item: HistoryItem) {
        guard let i = items.firstIndex(of: item) else { return }
        items[i].isFavorite.toggle()
        save()
    }

    func updateNote(for id: UUID, note: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    func delete(_ item: HistoryItem) {
        items.removeAll { $0.id == item.id }
        thumbCache.removeObject(forKey: item.id.uuidString as NSString)
        io.async { try? FileManager.default.removeItem(at: item.url) }
        save()
    }

    func clearAll(keepFavorites: Bool) {
        let doomed = items.filter { !(keepFavorites && $0.isFavorite) }
        items.removeAll { !(keepFavorites && $0.isFavorite) }
        io.async { doomed.forEach { try? FileManager.default.removeItem(at: $0.url) } }
        save()
    }

    func image(for item: HistoryItem) -> NSImage? { NSImage(contentsOf: item.url) }

    func thumbnail(for item: HistoryItem, maxSide: CGFloat = 480) -> NSImage? {
        let key = item.id.uuidString as NSString
        if let cached = thumbCache.object(forKey: key) { return cached }
        guard let src = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxSide * 2),
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let s = max(1, item.scale)
        let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / s, height: CGFloat(cg.height) / s))
        thumbCache.setObject(img, forKey: key)
        return img
    }

    private func trim() {
        let limit = max(20, Settings.shared.historyLimit)
        guard items.count > limit else { return }
        let overflow = items.enumerated().filter { $0.offset >= limit && !$0.element.isFavorite }.map(\.element)
        for item in overflow { delete(item) }
    }

    var totalBytes: Int64 {
        items.reduce(0) { acc, it in
            acc + ((try? FileManager.default.attributesOfItem(atPath: it.url.path)[.size] as? Int64) ?? 0)
        }
    }
}

extension NSImage {
    var pixelSize: NSSize {
        if let rep = representations.first as? NSBitmapImageRep {
            return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        if let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return NSSize(width: cg.width, height: cg.height)
        }
        return size
    }

    var pngData: Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }
}
