import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: MonitorStore?
    private var settings: AppSettings?
    private var monitor: SystemMonitor?
    private var peerCoordinator: PeerCoordinator?
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let store = MonitorStore()
        let settings = AppSettings()
        let monitor = SystemMonitor(store: store, profile: settings.samplingProfile)
        let peerConfiguration = PeerConfiguration()
        let peerStatusStore = PeerStatusStore()
        let peerCoordinator = PeerCoordinator(
            monitorStore: store,
            configuration: peerConfiguration,
            statusStore: peerStatusStore
        )
        self.store = store
        self.settings = settings
        self.monitor = monitor
        self.peerCoordinator = peerCoordinator
        menuBarController = MenuBarController(
            store: store,
            settings: settings,
            monitor: monitor,
            peerConfiguration: peerConfiguration,
            peerStatusStore: peerStatusStore,
            peerCoordinator: peerCoordinator
        )
        monitor.start()
        peerCoordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        peerCoordinator?.stop()
        monitor?.stop()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
