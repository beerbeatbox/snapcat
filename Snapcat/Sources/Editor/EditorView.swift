import SwiftUI
import AppKit

struct EditorView: View {
    @ObservedObject var model: EditorViewModel

    private let presetColors: [Color] = [
        .red, .orange, .yellow, .green, .blue, .purple, .white, .black
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            canvas
        }
        .background(hiddenKeyButtons)
        .frame(minWidth: 560, minHeight: 400)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            toolCluster
            Divider().frame(height: 20)
            colorGroup
            if model.tool == .blur || model.selectedBlurID != nil {
                blurLevelGroup
            }
            Spacer()
            trailingActions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var toolCluster: some View {
        HStack(spacing: 2) {
            ForEach(EditorTool.allCases) { tool in
                Button {
                    model.tool = tool
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 34, height: 26)
                        .foregroundStyle(model.tool == tool ? Color.white : Color.primary)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(model.tool == tool ? Color.accentColor : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help("\(tool.label) (\(String(tool.shortcut.character)))")
                .keyboardShortcut(tool.shortcut, modifiers: [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var colorGroup: some View {
        HStack(spacing: 6) {
            ForEach(Array(presetColors.enumerated()), id: \.offset) { _, swatch in
                Button {
                    model.color = swatch
                } label: {
                    Circle()
                        .fill(swatch)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle().stroke(Color.primary.opacity(0.2), lineWidth: 0.5)
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.accentColor, lineWidth: 2)
                                .padding(-3)
                                .opacity(isSelected(swatch) ? 1 : 0)
                        )
                }
                .buttonStyle(.plain)
            }
            ColorPicker("", selection: $model.color)
                .labelsHidden()
                .frame(width: 30)
        }
        .opacity(model.tool == .blur ? 0.4 : 1)
        .disabled(model.tool == .blur)
    }

    private func isSelected(_ swatch: Color) -> Bool {
        NSColor(swatch).usingColorSpace(.sRGB) == NSColor(model.color).usingColorSpace(.sRGB)
    }

    // MARK: - Blur level slider

    /// Selected blur region's level when one is selected (live editing),
    /// otherwise the tool default.
    private var blurLevelBinding: Binding<Double> {
        Binding(
            get: {
                if let id = model.selectedBlurID,
                   let annotation = model.annotations.first(where: { $0.id == id }) {
                    return Double(annotation.blurLevel)
                }
                return Double(model.blurLevel)
            },
            set: { model.setBlurLevel(Int($0.rounded())) }
        )
    }

    private var blurLevelGroup: some View {
        HStack(spacing: 6) {
            Image(systemName: "drop")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Slider(value: blurLevelBinding, in: 1...10, step: 1,
                   onEditingChanged: { editing in
                       if editing { model.beginBlurLevelEdit() }
                   })
                .frame(width: 110)
        }
        .help("Blur strength")
    }

    private var trailingActions: some View {
        HStack(spacing: 10) {
            if model.justCopied {
                Text("Copied ✓")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            // SF Symbols have uneven intrinsic sizes — pin the icon frame so
            // the icon-only buttons come out identical.
            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 20, height: 15)
            }
            .help("Undo (⌘Z)")
            .keyboardShortcut("z", modifiers: [.command])
            .disabled(!model.canUndo)

            Button {
                model.saveResult()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 20, height: 15)
            }
            .help("Save (⌘S)")
            .keyboardShortcut("s", modifiers: [.command])

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.copyResult()
                }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .help("Copy (⌘C)")
            .keyboardShortcut("c", modifiers: [.command])
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let backingScale = NSScreen.main?.backingScaleFactor ?? 2
            let padding: CGFloat = 32
            let availW = max(1, geo.size.width - padding * 2)
            let availH = max(1, geo.size.height - padding * 2)
            let scale = min(availW / model.pixelSize.width,
                            availH / model.pixelSize.height,
                            1 / backingScale)
            let fittedSize = CGSize(width: model.pixelSize.width * scale,
                                    height: model.pixelSize.height * scale)

            ZStack {
                Color(nsColor: .underPageBackgroundColor)

                imageStack(scale: scale)
                    .frame(width: fittedSize.width, height: fittedSize.height)
                    .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    private func imageStack(scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // 1. Base image.
            Image(model.cgImage, scale: 1, label: Text("Screenshot"))
                .resizable()
                .interpolation(.high)

            // 2. One blurred layer per blur level in use, each masked by
            //    that level's rects.
            ForEach(model.blurGroups(scale: scale)) { group in
                Image(model.blurredCG(level: group.level), scale: 1, label: Text("Blur"))
                    .resizable()
                    .interpolation(.none)
                    .mask(BlurMask(rects: group.rects))
            }

            // 3. Annotations overlay.
            annotationCanvas(scale: scale)
                .allowsHitTesting(false)

            // 4 & 5. Interaction layer.
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            model.dragChanged(startView: value.startLocation,
                                               currentView: value.location,
                                               scale: scale)
                        }
                        .onEnded { value in
                            model.dragEnded(startView: value.startLocation,
                                            currentView: value.location,
                                            scale: scale)
                        }
                )
                .onHover { inside in
                    if inside {
                        NSCursor.crosshair.push()
                    } else {
                        NSCursor.pop()
                    }
                }
        }
    }

    private func annotationCanvas(scale: CGFloat) -> some View {
        Canvas { context, _ in
            var drawList = model.annotations
            if let draft = model.draft {
                drawList.append(draft)
            }

            for annotation in drawList {
                let isDraft = model.draft?.id == annotation.id
                switch annotation.kind {
                case let .rectangle(rect):
                    let vr = scaledRect(rect, scale: scale)
                    context.stroke(Path(vr),
                                   with: .color(annotation.color),
                                   lineWidth: model.lineWidthImage * scale)
                case let .ellipse(rect):
                    let vr = scaledRect(rect, scale: scale)
                    context.stroke(Path(ellipseIn: vr),
                                   with: .color(annotation.color),
                                   lineWidth: model.lineWidthImage * scale)
                case let .blur(rect):
                    if isDraft {
                        let vr = scaledRect(rect, scale: scale)
                        let style = StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                        context.stroke(Path(roundedRect: vr, cornerRadius: 6),
                                       with: .color(.white),
                                       style: style)
                    }
                case let .number(center, value):
                    let vc = CGPoint(x: center.x * scale, y: center.y * scale)
                    let d = model.numberDiameter * scale
                    let circleRect = CGRect(x: vc.x - d / 2, y: vc.y - d / 2, width: d, height: d)
                    context.fill(Path(ellipseIn: circleRect), with: .color(annotation.color))
                    let ringWidth = d * 0.06
                    context.stroke(Path(ellipseIn: circleRect.insetBy(dx: ringWidth / 2, dy: ringWidth / 2)),
                                   with: .color(.white),
                                   lineWidth: ringWidth)
                    let text = Text("\(value)")
                        .font(.system(size: d * 0.52, weight: .bold))
                        .foregroundColor(.white)
                    context.draw(text, at: vc)
                }
            }

            // Selection indicator — drawn after all annotations so it sits
            // on top. View-only; never rendered into the export.
            if let selectedID = model.selectedID,
               let selected = model.annotations.first(where: { $0.id == selectedID }) {
                let bounds = selected.bounds(numberDiameter: model.numberDiameter)
                let vr = scaledRect(bounds, scale: scale).insetBy(dx: -6, dy: -6)
                context.stroke(Path(roundedRect: vr, cornerRadius: 4),
                               with: .color(.accentColor),
                               style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

                // Corner resize handles — rect kinds only; numbers stay
                // move-only. Drawn on top of the dashed indicator.
                if case .number = selected.kind {} else {
                    let corners = [CGPoint(x: vr.minX, y: vr.minY),
                                   CGPoint(x: vr.maxX, y: vr.minY),
                                   CGPoint(x: vr.minX, y: vr.maxY),
                                   CGPoint(x: vr.maxX, y: vr.maxY)]
                    for corner in corners {
                        let handleRect = CGRect(x: corner.x - 3.5, y: corner.y - 3.5,
                                                width: 7, height: 7)
                        context.fill(Path(handleRect), with: .color(.white))
                        context.stroke(Path(handleRect), with: .color(.accentColor),
                                       lineWidth: 1)
                    }
                }
            }
        }
    }

    /// Invisible buttons that give us Delete/Backspace and Esc handling
    /// without relying on `.onDeleteCommand` focus behavior.
    private var hiddenKeyButtons: some View {
        Group {
            Button("") { model.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: [])
            Button("") { model.deselect() }
                .keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func scaledRect(_ rect: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: rect.origin.x * scale,
               y: rect.origin.y * scale,
               width: rect.width * scale,
               height: rect.height * scale)
    }
}

/// Union of rounded blur rects, usable directly as a mask.
struct BlurMask: Shape {
    let rects: [CGRect]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for r in rects {
            path.addRoundedRect(in: r, cornerSize: CGSize(width: 6, height: 6))
        }
        return path
    }
}