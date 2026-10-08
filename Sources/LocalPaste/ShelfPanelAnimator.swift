import AppKit
import QuartzCore

/// Keeps position and opacity continuous when an opening or closing transition is reversed.
@MainActor
final class ShelfPanelAnimator {
    enum Direction {
        case opening, closing
        var duration: TimeInterval { self == .opening ? 0.24 : 0.16 }
        func eased(_ progress: CGFloat) -> CGFloat {
            self == .opening ? 1 - pow(1 - progress, 3) : progress * progress
        }
    }

    private weak var window: NSWindow?
    private var timer: Timer?
    private let now: () -> TimeInterval
    private var startTime: TimeInterval = 0
    private var startFrame = NSRect.zero
    private var endFrame = NSRect.zero
    private var startAlpha: CGFloat = 1
    private var endAlpha: CGFloat = 1
    private var direction = Direction.opening
    private var completion: (() -> Void)?
    private(set) var isRunning = false

    init(now: @escaping () -> TimeInterval = CACurrentMediaTime) { self.now = now }

    func animate(_ window: NSWindow, to frame: NSRect, alpha: CGFloat, direction: Direction,
                 reducedMotion: Bool, completion: @escaping () -> Void = {}) {
        cancel()
        if reducedMotion {
            window.setFrame(frame, display: false)
            window.alphaValue = alpha
            completion()
            return
        }
        self.window = window
        self.startFrame = window.frame
        self.startAlpha = window.alphaValue
        self.endFrame = frame
        self.endAlpha = alpha
        self.direction = direction
        self.startTime = now()
        self.completion = completion
        isRunning = true
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        completion = nil
        window = nil
        isRunning = false
    }

    // The injected monotonic clock also lets the self-test exercise interruptions deterministically.
    func tick() {
        guard isRunning, let window else { cancel(); return }
        let progress = CGFloat(min(1, max(0, (now() - startTime) / direction.duration)))
        let eased = direction.eased(progress)
        func interpolate(_ start: CGFloat, _ end: CGFloat) -> CGFloat { start + (end - start) * eased }
        window.setFrame(NSRect(x: interpolate(startFrame.minX, endFrame.minX),
                               y: interpolate(startFrame.minY, endFrame.minY),
                               width: interpolate(startFrame.width, endFrame.width),
                               height: interpolate(startFrame.height, endFrame.height)), display: false)
        window.alphaValue = interpolate(startAlpha, endAlpha)
        if progress >= 1 {
            window.setFrame(endFrame, display: false)
            window.alphaValue = endAlpha
            let finished = completion
            cancel()
            finished?()
        }
    }
}
