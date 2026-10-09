import AppKit

struct ShelfResizeEdges: OptionSet {
    let rawValue: Int
    static let left = Self(rawValue: 1 << 0)
    static let right = Self(rawValue: 1 << 1)
    static let bottom = Self(rawValue: 1 << 2)
    static let top = Self(rawValue: 1 << 3)
}

enum ShelfPanelPreset: String, CaseIterable {
    case compact, standard, wide

    var title: String {
        switch self {
        case .compact: return "紧凑 · 640 × 240"
        case .standard: return "标准 · 900 × 240"
        case .wide: return "宽大 · 1200 × 240"
        }
    }

    var size: NSSize {
        switch self {
        case .compact: return NSSize(width: 640, height: 240)
        case .standard: return NSSize(width: 900, height: 240)
        case .wide: return NSSize(width: 1200, height: 240)
        }
    }
}

enum ShelfPanelSizing {
    static let defaultSize = NSSize(width: 1200, height: 240)
    static let minimumSize = NSSize(width: 640, height: 240)
    static let screenMargin: CGFloat = 16

    static func availableFrame(on visibleFrame: NSRect) -> NSRect {
        let marginX = min(screenMargin, max(0, (visibleFrame.width - 1) / 2))
        let marginY = min(screenMargin, max(0, (visibleFrame.height - 1) / 2))
        return visibleFrame.insetBy(dx: marginX, dy: marginY)
    }

    static func presentationFrame(on visibleFrame: NSRect, preferredSize: NSSize?) -> NSRect {
        let available = availableFrame(on: visibleFrame)
        let requested = preferredSize ?? NSSize(width: available.width, height: defaultSize.height)
        let width = fitted(requested.width, minimum: minimumSize.width, maximum: available.width,
                           fallback: available.width)
        let height = fitted(requested.height, minimum: minimumSize.height, maximum: available.height,
                            fallback: defaultSize.height)
        return NSRect(x: available.midX - width / 2, y: available.minY, width: width, height: height)
    }

    static func resizedFrame(_ initial: NSRect, translation: NSPoint, edges: ShelfResizeEdges,
                             visibleFrame: NSRect) -> NSRect {
        let available = availableFrame(on: visibleFrame)
        let minimumWidth = min(minimumSize.width, available.width)
        let minimumHeight = min(minimumSize.height, available.height)
        var left = initial.minX
        var right = initial.maxX
        var bottom = initial.minY
        var top = initial.maxY
        if edges.contains(.left) { left = max(available.minX, min(right - minimumWidth, left + translation.x)) }
        if edges.contains(.right) { right = min(available.maxX, max(left + minimumWidth, right + translation.x)) }
        if edges.contains(.bottom) { bottom = max(available.minY, min(top - minimumHeight, bottom + translation.y)) }
        if edges.contains(.top) { top = min(available.maxY, max(bottom + minimumHeight, top + translation.y)) }
        return NSRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }

    private static func fitted(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat, fallback: CGFloat) -> CGFloat {
        let valid = value.isFinite && value > 0 ? value : fallback
        return min(maximum, max(min(minimum, maximum), valid))
    }
}

enum ShelfCardLayout {
    static let cardWidth: CGFloat = 184
    static let cardHeight: CGFloat = 128
    static let gap: CGFloat = 11
    static let cornerRadius: CGFloat = 16

    static func cardSize(in stripHeight: CGFloat) -> NSSize {
        let available = max(80, stripHeight - 20)
        let height = min(cardHeight, available)
        let ratio = cardWidth / cardHeight
        let width = min(cardWidth, max(120, height * ratio))
        return NSSize(width: width, height: height)
    }
}

