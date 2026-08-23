import AppKit
import Combine
import SwiftUI

enum MenuBarImageRenderer {
    static func width(for mode: MenuDisplayMode, showNetwork: Bool) -> CGFloat {
        guard showNetwork, mode != .minimal else { return 22 }
        return mode == .compact ? 56 : 82
    }

    static func render(snapshot: SystemSnapshot, displayMode: MenuDisplayMode, showNetwork: Bool, width: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: NSStatusBar.system.thickness))
        image.lockFocus()
        defer { image.unlockFocus() }

        let offset: CGFloat = 0
        let barLevels = [snapshot.cpu.level, snapshot.memory.level, snapshot.thermal.level]
        for (index, level) in barLevels.enumerated() {
            drawBar(at: offset + CGFloat(index) * 5 + 4, level: level, usesThermalScale: index == 2)
        }

        guard showNetwork, displayMode != .minimal else { return image }
        let font = NSFont.monospacedDigitSystemFont(ofSize: displayMode == .compact ? 8.5 : 10, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        let separator = displayMode == .compact ? "" : " "
        let upload = displayMode == .compact
            ? ByteFormatter.rateCompact(snapshot.network.uploadBytesPerSecond)
            : snapshot.network.uploadShortText
        let download = displayMode == .compact
            ? ByteFormatter.rateCompact(snapshot.network.downloadBytesPerSecond)
            : snapshot.network.downloadShortText
        let top = "\u{2191}\(separator)\(upload)"
        let bottom = "\u{2193}\(separator)\(download)"
        let textX = offset + (displayMode == .compact ? 20 : 22)
        top.draw(at: NSPoint(x: textX, y: 10), withAttributes: attributes)
        bottom.draw(at: NSPoint(x: textX, y: 0), withAttributes: attributes)
        return image
    }

    private static func drawBar(at x: CGFloat, level: MetricLevel, usesThermalScale: Bool) {
        let segmentHeight: CGFloat = 4
        let segmentGap: CGFloat = 1
        let width: CGFloat = 3
        for index in 0..<3 {
            let y = CGFloat(index) * (segmentHeight + segmentGap) + 3
            let rect = NSRect(x: x, y: y, width: width, height: segmentHeight)
            let isFilled = index < level.barFill
            let color: NSColor
            if isFilled, usesThermalScale {
                switch index {
                case 0: color = .systemGreen
                case 1: color = .systemYellow
                default: color = .systemRed
                }
            } else {
                color = isFilled ? level.color : NSColor.quaternaryLabelColor
            }
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
    }
}

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let store: MonitorStore
    private let settings: AppSettings
    private let monitor: SystemMonitor
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var settingsWindowController: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var lastRenderSignature = ""

    init(store: MonitorStore, settings: AppSettings, monitor: SystemMonitor) {
        self.store = store
        self.settings = settings
        self.monitor = monitor
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.imageScaling = .scaleNone
        statusItem.button?.showsBorderOnlyWhileMouseInside = true
        statusItem.button?.setAccessibilityLabel("Mac Monitor")
        updateStatusItemSize()

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 360, height: 300)
        popover.delegate = self
        observeChanges()
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.setDetailDemand(nil)
        popover.contentViewController = nil
    }

    private func observeChanges() {
        store.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusImage()
            }
            .store(in: &cancellables)

        settings.$displayMode
            .combineLatest(settings.$showNetwork)
            .receive(on: RunLoop.main)
            .sink { [weak self] mode, showNetwork in
                guard let self else { return }
                self.updateStatusItemSize()
                self.updateStatusImage(force: true)
            }
            .store(in: &cancellables)

        settings.$samplingProfile
            .receive(on: RunLoop.main)
            .sink { [weak self] profile in
                self?.monitor.setSamplingProfile(profile)
            }
            .store(in: &cancellables)
    }

    private func updateStatusItemSize() {
        statusItem.length = MenuBarImageRenderer.width(for: settings.displayMode, showNetwork: settings.showNetwork)
    }

    private func updateStatusImage(force: Bool = false) {
        let width = statusItem.length
        let signature = [
            settings.displayMode.rawValue,
            settings.showNetwork.description,
            store.snapshot.cpu.level.label,
            store.snapshot.memory.level.label,
            store.snapshot.thermal.level.label,
            store.snapshot.network.uploadShortText,
            store.snapshot.network.downloadShortText
        ].joined(separator: "|")
        guard force || signature != lastRenderSignature else { return }

        lastRenderSignature = signature
        statusItem.button?.image = MenuBarImageRenderer.render(
            snapshot: store.snapshot,
            displayMode: settings.displayMode,
            showNetwork: settings.showNetwork,
            width: width
        )
        statusItem.button?.toolTip = "CPU \(store.snapshot.cpu.primaryText), Memory \(store.snapshot.memory.level.label), \(HardwareInfo.temperatureTitle) \(store.snapshot.thermal.primaryText), upload \(store.snapshot.network.uploadText), download \(store.snapshot.network.downloadText)"
    }

    @objc private func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        showPopover(relativeTo: button)
    }

    private func showPopover(relativeTo button: NSStatusBarButton? = nil) {
        guard let button = button ?? statusItem.button else { return }
        let dashboard = DashboardView(
            store: store,
            onOpenSettings: { [weak self] in self?.showSettings() },
            onQuit: { NSApplication.shared.terminate(nil) },
            onDetailDemand: { [weak self] metric in
                guard let self else { return }
                self.monitor.setDetailDemand(metric)
                self.updatePopoverSize(for: metric)
            }
        )
        let controller = NSHostingController(rootView: dashboard)
        popover.contentViewController = controller
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        positionPopoverWindow(relativeTo: button)
        DispatchQueue.main.async { [weak self] in
            if let button = self?.statusItem.button {
                self?.positionPopoverWindow(relativeTo: button)
            }
            self?.popover.contentViewController?.view.window?.makeFirstResponder(nil)
        }
    }

    private func updatePopoverSize(for metric: MetricKind?) {
        popover.contentSize = NSSize(width: 360, height: metric == nil ? 300 : 400)
        if let button = statusItem.button, popover.isShown {
            positionPopoverWindow(relativeTo: button)
        }
    }

    private func positionPopoverWindow(relativeTo button: NSStatusBarButton) {
        guard
            let window = popover.contentViewController?.view.window,
            let hostWindow = button.window,
            let screen = hostWindow.screen
        else { return }

        let anchorInWindow = button.convert(button.bounds, to: nil)
        let anchorOnScreen = hostWindow.convertToScreen(anchorInWindow)
        let visibleFrame = screen.visibleFrame
        let size = window.frame.size
        let horizontalMargin: CGFloat = 8
        let verticalMargin: CGFloat = 6

        var x = anchorOnScreen.midX - size.width / 2
        x = max(visibleFrame.minX + horizontalMargin, min(x, visibleFrame.maxX - size.width - horizontalMargin))

        var y = anchorOnScreen.minY - size.height - verticalMargin
        if y < visibleFrame.minY + horizontalMargin {
            y = anchorOnScreen.maxY + verticalMargin
        }
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func showSettings() {
        monitor.setDetailDemand(nil)
        popover.performClose(nil)
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(settings: settings, onResetNetworkTotals: { [weak self] in
                self?.monitor.resetNetworkTotals()
            }) { [weak self] in
                self?.returnToOverview()
            }
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        settingsWindowController?.window?.makeFirstResponder(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func returnToOverview() {
        settingsWindowController?.close()
        showPopover()
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettingsFromMenu), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitFromMenu), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.midX, y: button.bounds.minY), in: button)
    }

    @objc private func openSettingsFromMenu() {
        showSettings()
    }

    @objc private func quitFromMenu() {
        NSApplication.shared.terminate(nil)
    }
}
