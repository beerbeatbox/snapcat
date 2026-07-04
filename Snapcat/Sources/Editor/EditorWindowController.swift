import AppKit
import SwiftUI

final class EditorWindowController: NSObject, NSWindowDelegate {

    private static var controllers: [EditorWindowController] = []

    private let window: NSWindow

    static func open(image: NSImage) {
        guard let model = EditorViewModel(image: image) else { return }

        let hosting = NSHostingController(rootView: EditorView(model: model))

        // Fit image aspect into 1100×720 plus ~44pt toolbar height; min 560×400.
        let maxContent = CGSize(width: 1100, height: 720)
        let pixel = model.pixelSize
        let fit = min(maxContent.width / pixel.width, maxContent.height / pixel.height, 1)
        let contentW = max(560, pixel.width * fit)
        let contentH = max(400, pixel.height * fit + 44)

        let window = NSWindow(contentViewController: hosting)
        // ARC holds a strong reference to the window; the default
        // isReleasedWhenClosed = true would cause an over-release on close.
        window.isReleasedWhenClosed = false
        window.title = "Snapcat"
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(CGSize(width: contentW, height: contentH))
        window.minSize = CGSize(width: 560, height: 400)

        let controller = EditorWindowController(window: window)
        window.delegate = controller
        controllers.append(controller)

        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private init(window: NSWindow) {
        self.window = window
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        EditorWindowController.controllers.removeAll { $0 === self }
    }
}
