import AppKit
import SwiftUI

final class PreviewPanelController {

    static let shared = PreviewPanelController()

    private var panel: NSPanel?
    private var dismissTimer: Timer?

    private init() {}

    func show(image: NSImage) {
        // A new capture replaces any visible panel.
        dismissImmediately()

        let card = PreviewCard(
            image: image,
            onSave: { [weak self] in
                CaptureService.saveToDesktop(image)
                // Let the "Saved ✓" state show briefly, then slip away.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    self?.dismiss()
                }
            },
            onEdit: { [weak self] in
                self?.dismiss()
                EditorWindowController.open(image: image)
            },
            onClose: { [weak self] in
                self?.dismiss()
            },
            onHoverChanged: { [weak self] hovering in
                self?.hoverChanged(hovering)
            }
        )

        let hosting = NSHostingView(rootView: card)
        hosting.setFrameSize(hosting.fittingSize)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = hosting.fittingSize
            let origin = NSPoint(x: visible.minX + 16,
                                 y: visible.minY + 16)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }

        self.panel = panel
        startTimer(seconds: 6)
    }

    private func startTimer(seconds: TimeInterval) {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func hoverChanged(_ hovering: Bool) {
        if hovering {
            dismissTimer?.invalidate()
            dismissTimer = nil
        } else {
            startTimer(seconds: 3)
        }
    }

    private func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard let panel = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            if self.panel === panel {
                self.panel = nil
            }
        })
    }

    private func dismissImmediately() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

struct PreviewCard: View {
    let image: NSImage
    let onSave: () -> Void
    let onEdit: () -> Void
    let onClose: () -> Void
    let onHoverChanged: (Bool) -> Void

    @State private var hovering = false
    @State private var saved = false

    /// Every capture gets the same fixed card; the image aspect-fits inside
    /// over a blurred backdrop, so extreme ratios (tall/thin) can't warp the
    /// layout or squeeze the buttons.
    private let cardSize = CGSize(width: 300, height: 200)

    private var fittedSize: CGSize {
        let s = min((cardSize.width - 24) / max(image.size.width, 1),
                    (cardSize.height - 24) / max(image.size.height, 1),
                    1)   // never upscale tiny captures
        return CGSize(width: image.size.width * s, height: image.size.height * s)
    }

    var body: some View {
        ZStack {
            // Blurred fill of the capture itself as the card backdrop.
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: cardSize.width, height: cardSize.height)
                .scaleEffect(1.2)   // hide the blur's transparent halo at the edges
                .blur(radius: 22)
                .overlay(Color.black.opacity(0.35))

            // The actual capture, aspect-fit in the center.
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: fittedSize.width, height: fittedSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 2)

            if hovering {
                Color.black.opacity(0.28)
                    .transition(.opacity)

                HStack(spacing: 8) {
                    Button {
                        saved = true
                        onSave()
                    } label: {
                        Label(saved ? "Saved ✓" : "Save",
                              systemImage: saved ? "checkmark" : "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .disabled(saved)

                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil.tip.crop.circle")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.regular)
                .transition(.opacity)
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 22, height: 22)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .transition(.opacity)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .padding(14)
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.15)) {
                hovering = inside
            }
            onHoverChanged(inside)
        }
    }
}
