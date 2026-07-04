import AppKit

final class CaptureService {

    static let shared = CaptureService()

    private(set) var lastCapture: NSImage?

    private init() {}

    func captureArea() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapcat-\(UUID().uuidString).png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", path.path]

        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                let fm = FileManager.default
                // No file → user pressed Esc / cancelled.
                guard fm.fileExists(atPath: path.path),
                      let image = NSImage(contentsOf: path) else {
                    return
                }
                self.lastCapture = image
                CaptureService.copyToClipboard(image)
                try? fm.removeItem(at: path)
                PreviewPanelController.shared.show(image: image)
            }
        }

        do {
            try process.run()
        } catch {
            NSLog("Snapcat: failed to launch screencapture: \(error)")
        }
    }

    static func copyToClipboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func defaultFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Snapcat \(formatter.string(from: date)).png"
    }

    @discardableResult
    static func saveToDesktop(_ image: NSImage) -> URL? {
        guard let data = pngData(from: image),
              let desktop = FileManager.default.urls(for: .desktopDirectory,
                                                     in: .userDomainMask).first else { return nil }
        let url = desktop.appendingPathComponent(defaultFileName())
        do {
            try data.write(to: url)
            return url
        } catch {
            NSLog("Snapcat: failed to save to Desktop: \(error)")
            return nil
        }
    }
}
