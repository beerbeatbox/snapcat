import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        HotkeyManager.shared.onHotkey = { CaptureService.shared.captureArea() }
        HotkeyManager.shared.register()
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Snapcat")
                ?? NSImage(systemSymbolName: "camera", accessibilityDescription: "Snapcat")
            image?.isTemplate = true
            button.image = image
        }
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = true

        let capture = NSMenuItem(title: "Capture Area",
                                 action: #selector(captureArea),
                                 keyEquivalent: "4")
        capture.keyEquivalentModifierMask = [.command, .shift]
        capture.target = self
        menu.addItem(capture)

        let editLast = NSMenuItem(title: "Edit Last Capture",
                                  action: #selector(editLastCapture),
                                  keyEquivalent: "")
        editLast.target = self
        menu.addItem(editLast)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About Snapcat",
                               action: #selector(showAbout),
                               keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Snapcat",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    // MARK: - Actions

    @objc private func captureArea() {
        CaptureService.shared.captureArea()
    }

    @objc private func editLastCapture() {
        guard let image = CaptureService.shared.lastCapture else { return }
        EditorWindowController.open(image: image)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(editLastCapture) {
            return CaptureService.shared.lastCapture != nil
        }
        return true
    }
}
