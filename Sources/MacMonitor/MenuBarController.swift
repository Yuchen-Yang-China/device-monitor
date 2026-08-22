import AppKit
import Combine
import SwiftUI

enum MenuBarImageRenderer {
    static func render(snapshot: SystemSnapshot, displayMode: MenuDisplayMode, showNetwork: Bool, width: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: NSStatusBar.system.thickness))
        image.lockFocus()
        defer { image.unlockFocus() }

        let barLevels = [snapshot.cpu.level, snapshot.memory.level, snapshot.thermal.level]
        for (index, level) in barLevels.enumerated() {
            drawBar(at: CGFloat(index) * 5 + 4, level: level, usesThermalScale: index == 2)
        }

        guard showNetwork, displayMode != .minimal else { return image }
        let font = NSFont.monospacedDigitSystemFont(ofSize: displayMode == .compact ? 9 : 10, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        let top = "\u{2191} \(snapshot.network.uploadShortText)"
        let bottom = "\u{2193} \(snapshot.network.downloadShortText)"
        top.draw(at: NSPoint(x: 22, y: 10), withAttributes: attributes)
        bottom.draw(at: NSPoint(x: 22, y: 0), withAttributes: attributes)
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
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var settingsWindowController: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var lastRenderSignature = ""

    init(store: MonitorStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.imageScaling = .scaleNone
        statusItem.button?.setAccessibilityLabel("Mac Monitor")
        updateStatusItemSize()

        popover.behavior = .transient
        popover.delegate = self
        observeChanges()
    }

    func popoverDidClose(_ notification: Notification) {
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
    }

    private func updateStatusItemSize() {
        let width: CGFloat
        if settings.displayMode == .minimal || !settings.showNetwork {
            width = 22
        } else if settings.displayMode == .compact {
            width = 66
        } else {
            width = 82
        }
        statusItem.length = width
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
            onQuit: { NSApplication.shared.terminate(nil) }
        )
        let controller = NSHostingController(rootView: dashboard)
        popover.contentViewController = controller
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        DispatchQueue.main.async { [weak self] in
            self?.popover.contentViewController?.view.window?.makeFirstResponder(nil)
        }
    }

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(settings: settings) { [weak self] in
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
}
