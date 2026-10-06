import AppKit
import Combine
import CryptoKit
import Foundation
import ImageIO

enum ClipboardEntryKind: String, Codable {
    case text
    case image
    case files
}

enum ClipboardRetention: Int, CaseIterable {
    case oneDay = 1
    case threeDays = 3
    case fiveDays = 5
    case oneWeek = 7

    var title: String { self == .oneWeek ? "一周" : "\(rawValue) 天" }
    var interval: TimeInterval { TimeInterval(rawValue) * 24 * 60 * 60 }
}

private struct ClipboardSettings: Codable {
    let retentionDays: Int
}

struct ClipboardBoard: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
}

struct ClipboardEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var createdAt: Date
    var kind: ClipboardEntryKind
    var text: String?
    var imageFilename: String?
    var fileURLs: [String]?
    var fingerprint: String
    var isPinned: Bool
    var sourceApplication: String?
    var boardID: UUID? = nil

    var preview: String {
        switch kind {
        case .text:
            return (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        case .image:
            return "图片"
        case .files:
            let names = (fileURLs ?? []).compactMap { URL(string: $0)?.lastPathComponent }
            return names.isEmpty ? "文件" : names.joined(separator: "、")
        }
    }

    var symbol: String {
        switch kind {
        case .text:
            if linkURL != nil { return "link" }
            return "text.alignleft"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        }
    }

    var linkURL: URL? {
        guard kind == .text, !preview.contains(where: { $0.isWhitespace }),
              let url = URL(string: preview),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    var typeName: String {
        switch kind {
        case .text: return linkURL == nil ? "文字" : "链接"
        case .image: return "图片"
        case .files: return "文件"
        }
    }
}

@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var isPaused: Bool
    @Published private(set) var retention: ClipboardRetention = .oneDay
    @Published private(set) var boards: [ClipboardBoard] = [
        ClipboardBoard(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "常用内容")
    ]
    @Published var notice: String?

    private let storageDirectory: URL
    private let historyURL: URL
    private let boardsURL: URL
    private let settingsURL: URL
    private let imagesDirectory: URL
    private let shouldMonitor: Bool
    private let currentDate: () -> Date
    private var lastRetentionSweep: Date?
    private var monitorTimer: Timer?
    private var lastChangeCount: Int
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private let maximumEntries = 200
    private let maximumTextBytes = 1_000_000
    private let maximumImageBytes = 10_000_000
    private let maximumImageStorageBytes = 200_000_000

    init(storageDirectory: URL? = nil, shouldMonitor: Bool = true, now: @escaping () -> Date = { Date() }) {
        let base = storageDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalPaste", isDirectory: true)
        self.storageDirectory = base
        self.historyURL = base.appendingPathComponent("history.json")
        self.boardsURL = base.appendingPathComponent("boards.json")
        self.settingsURL = base.appendingPathComponent("settings.json")
        self.imagesDirectory = base.appendingPathComponent("Images", isDirectory: true)
        self.shouldMonitor = shouldMonitor
        self.currentDate = now
        self.isPaused = shouldMonitor && UserDefaults.standard.bool(forKey: "LocalPaste.isPaused")
        self.lastChangeCount = shouldMonitor ? NSPasteboard.general.changeCount : 0
        thumbnailCache.totalCostLimit = 48_000_000
        if let data = try? Data(contentsOf: settingsURL),
           let settings = try? JSONDecoder().decode(ClipboardSettings.self, from: data),
           let saved = ClipboardRetention(rawValue: settings.retentionDays) {
            retention = saved
        }

        if let data = try? Data(contentsOf: boardsURL),
           let saved = try? JSONDecoder().decode([ClipboardBoard].self, from: data), !saved.isEmpty {
            boards = saved
        }
        loadHistory()
        if shouldMonitor { startMonitoring() }
    }

    deinit {
        monitorTimer?.invalidate()
    }

    var pinnedCount: Int { entries.filter(\.isPinned).count }

    func setRetention(_ value: ClipboardRetention) {
        guard value != retention else { return }
        do {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storageDirectory.path)
            try JSONEncoder().encode(ClipboardSettings(retentionDays: value.rawValue)).write(to: settingsURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
        } catch {
            notice = "无法保存保留时间设置"
            return
        }
        retention = value
        notice = "历史保留 \(value.title)，固定内容继续保留"
        removeExpiredEntries()
    }

    @discardableResult
    func removeExpiredEntries() -> Int {
        let date = currentDate()
        lastRetentionSweep = date
        let expired = entries.filter { isExpired($0, at: date) }
        guard !expired.isEmpty else { return 0 }
        let identifiers = Set(expired.map(\.id))
        entries.removeAll { identifiers.contains($0.id) }
        expired.forEach { removeImage(for: $0) }
        saveHistory()
        return expired.count
    }

    private func isExpired(_ entry: ClipboardEntry, at date: Date) -> Bool {
        !entry.isPinned && entry.createdAt <= date.addingTimeInterval(-retention.interval)
    }

    func togglePaused() {
        isPaused.toggle()
        if shouldMonitor {
            UserDefaults.standard.set(isPaused, forKey: "LocalPaste.isPaused")
            lastChangeCount = NSPasteboard.general.changeCount
        }
        notice = isPaused ? "已暂停记录" : "已恢复记录"
    }

    func togglePin(_ entry: ClipboardEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].isPinned.toggle()
        entries[index].boardID = entries[index].isPinned ? boards.first?.id : nil
        let isPinned = entries[index].isPinned
        saveHistory()
        notice = isPinned ? "已固定到常用内容" : "已取消固定"
        if !isPinned {
            removeExpiredEntries()
            if !entries.contains(where: { $0.id == entry.id }) { notice = "已取消固定，记录已到期" }
        }
    }

    @discardableResult
    func createBoard(named name: String) -> ClipboardBoard? {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 12, boards.count < 8,
              !boards.contains(where: { $0.name == title }) else {
            notice = "分组名称需为 1–12 个字且不能重复，最多 8 个分组"
            return nil
        }
        let board = ClipboardBoard(id: UUID(), name: title)
        boards.append(board)
        saveBoards()
        return board
    }

    func pin(_ entry: ClipboardEntry, to board: ClipboardBoard) {
        guard boards.contains(where: { $0.id == board.id }),
              let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].isPinned = true
        entries[index].boardID = board.id
        saveHistory()
        notice = "已加入“\(board.name)”"
    }

    func entries(in board: ClipboardBoard) -> [ClipboardEntry] {
        entries.filter { $0.isPinned && ($0.boardID ?? boards.first?.id) == board.id }
    }

    func remove(_ entry: ClipboardEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let removed = entries.remove(at: index)
        removeImage(for: removed)
        saveHistory()
    }

    func clearHistory() {
        entries.removeAll()
        thumbnailCache.removeAllObjects()
        try? FileManager.default.removeItem(at: imagesDirectory)
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        saveHistory()
        notice = "历史记录已清空"
    }

    @discardableResult
    func copy(_ entry: ClipboardEntry, to pasteboard: NSPasteboard = .general) -> Bool {
        let storedEntry = entries.first { $0.id == entry.id } ?? entry
        guard !isExpired(storedEntry, at: currentDate()) else {
            removeExpiredEntries()
            notice = "这条记录已到期"
            return false
        }
        let objects: [NSPasteboardWriting]
        switch entry.kind {
        case .text:
            guard let text = entry.text, !text.isEmpty else {
                notice = "这条文字记录无法复制"
                return false
            }
            objects = [text as NSString]
        case .image:
            guard let image = image(for: entry) else {
                notice = "找不到这张图片"
                return false
            }
            objects = [image]
        case .files:
            let strings = entry.fileURLs ?? []
            let urls = strings.compactMap(URL.init(string:)).filter {
                $0.isFileURL && FileManager.default.fileExists(atPath: $0.path)
            }
            guard !urls.isEmpty, urls.count == strings.count else {
                notice = "原文件已移动或删除，无法复制"
                return false
            }
            objects = urls.map { $0 as NSURL }
        }

        // Keep a materialized snapshot so an unsuccessful write can restore the previous clipboard.
        let previousItems = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(objects) else {
            pasteboard.clearContents()
            if !previousItems.isEmpty { pasteboard.writeObjects(previousItems) }
            if shouldMonitor && pasteboard.name == NSPasteboard.general.name {
                lastChangeCount = pasteboard.changeCount
            }
            notice = "复制失败，请重试"
            return false
        }
        if shouldMonitor && pasteboard.name == NSPasteboard.general.name {
            lastChangeCount = pasteboard.changeCount
        }
        if let index = entries.firstIndex(where: { $0.id == storedEntry.id }) {
            var reused = entries.remove(at: index)
            reused.createdAt = currentDate()
            entries.insert(reused, at: 0)
            saveHistory()
        }
        notice = "已复制，按 ⌘V 粘贴"
        return true
    }

    func imageURL(for entry: ClipboardEntry) -> URL? {
        guard entry.kind == .image, let filename = entry.imageFilename,
              filename.hasSuffix(".png"), filename == URL(fileURLWithPath: filename).lastPathComponent,
              !filename.contains("/") else { return nil }
        let url = imagesDirectory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func image(for entry: ClipboardEntry) -> NSImage? {
        imageURL(for: entry).flatMap { NSImage(contentsOf: $0) }
    }

    func thumbnail(for entry: ClipboardEntry) -> NSImage? {
        guard let url = imageURL(for: entry) else { return nil }
        let key = url.lastPathComponent as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 480
              ] as CFDictionary) else { return nil }
        let thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        thumbnailCache.setObject(thumbnail, forKey: key, cost: image.width * image.height * 4)
        return thumbnail
    }

    func recordText(_ text: String, source: String? = nil) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let data = Data(text.utf8)
        guard data.count <= maximumTextBytes else {
            notice = "这段文字太大，未加入历史"
            return
        }
        let fingerprint = Self.fingerprint(data)
        insert(ClipboardEntry(
            id: UUID(), createdAt: currentDate(), kind: .text, text: text,
            imageFilename: nil, fileURLs: nil, fingerprint: fingerprint,
            isPinned: false, sourceApplication: source
        ))
    }

    private func startMonitoring() {
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkClipboard() }
        }
    }

    private func checkClipboard() {
        let date = currentDate()
        if lastRetentionSweep == nil || date.timeIntervalSince(lastRetentionSweep!) >= 60 || date < lastRetentionSweep! {
            removeExpiredEntries()
        }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        let source = NSWorkspace.shared.frontmostApplication?.localizedName
        capture(from: pasteboard, source: source)
    }

    // A separate pasteboard can exercise capture without reading the user's clipboard.
    func capture(from pasteboard: NSPasteboard, source: String? = nil) {
        guard !isPaused, !containsSensitiveMarker(pasteboard.types ?? []) else { return }
        if let fileURLs = readFileURLs(from: pasteboard), !fileURLs.isEmpty {
            recordFiles(fileURLs, source: source)
            return
        }

        if let imageData = readImageData(from: pasteboard) {
            recordImage(imageData, source: source)
            return
        }

        if let text = pasteboard.string(forType: .string) {
            recordText(text, source: source)
        }
    }

    private func containsSensitiveMarker(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        let rawTypes = types.map(\.rawValue)
        let blockedMarkers = [
            "org.nspasteboard.ConcealedType",
            "org.nspasteboard.TransientType",
            "org.nspasteboard.AutoGeneratedType",
            "com.agilebits.onepassword",
            "com.apple.pasteboard.transient"
        ]
        return rawTypes.contains { type in blockedMarkers.contains(where: type.localizedCaseInsensitiveContains) }
    }

    private func readFileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        guard let items = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return nil
        }
        return items
    }

    private func readImageData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: NSPasteboard.PasteboardType("public.png")), NSImage(data: png) != nil { return png }
        guard let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func recordFiles(_ urls: [URL], source: String?) {
        let strings = urls.filter {
            $0.isFileURL && FileManager.default.fileExists(atPath: $0.path)
        }.map(\.absoluteString)
        guard !strings.isEmpty else { return }
        let data = Data(strings.joined(separator: "\n").utf8)
        insert(ClipboardEntry(
            id: UUID(), createdAt: currentDate(), kind: .files, text: nil,
            imageFilename: nil, fileURLs: strings, fingerprint: Self.fingerprint(data),
            isPinned: false, sourceApplication: source
        ))
    }

    private func recordImage(_ data: Data, source: String?) {
        guard NSImage(data: data) != nil else { return }
        guard data.count <= maximumImageBytes else {
            notice = "图片超过 10 MB，未加入历史"
            return
        }
        let id = UUID()
        let filename = "\(id.uuidString).png"
        do {
            try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
            try data.write(to: imagesDirectory.appendingPathComponent(filename), options: .atomic)
            insert(ClipboardEntry(
                id: id, createdAt: currentDate(), kind: .image, text: nil,
                imageFilename: filename, fileURLs: nil, fingerprint: Self.fingerprint(data),
                isPinned: false, sourceApplication: source
            ))
        } catch {
            notice = "无法保存图片"
        }
    }

    private func insert(_ entry: ClipboardEntry) {
        removeExpiredEntries()
        if let existingIndex = entries.firstIndex(where: { $0.kind == entry.kind && $0.fingerprint == entry.fingerprint }) {
            let existing = entries.remove(at: existingIndex)
            if existing.isPinned {
                var updated = entry
                updated.isPinned = true
                updated.boardID = existing.boardID
                entries.insert(updated, at: 0)
            } else {
                entries.insert(entry, at: 0)
            }
            if existing.id != entry.id { removeImage(for: existing) }
        } else {
            entries.insert(entry, at: 0)
        }

        enforceEntryLimit()
        enforceImageStorageLimit()
        saveHistory()
    }

    private func enforceEntryLimit() {
        while entries.count > maximumEntries {
            guard let index = entries.lastIndex(where: { !$0.isPinned }) else { break }
            removeImage(for: entries.remove(at: index))
        }
    }

    private func enforceImageStorageLimit() {
        var totalBytes = entries.compactMap { entry -> (ClipboardEntry, Int)? in
            guard entry.kind == .image, let filename = entry.imageFilename,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: imagesDirectory.appendingPathComponent(filename).path),
                  let size = attributes[.size] as? Int else { return nil }
            return (entry, size)
        }.reduce(0) { $0 + $1.1 }

        while totalBytes > maximumImageStorageBytes {
            let images = entries.filter { $0.kind == .image }
            guard let victim = images.last(where: { !$0.isPinned }),
                  let index = entries.firstIndex(where: { $0.id == victim.id }) else { break }
            if let filename = victim.imageFilename,
               let attributes = try? FileManager.default.attributesOfItem(atPath: imagesDirectory.appendingPathComponent(filename).path),
               let size = attributes[.size] as? Int {
                totalBytes -= size
            }
            entries.remove(at: index)
            removeImage(for: victim)
        }
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let loaded = try? JSONDecoder().decode([ClipboardEntry].self, from: data) else { return }
        entries = loaded.filter { entry in
            switch entry.kind {
            case .image: return imageURL(for: entry) != nil
            case .text: return !(entry.text ?? "").isEmpty
            case .files: return !(entry.fileURLs ?? []).isEmpty
            }
        }.sorted { $0.createdAt > $1.createdAt }
        removeExpiredEntries()
        enforceEntryLimit()
        enforceImageStorageLimit()
    }

    private func saveHistory() {
        do {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storageDirectory.path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: historyURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
        } catch {
            notice = "无法保存历史记录"
        }
    }

    private func saveBoards() {
        do {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storageDirectory.path)
            try JSONEncoder().encode(boards).write(to: boardsURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: boardsURL.path)
        } catch {
            notice = "无法保存分组"
        }
    }

    private func removeImage(for entry: ClipboardEntry) {
        guard let url = imageURL(for: entry) else { return }
        thumbnailCache.removeObject(forKey: url.lastPathComponent as NSString)
        try? FileManager.default.removeItem(at: url)
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
