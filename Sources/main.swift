import AppKit

/// Lumen — a lightweight menu bar utility for display brightness and volume.
///
/// Runs as an accessory app (`LSUIElement`), so it lives only in the menu bar:
/// no Dock icon, no windows, and no system permissions required.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = MenuBarController()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
