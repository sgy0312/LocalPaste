import AppKit
import Carbon.HIToolbox
import QuartzCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private lazy var store = ClipboardStore()
    private let panel = ClipboardShelfPanel(contentRect: NSRect(origin: .zero, size: ClipboardShelfController.panelSize),
                                            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
    private var controller: ClipboardShelfController!
    private var statusItem: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var previousApplication: NSRunningApplication?
    private var transitionID = 0
    private var isClosing = false
    private let panelAnimator = ShelfPanelAnimator()
    private var settledFrame: NSRect?
    private let widthPreference = "LocalPaste.panelWidth"
    private let heightPreference = "LocalPaste.panelHeight"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupPanel()
        setupStatusItem()
        registerGlobalShortcut()
        DispatchQueue.main.async { self.showPanel() }
    }

    func applicationDidResignActive(_ notification: Notification) {
        if NSApp.modalWindow == nil, !isClosing {
            transitionID += 1
            panelAnimator.cancel()
            controller.prepareForDismissal()
            panel.orderOut(nil)
            panel.alphaValue = 1
            if let settledFrame { panel.setFrame(settledFrame, display: false) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelAnimator.cancel()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private func setupPanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = ShelfPanelSizing.minimumSize
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        controller = ClipboardShelfController(store: store) { [weak self] in
            self?.closePanel()
        } onClose: { [weak self] in
            self?.closePanel()
        } onResizeEnd: { [weak self] in
            self?.rememberPanelSize()
        } onResetSize: { [weak self] in
            self?.resetPanelSize()
        } onApplyPreset: { [weak self] preset in
            self?.applyPreset(preset)
        } onResizeStart: { [weak self] in
            self?.stopTransitionForResize()
        }
        panel.contentViewController = controller
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "本地剪贴板")
        button.toolTip = "本地剪贴板 · ⌘⇧V"
        button.target = self
        button.action = #selector(togglePanel)
    }

    @objc private func togglePanel() {
        if panel.isVisible && !isClosing { closePanel() } else { showPanel() }
    }

    private func showPanel() {
        guard !panel.isVisible || isClosing else { return }
        transitionID += 1
        let resuming = panel.isVisible
        panelAnimator.cancel()
        isClosing = false
        panel.ignoresMouseEvents = false
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = front
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        var targetFrame = panel.frame
        if let screen {
            configureSizeLimits(on: screen)
            targetFrame = ShelfPanelSizing.presentationFrame(on: screen.visibleFrame, preferredSize: preferredPanelSize)
        }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        settledFrame = targetFrame
        if !resuming {
            panel.alphaValue = reduced ? 1 : 0
            panel.setFrame(reduced ? targetFrame : targetFrame.offsetBy(dx: 0, dy: -8), display: false)
        }
        controller.prepareForPresentation()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        controller.focusInput()
        panelAnimator.animate(panel, to: targetFrame, alpha: 1, direction: .opening, reducedMotion: reduced)
    }

    private var preferredPanelSize: NSSize? {
        let defaults = UserDefaults.standard
        // Migrate only the former default height, preserving custom sizes and width.
        if !defaults.bool(forKey: "LocalPaste.uniformCardHeightMigrated") {
            let savedHeight = defaults.double(forKey: heightPreference)
            if savedHeight == 352 || savedHeight == 288 {
                defaults.set(ShelfPanelSizing.defaultSize.height, forKey: heightPreference)
            }
            defaults.set(true, forKey: "LocalPaste.uniformCardHeightMigrated")
        }
        guard defaults.object(forKey: widthPreference) != nil,
              defaults.object(forKey: heightPreference) != nil else { return nil }
        return NSSize(width: defaults.double(forKey: widthPreference), height: defaults.double(forKey: heightPreference))
    }

    private func configureSizeLimits(on screen: NSScreen) {
        let available = ShelfPanelSizing.availableFrame(on: screen.visibleFrame)
        panel.minSize = NSSize(width: min(ShelfPanelSizing.minimumSize.width, available.width),
                               height: min(ShelfPanelSizing.minimumSize.height, available.height))
        panel.maxSize = available.size
    }

    func windowDidEndLiveResize(_ notification: Notification) { rememberPanelSize() }
    func windowWillStartLiveResize(_ notification: Notification) { stopTransitionForResize() }

    private func stopTransitionForResize() {
        panelAnimator.cancel()
        panel.alphaValue = 1
        settledFrame = panel.frame
    }

    private func rememberPanelSize() {
        settledFrame = panel.frame
        UserDefaults.standard.set(panel.frame.width, forKey: widthPreference)
        UserDefaults.standard.set(panel.frame.height, forKey: heightPreference)
    }

    private func resetPanelSize() {
        stopTransitionForResize()
        UserDefaults.standard.removeObject(forKey: widthPreference)
        UserDefaults.standard.removeObject(forKey: heightPreference)
        guard let screen = panel.screen ?? NSScreen.main else { return }
        configureSizeLimits(on: screen)
        let frame = ShelfPanelSizing.presentationFrame(on: screen.visibleFrame, preferredSize: nil)
        panel.setFrame(frame, display: true)
        settledFrame = panel.frame
    }

    private func closePanel() {
        guard panel.isVisible, !isClosing else { return }
        controller.prepareForDismissal()
        transitionID += 1
        let token = transitionID
        isClosing = true
        panel.ignoresMouseEvents = true
        let target = (settledFrame ?? panel.frame).offsetBy(dx: 0, dy: -6)
        panelAnimator.animate(panel, to: target, alpha: 0, direction: .closing,
                              reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) { [weak self] in
            guard let self, self.transitionID == token else { return }
            self.panel.orderOut(nil)
            self.isClosing = false
            self.panel.ignoresMouseEvents = false
            self.panel.alphaValue = 1
            if let frame = self.settledFrame { self.panel.setFrame(frame, display: false) }
        }
        previousApplication?.activate(options: [])
    }

    private func applyPreset(_ preset: ShelfPanelPreset) {
        stopTransitionForResize()
        guard let screen = panel.screen ?? NSScreen.main else { return }
        configureSizeLimits(on: screen)
        panel.setFrame(ShelfPanelSizing.presentationFrame(on: screen.visibleFrame, preferredSize: preset.size), display: true)
        rememberPanelSize()
    }

    private func registerGlobalShortcut() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerProcPtr = { _, _, userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.togglePanel() }
            return noErr
        }
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(), handler, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &eventHandler
        )
        guard handlerStatus == noErr else {
            store.notice = "快捷键暂不可用，请点击菜单栏图标"
            return
        }
        let identifier = EventHotKeyID(signature: OSType(0x4C505354), id: 1)
        let shortcutStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_V), UInt32(shiftKey | cmdKey), identifier,
            GetApplicationEventTarget(), 0, &hotKey
        )
        if shortcutStatus != noErr { store.notice = "⌘⇧V 已被占用，请点击菜单栏图标" }
    }
}

private final class ClipboardShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
