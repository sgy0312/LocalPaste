import AppKit
import Combine
import Foundation
import QuartzCore

private enum ShelfGeometry {
    static let panelRadius: CGFloat = 28
    static let cardRadius: CGFloat = ShelfCardLayout.cornerRadius
    static let gap: CGFloat = ShelfCardLayout.gap

    static let materialMask: NSImage = {
        let radius = panelRadius
        let size = NSSize(width: radius * 2 + 1, height: radius * 2 + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }()
}

private enum ShelfMotion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func update(_ layer: CALayer?, values: [String: Any], animated: Bool) {
        guard let layer else { return }
        var starting: [String: Any] = [:]
        for key in values.keys {
            starting[key] = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (key, value) in values { layer.setValue(value, forKeyPath: key) }
        CATransaction.commit()
        guard animated, !reduced, layer.superlayer != nil else { return }
        for (key, value) in values {
            guard let start = starting[key] else { continue }
            let transition = CABasicAnimation(keyPath: key)
            transition.fromValue = start
            transition.toValue = value
            transition.duration = 0.16
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(transition, forKey: key)
        }
    }
}

@MainActor
final class ClipboardShelfController: NSViewController, NSSearchFieldDelegate {
    static let panelSize = ShelfPanelSizing.defaultSize
    private let store: ClipboardStore
    private let copyPasteboard: NSPasteboard
    private let onCopy: () -> Void
    private let onClose: () -> Void
    private let onResizeEnd: () -> Void
    private let onResizeStart: () -> Void
    private let onResetSize: () -> Void
    private let onApplyPreset: (ShelfPanelPreset) -> Void
    private let previewMode: Bool
    private let searchField = NSSearchField()
    private let historyButton = NSButton()
    private let tabs = NSStackView()
    private let tabScroll = NSScrollView()
    private var tabWidth: NSLayoutConstraint!
    private var searchWidth: NSLayoutConstraint!
    private var tabDocumentWidth: CGFloat = 108
    private let typeButton = ShelfIconButton()
    private let menuButton = ShelfIconButton()
    private let typeFilterChip = NSButton()
    private let statusLabel = ShelfTextField(labelWithString: "")
    private let countLabel = ShelfTextField(labelWithString: "")
    private let scrollView = HorizontalHistoryScrollView()
    private let strip = ClipboardStripView()
    private let welcome = NSView()
    private var cards: [ClipboardShelfCard] = []
    private var visibleEntries: [ClipboardEntry] = []
    private var selectedID: UUID?
    private var selectedBoardID: UUID?
    private var selectedType = 0
    private var boardButtons: [NSButton] = []
    private var knownBoards: [ClipboardBoard] = []
    private var renderedBoards: [ClipboardBoard] = []
    private var stripSize = NSSize.zero
    private var previewController: ContentPreviewController?
    private var showWelcome: Bool
    private var observation: AnyCancellable?
    private var accessibilityObserver: NSObjectProtocol?

    init(store: ClipboardStore, previewMode: Bool = false, onCopy: @escaping () -> Void,
         onClose: @escaping () -> Void = {}, onResizeEnd: @escaping () -> Void = {},
         onResetSize: @escaping () -> Void = {}, onApplyPreset: @escaping (ShelfPanelPreset) -> Void = { _ in },
         onResizeStart: @escaping () -> Void = {}, copyPasteboard: NSPasteboard = .general) {
        self.store = store
        self.copyPasteboard = copyPasteboard
        self.previewMode = previewMode
        self.onCopy = onCopy
        self.onClose = onClose
        self.onResizeEnd = onResizeEnd
        self.onResizeStart = onResizeStart
        self.onResetSize = onResetSize
        self.onApplyPreset = onApplyPreset
        self.showWelcome = previewMode || !UserDefaults.standard.bool(forKey: "LocalPaste.welcomeDismissed")
        super.init(nibName: nil, bundle: nil)
        observation = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    override func loadView() {
        let root = ClipboardShelfBackdrop(frame: NSRect(origin: .zero, size: Self.panelSize))
        root.autoresizingMask = [.width, .height]
        root.isPreview = previewMode
        root.glassCornerRadius = ShelfGeometry.panelRadius
        root.material = ShelfGlass.panelMaterial
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = ShelfGeometry.panelRadius
        root.layer?.cornerCurve = .circular
        root.maskImage = ShelfGeometry.materialMask
        root.layer?.backgroundColor = NSColor.clear.cgColor
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = ShelfGlass.panelBorder().cgColor
        root.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        root.layoutHandler = { [weak self] in self?.layoutContents() }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        stack.addArrangedSubview(makeToolbar())
        stack.addArrangedSubview(makeHistory())
        stack.addArrangedSubview(makeFooter())
        let resize = ShelfResizeOverlay(frame: root.bounds)
        resize.autoresizingMask = [.width, .height]
        resize.onResizeEnd = onResizeEnd
        resize.onResizeStart = onResizeStart
        root.addSubview(resize)
        view = root
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.accessibilityOptionsChanged() }
        }
        refresh()
    }

