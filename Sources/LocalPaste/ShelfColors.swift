import AppKit

enum ShelfColors {
    // Opaque secondary text stays readable on both cards and the frosted shelf.
    static let secondaryText = NSColor(name: NSColor.Name("ShelfSecondaryText")) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(calibratedWhite: dark ? 0.78 : 0.34, alpha: 1)
    }
}
