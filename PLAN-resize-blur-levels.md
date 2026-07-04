# Snapcat v1.2 — Corner resize handles + per-region blur intensity (Source of Truth)

Two features for the editor:
A. Selected rect-kind annotations get 4 corner handles and can be resized by
   dragging them.
B. Blur strength is adjustable per blur region via a 1–10 slider in the
   toolbar (visible while the blur tool is active, or while a blur region is
   selected — adjusting a selected region updates it live).

Only these files may change: `Snapcat/Sources/Editor/EditorModels.swift`,
`EditorViewModel.swift`, `EditorView.swift`. **Re-read all three from disk
first** — they changed again since your last report (renumberBadges landed).
Everything else (capture, preview, window controller, project.yml, PLAN*.md)
is off-limits.

Acceptance: `xcodebuild -project Snapcat.xcodeproj -scheme Snapcat
-configuration Debug build` exits 0, no new warnings. Don't run the app.

---

## A. Corner resize handles

### UX contract

1. Handles exist ONLY for the selected annotation, and ONLY for rect kinds
   (`.blur`, `.rectangle`, `.ellipse`). `.number` badges stay move-only (their
   size is a global system metric; per-badge sizes would look inconsistent).
2. Visual: the selection indicator today is a dashed accent rounded rect
   around `bounds.insetBy(-6 view pt)`. Draw a handle at each of its 4
   corners: 7×7 view-pt square, white fill, 1 pt `Color.accentColor` stroke,
   drawn after (on top of) the dashed rect in the same `Canvas`.
3. Dragging a handle resizes: the dragged corner follows the cursor, the
   OPPOSITE corner of the original rect is the fixed anchor. Dragging past the
   anchor flips the rect naturally (rect is re-normalized every tick).
4. Resizing a blur region re-blurs the new area live (this falls out of the
   mask — verify, don't special-case).
5. A resize below 3 px width or height at gesture end restores the original
   and drops the gesture's history snapshot (same pattern as click-select).
   A no-move click on a handle (< 3 image px total) does the same.

### Implementation

`ActiveDrag` gains a case:

```swift
case resize(id: UUID, original: Annotation, corner: Corner)
enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }
```

Priority on the FIRST tick of `dragChanged` (order matters):
1. If a selected rect-kind annotation exists and the gesture's start point is
   within a handle hit zone → `.resize` + `pushHistory()`. Handle hit zone:
   circle of radius `10 / scale` (image px) around each corner of the
   annotation's actual rect (use the RECT's corners for geometry, even though
   the visuals sit on the −6-inset indicator — the few points of offset don't
   matter at a 10 pt radius). Handle check comes BEFORE `hitTest` so a handle
   overlapping another object still wins.
2. Else existing `hitTest` → `.move`.
3. Else `.draw`.

Resize math per tick (unclamped, same convention as move):

```swift
delta   = (currentView − startView) / scale            // raw, unclamped
moving  = original rect's corner for `corner` + delta
anchor  = original rect's OPPOSITE corner               // from the ORIGINAL
newRect = normalizedRect(anchor, moving)
annotations[idx] = original with its rect replaced by newRect  // same id, color, level
```

Add a small helper on `Annotation` (Models file):
`func withRect(_ rect: CGRect) -> Annotation` — replaces the rect for the
three rect kinds, returns self unchanged for `.number`.

`dragEnded` for `.resize`: if final rect width < 3 or height < 3 (or total
drag distance < 3 image px), restore `original` at its index and
`history.removeLast()`. Selection is kept in all cases.

---

## B. Per-region blur intensity

### Model

`Annotation` gains `var blurLevel: Int = 3` (meaningful only for `.blur`,
like `color` is ignored for it). Do NOT add an associated value to the enum —
that would ripple through every pattern match for no benefit.

### View model

- `@Published var blurLevel: Int = 3` — the tool's current setting, applied
  to newly drawn blur regions (draft AND commit must copy it).
