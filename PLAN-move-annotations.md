# Snapcat v1.1 — Movable / selectable annotations (Source of Truth)

Goal: in the editor, existing annotations (blur regions, numbered badges,
ellipses, rectangles) can be selected, dragged to a new position, and deleted —
CleanShot-style, with no separate "select" tool. Drawing still works exactly as
before when the drag starts on empty canvas.

The codebase has changed since the v1 build (preview card redesign, Save
button, hotkey ⇧⌘4, real signing). **Re-read these files before editing —
do not rely on your memory of them:** `Snapcat/Sources/Editor/EditorModels.swift`,
`EditorViewModel.swift`, `EditorView.swift`. Only those three files change in
this task. Do not touch capture, preview panel, window controller, export
behavior, project.yml, or PLAN.md.

Build/acceptance identical to v1: `xcodebuild -project Snapcat.xcodeproj
-scheme Snapcat -configuration Debug build` exits 0, no new warnings. Do not
run the app.

## UX rules (the contract)

1. Drag starting ON an existing annotation's *solid part* → moves that
   annotation (topmost first, i.e. iterate `annotations.reversed()`).
2. Drag starting on empty canvas → current drawing behavior (and deselects).
3. Plain click (drag distance < 3 image px) on a solid part → selects only.
   Plain click on empty canvas → deselects; with the number tool it places a
   badge exactly as today.
4. "Solid part" per kind (hit-testing is in IMAGE pixel coordinates):
   - `.number(center, _)`: circle of radius `numberDiameter/2 + tol`.
   - `.blur(r)`: the whole rect `r` (it reads as a solid block).
   - `.rectangle(r)` / `.ellipse(r)`: only the stroke band — point is inside
     `r.insetBy(dx: -tol, dy: -tol)` but NOT inside `r.insetBy(dx: +tol, dy: +tol)`
     (if `r` is smaller than `2*tol` on either axis, the whole rect counts).
     Rationale: clicking INSIDE an empty box must still draw/place on top of it.
   - `tol = max(lineWidthImage * 1.5, 10 / scale)` — pass the current view
     scale in so the finger target stays ~10 view points regardless of zoom.
5. Selected annotation shows a selection indicator (see View section). The
   just-moved or just-drawn annotation becomes selected.
6. **Delete / Backspace** removes the selected annotation. **Esc** deselects.
7. Moving is unclamped (a shape may hang past the image edge; export already
   clips naturally). Blur regions moved = the pixellated mask simply follows
   the rect — no extra work needed, verify it previews live while dragging.

## EditorModels.swift

Add to `Annotation`:

```swift
func moved(by delta: CGVector) -> Annotation   // returns a copy with kind offset
var bounds: CGRect                              // number → the badge circle's rect
```

`moved(by:)` offsets the rect (`offsetBy`) or the number's center. `bounds`
needs the badge diameter, which lives on the view model — instead give
`Annotation` a `func bounds(numberDiameter: CGFloat) -> CGRect`.

## EditorViewModel.swift

New published state: `@Published var selectedID: UUID?`.

Replace the pop-last undo with a snapshot history:

```swift
private var history: [[Annotation]] = []   // cap at 50 entries (drop oldest)
private func pushHistory() { ... }          // call BEFORE every mutation
func undo()                                  // restore last snapshot; if the
                                             // selected id no longer exists, deselect
var canUndo: Bool { !history.isEmpty }
```

Mutations that push history: committing a drawn annotation, starting a real
move (one snapshot per move gesture, not per drag tick), deleting.

Drag state machine (private):

```swift
private enum ActiveDrag {
    case draw
    case move(id: UUID, original: Annotation)
}
private var activeDrag: ActiveDrag?
```

`dragChanged(startView:currentView:scale:)`:
- On the FIRST change of a gesture (`activeDrag == nil`): hit-test the start
  point. Hit → `activeDrag = .move(id, originalCopy)`, `selectedID = id`,
  `pushHistory()`. Miss → `activeDrag = .draw`, `selectedID = nil`, then the
  existing draft logic.
- `.move`: `delta = current − start` (image space); replace the annotation
  having that id with `original.moved(by: delta)` — always relative to the
  gesture's ORIGINAL copy, never cumulative, or the shape accelerates.
- `.draw`: existing behavior unchanged.

`dragEnded(startView:currentView:scale:)` — `defer { activeDrag = nil; draft = nil }`:
- `.move`: if total drag distance < 3 image px, it was a click-select: the
  annotation hasn't effectively moved, so REMOVE the history snapshot pushed at
  gesture start (`history.removeLast()`) — otherwise ⌘Z would appear to do
  nothing. Keep the selection either way.
- `.draw` (or nil): existing commit logic, with two changes: `pushHistory()`
  immediately before appending, and set `selectedID` to the new annotation's id
  after appending. The number-tool click keeps placing a badge as today.
- Keep the existing >3 px minimum for rect-based commits.

`deleteSelected()`: if a selection exists → `pushHistory()`, remove it, deselect.
`deselect()`: `selectedID = nil`.
`hitTest(_ point: CGPoint, scale: CGFloat) -> UUID?` per the UX rules above.

Export (`renderFinal`) is untouched — selection is view-only state and must not
render into the exported image.

## EditorView.swift

- Undo button: disable on `!model.canUndo` instead of `annotations.isEmpty`.
- Selection indicator in the annotation `Canvas` (view space): for the selected
  annotation, stroke a rounded rect (`cornerRadius` 4) around
  `bounds(numberDiameter:)` scaled to view space and inset by −6 view pt,
  `Color.accentColor`, `lineWidth` 1.5, dash `[4, 3]`. Draw it AFTER all
  annotations so it sits on top. Skip while that annotation is mid-move? No —
  keep it visible during the move; it doubles as drag feedback.
- Keyboard: SwiftUI's `.onDeleteCommand` needs a focused view and is flaky on
  a plain Canvas — instead add two hidden buttons (e.g. in a 0-opacity
  `background`): one with `.keyboardShortcut(.delete, modifiers: [])` calling
  `model.deleteSelected()`, one with `.keyboardShortcut(.cancelAction)` calling
  `model.deselect()`. Buttons must not be visible or focusable-looking:
  `Button("") { … }.keyboardShortcut(…).opacity(0).frame(width: 0, height: 0)`.
  (`.cancelAction` = Esc.)
- Cursor stays crosshair everywhere — acceptable for v1.1; do not add
  per-object cursor logic.

## Pitfalls

- All hit-testing/moving in image pixel coordinates; only the tolerance is
  derived from view points via `scale`. Do not mix spaces.
- One history snapshot per user action (gesture/commit/delete) — never per
  onChanged tick.
- Move must be computed from the gesture's original annotation copy.
- Selection state must not leak into export.
- `annotations.reversed()` for hit-testing so the topmost (most recent) wins.
- Blur mask (`blurRects`) reads committed annotations — a moving blur rect
  updates live for free; don't special-case it.

Report: what changed per file, any deviation + why, final BUILD result.
