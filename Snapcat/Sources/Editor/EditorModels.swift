import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    case blur, number, ellipse, rectangle, text

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .blur:      return "eye.slash"
        case .number:    return "1.circle"
        case .ellipse:   return "circle"
        case .rectangle: return "rectangle"
        case .text:      return "textformat"
        }
    }

    var label: String {
        switch self {
        case .blur:      return "Blur"
        case .number:    return "Number"
        case .ellipse:   return "Oval"
        case .rectangle: return "Box"
        case .text:      return "Text"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .blur:      return "b"
        case .number:    return "n"
        case .ellipse:   return "o"
        case .rectangle: return "r"
        case .text:      return "t"
        }
    }
}

struct Annotation: Identifiable {
    enum Kind {
        case blur(CGRect)
        case number(center: CGPoint, value: Int)
        case ellipse(CGRect)
        case rectangle(CGRect)
        case text(origin: CGPoint, string: String)
    }

    let id = UUID()
    var kind: Kind
    var color: Color        // ignored for .blur
    var blurLevel: Int = 3  // 1...10; meaningful only for .blur
    var fontSize: CGFloat = 30  // pt; meaningful only for .text
    /// Wrap width in image px (.text only). nil = auto-size to content,
    /// no wrapping; set by dragging the side handles.
    var textWrapWidth: CGFloat?

    /// A copy of this annotation (same id) with its rect replaced.
    /// Returns self unchanged for `.number` and `.text` (belt-and-braces:
    /// the drag state machine never targets them for rect resize — text
    /// scales via fontSize instead).
    func withRect(_ rect: CGRect) -> Annotation {
        var copy = self
        switch kind {
        case .blur:      copy.kind = .blur(rect)
        case .ellipse:   copy.kind = .ellipse(rect)
        case .rectangle: copy.kind = .rectangle(rect)
        case .number, .text: break
        }
        return copy
    }

    /// A copy of this annotation (same id) with its geometry offset by `delta`.
    func moved(by delta: CGVector) -> Annotation {
        var copy = self
        switch kind {
        case let .blur(rect):
            copy.kind = .blur(rect.offsetBy(dx: delta.dx, dy: delta.dy))
        case let .number(center, value):
            copy.kind = .number(center: CGPoint(x: center.x + delta.dx,
                                                y: center.y + delta.dy),
                                value: value)
        case let .ellipse(rect):
            copy.kind = .ellipse(rect.offsetBy(dx: delta.dx, dy: delta.dy))
        case let .rectangle(rect):
            copy.kind = .rectangle(rect.offsetBy(dx: delta.dx, dy: delta.dy))
        case let .text(origin, string):
            copy.kind = .text(origin: CGPoint(x: origin.x + delta.dx,
                                              y: origin.y + delta.dy),
                              string: string)
        }
        return copy
    }

    /// Bounding rect in image pixels. Numbers need the badge diameter,
    /// which lives on the view model.
    func bounds(numberDiameter: CGFloat) -> CGRect {
        switch kind {
        case let .blur(rect), let .ellipse(rect), let .rectangle(rect):
            return rect
        case let .number(center, _):
            let radius = numberDiameter / 2
            return CGRect(x: center.x - radius,
                          y: center.y - radius,
                          width: numberDiameter,
                          height: numberDiameter)
        case let .text(origin, _):
            // Real text bounds require font measurement — use
            // EditorViewModel.bounds(of:) everywhere instead.
            return CGRect(origin: origin, size: .zero)
        }
    }
}
