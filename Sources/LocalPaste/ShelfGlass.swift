import AppKit

enum ShelfGlass {
    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    static var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

    static let panelMaterial: NSVisualEffectView.Material = .underWindowBackground

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func panelBorder() -> NSColor {
        if increaseContrast || reduceTransparency { return .labelColor.withAlphaComponent(0.55) }
        return NSColor(name: NSColor.Name("ShelfGlassEdge")) { appearance in
            .white.withAlphaComponent(isDark(appearance) ? 0.18 : 0.70)
        }
    }

    static func cardFill(selected: Bool, hovered: Bool) -> NSColor {
        if reduceTransparency { return NSColor.controlBackgroundColor }
        return NSColor(name: nil) { appearance in
            let dark = isDark(appearance)
            let alpha: CGFloat = dark ? 0.82 : 0.78
            let base = NSColor(calibratedWhite: dark ? 0.17 : 1.0, alpha: 1)
            let fraction = selected ? 0.05 : hovered ? 0.025 : 0
            return (base.blended(withFraction: fraction, of: .systemBlue) ?? base).withAlphaComponent(alpha)
        }
    }

    static func cardBorder(selected: Bool, hovered: Bool) -> NSColor {
        if selected { return NSColor.systemBlue.withAlphaComponent(increaseContrast ? 1 : 0.85) }
        if increaseContrast { return NSColor.labelColor.withAlphaComponent(0.55) }
        if hovered { return NSColor.systemBlue.withAlphaComponent(0.30) }
        return NSColor.separatorColor.withAlphaComponent(reduceTransparency ? 0.50 : 0.22)
    }

    static func tabFill(selected: Bool) -> NSColor {
        selected ? NSColor.systemBlue.withAlphaComponent(reduceTransparency ? 0.22 : 0.14) : .clear
    }

    static func tabBorder(selected: Bool) -> NSColor {
        selected ? NSColor.systemBlue.withAlphaComponent(increaseContrast ? 0.85 : reduceTransparency ? 0.35 : 0.22) : .clear
    }

    static func iconHoverFill() -> NSColor {
        NSColor.labelColor.withAlphaComponent(reduceTransparency ? 0.10 : 0.065)
    }

    static func welcomeFill() -> NSColor {
        NSColor.labelColor.withAlphaComponent(reduceTransparency ? 0.06 : 0.035)
    }

    static func readabilityFill() -> NSColor {
        if reduceTransparency { return NSColor.textBackgroundColor }
        return NSColor(name: NSColor.Name("ShelfReadingPlate")) { appearance in
            NSColor(calibratedWhite: isDark(appearance) ? 0.13 : 1.0, alpha: 0.72)
        }
    }

    /// A generated backdrop for offline examples; the running app uses the system material.
    static func drawPreview(in bounds: NSRect, appearance: NSAppearance) {
        if reduceTransparency {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            return
        }
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.30, green: 0.34, blue: 0.62, alpha: 1),
            NSColor(calibratedRed: 0.54, green: 0.40, blue: 0.66, alpha: 1),
            NSColor(calibratedRed: 0.92, green: 0.66, blue: 0.42, alpha: 1)
        ])!
        gradient.draw(in: bounds, angle: -35)
        NSColor(calibratedWhite: isDark(appearance) ? 0.08 : 1, alpha: isDark(appearance) ? 0.78 : 0.72).setFill()
        bounds.fill()
    }
}

/// One native blur surface for each window, with live accessibility fallbacks.
@MainActor
class ShelfGlassBackground: NSVisualEffectView {
    var isPreview = false {
        didSet {
            previewBackdrop.isHidden = !isPreview
            previewBackdrop.needsDisplay = true
        }
    }
    var glassCornerRadius: CGFloat = 0
    private var displayObserver: NSObjectProtocol?
    private let previewBackdrop = ShelfGlassPreviewBackdrop()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        blendingMode = .behindWindow
        state = .active
        previewBackdrop.frame = bounds
        previewBackdrop.autoresizingMask = [.width, .height]
        previewBackdrop.isHidden = true
        addSubview(previewBackdrop)
        updateGlass()
        displayObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateGlass() }
            }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let displayObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayObserver) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGlass()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateGlass()
    }

    func updateGlass() {
        material = ShelfGlass.panelMaterial
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (ShelfGlass.reduceTransparency ? NSColor.windowBackgroundColor : .clear).cgColor
            layer?.borderColor = ShelfGlass.panelBorder().cgColor
        }
        previewBackdrop.needsDisplay = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if glassCornerRadius > 0 {
            NSBezierPath(roundedRect: bounds, xRadius: glassCornerRadius, yRadius: glassCornerRadius).addClip()
        }
        if ShelfGlass.reduceTransparency {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
        }
    }
}

private final class ShelfGlassPreviewBackdrop: NSView {
    override var allowsVibrancy: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        ShelfGlass.drawPreview(in: bounds, appearance: effectiveAppearance)
    }
}

@MainActor
final class ShelfReadingPlate: NSView {
    private var displayObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        updateFill()
        displayObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateFill() }
            }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let displayObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayObserver) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateFill()
    }

    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = ShelfGlass.readabilityFill().cgColor
        }
    }
}
