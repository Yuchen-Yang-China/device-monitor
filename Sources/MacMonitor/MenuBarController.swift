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
        // A failed read must not look like a live rate in the status item.
        // The tooltip retains the last known value with an explicit stale
        // label for users who need that context.
        let upload = snapshot.network.isStale
            ? "--"
            : (displayMode == .compact
                ? ByteFormatter.rateCompact(snapshot.network.uploadBytesPerSecond)
                : snapshot.network.uploadShortText)
        let download = snapshot.network.isStale
            ? "--"
            : (displayMode == .compact
                ? ByteFormatter.rateCompact(snapshot.network.downloadBytesPerSecond)
                : snapshot.network.downloadShortText)
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
    private enum PopoverLayout {
        static let overviewSize = NSSize(width: 360, height: 300)
        static let detailSize = NSSize(width: 360, height: 400)
    }

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
        statusItem.button?.setAccessibilityHelp("Open the Mac Monitor dashboard")
        updateStatusItemSize()

        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentSize = PopoverLayout.overviewSize
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
        let renderSignature = [
            settings.displayMode.rawValue,
            settings.showNetwork.description,
            store.snapshot.cpu.level.label,
            store.snapshot.memory.level.label,
            store.snapshot.thermal.level.label,
            store.snapshot.network.isStale.description,
            store.snapshot.network.uploadShortText,
            store.snapshot.network.downloadShortText
        ].joined(separator: "|")
        if force || renderSignature != lastRenderSignature {
            lastRenderSignature = renderSignature
            statusItem.button?.image = MenuBarImageRenderer.render(
                snapshot: store.snapshot,
                displayMode: settings.displayMode,
                showNetwork: settings.showNetwork,
                width: width
            )
        }

        // Keep text descriptions live even when the compact image itself did
        // not change (for example, CPU moves within the same pressure level).
        let summary = statusSummary
        statusItem.button?.toolTip = summary
        statusItem.button?.setAccessibilityValue(summary)
    }

    private var statusSummary: String {
        let snapshot = store.snapshot
        let network = snapshot.network
        let upload: String
        let download: String
        if network.isStale {
            upload = network.uploadText == "Unavailable" ? "unavailable" : "last known \(network.uploadText)"
            download = network.downloadText == "Unavailable" ? "unavailable" : "last known \(network.downloadText)"
        } else {
            upload = network.uploadText
            download = network.downloadText
        }
        let networkStatus: String
        if network.isStale {
            networkStatus = "network out of date"
        } else if network.uploadBytesPerSecond == nil, network.downloadBytesPerSecond == nil {
            networkStatus = "network unavailable"
        } else {
            networkStatus = "network current"
        }
        let cpu = freshnessValue(snapshot.cpu.primaryText, level: snapshot.cpu.level)
        let memory = freshnessValue(snapshot.memory.primaryText, level: snapshot.memory.level)
        let thermal = freshnessValue(snapshot.thermal.primaryText, level: snapshot.thermal.level)
        return "CPU \(cpu), Memory \(memory), \(HardwareInfo.temperatureTitle) \(thermal), \(networkStatus), upload \(upload), download \(download)"
    }

    private func freshnessValue(_ value: String, level: MetricLevel) -> String {
        switch level {
        case .stale:
            return value == "--" || value == "Unavailable" ? "unavailable" : "last known \(value)"
        case .unavailable:
            return "unavailable"
        case .sampling:
            return "collecting"
        case .normal, .elevated, .critical:
            return value == "Unavailable" || value == "--" ? "unavailable" : value
        }
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
        popover.contentSize = PopoverLayout.overviewSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        positionPopoverWindow(relativeTo: button)
        DispatchQueue.main.async { [weak self] in
            if let button = self?.statusItem.button {
                self?.positionPopoverWindow(relativeTo: button)
            }
        }
    }

    private func updatePopoverSize(for metric: MetricKind?) {
        let size = metric == nil ? PopoverLayout.overviewSize : PopoverLayout.detailSize
        guard popover.contentSize != size else { return }

        popover.contentSize = size
        // AppKit updates the popover window on the next run loop turn. Re-read
        // the final frame then, otherwise positioning uses the previous height.
        guard popover.isShown else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            self.positionPopoverWindow(relativeTo: button)
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

        let minimumY = visibleFrame.minY + verticalMargin
        let maximumY = visibleFrame.maxY - size.height - verticalMargin
        let aboveY = anchorOnScreen.minY - size.height - verticalMargin
        let belowY = anchorOnScreen.maxY + verticalMargin
        var y = aboveY >= minimumY ? aboveY : belowY
        if maximumY >= minimumY {
            y = min(max(y, minimumY), maximumY)
        } else {
            // A very small display cannot fit the full dashboard. Keep the
            // window visible instead of allowing it to drift off-screen.
            y = minimumY
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
