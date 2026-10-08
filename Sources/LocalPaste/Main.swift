import AppKit
import Foundation

@main
enum LocalPasteMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--ui-self-test") {
            runSizingSelfTest()
            runInteractionSelfTest()
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            runSelfTest()
            runSizingSelfTest()
            runInteractionSelfTest()
            runRetentionSelfTest()
            return
        }
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
    private static func runRetentionSelfTest() {
        let directory = temporaryDirectory("RetentionTest")
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var clock = start
        for retention in ClipboardRetention.allCases {
            clock = start
            let folder = directory.appendingPathComponent("\(retention.rawValue)")
            let store = ClipboardStore(storageDirectory: folder, shouldMonitor: false, now: { clock })
            expect(store.retention == .oneDay, "Retention must default to one day")
            store.setRetention(retention)
            store.recordText("固定的常用内容")
            store.togglePin(store.entries[0])
            store.recordText("普通历史")
            let text = store.entries[0]
            let file = folder.appendingPathComponent("原始文件.txt")
            try! Data("原始文件不能因历史到期而被删除".utf8).write(to: file)
            board.clearContents()
            board.writeObjects([file as NSURL])
            store.capture(from: board)
            board.clearContents()
            board.setData(samplePNG(), forType: NSPasteboard.PasteboardType("public.png"))
            store.capture(from: board)
            let image = store.entries[0]
            let imageURL = store.imageURL(for: image)!
            clock = start.addingTimeInterval(retention.interval - 1)
            expect(store.removeExpiredEntries() == 0 && store.entries.count == 4,
                   "History must remain until the exact retention boundary")
            store.togglePaused()
            clock = start.addingTimeInterval(retention.interval)
            expect(store.removeExpiredEntries() == 3 && store.entries.count == 1 && store.entries[0].isPinned,
                   "Expired ordinary history must be removed while paused; pins must survive")
            expect(!FileManager.default.fileExists(atPath: imageURL.path) && FileManager.default.fileExists(atPath: file.path),
                   "Expiration must remove image copies and preserve original files")
            board.clearContents()
            board.setString("保留当前剪贴板", forType: .string)
            expect(!store.copy(text, to: board) && board.string(forType: .string) == "保留当前剪贴板",
                   "Expired cards must not replace the current clipboard")
            let reloaded = ClipboardStore(storageDirectory: folder, shouldMonitor: false, now: { clock })
            expect(reloaded.retention == retention && reloaded.entries.count == 1,
                   "Retention settings and cleanup must persist")
            store.togglePin(store.entries[0])
            expect(store.entries.isEmpty, "Unpinning already-expired content must clean it immediately")
        }

        clock = start
        let shortening = ClipboardStore(storageDirectory: directory.appendingPathComponent("Shortening"), shouldMonitor: false, now: { clock })
        shortening.setRetention(.oneWeek)
        shortening.recordText("六天前的普通内容")
        shortening.recordText("六天前的固定内容")
        shortening.togglePin(shortening.entries[0])
        clock = start.addingTimeInterval(6 * 24 * 60 * 60)
        shortening.setRetention(.fiveDays)
        expect(shortening.entries.count == 1 && shortening.entries[0].isPinned,
               "Shortening retention must immediately clean ordinary history and preserve pins")
        shortening.setRetention(.oneWeek)
        expect(shortening.entries.count == 1, "Extending retention must not restore deleted history")

        clock = start
        let extending = ClipboardStore(storageDirectory: directory.appendingPathComponent("Extending"), shouldMonitor: false, now: { clock })
        extending.recordText("延长保留时间")
        clock = start.addingTimeInterval(12 * 60 * 60)
        extending.setRetention(.threeDays)
        clock = start.addingTimeInterval(2 * 24 * 60 * 60)
        expect(extending.removeExpiredEntries() == 0, "Extending retention must keep unexpired history longer")
        clock = start.addingTimeInterval(3 * 24 * 60 * 60)
        expect(extending.removeExpiredEntries() == 1, "Extended history must expire at its new boundary")

        clock = start
        let renewal = ClipboardStore(storageDirectory: directory.appendingPathComponent("Renewal"), shouldMonitor: false, now: { clock })
        renewal.recordText("重复复制刷新期限")
        clock = start.addingTimeInterval(18 * 60 * 60)
        renewal.recordText("重复复制刷新期限")
        clock = start.addingTimeInterval(30 * 60 * 60)
        expect(renewal.removeExpiredEntries() == 0 && renewal.entries.count == 1, "Recopying content must renew its lifetime without duplicates")
        expect(renewal.copy(renewal.entries[0], to: board), "Copying a valid history card must succeed")
        clock = start.addingTimeInterval(48 * 60 * 60)
        expect(renewal.removeExpiredEntries() == 0, "Copying a history card must renew its lifetime")
        clock = start.addingTimeInterval(54 * 60 * 60)
        expect(renewal.removeExpiredEntries() == 1, "Renewed content must expire after one full day")

        clock = start
        let startupFolder = directory.appendingPathComponent("Startup")
        let startup = ClipboardStore(storageDirectory: startupFolder, shouldMonitor: false, now: { clock })
        startup.recordText("关闭应用期间到期的内容")
        board.clearContents()
        board.setData(samplePNG(), forType: NSPasteboard.PasteboardType("public.png"))
        startup.capture(from: board)
        let startupImageURL = startup.imageURL(for: startup.entries[0])!
        clock = start.addingTimeInterval(ClipboardRetention.oneDay.interval)
        let resumed = ClipboardStore(storageDirectory: startupFolder, shouldMonitor: false, now: { clock })
        expect(resumed.entries.isEmpty && !FileManager.default.fileExists(atPath: startupImageURL.path),
               "Startup must clean content that expired while the app was closed")
        let persisted = try! JSONDecoder().decode([ClipboardEntry].self, from: Data(contentsOf: startupFolder.appendingPathComponent("history.json")))
        expect(persisted.isEmpty, "Startup cleanup must also update the saved history")

        try! Data("{\"retentionDays\":2}".utf8).write(to: startupFolder.appendingPathComponent("settings.json"))
        let invalid = ClipboardStore(storageDirectory: startupFolder, shouldMonitor: false, now: { clock })
        expect(invalid.retention == .oneDay, "Unsupported saved settings must fall back to one day")
        print("LocalPaste retention self-test passed: 1/3/5/7 days, exact expiry, pins, image cleanup, original files, pause, persistence, setting changes, renewal, startup")
    }

    @MainActor
    private static func runSizingSelfTest() {
        let visible = NSRect(x: -1920, y: 40, width: 1920, height: 1040)
        let available = ShelfPanelSizing.availableFrame(on: visible)
        let frame = ShelfPanelSizing.presentationFrame(on: visible, preferredSize: NSSize(width: 900, height: 500))
        expect(frame.size == NSSize(width: 900, height: 500) && frame.midX == available.midX && frame.minY == available.minY,
               "Remembered size must stay centered on the active screen")
        let large = ShelfPanelSizing.presentationFrame(on: visible, preferredSize: NSSize(width: 5000, height: 5000))
        expect(large == available, "Oversized preferences must fit a smaller screen")
        let invalid = ShelfPanelSizing.presentationFrame(on: visible, preferredSize: NSSize(width: CGFloat.nan, height: -1))
        expect(invalid.width == available.width && invalid.height == ShelfPanelSizing.defaultSize.height,
               "Invalid preferences must fall back safely")
        let compactScreen = NSRect(x: 0, y: 0, width: 600, height: 340)
        expect(ShelfPanelSizing.presentationFrame(on: compactScreen, preferredSize: nil) == ShelfPanelSizing.availableFrame(on: compactScreen),
               "Small displays must remain usable")
        let minimum = ShelfPanelSizing.resizedFrame(frame, translation: NSPoint(x: -2000, y: -2000),
                                                    edges: [.right, .top], visibleFrame: visible)
        expect(minimum.size == ShelfPanelSizing.minimumSize && minimum.origin == frame.origin,
               "Resizing must preserve the opposite corner and minimum size")
        let maximum = ShelfPanelSizing.resizedFrame(frame, translation: NSPoint(x: 5000, y: 5000),
                                                    edges: [.right, .top], visibleFrame: visible)
        expect(maximum.maxX == available.maxX && maximum.maxY == available.maxY,
               "Resize gestures must stay within the screen")
        let left = ShelfPanelSizing.resizedFrame(frame, translation: NSPoint(x: 5000, y: 0), edges: .left, visibleFrame: visible)
        expect(left.width == ShelfPanelSizing.minimumSize.width && left.maxX == frame.maxX,
               "Left-edge resizing must keep the right edge fixed")
        let bottom = ShelfPanelSizing.resizedFrame(frame, translation: NSPoint(x: 0, y: 5000), edges: .bottom, visibleFrame: visible)
        expect(bottom.height == ShelfPanelSizing.minimumSize.height && bottom.maxY == frame.maxY,
               "Bottom-edge resizing must keep the top edge fixed")

        let directory = temporaryDirectory("SizingTest")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(storageDirectory: directory, shouldMonitor: false)
        for index in 1..<8 { store.createBoard(named: "较长的固定分组\(index)") }
        store.recordText(String(repeating: "调整尺寸后仍可浏览内容。", count: 45))
        var resizeCompletions = 0
        let controller = ClipboardShelfController(store: store, previewMode: true, onCopy: {}, onResizeEnd: { resizeCompletions += 1 })
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: ClipboardShelfController.panelSize),
                              styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let all = descendants(controller.view)
        let overlay = all.compactMap { $0 as? ShelfResizeOverlay }.first!
        let searchField = all.compactMap { $0 as? NSSearchField }.first!
        for retention in ClipboardRetention.allCases {
            let menu = controller.makeSettingsMenu()
            let retentionMenu = menu.items.first { $0.title.hasPrefix("历史保留时间：") }!.submenu!
            let choices = retentionMenu.items.filter { ClipboardRetention(rawValue: $0.tag) != nil }
            expect(choices.map(\.tag) == [1, 3, 5, 7], "The settings menu must expose every requested retention option")
            expect(choices.first(where: { $0.tag == store.retention.rawValue })?.state == .on,
                   "The menu must mark the active retention setting")
            let item = choices.first { $0.tag == retention.rawValue }!
            expect(NSApp.sendAction(item.action!, to: item.target, from: item) && store.retention == retention,
                   "Choosing a menu item must update retention")
        }
        store.setRetention(.oneDay)
        for size in [NSSize(width: 640, height: 352), NSSize(width: 800, height: 440),
                     NSSize(width: 1200, height: 352), NSSize(width: 1000, height: 620)] {
            for searching in [false, true] {
                if searching { window.makeFirstResponder(searchField) }
                else { window.makeFirstResponder(controller.view) }
                window.setContentSize(size)
                window.contentView?.layoutSubtreeIfNeeded()
                for _ in 0..<3 { controller.view.layoutSubtreeIfNeeded() }
                expect(controller.view.bounds.size == size, "Content must follow window dimensions: requested \(size), actual \(controller.view.bounds.size), window \(window.frame)")
                for button in all.compactMap({ $0 as? NSButton }).filter({
                    ["新建固定分组", "筛选内容类型", "设置与管理"].contains($0.toolTip ?? "") || $0.title == "剪贴板"
                }) {
                    let rect = button.convert(button.bounds, to: controller.view)
                    expect(controller.view.bounds.insetBy(dx: -1, dy: -1).contains(rect), "Toolbar controls must fit at every size")
                    expect(overlay.hitTest(NSPoint(x: rect.midX, y: rect.midY)) == nil, "Resize handles must not steal toolbar clicks")
                }
                expect(!searchField.isHidden && controller.view.bounds.contains(searchField.convert(searchField.bounds, to: controller.view)),
                       "Search must remain visible and accessible in compact layouts")
                expect(overlay.hitTest(NSPoint(x: size.width / 2, y: size.height / 2)) == nil,
                       "The card area must remain interactive")
                expect(overlay.hitTest(NSPoint(x: size.width - 20, y: 20)) === overlay,
                       "The visible corner grip must receive resize gestures")
                let card = descendants(controller.view).first { $0.identifier?.rawValue.hasPrefix("clipboard-card-") == true }!
                expect(abs(card.frame.height - max(220, size.height - 124)) <= 1,
                       "Cards must use the additional height instead of leaving a blank panel")
                for button in descendants(card).compactMap({ $0 as? NSButton }) {
                    expect(card.bounds.contains(button.convert(button.bounds, to: card)), "Card actions must stay inside the card")
                }
            }
        }
        if let screen = NSScreen.main {
            let initial = ShelfPanelSizing.presentationFrame(on: screen.visibleFrame, preferredSize: NSSize(width: 800, height: 400))
            window.setFrame(initial, display: false)
            controller.view.layoutSubtreeIfNeeded()
            let location = NSPoint(x: initial.width / 2, y: initial.height - 3)
            func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            overlay.mouseDown(with: event(.leftMouseDown, at: location))
            overlay.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: location.x, y: location.y + 40)))
            overlay.mouseUp(with: event(.leftMouseUp, at: location))
            let expected = ShelfPanelSizing.resizedFrame(initial, translation: NSPoint(x: 0, y: 40), edges: .top, visibleFrame: screen.visibleFrame)
            let actual = window.frame
            let matches = abs(actual.minX - expected.minX) <= 1 && abs(actual.minY - expected.minY) <= 1 &&
                abs(actual.width - expected.width) <= 1 && abs(actual.height - expected.height) <= 1
            expect(matches && resizeCompletions == 1,
                   "A drag must resize the actual window and finish once: initial \(initial), actual \(window.frame), expected \(expected), callbacks \(resizeCompletions), overlay \(overlay.bounds)")
        }
        print("LocalPaste UI self-test passed: screen limits, minimum size, responsive toolbar, search, hit testing, resize gestures")
    }

    @MainActor
    private static func runInteractionSelfTest() {
        let directory = temporaryDirectory("InteractionTest")
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(storageDirectory: directory, shouldMonitor: false)
        let fullText = String(repeating: "完整预览保留所有文字和换行。\n", count: 100)
        store.recordText(fullText)
        var closes = 0
        var appliedPresets: [ShelfPanelPreset] = []
        let controller = ClipboardShelfController(store: store, previewMode: true, onCopy: {},
                                                  onClose: { closes += 1 }, onApplyPreset: { appliedPresets.append($0) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                              styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { controller.prepareForDismissal(); window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let search = descendants(controller.view).compactMap { $0 as? NSSearchField }.first!
        func key(_ code: UInt16, text: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: text,
                             charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        }
        controller.focusInput()
        expect(window.firstResponder === controller.view, "Opening an empty search must allow card arrow keys and Space")
        controller.view.keyDown(with: key(0, text: "a"))
        expect(search.currentEditor()?.string == "a", "Typing from cards must hand the initiating key to the native search editor")
        search.stringValue = ""
        expect(controller.view.performKeyEquivalent(with: key(3, text: "f", modifiers: .command)), "Command-F must reach the search field")
        let editor = search.currentEditor() as! NSTextView
        expect(!controller.control(search, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))) &&
               !controller.control(search, textView: editor, doCommandBy: #selector(NSResponder.moveRight(_:))),
               "Search must preserve native text caret navigation")
        editor.insertText("hello world", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        expect(editor.string == "hello world", "Spaces must remain ordinary text while searching")
        search.stringValue = "missing"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        expect(!descendants(controller.view).contains { $0.identifier?.rawValue.hasPrefix("clipboard-card-") == true },
               "Search must show an empty state for unmatched content")
        expect(controller.control(search, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))), "Search must handle Escape")
        expect(search.stringValue.isEmpty && closes == 0, "First Escape must clear the query without closing the shelf")
        search.stringValue = "完整预览"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        window.makeFirstResponder(search)
        let searchEditor = search.currentEditor() as! NSTextView
        expect(controller.control(search, textView: searchEditor, doCommandBy: #selector(NSResponder.moveDown(_:))) &&
               window.firstResponder === controller.view && search.stringValue == "完整预览",
               "Down must move focus to matching cards while preserving the search query")
        controller.view.keyDown(with: key(49, text: " "))
        let preview = window.childWindows!.first!
        expect(preview.identifier?.rawValue == "clipboard-content-preview", "Space must open a child preview")
        preview.contentView?.layoutSubtreeIfNeeded()
        let textView = descendants(preview.contentView!).compactMap { $0 as? NSTextView }.first!
        expect(textView.string == fullText && !textView.isEditable && textView.isSelectable,
               "Preview must show the full selectable text without editing history")
        let oldWidth = textView.frame.width
        preview.setContentSize(NSSize(width: 700, height: 500))
        preview.contentView?.layoutSubtreeIfNeeded()
        expect(textView.frame.width > oldWidth, "Full text must reflow when preview is resized")
        preview.cancelOperation(nil)
        expect(window.childWindows?.isEmpty != false && closes == 0, "Escape must close only the preview first")
        controller.view.keyDown(with: key(53))
        expect(search.stringValue.isEmpty && closes == 0, "Escape after a filtered preview must clear search next")
        controller.view.keyDown(with: key(53))
        expect(closes == 1, "Escape must close the shelf after preview and search are cleared")

        let sizeMenu = controller.makeSettingsMenu().items.first { $0.title == "面板尺寸" }!.submenu!
        for item in sizeMenu.items where item.representedObject is String {
            expect(NSApp.sendAction(item.action!, to: item.target, from: item), "Size presets must be usable as menu actions")
        }
        expect(appliedPresets == ShelfPanelPreset.allCases, "All three size presets must invoke the sizing callback")
        let previewButton = descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.toolTip == "预览完整内容" }!
        previewButton.performClick(nil)
        expect(window.childWindows?.count == 1, "The visible preview button must open a preview")
        controller.prepareForDismissal()
        expect(window.childWindows?.isEmpty != false, "Closing the shelf must also close the preview")
        previewButton.performClick(nil)
        store.remove(store.entries[0])
        controller.prepareForPresentation()
        expect(window.childWindows?.isEmpty != false, "Deleting a previewed entry must close its preview")

        let file = directory.appendingPathComponent("原文件.txt")
        try! Data("示例文件".utf8).write(to: file)
        board.clearContents()
        board.writeObjects([file as NSURL])
        store.capture(from: board)
        let filePreview = ContentPreviewController(entry: store.entries[0], store: store, onCopy: {}, onClose: {})
        filePreview.show(on: window)
        let fileWindow = window.childWindows!.first!
        fileWindow.contentView?.layoutSubtreeIfNeeded()
        expect(descendants(fileWindow.contentView!).compactMap { $0 as? NSTextView }.first?.string == file.path,
               "File previews must show the original path without opening files")
        filePreview.close()
        board.clearContents()
        board.setData(samplePNG(), forType: NSPasteboard.PasteboardType("public.png"))
        store.capture(from: board)
        let imagePreview = ContentPreviewController(entry: store.entries[0], store: store, onCopy: {}, onClose: {})
        imagePreview.show(on: window)
        let imageWindow = window.childWindows!.first!
        imageWindow.contentView?.layoutSubtreeIfNeeded()
        let image = descendants(imageWindow.contentView!).compactMap { $0 as? NSImageView }.first!
        expect(image.image != nil && image.bounds.width > 0 && image.bounds.height > 0, "Image previews must have visible content")
        imagePreview.close()
        let emptyBoard = store.createBoard(named: "空分组")!
        controller.prepareForPresentation()
        let groupMenu = controller.makeSettingsMenu().items.first { $0.title == "切换分组" }!.submenu!
        let groupItem = groupMenu.items.first { ($0.representedObject as? UUID) == emptyBoard.id }!
        expect(NSApp.sendAction(groupItem.action!, to: groupItem.target, from: groupItem) &&
               !descendants(controller.view).contains { $0.identifier?.rawValue.hasPrefix("clipboard-card-") == true },
               "Every group must be reachable through a menu even when tabs are clipped")
        let allItem = groupMenu.items[0]
        expect(NSApp.sendAction(allItem.action!, to: allItem.target, from: allItem) &&
               descendants(controller.view).contains { $0.identifier?.rawValue.hasPrefix("clipboard-card-") == true },
               "The group menu must return to all clipboard history")
        print("LocalPaste interaction self-test passed: persistent search, caret and spaces, layered Escape, full text/image/file preview, cleanup, size presets")
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
        var size = ClipboardShelfController.panelSize
        if let index = CommandLine.arguments.firstIndex(of: "--size"), CommandLine.arguments.count > index + 2,
           let width = Double(CommandLine.arguments[index + 1]), let height = Double(CommandLine.arguments[index + 2]),
           width.isFinite, height.isFinite, width >= ShelfPanelSizing.minimumSize.width, height >= ShelfPanelSizing.minimumSize.height {
            size = NSSize(width: width, height: height)
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        if CommandLine.arguments.contains("--dark") {
            window.appearance = NSAppearance(named: .darkAqua)
        } else {
            window.appearance = NSAppearance(named: .aqua)
        }
        window.contentViewController = controller
        window.setContentSize(size)
        window.contentView?.layoutSubtreeIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        var renderView = controller.view
        var contentPreview: ContentPreviewController?
        if let index = CommandLine.arguments.firstIndex(of: "--preview-content"), CommandLine.arguments.count > index + 1 {
            let kind = CommandLine.arguments[index + 1]
            let entry = store.entries.first {
                kind == "image" ? $0.kind == .image : kind == "files" ? $0.kind == .files :
                    kind == "link" ? $0.linkURL != nil : $0.kind == .text && $0.linkURL == nil
            }!
            let preview = ContentPreviewController(entry: entry, store: store, onCopy: {}, onClose: {})
            contentPreview = preview
            preview.show(on: window)
            renderView = window.childWindows!.first!.contentView!
            renderView.layoutSubtreeIfNeeded()
            renderView.window?.displayIfNeeded()
        }
        defer { contentPreview?.close() }
        if CommandLine.arguments.contains("--layout") { reportLayout(renderView) }
        guard let bitmap = renderView.bitmapImageRepForCachingDisplay(in: renderView.bounds) else {
            fatalError("Cannot create preview bitmap")
        }
        renderView.cacheDisplay(in: renderView.bounds, to: bitmap)
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
        if let text = view as? NSTextView { print("Text preview: \(text.frame), \(text.string.count) characters") }
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
