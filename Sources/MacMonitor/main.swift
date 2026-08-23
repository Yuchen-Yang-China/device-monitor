import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: MonitorStore?
    private var settings: AppSettings?
    private var monitor: SystemMonitor?
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let store = MonitorStore()
        let settings = AppSettings()
        let monitor = SystemMonitor(store: store, profile: settings.samplingProfile)
        self.store = store
        self.settings = settings
        self.monitor = monitor
        menuBarController = MenuBarController(store: store, settings: settings, monitor: monitor)
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