    @objc private func accessibilityOptionsChanged() {
        guard isViewLoaded else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            welcome.layer?.backgroundColor = ShelfGlass.welcomeFill().cgColor
        }
        cards.forEach { $0.refreshAppearance() }
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusInput()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutContents()
    }

    private func layoutContents() {
        updateResponsiveChrome()
        scrollView.layoutSubtreeIfNeeded()
        let size = scrollView.contentSize
        if size.width > 0 && size.height > 0 && size != stripSize { rebuildHistory() }
    }

    func focusInput() {
        view.window?.makeFirstResponder(searchField.stringValue.isEmpty ? view : searchField)
    }

    func prepareForDismissal() { closePreview(restoringFocus: false) }

    func prepareForPresentation() {
        store.removeExpiredEntries()
        refresh()
        cards.forEach { $0.refreshTimestamp() }
    }

    func controlTextDidChange(_ notification: Notification) {
        selectedID = nil
        refresh()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): focusResultsFromSearch(); return true
        case #selector(NSResponder.insertTab(_:)): focusResultsFromSearch(); return true
        case #selector(NSResponder.cancelOperation(_:)): handleEscape(); return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1); view.window?.makeFirstResponder(view); return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1); view.window?.makeFirstResponder(view); return true
        default: return false
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "f" {
            view.window?.makeFirstResponder(searchField)
            return true
        }
        if event.keyCode == 53, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) {
            handleEscape()
            return true
        }
        // Search editors and native buttons retain their own keyboard behavior.
        guard view.window?.firstResponder === view else { return false }
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command {
            switch event.keyCode {
            case 123: cycleBoard(-1); return true
            case 124: cycleBoard(1); return true
            default: break
            }
        }
        guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) else { return false }
        switch event.keyCode {
        case 36, 76: copySelected()
        case 48: view.window?.makeFirstResponder(searchField)
        case 123, 126: moveSelection(-1)
        case 124, 125: moveSelection(1)
        case 49: showPreview()
        default:
            guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
                  let text = event.characters, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  !text.isEmpty else { return false }
            view.window?.makeFirstResponder(searchField)
            guard let editor = searchField.currentEditor() as? NSTextView else { return false }
            editor.setSelectedRange(NSRange(location: (searchField.stringValue as NSString).length, length: 0))
            // Let the native editor process the initiating key, including input methods.
            editor.keyDown(with: event)
        }
        return true
    }

    private func makeToolbar() -> NSView {
        let container = fixedHeight(56)
        configureTab(historyButton, title: "剪贴板", symbol: "clock.arrow.circlepath", action: #selector(showHistory))
        searchField.placeholderString = "搜索内容、文件名或应用"
        searchField.setAccessibilityLabel("搜索剪贴板")
        searchField.toolTip = "搜索内容、文件名或来源应用（⌘F）"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(focusResultsFromSearch)
        searchField.sendsSearchStringImmediately = true
        searchField.controlSize = .regular
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchWidth = searchField.widthAnchor.constraint(equalToConstant: 220)
        searchWidth.isActive = true

        tabs.orientation = .horizontal
        tabs.alignment = .centerY
        tabs.spacing = 8
        tabScroll.drawsBackground = false
        tabScroll.borderType = .noBorder
        tabScroll.hasHorizontalScroller = false
        tabScroll.documentView = tabs
        tabScroll.translatesAutoresizingMaskIntoConstraints = false
        tabWidth = tabScroll.widthAnchor.constraint(equalToConstant: 108)
        tabWidth.priority = .defaultLow
        NSLayoutConstraint.activate([tabWidth, tabScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 1),
                                     tabScroll.heightAnchor.constraint(equalToConstant: 38)])

        let add = ShelfIconButton()
        configureIcon(add, symbol: "plus", help: "新建固定分组", action: #selector(createBoard))
        configureIcon(typeButton, symbol: "line.3.horizontal.decrease", help: "筛选内容类型", action: #selector(showTypeMenu))
        configureIcon(menuButton, symbol: "gearshape", help: "设置", action: #selector(showSettingsMenu))
        menuButton.identifier = NSUserInterfaceItemIdentifier("clipboard-settings")
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(menuButton)
        let center = NSStackView(views: [searchField, historyButton, tabScroll, add, typeButton])
        center.orientation = .horizontal
        center.alignment = .centerY
        center.spacing = 8
        center.detachesHiddenViews = true
        center.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(center)
        let centering = center.centerXAnchor.constraint(equalTo: container.centerXAnchor)
        centering.priority = .defaultHigh
        NSLayoutConstraint.activate([
            centering,
            center.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            center.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            center.trailingAnchor.constraint(lessThanOrEqualTo: menuButton.leadingAnchor, constant: -12),
            menuButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            menuButton.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    private func makeHistory() -> NSView {
        let container = NSView()
        let row = NSStackView(views: [welcome, scrollView])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.detachesHiddenViews = true
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        welcome.translatesAutoresizingMaskIntoConstraints = false
        welcome.wantsLayer = true
        welcome.layer?.cornerRadius = ShelfGeometry.cardRadius
        welcome.layer?.cornerCurve = .continuous
        welcome.layer?.backgroundColor = ShelfGlass.welcomeFill().cgColor
        NSLayoutConstraint.activate([
            welcome.widthAnchor.constraint(equalToConstant: 184),
            welcome.heightAnchor.constraint(equalToConstant: 162)
        ])
        buildWelcome()
        welcome.isHidden = !showWelcome
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = strip
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.heightAnchor.constraint(equalTo: row.heightAnchor)
        ])
        return container
    }

    private func buildWelcome() {
        let icon = NSImageView(image: NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = ShelfColors.secondaryText
        let title = label("只在这台 Mac", size: 13, weight: .semibold)
        let body = ShelfTextField(wrappingLabelWithString: "找回复制过的内容。\n点击卡片复制，\n再按 ⌘V 粘贴。")
        body.font = .systemFont(ofSize: 12)
        body.textColor = ShelfColors.secondaryText
        body.maximumNumberOfLines = 6
        let shortcut = label("⌘⇧V  随时呼出", size: 11, weight: .medium, color: .systemBlue)
        let close = ShelfIconButton()
        configureIcon(close, symbol: "xmark", help: "关闭使用提示", action: #selector(dismissWelcome))
        for child in [icon, title, body, shortcut, close] {
            child.translatesAutoresizingMaskIntoConstraints = false
            welcome.addSubview(child)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: welcome.leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: welcome.topAnchor, constant: 16),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            close.trailingAnchor.constraint(equalTo: welcome.trailingAnchor, constant: -7),
            close.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: icon.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: welcome.trailingAnchor, constant: -12),
            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 14),
            body.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 9),
            shortcut.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            shortcut.bottomAnchor.constraint(equalTo: welcome.bottomAnchor, constant: -17)
        ])
    }

    private func makeFooter() -> NSView {
        let container = fixedHeight(30)
        statusLabel.identifier = NSUserInterfaceItemIdentifier("clipboard-status")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = ShelfColors.secondaryText
        statusLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = ShelfColors.secondaryText
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        typeFilterChip.identifier = NSUserInterfaceItemIdentifier("clipboard-type-filter-chip")
        typeFilterChip.bezelStyle = .rounded
        typeFilterChip.controlSize = .small
        typeFilterChip.font = .systemFont(ofSize: 11, weight: .medium)
        typeFilterChip.contentTintColor = .systemBlue
        typeFilterChip.target = self
        typeFilterChip.action = #selector(clearTypeFilter)
        typeFilterChip.focusRingType = .exterior
        typeFilterChip.isHidden = true
        typeFilterChip.setContentCompressionResistancePriority(.required, for: .horizontal)
        typeFilterChip.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [statusLabel, typeFilterChip, NSView(), countLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.detachesHiddenViews = true
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -44),
            row.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    private func refresh() {
        guard isViewLoaded else { return }
        if knownBoards != store.boards { rebuildTabs() }
        let searching = !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        styleTab(historyButton, selected: !searching && selectedBoardID == nil)
        for (index, button) in boardButtons.enumerated() {
            styleTab(button, selected: !searching && store.boards[index].id == selectedBoardID)
        }
        let typeTitle = ["全部类型", "文字", "链接", "图片", "文件"][selectedType]
        typeButton.contentTintColor = selectedType == 0 ? ShelfColors.secondaryText : .systemBlue
        typeButton.toolTip = selectedType == 0 ? "筛选内容类型" : "筛选内容类型：\(typeTitle) · 点击底部 × 清除"
        typeButton.setAccessibilityValue(typeTitle)
        typeFilterChip.isHidden = selectedType == 0
        typeFilterChip.title = "\(typeTitle) ×"
        typeFilterChip.toolTip = "清除\(typeTitle)筛选，保留关键词和分组"
        typeFilterChip.setAccessibilityLabel("清除类型筛选：\(typeTitle)")
        if let notice = store.notice { statusLabel.stringValue = notice }
        else if store.isPaused { statusLabel.stringValue = "记录已暂停" }
        else if searching { statusLabel.stringValue = "搜索全部内容" }
        else { statusLabel.stringValue = "" }
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
        statusLabel.toolTip = statusLabel.stringValue
        rebuildHistory()
    }

    private func rebuildTabs() {
        tabs.arrangedSubviews.forEach { tabs.removeArrangedSubview($0); $0.removeFromSuperview() }
        boardButtons.removeAll()
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemBlue, .systemPurple, .systemGreen]
        var x: CGFloat = 0
        for (index, board) in store.boards.enumerated() {
            let button = NSButton()
            configureTab(button, title: board.name, symbol: "circle.fill", action: #selector(selectBoard(_:)))
            button.tag = index
            button.image?.isTemplate = false
            let colored = NSImage(size: NSSize(width: 10, height: 10))
            colored.lockFocus()
            colors[index % colors.count].setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 8, height: 8)).fill()
            colored.unlockFocus()
            button.image = colored
            let width = max(88, button.intrinsicContentSize.width + 14)
            button.widthAnchor.constraint(equalToConstant: width).isActive = true
            tabs.addArrangedSubview(button)
            boardButtons.append(button)
            x += width + 8
        }
        let width = max(1, x - 8)
        tabs.frame = NSRect(x: 0, y: 0, width: width, height: 38)
        tabDocumentWidth = width
        updateResponsiveChrome()
        knownBoards = store.boards
    }

    private func updateResponsiveChrome() {
        guard isViewLoaded, tabWidth != nil, searchWidth != nil else { return }
        let width = view.bounds.width
        let search = min(240, max(180, width - 460))
        if searchWidth.constant != search { searchWidth.constant = search }
        // Leave space for the fixed controls, gaps, and the menu at the right edge.
        let fixedWidth: CGFloat = 200 + search
        let availableTabs = max(1, width - 84 - fixedWidth)
        let tabsWidth = min(tabDocumentWidth, 420, availableTabs)
        if tabWidth.constant != tabsWidth { tabWidth.constant = tabsWidth }
        welcome.isHidden = !showWelcome || width < 900 || view.bounds.height <= 260
    }

    private func rebuildHistory() {
        guard isViewLoaded else { return }
        let scrollX = scrollView.contentView.bounds.origin.x
        let nextEntries = filteredEntries()
        if let previewController, !store.entries.contains(where: { $0.id == previewController.entryID }) {
            closePreview()
        }
        stripSize = scrollView.contentSize
        if nextEntries == visibleEntries, renderedBoards == store.boards, !cards.isEmpty {
            if !visibleEntries.contains(where: { $0.id == selectedID }) { selectedID = visibleEntries.first?.id }
            layoutHistory(preserving: scrollX)
            updateSelection()
            return
        }
        strip.subviews.forEach { $0.removeFromSuperview() }
        cards.removeAll()
        visibleEntries = nextEntries
        renderedBoards = store.boards
        if !visibleEntries.contains(where: { $0.id == selectedID }) { selectedID = visibleEntries.first?.id }
        if visibleEntries.isEmpty {
            let message: String
            if !searchField.stringValue.isEmpty { message = "没有找到匹配内容\n试试其他关键词，或按 Esc 清除搜索" }
            else if selectedBoardID != nil { message = "这个分组还没有内容\n右键点击卡片，将常用内容固定到这里" }
            else if selectedType != 0 { message = "还没有这类内容\n复制后会自动出现在这里，或选择全部类型" }
            else if store.isPaused { message = "记录已暂停\n在设置中恢复后，继续保存新复制的内容" }
            else { message = "还没有剪贴板内容\n复制文字、链接、图片或文件后，随时回来找" }
            let empty = label(message, size: 13, color: ShelfColors.secondaryText)
            empty.alignment = .center
            empty.maximumNumberOfLines = 2
            empty.frame = NSRect(x: 10, y: max(10, stripSize.height / 2 - 22), width: max(300, stripSize.width - 20), height: 44)
            strip.addSubview(empty)
        } else {
            for entry in visibleEntries {
                let card = ClipboardShelfCard(entry: entry, store: store, animationsEnabled: !previewMode, onCopy: { [weak self] in
                    guard let self else { return }
                    self.selectedID = entry.id
                    if self.store.copy(entry, to: self.copyPasteboard) { self.onCopy() }
                }, onPreview: { [weak self] in
                    guard let self else { return }
                    self.selectedID = entry.id
                    self.updateSelection()
                    self.showPreview()
                })
                strip.addSubview(card)
                cards.append(card)
            }
        }
        layoutHistory(preserving: scrollX)
        countLabel.stringValue = "\(visibleEntries.count) 条"
        updateSelection()
    }

    private func layoutHistory(preserving scrollX: CGFloat) {
        let cardSize = ShelfCardLayout.cardSize(in: stripSize.height)
        let height = cardSize.height
        let width = cardSize.width
        let gap = ShelfCardLayout.gap
        let y = max(8, (stripSize.height - height) / 2)
        for (index, card) in cards.enumerated() {
            let frame = NSRect(x: 12 + CGFloat(index) * (width + gap), y: y, width: width, height: height)
            if card.frame != frame { card.frame = frame }
        }
        let extent = 24 + CGFloat(cards.count) * width + CGFloat(max(0, cards.count - 1)) * gap
        let documentWidth = max(stripSize.width, extent)
        strip.frame = NSRect(x: 0, y: 0, width: max(1, documentWidth), height: max(height + 16, stripSize.height))
        scrollView.contentView.scroll(to: NSPoint(x: max(0, min(scrollX, documentWidth - stripSize.width)), y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func filteredEntries() -> [ClipboardEntry] {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries: [ClipboardEntry]
        if !query.isEmpty { entries = store.entries }
        else if let board = store.boards.first(where: { $0.id == selectedBoardID }) { entries = store.entries(in: board) }
        else { entries = store.entries }
        return entries.filter { entry in
            switch selectedType {
            case 1: if entry.kind != .text || entry.linkURL != nil { return false }
            case 2: if entry.linkURL == nil { return false }
            case 3: if entry.kind != .image { return false }
            case 4: if entry.kind != .files { return false }
            default: break
            }
            return query.isEmpty || entry.preview.localizedCaseInsensitiveContains(query) ||
                (entry.linkDisplayName?.localizedCaseInsensitiveContains(query) ?? false) ||
                (entry.sourceApplication?.localizedCaseInsensitiveContains(query) ?? false) ||
                (entry.fileURLs?.contains { $0.localizedCaseInsensitiveContains(query) } ?? false)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private func updateSelection() {
        for (index, card) in cards.enumerated() { card.isSelected = visibleEntries[index].id == selectedID }
    }

    private func moveSelection(_ step: Int) {
        guard !visibleEntries.isEmpty else { return }
        let current = visibleEntries.firstIndex { $0.id == selectedID } ?? 0
        let next = max(0, min(visibleEntries.count - 1, current + step))
        selectedID = visibleEntries[next].id
        updateSelection()
        let clip = scrollView.contentView
        let target = cards[next].frame.insetBy(dx: -14, dy: 0)
        var x = clip.bounds.minX
        if target.minX < clip.bounds.minX { x = target.minX }
        else if target.maxX > clip.bounds.maxX { x = target.maxX - clip.bounds.width }
        x = max(0, min(x, strip.frame.width - clip.bounds.width))
        guard abs(x - clip.bounds.minX) > 0.5 else { return }
        if ShelfMotion.reduced {
            clip.scroll(to: NSPoint(x: x, y: 0))
            scrollView.reflectScrolledClipView(clip)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(NSPoint(x: x, y: 0))
            } completionHandler: { [weak self] in
                guard let self else { return }
                self.scrollView.reflectScrolledClipView(clip)
            }
        }
    }

    @objc private func copySelected() {
        guard let entry = visibleEntries.first(where: { $0.id == selectedID }) ?? visibleEntries.first else { return }
        if store.copy(entry, to: copyPasteboard) { onCopy() }
    }

    @objc private func focusResultsFromSearch() {
        guard !visibleEntries.isEmpty else { return }
        if !visibleEntries.contains(where: { $0.id == selectedID }) { selectedID = visibleEntries.first?.id }
        updateSelection()
        view.window?.makeFirstResponder(view)
    }

    @objc private func clearTypeFilter() {
        selectedType = 0
        selectedID = nil
        refresh()
        resetScroll()
        focusInput()
    }

    private func cycleBoard(_ step: Int) {
        let boards = store.boards
        let count = 1 + boards.count
        let current = selectedBoardID.flatMap { id in boards.firstIndex(where: { $0.id == id }) }.map { $0 + 1 } ?? 0
        let next = (current + step + count) % count
        selectedBoardID = next == 0 ? nil : boards[next - 1].id
        searchField.stringValue = ""
        selectedID = nil
        refresh()
        resetScroll()
        scrollSelectedTabIntoView()
    }

    private func scrollSelectedTabIntoView() {
        if selectedBoardID == nil {
            tabScroll.contentView.scroll(to: .zero)
        } else if let index = store.boards.firstIndex(where: { $0.id == selectedBoardID }), index < boardButtons.count {
            view.layoutSubtreeIfNeeded()
            let target = boardButtons[index]
            let clip = tabScroll.contentView
            let frame = target.convert(target.bounds, to: tabs)
            var x = clip.bounds.minX
            if frame.minX < clip.bounds.minX { x = frame.minX }
            else if frame.maxX > clip.bounds.maxX { x = frame.maxX - clip.bounds.width }
            x = max(0, min(x, tabs.bounds.width - clip.bounds.width))
            clip.scroll(to: NSPoint(x: x, y: 0))
        }
        tabScroll.reflectScrolledClipView(tabScroll.contentView)
    }

    @objc private func showHistory() {
        selectedBoardID = nil
        searchField.stringValue = ""
        selectedID = nil
        refresh()
        resetScroll()
        scrollSelectedTabIntoView()
        focusInput()
    }
    @objc private func selectBoard(_ sender: NSButton) {
        selectedBoardID = store.boards[sender.tag].id
        searchField.stringValue = ""
        selectedID = nil
        refresh()
        resetScroll()
        scrollSelectedTabIntoView()
        focusInput()
    }
    private func resetScroll() {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func dismissWelcome() {
        showWelcome = false
        if !previewMode { UserDefaults.standard.set(true, forKey: "LocalPaste.welcomeDismissed") }
        welcome.isHidden = true
        view.layoutSubtreeIfNeeded()
        rebuildHistory()
    }

    @objc private func createBoard() {
        let alert = NSAlert()
        alert.messageText = "新建固定分组"
        alert.informativeText = "例如“实用链接”或“常用回复”。名称最多 12 个字。"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 26))
        input.placeholderString = "分组名称"
        alert.accessoryView = input
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = input
        if alert.runModal() == .alertFirstButtonReturn, let board = store.createBoard(named: input.stringValue) {
            selectedBoardID = board.id
            selectedID = nil
        }
        refresh()
        focusInput()
    }

    @objc private func showTypeMenu() {
        let menu = NSMenu()
        for (index, title) in ["全部类型", "文字", "链接", "图片", "文件"].enumerated() {
            let item = menu.addItem(withTitle: title, action: #selector(selectType(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = selectedType == index ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: typeButton.bounds.minY), in: typeButton)
    }
    @objc private func selectType(_ sender: NSMenuItem) {
        selectedType = sender.tag
        selectedID = nil
        refresh()
        resetScroll()
    }

    @objc private func showSettingsMenu() {
        let menu = makeSettingsMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: menuButton.bounds.minY), in: menuButton)
    }

    func makeSettingsMenu() -> NSMenu {
        let menu = NSMenu()
        let title = menu.addItem(withTitle: "本地剪贴板 · 仅存本机", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(.separator())
        addItem(menu, store.isPaused ? "恢复记录" : "暂停记录", #selector(togglePause))
        let retentionItem = menu.addItem(withTitle: "历史保留时间：\(store.retention.title)", action: nil, keyEquivalent: "")
        let retentionMenu = NSMenu(title: "历史保留时间")
        for value in ClipboardRetention.allCases {
            let item = retentionMenu.addItem(withTitle: value == .oneDay ? "1 天（默认）" : value.title,
                                            action: #selector(selectRetention(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value.rawValue
            item.state = store.retention == value ? .on : .off
        }
        retentionMenu.addItem(.separator())
        retentionMenu.addItem(withTitle: "固定内容继续保留", action: nil, keyEquivalent: "").isEnabled = false
        retentionItem.submenu = retentionMenu
        let sizeItem = menu.addItem(withTitle: "面板尺寸", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu(title: "面板尺寸")
        for preset in ShelfPanelPreset.allCases {
            let item = sizeMenu.addItem(withTitle: preset.title, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
        }
        sizeMenu.addItem(.separator())
        addItem(sizeMenu, "恢复默认大小", #selector(resetPanelSize))
        sizeItem.submenu = sizeMenu
        let boardItem = menu.addItem(withTitle: "切换分组", action: nil, keyEquivalent: "")
        let boardMenu = NSMenu(title: "切换分组")
        let history = boardMenu.addItem(withTitle: "全部剪贴板", action: #selector(showHistory), keyEquivalent: "")
        history.target = self
        history.state = selectedBoardID == nil ? .on : .off
        for board in store.boards {
            let item = boardMenu.addItem(withTitle: board.name, action: #selector(selectBoardFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = board.id
            item.state = selectedBoardID == board.id ? .on : .off
        }
        boardItem.submenu = boardMenu
        addItem(menu, "新建固定分组…", #selector(createBoard))
        addItem(menu, "清空历史…", #selector(confirmClear))
        let helpItem = menu.addItem(withTitle: "使用帮助", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "使用帮助")
        for hint in ["⌘⇧V 呼出或关闭面板", "点击卡片复制 · 空格预览", "⌘F 搜索 · 回车选中结果，再回车复制",
                     "方向键选择 · ⌘← ⌘→ 切换分组", "右键卡片可预览、固定与删除", "Esc 依次关闭预览、搜索、面板"] {
            helpMenu.addItem(withTitle: hint, action: nil, keyEquivalent: "").isEnabled = false
        }
        helpItem.submenu = helpMenu
        menu.addItem(.separator())
        addItem(menu, "退出本地剪贴板", #selector(quitApp))
        return menu
    }
    @objc private func togglePause() { store.togglePaused() }
    @objc private func selectRetention(_ sender: NSMenuItem) {
        if let value = ClipboardRetention(rawValue: sender.tag) { store.setRetention(value) }
        refresh()
    }
    @objc private func resetPanelSize() { onResetSize() }
    @objc private func selectBoardFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        selectedBoardID = id
        searchField.stringValue = ""
        selectedID = nil
        refresh()
        resetScroll()
        scrollSelectedTabIntoView()
        focusInput()
    }
    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let preset = ShelfPanelPreset(rawValue: raw) else { return }
        onApplyPreset(preset)
    }

    private func handleEscape() {
        if previewController != nil { closePreview() }
        else if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            selectedID = nil
            refresh()
            resetScroll()
            view.window?.makeFirstResponder(view)
        } else { onClose() }
    }

    private func showPreview() {
        guard let entry = visibleEntries.first(where: { $0.id == selectedID }) ?? visibleEntries.first else { return }
        if previewController?.entryID == entry.id { closePreview(); return }
        closePreview(restoringFocus: false)
        let preview = ContentPreviewController(entry: entry, store: store, onCopy: { [weak self] in
            guard let self else { return }
            self.closePreview(restoringFocus: false)
            self.onCopy()
        }, onClose: { [weak self] in
            self?.closePreview()
        }, copyPasteboard: copyPasteboard)
        previewController = preview
        preview.show(on: view.window)
    }

    private func closePreview(restoringFocus: Bool = true) {
        previewController?.close()
        previewController = nil
        if restoringFocus, view.window?.isVisible == true {
            view.window?.makeKey()
            focusInput()
        }
    }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func confirmClear() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清空全部历史？"
        alert.informativeText = "这会删除本机保存的所有记录和图片，包括分组中的固定内容。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "清空")
        if alert.runModal() == .alertSecondButtonReturn { store.clearHistory() }
        focusInput()
    }

    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
    }
    private func fixedHeight(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }
    private func configureIcon(_ button: NSButton, symbol: String, help: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = ShelfColors.secondaryText
        button.target = self
        button.action = action
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.focusRingType = .exterior
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 14
        button.layer?.cornerCurve = .continuous
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 32), button.heightAnchor.constraint(equalToConstant: 32)])
    }
    private func configureTab(_ button: NSButton, title: String, symbol: String, action: Selector) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 16
        button.layer?.cornerCurve = .continuous
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        if button === historyButton { button.widthAnchor.constraint(equalToConstant: 96).isActive = true }
    }
    private func styleTab(_ button: NSButton, selected: Bool) {
        button.setAccessibilityValue(selected ? "已选中" : "未选中")
        button.contentTintColor = .labelColor
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            ShelfMotion.update(button.layer, values: [
                "backgroundColor": ShelfGlass.tabFill(selected: selected).cgColor,
                "borderColor": ShelfGlass.tabBorder(selected: selected).cgColor,
                "borderWidth": 1
            ], animated: !previewMode)
        }
    }
    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = ShelfTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }
}

private final class ClipboardShelfBackdrop: ShelfGlassBackground {
    var keyHandler: ((NSEvent) -> Bool)?
    var layoutHandler: (() -> Void)?
    override func layout() { super.layout(); layoutHandler?() }
    override var acceptsFirstResponder: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "f" {
            return keyHandler?(event) ?? false
        }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }
}

private final class ClipboardStripView: NSView {
    override var isFlipped: Bool { true }
}

private final class ShelfTextField: NSTextField {
    override var allowsVibrancy: Bool { false }
}

private final class ShelfIconButton: NSButton {
    private var hoverTracking: NSTrackingArea?

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ hovered: Bool) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ShelfMotion.update(layer, values: [
                "backgroundColor": (hovered ? ShelfGlass.iconHoverFill() : .clear).cgColor
            ], animated: true)
        }
    }
}

