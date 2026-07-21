import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

final class EditorViewModel: ObservableObject {

    // Immutable image data (all in PIXEL coordinates, top-left origin).
    let cgImage: CGImage
    let pixelSize: CGSize
    let baseNSImage: NSImage

    /// Pixels per logical point of the source image. screencapture embeds
    /// DPI metadata, so NSImage.size is in points while cgImage is pixels
    /// (2 on Retina). Font pt → image px = pt × displayScale.
    let displayScale: CGFloat

    // Published editor state.
    @Published var tool: EditorTool = .rectangle {
        didSet {
            // Switching tools mid-typing ends the session cleanly.
            if oldValue != tool { commitTextEditing() }
        }
    }
    @Published var color: Color = .red {
        didSet {
            // Mid-edit swatch changes recolor the text being typed.
            guard let id = editingTextID,
                  let index = annotations.firstIndex(where: { $0.id == id }) else { return }
            annotations[index].color = color
        }
    }
    @Published var annotations: [Annotation] = []
    @Published var draft: Annotation?
    @Published var justCopied: Bool = false
    @Published var selectedID: UUID?
    @Published var blurLevel: Int = 3   // tool default, applied to new blur regions
    @Published var textFontSize: CGFloat = 30   // tool default, pt
    @Published var editingTextID: UUID?
    @Published var editingBuffer: String = ""
    /// Pre-edit copy when re-editing an existing text; nil for newly created.
    private var editingOriginal: Annotation?

    private var justCopiedWorkItem: DispatchWorkItem?

    // MARK: - Per-level pixellation cache

    private let ciContext = CIContext(options: nil)
    private var blurCG: [Int: CGImage] = [:]
    private var blurNS: [Int: NSImage] = [:]

    /// Level → pixellate scale mapping (level 3 ≈ the original look).
    func pixellateScale(level: Int) -> CGFloat {
        max(6, pixelSize.width / 270 * CGFloat(level))
    }

    func blurredCG(level: Int) -> CGImage {
        let level = level.clamped(to: 1...10)
        if let cached = blurCG[level] { return cached }
        let input = CIImage(cgImage: cgImage).clampedToExtent()
        let filter = CIFilter.pixellate()
        filter.inputImage = input
        filter.scale = Float(pixellateScale(level: level))
        let extent = CGRect(origin: .zero, size: pixelSize)
        let output = (filter.outputImage ?? input).cropped(to: extent)
        let rendered = ciContext.createCGImage(output, from: extent) ?? cgImage
        blurCG[level] = rendered
        return rendered
    }

    func blurredNSImage(level: Int) -> NSImage {
        let level = level.clamped(to: 1...10)
        if let cached = blurNS[level] { return cached }
        let image = NSImage(cgImage: blurredCG(level: level), size: pixelSize)  // 1 pt = 1 px
        blurNS[level] = image
        return image
    }

    // MARK: - Undo history (one snapshot per user action)

    private var history: [[Annotation]] = []

    var canUndo: Bool { !history.isEmpty }

    /// Call BEFORE every mutation. Capped at 50 entries (oldest dropped).
    private func pushHistory() {
        history.append(annotations)
        if history.count > 50 {
            history.removeFirst()
        }
    }

    func undo() {
        guard let snapshot = history.popLast() else { return }
        annotations = snapshot
        if let selected = selectedID,
           !annotations.contains(where: { $0.id == selected }) {
            selectedID = nil
        }
    }

