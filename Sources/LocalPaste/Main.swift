import AppKit
import Foundation

@main
enum LocalPasteMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            runSelfTest()
            return
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"),
           CommandLine.arguments.count > index + 1 {
            renderPreview(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            return
        }
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }

    @MainActor
    private static func runSelfTest() {
        let directory = temporaryDirectory("SelfTest")
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(storageDirectory: directory, shouldMonitor: false)
        store.recordText("常用文字", source: "测试")
        store.togglePin(store.entries[0])
        store.recordText("常用文字")
        expect(store.entries.count == 1 && store.entries[0].isPinned, "Deduplication must preserve pin")
        for index in 0..<220 { store.recordText("历史 \(index)") }
        expect(store.entries.count == 200 && store.entries.contains { $0.preview == "常用文字" && $0.isPinned }, "Capacity must preserve pinned entry")
        let reloaded = ClipboardStore(storageDirectory: directory, shouldMonitor: false)
        expect(reloaded.entries.count == 200 && reloaded.pinnedCount == 1, "History must persist")
        let linksBoard = store.createBoard(named: "实用链接")!
        store.pin(store.entries[0], to: linksBoard)
        let groupedText = store.entries[0].text!
        store.recordText(groupedText)
        expect(store.entries(in: linksBoard).count == 1, "Deduplication must preserve board membership")
        let groupedReload = ClipboardStore(storageDirectory: directory, shouldMonitor: false)
        expect(groupedReload.boards.contains(linksBoard) && groupedReload.entries(in: linksBoard).count == 1, "Board and membership must persist")
        store.clearHistory()
        store.recordText("   \n")
        store.recordText(String(repeating: "字", count: 340_000))
        expect(store.entries.isEmpty, "Empty and oversized text must be ignored")

        board.clearContents()
        board.setString("https://pasteapp.io/", forType: .string)
        store.capture(from: board, source: "Safari")
        expect(store.entries.first?.linkURL?.host == "pasteapp.io", "Recognize a web link")
        store.recordText("let value: Int = 1")
        expect(store.entries.first?.linkURL == nil, "Code is not a link")

        board.clearContents()
        board.setString("私密测试内容", forType: .string)
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let count = store.entries.count
        store.capture(from: board)
        expect(store.entries.count == count, "Concealed clipboard must be ignored")
        board.clearContents()
        board.setString("暂停时的测试内容", forType: .string)
        store.togglePaused()
        store.capture(from: board)
        expect(store.entries.count == count, "Paused capture must be ignored")
        store.togglePaused()
        store.capture(from: board)
        expect(store.entries.first?.text == "暂停时的测试内容", "Capture must resume")
        expect(store.copy(store.entries[0], to: board) && board.string(forType: .string) == "暂停时的测试内容", "Text copy must work")

        let file = directory.appendingPathComponent("测试文件.txt")
        try! Data("测试文件".utf8).write(to: file)
        board.clearContents()
        board.writeObjects([file as NSURL])
        store.capture(from: board)
        let fileEntry = store.entries[0]
        expect(fileEntry.kind == .files && store.copy(fileEntry, to: board), "File capture and copy must work")
        try! FileManager.default.removeItem(at: file)
        board.clearContents()
        board.setString("保留当前剪贴板", forType: .string)
        expect(!store.copy(fileEntry, to: board) && board.string(forType: .string) == "保留当前剪贴板", "Missing files must not clear clipboard")

        board.clearContents()
        board.setData(samplePNG(), forType: NSPasteboard.PasteboardType("public.png"))
        store.capture(from: board)
        let imageEntry = store.entries[0]
        expect(imageEntry.kind == .image && store.thumbnail(for: imageEntry) != nil, "Image capture and thumbnail must work")
        expect(store.copy(imageEntry, to: board) && NSImage(pasteboard: board) != nil, "Image copy must work")
        let imageURL = store.imageURL(for: imageEntry)!
        store.remove(imageEntry)
        expect(!FileManager.default.fileExists(atPath: imageURL.path), "Delete must remove image asset")
        board.clearContents()
        board.setString("保留当前剪贴板", forType: .string)
        expect(!store.copy(imageEntry, to: board) && board.string(forType: .string) == "保留当前剪贴板", "Missing image must not clear clipboard")
        var unsafe = imageEntry
        unsafe.imageFilename = "../outside.png"
        expect(store.imageURL(for: unsafe) == nil, "Image lookup must reject directory traversal")
        store.clearHistory()
        let cleared = ClipboardStore(storageDirectory: directory, shouldMonitor: false)
        expect(cleared.entries.isEmpty, "Clear must persist")
        print("LocalPaste self-test passed: persistence, deduplication, pinned capacity, boards, links, privacy markers, pause, text/file/image copy, failure protection, image cleanup")
    }

    @MainActor
    private static func renderPreview(to output: URL) {
        let directory = temporaryDirectory("Preview")
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(storageDirectory: directory, shouldMonitor: false)
        store.recordText("今天要做的事\n\n整理工作资料\n完成本周计划\n给常用内容留一个位置", source: "备忘录")
        store.recordText("https://pasteapp.io/", source: "Safari")
        let links = store.createBoard(named: "实用链接")!
        store.pin(store.entries[0], to: links)
        store.recordText("常用回复\n\n收到，我会尽快处理。\n完成后给你反馈。", source: "备忘录")
        store.togglePin(store.entries[0])
        let file = directory.appendingPathComponent("本周计划.txt")
        try! Data("本周计划".utf8).write(to: file)
        board.clearContents()
        board.writeObjects([file as NSURL])
        store.capture(from: board, source: "Finder")
        board.clearContents()
        board.setData(samplePNG(), forType: NSPasteboard.PasteboardType("public.png"))
        store.capture(from: board, source: "预览")
        store.notice = nil

        let controller = ClipboardShelfController(store: store, previewMode: true, onCopy: {})
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: ClipboardShelfController.panelSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        if CommandLine.arguments.contains("--dark") {
            window.appearance = NSAppearance(named: .darkAqua)
        } else {
            window.appearance = NSAppearance(named: .aqua)
        }
        window.contentViewController = controller
        window.contentView?.layoutSubtreeIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        if CommandLine.arguments.contains("--layout") { reportLayout(controller.view) }
        guard let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) else {
            fatalError("Cannot create preview bitmap")
        }
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode preview") }
        try! png.write(to: output)
        print(output.path)
    }

    private static func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LocalPaste-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }

    @MainActor
    private static func reportLayout(_ view: NSView) {
        if let label = view as? NSTextField { print("\(label.stringValue.prefix(25)): \(label.frame)") }
        for child in view.subviews { reportLayout(child) }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    private static func samplePNG() -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 360, pixelsHigh: 200,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<200 {
            for x in 0..<360 {
                let u = Double(x) / 359
                let v = Double(y) / 199
                let circle = pow(Double(x - 270), 2) + pow(Double(y - 57), 2) < 24 * 24
                let hill = Double(y) > 139 + 25 * sin(Double(x) / 58)
                let color = circle ? NSColor(calibratedRed: 1, green: 0.85, blue: 0.53, alpha: 1)
                    : hill ? NSColor(calibratedRed: 0.20, green: 0.32 + 0.12 * u, blue: 0.57, alpha: 1)
                    : NSColor(calibratedRed: 0.32 + 0.25 * v, green: 0.48 + 0.18 * u, blue: 0.87 + 0.07 * v, alpha: 1)
                bitmap.setColor(color, atX: x, y: y)
            }
        }
        return bitmap.representation(using: .png, properties: [:])!
    }
}
