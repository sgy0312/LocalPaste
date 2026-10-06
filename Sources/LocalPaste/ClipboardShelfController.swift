import AppKit
import Combine
import Foundation
import QuartzCore

private enum ShelfGeometry {
    static let cardWidth: CGFloat = 236
    static let cardHeight: CGFloat = 224
    static let gap: CGFloat = 20
    static let cardRadius: CGFloat = 26
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
    private let onCopy: () -> Void
    private let onClose: () -> Void
    private let onResizeEnd: () -> Void
    private let onResetSize: () -> Void
    private let previewMode: Bool
    private let searchField = NSSearchField()
    private let searchButton = ShelfIconButton()
    private let historyButton = NSButton()
    private let tabs = NSStackView()
    private let tabScroll = NSScrollView()
    private var tabWidth: NSLayoutConstraint!
    private var searchWidth: NSLayoutConstraint!
    private var tabDocumentWidth: CGFloat = 108
    private let typeButton = ShelfIconButton()
    private let menuButton = ShelfIconButton()
    private let statusLabel = ShelfTextField(labelWithString: "")
    private let privacyLabel = ShelfTextField(labelWithString: "")
    private let countLabel = ShelfTextField(labelWithString: "")
    private let keyboardHint = ShelfTextField(labelWithString: "← → 选择   回车复制   esc 关闭")
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
    private var searchVisible = false
    private var showWelcome: Bool
    private var observation: AnyCancellable?

    init(store: ClipboardStore, previewMode: Bool = false, onCopy: @escaping () -> Void,
         onClose: @escaping () -> Void = {}, onResizeEnd: @escaping () -> Void = {}, onResetSize: @escaping () -> Void = {}) {
        self.store = store
        self.previewMode = previewMode
        self.onCopy = onCopy
        self.onClose = onClose
        self.onResizeEnd = onResizeEnd
        self.onResetSize = onResetSize
        self.showWelcome = previewMode || !UserDefaults.standard.bool(forKey: "LocalPaste.welcomeDismissed")
        super.init(nibName: nil, bundle: nil)
        observation = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = ClipboardShelfBackdrop(frame: NSRect(origin: .zero, size: Self.panelSize))
        root.autoresizingMask = [.width, .height]
        root.isPreview = previewMode
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 34
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.14).cgColor
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
        root.addSubview(resize)
        view = root
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

    func focusInput() { view.window?.makeFirstResponder(searchVisible ? searchField : view) }

    func prepareForPresentation() {
        store.removeExpiredEntries()
        refresh()
        cards.forEach { $0.refreshTimestamp() }
    }