private final class RoundedThumbnailView: NSView {
    private let image: NSImage

    init(image: NSImage) { self.image = image; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let destination = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                 width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(roundedRect: destination, xRadius: 14, yRadius: 14).addClip()
        image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}

private final class HorizontalHistoryScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 16
            let maximum = max(0, (documentView?.frame.width ?? 0) - contentSize.width)
            let x = max(0, min(maximum, contentView.bounds.origin.x - event.scrollingDeltaY * scale))
            if event.hasPreciseScrollingDeltas || ShelfMotion.reduced {
                contentView.scroll(to: NSPoint(x: x, y: 0))
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.14
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    contentView.animator().setBoundsOrigin(NSPoint(x: x, y: 0))
                }
            }
            reflectScrolledClipView(contentView)
        } else { super.scrollWheel(with: event) }
    }
}

@MainActor
private final class ClipboardShelfCard: NSView {
    private let entry: ClipboardEntry
    private let store: ClipboardStore
    private let onCopy: () -> Void
    private let onPreview: () -> Void
    private let animationsEnabled: Bool
    private let headerLabel = ShelfTextField(labelWithString: "")
    private var bodyLabel: NSTextField?
    private var contentRegion: NSView?
    private var tracking: NSTrackingArea?
    private var isHovered = false
    var isSelected = false {
        didSet {
            if isSelected != oldValue { updateColors(animated: true) }
            setAccessibilityValue((isSelected ? "已选中" : "未选中") + (entry.isPinned ? "，已固定" : ""))
        }
    }

