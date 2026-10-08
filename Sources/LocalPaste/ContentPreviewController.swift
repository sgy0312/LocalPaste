import AppKit

/// A local preview that never opens URLs or the original files.
@MainActor
final class ContentPreviewController: NSObject, NSWindowDelegate {
    let entryID: UUID
    private let entry: ClipboardEntry
    private let store: ClipboardStore
    private let onCopy: () -> Void
    private let onClose: () -> Void
    private var previewWindow: ClipboardPreviewPanel?
    private weak var parentWindow: NSWindow?

    init(entry: ClipboardEntry, store: ClipboardStore, onCopy: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.entryID = entry.id
        self.entry = entry
        self.store = store
        self.onCopy = onCopy
        self.onClose = onClose
        super.init()
    }

    func show(on parent: NSWindow?) {
        parentWindow = parent
        let visible = parent?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let size = NSSize(width: min(560, visible.width - 32), height: min(440, visible.height - 64))
        let frame = NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                           width: size.width, height: size.height)
        let window = ClipboardPreviewPanel(contentRect: frame, styleMask: [.titled, .closable, .resizable],
                                           backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("clipboard-content-preview")
        window.title = "\(entry.typeName) · 预览"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.minSize = NSSize(width: min(360, size.width), height: min(260, size.height))
        window.delegate = self
        window.onEscape = { [weak self] in self?.onClose() }
        window.contentView = makeContent(size: size)
        if let parent {
            window.appearance = parent.appearance
            parent.addChildWindow(window, ordered: .above)
        }
        previewWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let window = previewWindow else { return }
        previewWindow = nil
        parentWindow?.removeChildWindow(window)
        window.delegate = nil
        window.onEscape = nil
        window.close()
        parentWindow = nil
    }

    func windowWillClose(_ notification: Notification) {
        if let window = previewWindow { parentWindow?.removeChildWindow(window) }
        previewWindow = nil
        parentWindow = nil
        onClose()
    }

    @objc private func copyEntry() {
        if store.copy(entry) { onCopy() }
    }

    @objc private func closeEntry() { onClose() }

    private func makeContent(size: NSSize) -> NSView {
        let container = ContentPreviewBackground(frame: NSRect(origin: .zero, size: size))
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        let source = NSTextField(labelWithString: entry.sourceApplication ?? "仅存本机")
        source.font = .systemFont(ofSize: 12)
        source.textColor = ShelfColors.secondaryText
        source.lineBreakMode = .byTruncatingTail
        let close = NSButton(title: "关闭", target: self, action: #selector(closeEntry))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        let copy = NSButton(title: "复制", target: self, action: #selector(copyEntry))
        copy.bezelStyle = .rounded
        copy.keyEquivalent = "\r"
        for child in [source, close, copy] {
            child.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(child)
        }
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            footer.heightAnchor.constraint(equalToConstant: 32),
            source.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            source.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -12),
            source.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: copy.leadingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 64),
            copy.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            copy.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            copy.widthAnchor.constraint(equalToConstant: 64)
        ])

        let content: NSView
        if entry.kind == .image, let image = store.image(for: entry) {
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.setAccessibilityLabel("剪贴板图片预览")
            content = imageView
        } else {
            let scroll = NSScrollView()
            scroll.borderType = .noBorder
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: size.width - 40, height: size.height - 80))
            text.isEditable = false
            text.isSelectable = true
            text.isRichText = false
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.minSize = NSSize(width: 0, height: 0)
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.textContainer?.containerSize = NSSize(width: text.frame.width, height: .greatestFiniteMagnitude)
            text.textContainerInset = NSSize(width: 8, height: 8)
            text.font = .systemFont(ofSize: 14)
            text.textColor = .labelColor
            text.drawsBackground = false
            text.setAccessibilityLabel("剪贴板完整内容")
            if entry.kind == .files {
                text.string = (entry.fileURLs ?? []).map { URL(string: $0)?.path ?? $0 }.joined(separator: "\n\n")
            } else { text.string = entry.text ?? entry.preview }
            scroll.documentView = text
            text.layoutManager?.ensureLayout(for: text.textContainer!)
            content = scroll
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12)
        ])
        return container
    }
}

private final class ContentPreviewBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}

@MainActor
private final class ClipboardPreviewPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() }
        else { super.keyDown(with: event) }
    }
}