- Level → pixellate scale mapping (keep 3 ≈ today's look):
  `func pixellateScale(level: Int) -> CGFloat { max(6, pixelSize.width / 270 * CGFloat(level)) }`
- Replace the single precomputed `blurredCG`/`blurredNSImage` stored
  properties with a lazy per-level cache:

```swift
private var blurCG: [Int: CGImage] = [:]
private var blurNS: [Int: NSImage] = [:]
func blurredCG(level: Int) -> CGImage      // render via CIFilter.pixellate + cache
func blurredNSImage(level: Int) -> NSImage // NSImage over the cached CGImage, 1pt = 1px
```

  Rendering: same recipe as the current init code (clampedToExtent, crop to
  extent, fall back to the base image on failure) but with
  `filter.scale = Float(pixellateScale(level:))`. Clamp incoming level to
  1...10. Warm the cache for level 3 in `init` so first paint is instant.
  One `CIContext` stored and reused across renders — don't create one per call.
- `blurRects(scale:)` becomes
  `func blurGroups(scale: CGFloat) -> [(level: Int, rects: [CGRect])]` —
  committed blur annotations (+ draft blur) grouped by `blurLevel`, levels
  sorted ascending for stable view identity.
- Selection-aware level editing:
  - `var selectedBlurID: UUID?` (computed: selected annotation if it's a blur)
  - `func setBlurLevel(_ level: Int)` — clamp 1...10; if a blur annotation is
    selected, rewrite ITS `blurLevel` (live update); otherwise set the tool
    default `blurLevel`.
  - `func beginBlurLevelEdit()` — `pushHistory()` only if a blur annotation is
    selected (one snapshot per slider gesture; tool-default changes are not
    undoable state).

### Export (renderFinal) — two changes

1. Use `blurredNSImage(level: annotation.blurLevel)` per region.
2. Hardening: regions moved/resized past the image edge must be clipped —
   `let clipped = rect.intersection(fullRect)`, skip if `clipped.isNull` or
   empty, and compute the `from:` rect from `clipped` (same Y-flip as today).
   Draw `in: clipped` too, so dest and source stay aligned.

### EditorView

- Blur overlay layer: replace the single masked `Image` with one masked layer
  per level group:

```swift
ForEach(model.blurGroups(scale: scale), id: \.level) { group in
    Image(model.blurredCG(level: group.level), scale: 1, label: Text("Blur"))
        .resizable()
        .interpolation(.none)
        .mask(BlurMask(rects: group.rects))
}
```

- Toolbar slider, placed after the color group:

```swift
if model.tool == .blur || model.selectedBlurID != nil {
    HStack(spacing: 6) {
        Image(systemName: "drop")            // small secondary icon
        Slider(value: blurLevelBinding, in: 1...10, step: 1,
               onEditingChanged: { if $0 { model.beginBlurLevelEdit() } })
            .frame(width: 110)
    }
}
```

  `blurLevelBinding: Binding<Double>` — get: selected blur's level if one is
  selected, else the tool default; set: `model.setBlurLevel(Int($0.rounded()))`.
- Draft blur creation already flows through the VM — just make sure the draft
  annotation carries `blurLevel = model.blurLevel` so the live preview shows
  the chosen strength while dragging.

---

## Pitfalls

- Resize is always computed from the gesture's ORIGINAL annotation (stored in
  the `ActiveDrag` case) — never from the current mutated rect.
- Handle hit-testing before body hit-testing, and only when the handle's
  annotation is already selected.
- One history snapshot per gesture (resize gesture, slider gesture, commit,
  delete) — never per tick.
- The blur cache is keyed by clamped Int level; `setBlurLevel` on a selected
  region must NOT re-render synchronously in the setter beyond what the view
  pulls — the view calling `blurredCG(level:)` triggers the lazy render.
- Keep the pixel-coordinate invariant; only tolerances/handle sizes derive
  from view points via `scale`.
- Selection indicator + handles must not render into the export.
- `withRect` on `.number` returns self — resize can never target a number
  (the state machine already prevents it; this is belt-and-braces).

Report: per-file changes, any deviations + why, final BUILD line.