    // MARK: - Drag state machine

    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var opposite: Corner {
            switch self {
            case .topLeft:     return .bottomRight
            case .topRight:    return .bottomLeft
            case .bottomLeft:  return .topRight
            case .bottomRight: return .topLeft
            }
        }
    }

    private enum ActiveDrag {
        case draw
        case move(id: UUID, original: Annotation)
        case resize(id: UUID, original: Annotation, corner: Corner)
        case resizeTextWidth(id: UUID, original: Annotation, leftEdge: Bool)
        /// The press that ended a typing session — consumed whole: no draw,
        /// no select. The user clicks again to start the next thing.
        case swallow
    }

    /// What a handle hit resolves to: a rect corner (shapes; bottom-right on
    /// text scales the font) or a text side-circle (wrap width).
    private enum HandleTarget {
        case corner(Corner)
        case textEdge(left: Bool)
    }

    private var activeDrag: ActiveDrag?

    /// Corner point of a rect in image coordinates (top-left origin ⇒ top = minY).
    private func cornerPoint(_ corner: Corner, of rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    /// If `point` (image px) falls in a handle hit zone of the SELECTED
    /// annotation, return the resize target. Handle zones are circles of
    /// radius ~10 view points around the handle's actual position.
    private func handleHit(at point: CGPoint, scale: CGFloat) -> (id: UUID, original: Annotation, target: HandleTarget)? {
        guard let selected = selectedID,
              let annotation = annotations.first(where: { $0.id == selected }) else { return nil }
        func hits(_ p: CGPoint, radius: CGFloat) -> Bool {
            let dx = point.x - p.x
            let dy = point.y - p.y
            return dx * dx + dy * dy <= radius * radius
        }
        switch annotation.kind {
        case .number:
            return nil   // number badges stay move-only
        case .text:
            // Bottom-right square scales the font; side circles set the
            // wrap width. Corner wins when the zones overlap (tiny text).
            let rect = handleBox(of: annotation, scale: scale)
            let radius = 10 / scale
            if hits(cornerPoint(.bottomRight, of: rect), radius: radius) {
                return (annotation.id, annotation, .corner(.bottomRight))
            }
            if hits(CGPoint(x: rect.minX, y: rect.midY), radius: radius) {
                return (annotation.id, annotation, .textEdge(left: true))
            }
            if hits(CGPoint(x: rect.maxX, y: rect.midY), radius: radius) {
                return (annotation.id, annotation, .textEdge(left: false))
            }
            return nil
        case let .blur(rect), let .ellipse(rect), let .rectangle(rect):
            let radius = 10 / scale
            for corner in Corner.allCases {
                if hits(cornerPoint(corner, of: rect), radius: radius) {
                    return (annotation.id, annotation, .corner(corner))
                }
            }
            return nil
        }
    }

    // MARK: - Init

    init?(image: NSImage) {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        self.cgImage = cg
        let size = CGSize(width: cg.width, height: cg.height)
        self.pixelSize = size
        self.baseNSImage = NSImage(cgImage: cg, size: size)

        let logicalWidth = image.size.width
        let ratio = logicalWidth > 0 ? size.width / logicalWidth : 1
        self.displayScale = (ratio.isFinite && ratio > 0) ? ratio : 1

        // Warm the cache for the default level so first paint is instant.
        _ = blurredNSImage(level: 3)
    }

    // MARK: - Derived sizing (shared by preview + export)

    var nextNumber: Int {
        annotations.reduce(0) { count, annotation in
            if case .number = annotation.kind { return count + 1 }
            return count
        } + 1
    }

    var lineWidthImage: CGFloat {
        max(4, pixelSize.width * 0.004)
    }

    var numberDiameter: CGFloat {
        max(32, pixelSize.width * 0.028)
    }

    /// Rendered size of a text annotation's string in image pixels.
    /// Multi-line aware (Enter inserts newlines); with `wrapWidth` the box
    /// keeps that width and the text re-flows inside it (side handles).
    func textDisplaySize(_ string: String, fontSize: CGFloat,
                         wrapWidth: CGFloat? = nil) -> CGSize {
        let font = NSFont.boldSystemFont(ofSize: fontSize * displayScale)
        let attributed = NSAttributedString(string: string, attributes: [.font: font])
        let constraint = CGSize(width: wrapWidth ?? CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        let rect = attributed.boundingRect(with: constraint,
                                           options: [.usesLineFragmentOrigin])
        // Floors keep empty/short strings hittable and the edit frame visible.
        return CGSize(width: max(ceil(wrapWidth ?? rect.width), fontSize * displayScale * 0.5),
                      height: max(ceil(rect.height), fontSize * displayScale * 1.1))
    }

    /// Bounding rect in image pixels for ANY kind — text needs measurement,
    /// so callers should prefer this over Annotation.bounds(numberDiameter:).
    func bounds(of annotation: Annotation) -> CGRect {
        if case let .text(origin, string) = annotation.kind {
            return CGRect(origin: origin,
                          size: textDisplaySize(string, fontSize: annotation.fontSize,
                                                wrapWidth: annotation.textWrapWidth))
        }
        return annotation.bounds(numberDiameter: numberDiameter)
    }

    /// Bounds as currently SHOWN: while a text is being typed, the live
    /// buffer (plus caret room, matching the floating editor's frame) drives
    /// the size — the committed string is stale until commit.
    func displayBounds(of annotation: Annotation) -> CGRect {
        guard annotation.id == editingTextID,
              case let .text(origin, _) = annotation.kind else {
            return bounds(of: annotation)
        }
        return CGRect(origin: origin,
                      size: textDisplaySize(editingBuffer + "M",
                                            fontSize: annotation.fontSize,
                                            wrapWidth: annotation.textWrapWidth))
    }

    /// The rect handles anchor to, in image px. While editing this mirrors
    /// the floating editor's padded frame (view-space constants: 3pt padding
    /// all around, extra 5pt NSTextView line-fragment inset on the left),
    /// so drawn handles, their hit zones, and the visible border coincide.
    func handleBox(of annotation: Annotation, scale: CGFloat) -> CGRect {
        let rect = displayBounds(of: annotation)
        guard annotation.id == editingTextID else { return rect }
        return CGRect(x: rect.minX - 8 / scale,
                      y: rect.minY - 3 / scale,
                      width: rect.width + 6 / scale,
                      height: rect.height + 6 / scale)
    }

    // MARK: - Interaction

    private func imagePoint(from viewPoint: CGPoint, scale: CGFloat) -> CGPoint {
        let x = (viewPoint.x / scale).clamped(to: 0...pixelSize.width)
        let y = (viewPoint.y / scale).clamped(to: 0...pixelSize.height)
        return CGPoint(x: x, y: y)
    }

    private func normalizedRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x),
               y: min(a.y, b.y),
               width: abs(a.x - b.x),
               height: abs(a.y - b.y))
    }

    /// Topmost (most recent) annotation whose solid part contains `point`
    /// (image pixel coordinates). Tolerance tracks ~10 view points.
    func hitTest(_ point: CGPoint, scale: CGFloat) -> UUID? {
        let tol = max(lineWidthImage * 1.5, 10 / scale)
        for annotation in annotations.reversed() {
            switch annotation.kind {
            case let .number(center, _):
                let radius = numberDiameter / 2 + tol
                let dx = point.x - center.x
                let dy = point.y - center.y
                if dx * dx + dy * dy <= radius * radius {
                    return annotation.id
                }
            case let .blur(rect):
                // A blur reads as a solid block — the whole rect hits.
                if rect.contains(point) {
                    return annotation.id
                }
            case let .rectangle(rect), let .ellipse(rect):
                // Only the stroke band: inside the clicked box must still
                // draw/place on top of it.
                let outer = rect.insetBy(dx: -tol, dy: -tol)
                guard outer.contains(point) else { break }
                if rect.width <= 2 * tol || rect.height <= 2 * tol {
                    return annotation.id
                }
                let inner = rect.insetBy(dx: tol, dy: tol)
                if !inner.contains(point) {
                    return annotation.id
                }
            case .text:
                // Text reads as a solid block — the whole measured rect hits.
                if bounds(of: annotation).insetBy(dx: -tol, dy: -tol).contains(point) {
                    return annotation.id
                }
            }
        }
        return nil
    }

    func dragChanged(startView: CGPoint, currentView: CGPoint, scale: CGFloat) {
        let start = imagePoint(from: startView, scale: scale)
        let current = imagePoint(from: currentView, scale: scale)

        // First change of the gesture: decide resize vs move vs draw.
        // Handle check comes BEFORE hitTest so a handle overlapping another
        // object still wins (and only the selected annotation has handles).
        if activeDrag == nil {
            if editingTextID != nil {
                // Handles stay live while typing — grabbing one resizes
                // without ending the session (no extra snapshot either:
                // mid-edit changes ride the session's snapshot, so Esc
                // still reverts everything in one go).
                if let hit = handleHit(at: start, scale: scale), hit.id == editingTextID {
                    switch hit.target {
                    case let .corner(corner):
                        activeDrag = .resize(id: hit.id, original: hit.original, corner: corner)
                    case let .textEdge(left):
                        activeDrag = .resizeTextWidth(id: hit.id, original: hit.original, leftEdge: left)
                    }
                } else {
                    // Any other press just ends the session and is consumed
                    // whole — no new box, no select-through. The next click
                    // acts normally.
                    commitTextEditing()
                    activeDrag = .swallow
                }
            } else if let hit = handleHit(at: start, scale: scale) {
                switch hit.target {
                case let .corner(corner):
                    activeDrag = .resize(id: hit.id, original: hit.original, corner: corner)
                case let .textEdge(left):
                    activeDrag = .resizeTextWidth(id: hit.id, original: hit.original, leftEdge: left)
                }
                pushHistory()
            } else if let id = hitTest(start, scale: scale),
                      let original = annotations.first(where: { $0.id == id }) {
                activeDrag = .move(id: id, original: original)
                selectedID = id
                pushHistory()
            } else {
                activeDrag = .draw
                selectedID = nil
            }
        }

        switch activeDrag {
        case let .move(id, original):
            // Unclamped delta from raw view points — a shape may hang past
            // the image edge. Always relative to the gesture's ORIGINAL copy.
            let delta = CGVector(dx: (currentView.x - startView.x) / scale,
                                 dy: (currentView.y - startView.y) / scale)
            if let index = annotations.firstIndex(where: { $0.id == id }) {
                annotations[index] = original.moved(by: delta)
            }
        case let .resize(id, original, corner):
            let delta = CGVector(dx: (currentView.x - startView.x) / scale,
                                 dy: (currentView.y - startView.y) / scale)
            if case let .text(origin, _) = original.kind {
                // Single bottom-right handle: font size follows the ratio of
                // the dragged diagonal (origin → cursor) to the original one.
                let rect = displayBounds(of: original)
                let dragged = CGPoint(x: rect.maxX + delta.dx,
                                      y: rect.maxY + delta.dy)
                let originalDiagonal = hypot(rect.width, rect.height)
                guard originalDiagonal > 0 else { break }
                let newDiagonal = hypot(max(dragged.x - origin.x, 0),
                                        max(dragged.y - origin.y, 0))
                if let index = annotations.firstIndex(where: { $0.id == id }) {
                    var copy = original
                    copy.fontSize = (original.fontSize * newDiagonal / originalDiagonal)
                        .clamped(to: 6...400)
                    // The box scales as one unit — wrap width follows the
                    // font (post-clamp ratio keeps them in sync at limits).
                    let ratio = copy.fontSize / original.fontSize
                    copy.textWrapWidth = original.textWrapWidth.map { $0 * ratio }
                    annotations[index] = copy
                }
            } else {
                // Dragged corner follows the cursor (unclamped); the OPPOSITE
                // corner of the ORIGINAL rect is the fixed anchor. Re-normalizing
                // every tick lets the rect flip naturally past the anchor.
                let rect = bounds(of: original)
                let movingCorner = cornerPoint(corner, of: rect)
                let moved = CGPoint(x: movingCorner.x + delta.dx,
                                    y: movingCorner.y + delta.dy)
                let anchor = cornerPoint(corner.opposite, of: rect)
                if let index = annotations.firstIndex(where: { $0.id == id }) {
                    annotations[index] = original.withRect(normalizedRect(anchor, moved))
                }
            }
        case let .resizeTextWidth(id, original, leftEdge):
            // Side circles re-flow the text: the dragged edge follows the
            // cursor, the opposite edge stays put. Width floor = one glyph.
            let dx = (currentView.x - startView.x) / scale
            let rect = displayBounds(of: original)
            let minWidth = original.fontSize * displayScale
            if let index = annotations.firstIndex(where: { $0.id == id }) {
                var copy = original
                if leftEdge {
                    let width = max(rect.width - dx, minWidth)
                    if case let .text(_, string) = original.kind {
                        copy.kind = .text(origin: CGPoint(x: rect.maxX - width,
                                                          y: rect.minY),
                                          string: string)
                    }
                    copy.textWrapWidth = width
                } else {
                    copy.textWrapWidth = max(rect.width + dx, minWidth)
                }
                annotations[index] = copy
            }
        case .swallow:
            break
        case .draw, nil:
            switch tool {
            case .number:
                draft = Annotation(kind: .number(center: current, value: nextNumber), color: color)
            case .rectangle:
                draft = Annotation(kind: .rectangle(normalizedRect(start, current)), color: color)
            case .ellipse:
                draft = Annotation(kind: .ellipse(normalizedRect(start, current)), color: color)
            case .blur:
                draft = Annotation(kind: .blur(normalizedRect(start, current)), color: color,
                                   blurLevel: blurLevel)
            case .text:
                break   // click-to-place; no drag preview
            }
        }
    }

    func dragEnded(startView: CGPoint, currentView: CGPoint, scale: CGFloat) {
        defer {
            activeDrag = nil
            draft = nil
        }
        let start = imagePoint(from: startView, scale: scale)
        let current = imagePoint(from: currentView, scale: scale)

        switch activeDrag {
        case let .move(id, original):
            let dx = (currentView.x - startView.x) / scale
            let dy = (currentView.y - startView.y) / scale
            if (dx * dx + dy * dy).squareRoot() < 3 {
                // Click-select: the annotation hasn't effectively moved.
                // Snap it back and drop the snapshot pushed at gesture start,
                // otherwise ⌘Z would appear to do nothing. Keep the selection.
                if let index = annotations.firstIndex(where: { $0.id == id }) {
                    annotations[index] = original
                }
                if !history.isEmpty {
                    history.removeLast()
                }
                // Double-click on a text opens the inline editor (AppKit
                // still knows the click count during a SwiftUI DragGesture).
                if let annotation = annotations.first(where: { $0.id == id }),
                   case .text = annotation.kind,
                   (NSApp.currentEvent?.clickCount ?? 0) >= 2 {
                    startEditing(id)
                }
            }
        case .swallow:
            break
        case let .resizeTextWidth(id, original, _):
            // No-move click on a side circle: restore + drop the snapshot
            // (same pattern as the corner-resize path below). Mid-edit drags
            // never pushed one — the session snapshot must survive.
            let dx = (currentView.x - startView.x) / scale
            let dy = (currentView.y - startView.y) / scale
            if (dx * dx + dy * dy).squareRoot() < 3 {
                if let index = annotations.firstIndex(where: { $0.id == id }) {
                    annotations[index] = original
                }
                if !history.isEmpty, editingTextID == nil {
                    history.removeLast()
                }
            }
        case let .resize(id, original, _):
            let dx = (currentView.x - startView.x) / scale
            let dy = (currentView.y - startView.y) / scale
            let distance = (dx * dx + dy * dy).squareRoot()
            let finalRect = annotations.first(where: { $0.id == id })
                .map { bounds(of: $0) }
            let tooSmall = finalRect.map { $0.width < 3 || $0.height < 3 } ?? true
            if distance < 3 || tooSmall {
                // Degenerate resize or no-move click on a handle: restore the
                // original and drop this gesture's snapshot (same pattern as
                // click-select). Selection is kept in all cases. Mid-edit
                // drags never pushed — keep the session snapshot intact.
                if let index = annotations.firstIndex(where: { $0.id == id }) {
                    annotations[index] = original
                }
                if !history.isEmpty, editingTextID == nil {
                    history.removeLast()
                }
            }
        case .draw, nil:
            switch tool {
            case .number:
                pushHistory()
                let annotation = Annotation(kind: .number(center: current, value: nextNumber), color: color)
                annotations.append(annotation)
                selectedID = annotation.id
            case .rectangle:
                let rect = normalizedRect(start, current)
                if rect.width > 3, rect.height > 3 {
                    pushHistory()
                    let annotation = Annotation(kind: .rectangle(rect), color: color)
                    annotations.append(annotation)
                    selectedID = annotation.id
                }
            case .ellipse:
                let rect = normalizedRect(start, current)
                if rect.width > 3, rect.height > 3 {
                    pushHistory()
                    let annotation = Annotation(kind: .ellipse(rect), color: color)
                    annotations.append(annotation)
                    selectedID = annotation.id
                }
            case .blur:
                let rect = normalizedRect(start, current)
                if rect.width > 3, rect.height > 3 {
                    pushHistory()
                    let annotation = Annotation(kind: .blur(rect), color: color,
                                                blurLevel: blurLevel)
                    annotations.append(annotation)
                    selectedID = annotation.id
                }
            case .text:
                // Click OR long drag both place a new text at the gesture's
                // start point (no drag-to-size — text has no word wrap).
                startNewText(at: start)
            }
        }
    }

    // MARK: - Blur level editing

    /// The selected annotation's id, but only if it's a blur region.
    var selectedBlurID: UUID? {
        guard let selected = selectedID,
              let annotation = annotations.first(where: { $0.id == selected }),
              case .blur = annotation.kind else { return nil }
        return selected
    }

    /// One history snapshot per slider gesture — only when a blur region is
    /// selected (tool-default changes are not undoable state).
    func beginBlurLevelEdit() {
        if selectedBlurID != nil {
            pushHistory()
        }
    }

    func setBlurLevel(_ level: Int) {
        let level = level.clamped(to: 1...10)
        if let id = selectedBlurID,
           let index = annotations.firstIndex(where: { $0.id == id }) {
            annotations[index].blurLevel = level
        } else {
            blurLevel = level
        }
    }

    // MARK: - Text editing

    /// The selected annotation's id, but only if it's a text.
    var selectedTextID: UUID? {
        guard let selected = selectedID,
              let annotation = annotations.first(where: { $0.id == selected }),
              case .text = annotation.kind else { return nil }
        return selected
    }

    /// Begin typing a brand-new text at `point` (image px).
    /// One history snapshot; commitTextEditing drops it if nothing was typed.
    func startNewText(at point: CGPoint) {
        commitTextEditing()
        pushHistory()
        var annotation = Annotation(kind: .text(origin: point, string: ""), color: color)
        annotation.fontSize = textFontSize
        annotations.append(annotation)
        selectedID = annotation.id
        editingTextID = annotation.id
        editingBuffer = ""
        editingOriginal = nil
    }

    /// Re-open an existing text annotation for editing (double-click).
    func startEditing(_ id: UUID) {
        commitTextEditing()
        guard let annotation = annotations.first(where: { $0.id == id }),
              case let .text(_, string) = annotation.kind else { return }
        pushHistory()
        editingOriginal = annotation
        editingTextID = id
        editingBuffer = string
        selectedID = id
    }

    /// Commit the buffer into the annotation. Empty (after trimming) means
    /// the user typed nothing worth keeping: remove the annotation and drop
    /// the session's snapshot so ⌘Z stays meaningful. An unchanged re-edit
    /// also drops its snapshot (same click-select pattern as dragEnded).
    func commitTextEditing() {
        guard let id = editingTextID else { return }
        defer {
            editingTextID = nil
            editingBuffer = ""
            editingOriginal = nil
        }
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = editingBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            annotations.remove(at: index)
            if selectedID == id { selectedID = nil }
            if !history.isEmpty { history.removeLast() }
            return
        }
        if case let .text(origin, _) = annotations[index].kind {
            annotations[index].kind = .text(origin: origin, string: editingBuffer)
        }
        if let original = editingOriginal,
           case let .text(_, originalString) = original.kind,
           originalString == editingBuffer,
           original.color == annotations[index].color,
           original.fontSize == annotations[index].fontSize,
           !history.isEmpty {
            history.removeLast()
        }
    }

    /// Abort the session (Esc): new text vanishes, re-edited text reverts.
    func cancelTextEditing() {
        guard let id = editingTextID else { return }
        defer {
            editingTextID = nil
            editingBuffer = ""
            editingOriginal = nil
        }
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        if let original = editingOriginal {
            annotations[index] = original
        } else {
            annotations.remove(at: index)
            if selectedID == id { selectedID = nil }
        }
        if !history.isEmpty { history.removeLast() }
    }

    /// Dropdown setter. Applies to the text being edited/selected (one undo
    /// snapshot when it's a committed one) and always becomes the new tool
    /// default, so the next text starts at the last-used size.
    func setTextFontSize(_ size: CGFloat) {
        let clamped = size.clamped(to: 6...400)
        textFontSize = clamped
        guard let id = editingTextID ?? selectedTextID,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        // Mid-edit changes ride the editing session's snapshot; cancel must
        // restore the pre-edit size too, so don't push a second one.
        if editingTextID == nil {
            pushHistory()
        }
        annotations[index].fontSize = clamped
    }

    func deleteSelected() {
        guard let selected = selectedID,
              let index = annotations.firstIndex(where: { $0.id == selected }) else { return }
        pushHistory()
        let removed = annotations.remove(at: index)
        // Deleting a badge from the middle would break the count-derived
        // `nextNumber` invariant (values == 1...count) — renumber to restore it.
        if case .number = removed.kind {
            renumberBadges()
        }
        selectedID = nil
    }

    /// Reassign every `.number` annotation's value sequentially from 1,
    /// in array (placement) order.
    private func renumberBadges() {
        var next = 1
        for index in annotations.indices {
            if case let .number(center, _) = annotations[index].kind {
                annotations[index].kind = .number(center: center, value: next)
                next += 1
            }
        }
    }

    func deselect() {
        selectedID = nil
    }

    /// One group per blur level in use, view-space rects. Levels sorted
    /// ascending for stable view identity.
    struct BlurGroup: Identifiable {
        let level: Int
        let rects: [CGRect]
        var id: Int { level }
    }

    /// Committed blur rects (+ in-progress draft blur), grouped by level and
    /// scaled to view space.
    func blurGroups(scale: CGFloat) -> [BlurGroup] {
        var groups: [Int: [CGRect]] = [:]
        for annotation in annotations {
            if case let .blur(rect) = annotation.kind {
                groups[annotation.blurLevel, default: []].append(scaledRect(rect, scale: scale))
            }
        }
        if let draft = draft, case let .blur(rect) = draft.kind {
            groups[draft.blurLevel, default: []].append(scaledRect(rect, scale: scale))
        }
        return groups.keys.sorted().map { BlurGroup(level: $0, rects: groups[$0]!) }
    }

    private func scaledRect(_ rect: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: rect.origin.x * scale,
               y: rect.origin.y * scale,
               width: rect.width * scale,
               height: rect.height * scale)
    }

    // MARK: - Export

    func renderFinal() -> NSImage {
        let size = pixelSize
        let pixelH = size.height

        // Freeze mutable state NOW. NSImage rasterizes lazily — for the
        // pasteboard that can happen at paste time, after the user has kept
        // editing. The handler must reflect the state at copy/save time, and
        // must not touch self.annotations or the blur cache (an off-main
        // rasterization would race the cache dictionaries otherwise).
        let frozenAnnotations = annotations
        var blurImages: [Int: NSImage] = [:]
        for annotation in frozenAnnotations {
            if case .blur = annotation.kind {
                blurImages[annotation.blurLevel] = blurredNSImage(level: annotation.blurLevel)
            }
        }

        // NSImage draws lazily — the handler can run long after the editor
        // closes (e.g. when the pasteboard image is rasterized). Capture self
        // strongly: the image is not stored on the VM, so there is no cycle;
        // it just keeps the VM alive as long as the exported image exists.
        // (self is only used for immutable/derived members: baseNSImage,
        // lineWidthImage, numberDiameter, drawNumber.)
        let image = NSImage(size: size, flipped: true) { _ in
            let fullRect = CGRect(origin: .zero, size: size)

            // 1. Base image.
            self.baseNSImage.draw(in: fullRect)

            // 2. Blur regions (per-region level, clipped to the image —
            //    moved/resized regions may hang past the edge).
            for annotation in frozenAnnotations {
                guard case let .blur(rect) = annotation.kind else { continue }
                let clipped = rect.intersection(fullRect)
                guard !clipped.isNull, !clipped.isEmpty else { continue }
                guard let blurImage = blurImages[annotation.blurLevel] else { continue }
                // Source image is bottom-left origin → flip Y for the `from:` rect.
                let fromRect = CGRect(x: clipped.origin.x,
                                      y: pixelH - clipped.maxY,
                                      width: clipped.width,
                                      height: clipped.height)
                blurImage.draw(in: clipped,
                               from: fromRect,
                               operation: .sourceOver,
                               fraction: 1,
                               respectFlipped: true,
                               hints: [.interpolation: NSImageInterpolation.none.rawValue])
            }

            // 3 & 4. Shapes and numbers.
            for annotation in frozenAnnotations {
                let nsColor = NSColor(annotation.color)
                switch annotation.kind {
                case .blur:
                    break
                case let .rectangle(rect):
                    let path = NSBezierPath(rect: rect)
                    path.lineWidth = self.lineWidthImage
                    nsColor.setStroke()
                    path.stroke()
                case let .ellipse(rect):
                    let path = NSBezierPath(ovalIn: rect)
                    path.lineWidth = self.lineWidthImage
                    nsColor.setStroke()
                    path.stroke()
                case let .number(center, value):
                    self.drawNumber(value, at: center, color: nsColor)
                case let .text(origin, string):
                    let font = NSFont.boldSystemFont(ofSize: annotation.fontSize * self.displayScale)
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: nsColor
                    ]
                    // draw(with:) + usesLineFragmentOrigin renders \n line
                    // breaks; draw(at:) would put everything on one line.
                    let size = self.textDisplaySize(string, fontSize: annotation.fontSize,
                                                    wrapWidth: annotation.textWrapWidth)
                    (string as NSString).draw(with: CGRect(origin: origin, size: size),
                                              options: [.usesLineFragmentOrigin],
                                              attributes: attributes,
                                              context: nil)
                }
            }

            return true
        }
        image.size = size
        return image
    }

    private func drawNumber(_ value: Int, at center: CGPoint, color: NSColor) {
        let diameter = numberDiameter
        let radius = diameter / 2
        let circleRect = CGRect(x: center.x - radius,
                                y: center.y - radius,
                                width: diameter,
                                height: diameter)

        // Filled circle.
        let circle = NSBezierPath(ovalIn: circleRect)
        color.setFill()
        circle.fill()

        // White ring (~6% of diameter).
        let ringWidth = diameter * 0.06
        let ring = NSBezierPath(ovalIn: circleRect.insetBy(dx: ringWidth / 2, dy: ringWidth / 2))
        ring.lineWidth = ringWidth
        NSColor.white.setStroke()
        ring.stroke()

        // Value text.
        let font = NSFont.boldSystemFont(ofSize: diameter * 0.55)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let text = "\(value)" as NSString
        let textSize = text.size(withAttributes: attributes)
        let textOrigin = CGPoint(x: center.x - textSize.width / 2,
                                 y: center.y - textSize.height / 2)
        text.draw(at: textOrigin, withAttributes: attributes)
    }

    // MARK: - Actions

    func copyResult() {
        // The toolbar stays clickable while typing — the pasteboard must
        // contain the committed text, not a half-open editing session.
        commitTextEditing()
        CaptureService.copyToClipboard(renderFinal())
        justCopied = true
        justCopiedWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.justCopied = false
        }
        justCopiedWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func saveResult() {
        commitTextEditing()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "Snapcat \(formatter.string(from: Date())).png"

        panel.begin { [weak self] response in
            guard response == .OK,
                  let url = panel.url,
                  let self = self else { return }
            let image = self.renderFinal()
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .png, properties: [:]) else {
                return
            }
            try? data.write(to: url)
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