/// Only the thin perimeter receives resize gestures; the cards and controls remain interactive.
@MainActor
final class ShelfResizeOverlay: NSView {
    var onResizeStart: () -> Void = {}
    var onResizeEnd: () -> Void = {}
    private var edges: ShelfResizeEdges = []
    private var initialFrame = NSRect.zero
    private var initialPointer = NSPoint.zero
    private var visibleFrame = NSRect.zero
    private let edgeWidth: CGFloat = 9
    private let cornerWidth: CGFloat = 18
    private let gripWidth: CGFloat = 34

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) && !resizeEdges(at: local).isEmpty ? self : nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let w = bounds.width
        let h = bounds.height
        addCursorRect(NSRect(x: 0, y: cornerWidth, width: edgeWidth, height: max(0, h - 2 * cornerWidth)), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: w - edgeWidth, y: cornerWidth, width: edgeWidth, height: max(0, h - 2 * cornerWidth)), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: cornerWidth, y: 0, width: max(0, w - 2 * cornerWidth), height: edgeWidth), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: cornerWidth, y: h - edgeWidth, width: max(0, w - 2 * cornerWidth), height: edgeWidth), cursor: .resizeUpDown)
        for (origin, symbol) in [
            (NSPoint(x: 0, y: 0), "arrow.up.right.and.arrow.down.left"),
            (NSPoint(x: w - cornerWidth, y: h - cornerWidth), "arrow.up.right.and.arrow.down.left"),
            (NSPoint(x: 0, y: h - cornerWidth), "arrow.up.left.and.arrow.down.right"),
            (NSPoint(x: w - cornerWidth, y: 0), "arrow.up.left.and.arrow.down.right")
        ] {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
            image.size = NSSize(width: 18, height: 18)
            addCursorRect(NSRect(origin: origin, size: NSSize(width: cornerWidth, height: cornerWidth)),
                          cursor: NSCursor(image: image, hotSpot: NSPoint(x: 9, y: 9)))
        }
        let grip = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil) ?? NSImage()
        grip.size = NSSize(width: 18, height: 18)
        addCursorRect(NSRect(x: w - gripWidth, y: 0, width: gripWidth, height: gripWidth),
                      cursor: NSCursor(image: grip, hotSpot: NSPoint(x: 9, y: 9)))
    }

    override func mouseDown(with event: NSEvent) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        edges = resizeEdges(at: convert(event.locationInWindow, from: nil))
        if !edges.isEmpty { onResizeStart() }
        initialFrame = window.frame
        initialPointer = window.convertPoint(toScreen: event.locationInWindow)
        visibleFrame = screen.visibleFrame
    }

    override func mouseDragged(with event: NSEvent) {
        guard !edges.isEmpty, let window else { return }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        let delta = NSPoint(x: pointer.x - initialPointer.x, y: pointer.y - initialPointer.y)
        window.setFrame(ShelfPanelSizing.resizedFrame(initialFrame, translation: delta, edges: edges,
                                                     visibleFrame: visibleFrame), display: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard !edges.isEmpty else { return }
        edges = []
        onResizeEnd()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.45).setStroke()
        let grip = NSBezierPath()
        grip.lineWidth = 1.6
        grip.lineCapStyle = .round
        grip.move(to: NSPoint(x: bounds.midX - 20, y: bounds.maxY - 7))
        grip.line(to: NSPoint(x: bounds.midX + 20, y: bounds.maxY - 7))
        for offset: CGFloat in [0, 5, 10] {
            grip.move(to: NSPoint(x: bounds.maxX - 27 + offset, y: 12))
            grip.line(to: NSPoint(x: bounds.maxX - 12, y: 27 - offset))
        }
        grip.stroke()
    }

    private func resizeEdges(at point: NSPoint) -> ShelfResizeEdges {
        let left = point.x < cornerWidth
        let right = point.x > bounds.width - cornerWidth
        let bottom = point.y < cornerWidth
        let top = point.y > bounds.height - cornerWidth
        var result: ShelfResizeEdges = []
        if point.x > bounds.width - gripWidth && point.y < gripWidth { return [.right, .bottom] }
        if point.x < edgeWidth || left && (bottom || top) { result.insert(.left) }
        if point.x > bounds.width - edgeWidth || right && (bottom || top) { result.insert(.right) }
        if point.y < edgeWidth || bottom && (left || right) { result.insert(.bottom) }
        if point.y > bounds.height - edgeWidth || top && (left || right) { result.insert(.top) }
        return result
    }
}