    func controlTextDidChange(_ notification: Notification) {
        selectedID = nil
        rebuildHistory()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): copySelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): onClose(); return true
        case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
        default: return false
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: onClose()
        case 36, 76: copySelected()
        case 123, 126: moveSelection(-1)
        case 124, 125: moveSelection(1)
        default:
            guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
                  let text = event.characters, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  !text.isEmpty else { return false }
            if !searchVisible { toggleSearch() }
            searchField.stringValue += text
            selectedID = nil
            rebuildHistory()
        }
        return true
    }

    private func makeToolbar() -> NSView {
        let container = fixedHeight(64)
        configureIcon(searchButton, symbol: "magnifyingglass", help: "搜索剪贴板", action: #selector(toggleSearch))
        configureTab(historyButton, title: "剪贴板", symbol: "clock.arrow.circlepath", action: #selector(showHistory))
        searchField.placeholderString = "搜索内容或来源应用"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(copySelected)
        searchField.sendsSearchStringImmediately = true
        searchField.controlSize = .small
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchWidth = searchField.widthAnchor.constraint(equalToConstant: 190)
        searchWidth.isActive = true
        searchField.isHidden = true

        tabs.orientation = .horizontal
        tabs.alignment = .centerY
        tabs.spacing = 10
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
        configureIcon(menuButton, symbol: "ellipsis.circle", help: "设置与管理", action: #selector(showSettingsMenu))
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(menuButton)
        let center = NSStackView(views: [searchButton, searchField, historyButton, tabScroll, add, typeButton])
        center.orientation = .horizontal
        center.alignment = .centerY
        center.spacing = 10
        center.detachesHiddenViews = true
        center.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(center)
        let centering = center.centerXAnchor.constraint(equalTo: container.centerXAnchor)
        centering.priority = .defaultHigh
        NSLayoutConstraint.activate([
            centering,
            center.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            center.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            center.trailingAnchor.constraint(lessThanOrEqualTo: menuButton.leadingAnchor, constant: -16),
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
        welcome.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.035).cgColor
        NSLayoutConstraint.activate([
            welcome.widthAnchor.constraint(equalToConstant: 184),
            welcome.heightAnchor.constraint(equalToConstant: ShelfGeometry.cardHeight)
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
        icon.contentTintColor = .secondaryLabelColor
        let title = label("只在这台 Mac", size: 13, weight: .semibold)
        let body = ShelfTextField(wrappingLabelWithString: "复制过的内容，随时找回。\n\n点击卡片复制，\n再按 ⌘V 粘贴。")
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
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
        let container = fixedHeight(34)
        privacyLabel.font = .systemFont(ofSize: 10)
        privacyLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = .systemFont(ofSize: 10)
        countLabel.textColor = .secondaryLabelColor
        keyboardHint.font = .systemFont(ofSize: 10)
        keyboardHint.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [privacyLabel, statusLabel, NSView(), countLabel, keyboardHint])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.detachesHiddenViews = true
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -44),
            row.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    private func refresh() {
        guard isViewLoaded else { return }
        if knownBoards != store.boards { rebuildTabs() }
        styleTab(historyButton, selected: selectedBoardID == nil)
        for (index, button) in boardButtons.enumerated() {
            styleTab(button, selected: store.boards[index].id == selectedBoardID)
        }
        statusLabel.stringValue = store.notice ?? (store.isPaused ? "记录已暂停" : "输入即可搜索")
        privacyLabel.stringValue = "●  仅存本机 · 保留 \(store.retention.title)"
        typeButton.contentTintColor = selectedType == 0 ? .secondaryLabelColor : .systemBlue
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
            x += width + 10
        }
        let width = max(1, x - 10)
        tabs.frame = NSRect(x: 0, y: 0, width: width, height: 38)
        tabDocumentWidth = width
        updateResponsiveChrome()
        knownBoards = store.boards
    }

    private func updateResponsiveChrome() {
        guard isViewLoaded, tabWidth != nil, searchWidth != nil else { return }
        let width = view.bounds.width
        let search = min(190, max(160, width - 480))
        if searchWidth.constant != search { searchWidth.constant = search }
        // Leave space for the fixed controls, gaps, and the menu at the right edge.
        let fixedWidth: CGFloat = 232 + (searchVisible ? search + 10 : 0)
        let availableTabs = max(1, width - 84 - fixedWidth)
        let tabsWidth = min(tabDocumentWidth, searchVisible ? 260 : 440, availableTabs)
        if tabWidth.constant != tabsWidth { tabWidth.constant = tabsWidth }
        welcome.isHidden = !showWelcome || width < 880
        keyboardHint.isHidden = width < 780
    }

    private func rebuildHistory() {
        guard isViewLoaded else { return }
        let scrollX = scrollView.contentView.bounds.origin.x
        let nextEntries = filteredEntries()
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
            if !searchField.stringValue.isEmpty { message = "没有找到匹配内容，试试其他关键词" }
            else if selectedBoardID != nil { message = "右键点击卡片，把常用内容加入这个分组" }
            else if selectedType != 0 { message = "复制这类内容后，会自动出现在这里" }
            else { message = "从下一次复制开始，文字、链接、图片和文件都会保存在这里" }
            let empty = label(message, size: 13, color: .secondaryLabelColor)
            empty.alignment = .center
            empty.frame = NSRect(x: 10, y: max(10, stripSize.height / 2 - 10), width: max(300, stripSize.width - 20), height: 24)
            strip.addSubview(empty)
        } else {
            for entry in visibleEntries {
                let card = ClipboardShelfCard(entry: entry, store: store, animationsEnabled: !previewMode) { [weak self] in
                    guard let self else { return }
                    self.selectedID = entry.id
                    if self.store.copy(entry) { self.onCopy() }
                }
                strip.addSubview(card)
                cards.append(card)
            }
        }
        layoutHistory(preserving: scrollX)
        countLabel.stringValue = "\(visibleEntries.count) 条"
        updateSelection()
    }

    private func layoutHistory(preserving scrollX: CGFloat) {
        let height = max(ShelfGeometry.cardHeight, stripSize.height - 30)
        let width = min(340, ShelfGeometry.cardWidth + (height - ShelfGeometry.cardHeight) * 0.25)
        let gap = ShelfGeometry.gap
        let y = max(14, (stripSize.height - height) / 2)
        for (index, card) in cards.enumerated() {
            let frame = NSRect(x: 14 + CGFloat(index) * (width + gap), y: y, width: width, height: height)
            if card.frame != frame { card.frame = frame }
        }
        let extent = 28 + CGFloat(cards.count) * width + CGFloat(max(0, cards.count - 1)) * gap
        let documentWidth = max(stripSize.width, extent)
        strip.frame = NSRect(x: 0, y: 0, width: max(1, documentWidth), height: max(height + 28, stripSize.height))
        scrollView.contentView.scroll(to: NSPoint(x: max(0, min(scrollX, documentWidth - stripSize.width)), y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func filteredEntries() -> [ClipboardEntry] {
        let entries: [ClipboardEntry]
        if let board = store.boards.first(where: { $0.id == selectedBoardID }) { entries = store.entries(in: board) }
        else { entries = store.entries }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            switch selectedType {
            case 1: if entry.kind != .text || entry.linkURL != nil { return false }
            case 2: if entry.linkURL == nil { return false }
            case 3: if entry.kind != .image { return false }
            case 4: if entry.kind != .files { return false }
            default: break
            }
            return query.isEmpty || entry.preview.localizedCaseInsensitiveContains(query) ||
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
        if store.copy(entry) { onCopy() }
    }

    @objc private func toggleSearch() {
        searchVisible.toggle()
        searchField.isHidden = !searchVisible
        if !searchVisible { searchField.stringValue = ""; selectedID = nil }
        updateResponsiveChrome()
        view.layoutSubtreeIfNeeded()
        rebuildHistory()
        focusInput()
    }

    @objc private func showHistory() { selectedBoardID = nil; selectedID = nil; refresh(); resetScroll() }
    @objc private func selectBoard(_ sender: NSButton) {
        selectedBoardID = store.boards[sender.tag].id
        selectedID = nil
        refresh()
        resetScroll()
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
        addItem(menu, "新建固定分组…", #selector(createBoard))
        addItem(menu, "恢复默认大小", #selector(resetPanelSize))
        addItem(menu, "清空历史…", #selector(confirmClear))
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
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        button.toolTip = help
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 16
        button.layer?.cornerCurve = .continuous
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 32), button.heightAnchor.constraint(equalToConstant: 32)])
    }
    private func configureTab(_ button: NSButton, title: String, symbol: String, action: Selector) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 17
        button.layer?.cornerCurve = .continuous
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        if button === historyButton { button.widthAnchor.constraint(equalToConstant: 96).isActive = true }
    }
    private func styleTab(_ button: NSButton, selected: Bool) {
        button.contentTintColor = .labelColor
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            ShelfMotion.update(button.layer, values: [
                "backgroundColor": (selected ? NSColor.systemBlue.withAlphaComponent(0.10) : .clear).cgColor,
                "borderColor": (selected ? NSColor.systemBlue.withAlphaComponent(0.12) : .clear).cgColor,
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

private final class ClipboardShelfBackdrop: NSVisualEffectView {
    var isPreview = false
    var keyHandler: ((NSEvent) -> Bool)?
    var layoutHandler: (() -> Void)?
    override func layout() { super.layout(); layoutHandler?() }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isPreview {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
        }
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
                "backgroundColor": (hovered ? NSColor.labelColor.withAlphaComponent(0.065) : .clear).cgColor
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
    private let animationsEnabled: Bool
    private let headerLabel = ShelfTextField(labelWithString: "")
    private var bodyLabel: NSTextField?
    private var tracking: NSTrackingArea?
    private var isHovered = false
    var isSelected = false { didSet { if isSelected != oldValue { updateColors(animated: true) } } }

    init(entry: ClipboardEntry, store: ClipboardStore, animationsEnabled: Bool, onCopy: @escaping () -> Void) {
        self.entry = entry
        self.store = store
        self.onCopy = onCopy
        self.animationsEnabled = animationsEnabled
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("clipboard-card-\(entry.id)")
        wantsLayer = true
        layer?.cornerRadius = ShelfGeometry.cardRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        toolTip = "点击复制；右键可固定到分组或删除"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(entry.typeName)，\(String(entry.preview.prefix(120)))，点击复制")
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
            let lines = max(7, Int((bounds.height - 110) / 16))
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
            let base = NSColor.controlBackgroundColor
            let background = isSelected ? (base.blended(withFraction: 0.035, of: .systemBlue) ?? base) : base
            let border = isSelected ? NSColor.systemBlue.withAlphaComponent(0.68)
                : isHovered ? NSColor.systemBlue.withAlphaComponent(0.25) : NSColor.separatorColor.withAlphaComponent(0.12)
            ShelfMotion.update(layer, values: [
                "backgroundColor": background.withAlphaComponent(isHovered || isSelected ? 0.97 : 0.90).cgColor,
                "borderColor": border.cgColor,
                "borderWidth": isSelected ? 1.5 : 0.75,
                "shadowOpacity": isSelected || isHovered ? 0.13 : 0.065,
                "shadowRadius": isSelected || isHovered ? 14.0 : 9.0
            ], animated: animated && animationsEnabled)
        }
    }

    func refreshTimestamp() {
        headerLabel.stringValue = "\(entry.typeName)  \(relativeDate(entry.createdAt))"
    }

    private func buildContent() {
        let header = headerLabel
        refreshTimestamp()
        header.font = .systemFont(ofSize: 11, weight: .medium)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingTail
        let source = NSImageView(image: sourceIcon())
        source.imageScaling = .scaleProportionallyDown
        source.toolTip = entry.sourceApplication
        let pin = NSButton(image: NSImage(systemSymbolName: entry.isPinned ? "pin.fill" : "pin", accessibilityDescription: "固定内容") ?? NSImage(), target: self, action: #selector(togglePin))
        pin.isBordered = false
        pin.contentTintColor = entry.isPinned ? .systemRed : .tertiaryLabelColor
        pin.toolTip = entry.isPinned ? "取消固定" : "固定到常用内容"
        let metadata = ShelfTextField(labelWithString: detailText())
        metadata.font = .systemFont(ofSize: 10)
        metadata.textColor = .secondaryLabelColor
        metadata.lineBreakMode = .byTruncatingTail
        for child in [header, source, pin, metadata] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            header.heightAnchor.constraint(equalToConstant: 14),
            header.trailingAnchor.constraint(equalTo: source.leadingAnchor, constant: -8),
            source.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -17),
            source.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            source.widthAnchor.constraint(equalToConstant: 16), source.heightAnchor.constraint(equalToConstant: 16),
            pin.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
            pin.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
            pin.widthAnchor.constraint(equalToConstant: 22), pin.heightAnchor.constraint(equalToConstant: 22),
            metadata.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            metadata.trailingAnchor.constraint(equalTo: pin.leadingAnchor, constant: -8),
            metadata.centerYAnchor.constraint(equalTo: pin.centerYAnchor)
        ])
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 15),
            content.bottomAnchor.constraint(equalTo: metadata.topAnchor, constant: -12)
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
            name.font = .systemFont(ofSize: 12, weight: .medium)
            name.maximumNumberOfLines = 3
            name.lineBreakMode = .byTruncatingTail
            for child in [icon, name] { child.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(child) }
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 3),
                icon.widthAnchor.constraint(equalToConstant: 54), icon.heightAnchor.constraint(equalToConstant: 54),
                name.leadingAnchor.constraint(equalTo: content.leadingAnchor), name.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                name.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 13)
            ])
        } else {
            let text = NSTextField(wrappingLabelWithString: String((entry.linkURL?.host ?? entry.preview).prefix(650)))
            text.font = .systemFont(ofSize: entry.linkURL != nil ? 17 : 13, weight: entry.linkURL != nil ? .semibold : .regular)
            text.maximumNumberOfLines = entry.linkURL == nil ? 7 : 2
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
                let url = ShelfTextField(wrappingLabelWithString: String(entry.preview.prefix(300)))
                url.font = .systemFont(ofSize: 11)
                url.textColor = .secondaryLabelColor
                url.maximumNumberOfLines = 4
                url.lineBreakMode = .byTruncatingTail
                url.translatesAutoresizingMaskIntoConstraints = false
                content.addSubview(url)
                NSLayoutConstraint.activate([
                    url.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                    url.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                    url.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 12),
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
        switch entry.kind {
        case .text: return entry.linkURL != nil ? "链接 · 点击复制" : "\(entry.text?.count ?? 0) 个字"
        case .image: return "图片 · 点击复制"
        case .files: return "\(entry.fileURLs?.count ?? 0) 个文件 · 原文件位置"
        }
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
}