    init(entry: ClipboardEntry, store: ClipboardStore, animationsEnabled: Bool,
         onCopy: @escaping () -> Void, onPreview: @escaping () -> Void) {
        self.entry = entry
        self.store = store
        self.onCopy = onCopy
        self.onPreview = onPreview
        self.animationsEnabled = animationsEnabled
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("clipboard-card-\(entry.id)")
        wantsLayer = true
        layer?.cornerRadius = ShelfGeometry.cardRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        let sourcePrefix = entry.sourceApplication.map { "来自 \($0) · " } ?? ""
        toolTip = "\(sourcePrefix)点击复制 · 空格预览 · 右键可预览、固定到分组或删除"
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        let sourceSuffix = entry.sourceApplication.map { "，来自 \($0)" } ?? ""
        setAccessibilityLabel("\(entry.typeName)\(sourceSuffix)\(entry.isPinned ? "，已固定" : "")，\(String(entry.preview.prefix(120)))，点击复制，空格预览")
        buildContent()
        buildMenu()
        updateColors(animated: false)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors(animated: false) }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: ShelfGeometry.cardRadius,
                                  cornerHeight: ShelfGeometry.cardRadius, transform: nil)
        CATransaction.commit()
        if let bodyLabel, entry.linkURL == nil {
            let lines = max(2, Int((contentRegion?.bounds.height ?? 0) / 16))
            if bodyLabel.maximumNumberOfLines != lines { bodyLabel.maximumNumberOfLines = lines }
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true; updateColors(animated: true) }
    override func mouseExited(with event: NSEvent) { isHovered = false; updateColors(animated: true) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onCopy() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let target = super.hitTest(point) else { return nil }
        return target is NSButton ? target : self
    }
    override func accessibilityPerformPress() -> Bool { onCopy(); return true }

    private func updateColors(animated: Bool) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ShelfMotion.update(layer, values: [
                "backgroundColor": ShelfGlass.cardFill(selected: isSelected, hovered: isHovered).cgColor,
                "borderColor": ShelfGlass.cardBorder(selected: isSelected, hovered: isHovered).cgColor,
                "borderWidth": isSelected ? 2.0 : 0.75,
                "shadowOpacity": isSelected || isHovered ? 0.16 : 0.09,
                "shadowRadius": isSelected || isHovered ? 12.0 : 8.0
            ], animated: animated && animationsEnabled)
        }
    }

    func refreshTimestamp() {
        headerLabel.stringValue = "\(entry.typeName)  \(relativeDate(entry.createdAt))"
        headerLabel.toolTip = headerLabel.stringValue
    }

    func refreshAppearance() { updateColors(animated: false) }

    private func buildContent() {
        let header = headerLabel
        refreshTimestamp()
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .labelColor
        header.lineBreakMode = .byTruncatingTail
        let source = NSImageView(image: sourceIcon())
        source.imageScaling = .scaleProportionallyDown
        source.toolTip = entry.sourceApplication
        var leadingIcon: NSView = source
        if entry.isPinned {
            let pin = NSImageView(image: NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "已固定") ?? NSImage())
            pin.imageScaling = .scaleProportionallyDown
            pin.contentTintColor = ShelfColors.secondaryText
            pin.setAccessibilityLabel("已固定")
            pin.toolTip = "已固定 · 右键可取消固定"
            pin.translatesAutoresizingMaskIntoConstraints = false
            addSubview(pin)
            leadingIcon = pin
        }
        let metadata = ShelfTextField(labelWithString: detailText())
        metadata.toolTip = detailText()
        metadata.font = .systemFont(ofSize: 11)
        metadata.textColor = ShelfColors.secondaryText
        metadata.lineBreakMode = .byTruncatingTail
        for child in [header, source, metadata] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        var constraints: [NSLayoutConstraint] = [
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            header.heightAnchor.constraint(equalToConstant: 14),
            header.trailingAnchor.constraint(equalTo: leadingIcon.leadingAnchor, constant: -8),
            source.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            source.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            source.widthAnchor.constraint(equalToConstant: 16), source.heightAnchor.constraint(equalToConstant: 16),
            metadata.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            metadata.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            metadata.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ]
        if leadingIcon !== source {
            constraints.append(contentsOf: [
                leadingIcon.trailingAnchor.constraint(equalTo: source.leadingAnchor, constant: -6),
                leadingIcon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                leadingIcon.widthAnchor.constraint(equalToConstant: 14), leadingIcon.heightAnchor.constraint(equalToConstant: 14)
            ])
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "预览内容", target: self, selector: #selector(accessibilityPreviewEntry)),
            NSAccessibilityCustomAction(name: entry.isPinned ? "取消固定" : "固定到常用内容", target: self, selector: #selector(accessibilityTogglePin))
        ])
        let content = NSView()
        contentRegion = content
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: metadata.topAnchor, constant: -6)
        ])
        if entry.kind == .image {
            let image = RoundedThumbnailView(image: store.thumbnail(for: entry) ?? NSImage())
            image.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(image)
            fill(image, in: content)
        } else if entry.kind == .files {
            let url = entry.fileURLs?.first.flatMap(URL.init(string:))
            let icon = NSImageView(image: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage())
            icon.imageScaling = .scaleProportionallyDown
            let name = NSTextField(wrappingLabelWithString: String(entry.preview.prefix(200)))
            name.font = .systemFont(ofSize: 13, weight: .medium)
            name.textColor = .labelColor
            name.maximumNumberOfLines = 2
            name.lineBreakMode = .byTruncatingTail
            for child in [icon, name] { child.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(child) }
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                icon.topAnchor.constraint(equalTo: content.topAnchor),
                icon.widthAnchor.constraint(equalToConstant: 24), icon.heightAnchor.constraint(equalToConstant: 24),
                name.leadingAnchor.constraint(equalTo: content.leadingAnchor), name.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                name.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
                name.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor)
            ])
        } else {
            let linkTitle = entry.linkDisplayName ?? entry.linkURL?.host ?? entry.preview
            let text = NSTextField(wrappingLabelWithString: String(linkTitle.prefix(650)))
            text.font = .systemFont(ofSize: entry.linkURL != nil ? 14 : 13, weight: entry.linkURL != nil ? .semibold : .regular)
            text.textColor = .labelColor
            text.maximumNumberOfLines = entry.linkURL == nil ? 3 : 1
            bodyLabel = text
            text.lineBreakMode = .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(text)
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                text.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                text.topAnchor.constraint(equalTo: content.topAnchor),
                text.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor)
            ])
            if entry.linkURL != nil {
                let url = ShelfTextField(wrappingLabelWithString: String((entry.linkURL?.absoluteString ?? entry.preview).prefix(300)))
                url.font = .systemFont(ofSize: 12)
                url.textColor = ShelfColors.secondaryText
                url.maximumNumberOfLines = 1
                url.lineBreakMode = .byTruncatingTail
                url.translatesAutoresizingMaskIntoConstraints = false
                content.addSubview(url)
                NSLayoutConstraint.activate([
                    url.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                    url.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                    url.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 6),
                    url.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor)
                ])
            }
        }
    }

    private func sourceIcon() -> NSImage {
        if let source = entry.sourceApplication,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == source }),
           let icon = app.icon { return icon }
        return NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil) ?? NSImage()
    }
    private func detailText() -> String {
        let summary: String
        switch entry.kind {
        case .text: summary = entry.linkURL != nil ? "链接" : "\(entry.text?.count ?? 0) 个字"
        case .image: summary = "图片"
        case .files: summary = "\(entry.fileURLs?.count ?? 0) 个文件 · 原文件位置"
        }
        if let source = entry.sourceApplication, !source.isEmpty { return "\(source) · \(summary)" }
        return summary
    }
    private func relativeDate(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "刚刚" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    private func fill(_ child: NSView, in parent: NSView) {
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor), child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor), child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }
    private func buildMenu() {
        let menu = NSMenu()
        let copy = menu.addItem(withTitle: "复制", action: #selector(copyEntry), keyEquivalent: "")
        copy.target = self
        let preview = menu.addItem(withTitle: "预览内容", action: #selector(previewEntry), keyEquivalent: "")
        preview.target = self
        menu.addItem(.separator())
        for board in store.boards {
            let item = menu.addItem(withTitle: "固定到“\(board.name)”", action: #selector(pinToBoard(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = board
            item.state = entry.isPinned && (entry.boardID ?? store.boards.first?.id) == board.id ? .on : .off
        }
        if entry.isPinned {
            let item = menu.addItem(withTitle: "取消固定", action: #selector(togglePin), keyEquivalent: "")
            item.target = self
        }
        menu.addItem(.separator())
        let delete = menu.addItem(withTitle: "删除记录", action: #selector(deleteEntry), keyEquivalent: "")
        delete.target = self
        self.menu = menu
    }
    @objc private func pinToBoard(_ sender: NSMenuItem) {
        if let board = sender.representedObject as? ClipboardBoard { store.pin(entry, to: board) }
    }
    @objc private func togglePin() { store.togglePin(entry) }
    @objc private func deleteEntry() { store.remove(entry) }
    @objc private func copyEntry() { onCopy() }
    @objc private func previewEntry() { onPreview() }
    @objc private func accessibilityPreviewEntry() -> Bool { onPreview(); return true }
    @objc private func accessibilityTogglePin() -> Bool { store.togglePin(entry); return true }
}
