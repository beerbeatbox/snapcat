# Text Tool — Design Spec (2026-07-21)

เพิ่ม tool **Text** ใน editor ของ Snapcat: พิมพ์ข้อความลงบนภาพแบบ CleanShot X —
คลิกแล้วพิมพ์ inline ตรงจุดนั้น ตัวอักษร bold สีล้วนไม่มีพื้นหลัง
ปรับขนาดเป็น pt ผ่าน dropdown ใน toolbar หรือลาก handle มุมขวาล่าง

## Model

- `EditorTool`: เพิ่ม `case text` — symbol `textformat`, label "Text", shortcut **T**
- `Annotation.Kind`: เพิ่ม `case text(origin: CGPoint, string: String)`
  — `origin` = มุมซ้ายบนของ bounding box (พิกัด pixel, top-left origin)
- `Annotation`: เพิ่ม `fontSize: CGFloat = 30` (หน่วย pt, มีความหมายเฉพาะ `.text`
  — pattern เดียวกับ `blurLevel`)
- `EditorViewModel` เพิ่ม:
  - `@Published var textFontSize: CGFloat = 30` — tool default (จำค่าล่าสุดที่ใช้)
  - `@Published var editingTextID: UUID?` — annotation ที่กำลังพิมพ์อยู่ (nil = ไม่มี)
  - `let displayScale: CGFloat` — คำนวณใน `init` = `pixelSize.width / image.size.width`
    (screencapture ฝัง DPI metadata ให้ `NSImage.size` เป็น logical points;
    ถ้าค่าออกมา ≤ 0 หรือไม่ finite ให้ fallback = 1)

**ขนาดฟอนต์จริงในภาพ** = `fontSize × displayScale` pixels — ทำให้ "30 pt"
เห็นขนาดเท่ากับ 30 pt ของ CleanShot บนจอเดียวกัน
ฟอนต์: bold system font (รองรับไทยผ่าน system fallback)

## Interaction

**สร้าง:** Text tool + คลิกพื้นที่ว่าง → สร้าง text annotation ว่างที่จุดคลิก,
`selectedID` + `editingTextID` ชี้ไปที่มัน, TextField โฟกัสทันที พร้อมพิมพ์
(ลากยาวด้วย text tool ก็นับเป็นคลิก — สร้างที่จุด start; ไม่มีการวาดกล่องแบบ
CleanShot เพราะเราไม่มี word-wrap)

**ระหว่างพิมพ์ (editing):**
- TextField โปร่งใสวางทับตำแหน่งจริง ฟอนต์/สีตรงกับผลลัพธ์, กรอบ accent บาง ๆ
  (ไม่มี handle ระหว่างพิมพ์ — handle ใช้ตอน selected เท่านั้น)
- Canvas ข้ามการวาด annotation ตัวที่กำลัง edit (TextField แสดงแทน)
- เปลี่ยนสีจาก color picker → มีผลกับข้อความที่กำลังพิมพ์ทันที
- เปลี่ยนขนาดจาก dropdown → มีผลทันทีเช่นกัน
- **ปิด** keyboard shortcuts ทั้งหมดของ editor ชั่วคราว: tool keys (B/N/O/R/T),
  hidden Delete/Esc buttons, และ ⌘Z/⌘C/⌘S — ให้ field editor จัดการเอง
  (ไม่งั้นพิมพ์ "b" แล้ว tool สลับ / ⌘C copy ภาพแทนข้อความ)

**จบการพิมพ์:** (ปรับตาม feedback 2026-07-21: Enter ≠ commit)
- **Enter** = ขึ้นบรรทัดใหม่ — ข้อความเป็น multi-line ได้ (ใช้ `TextEditor`)
- **คลิกข้างนอกกรอบ** = commit (ทางหลักในการจบ); ถ้า trim แล้วว่างเปล่า →
  ลบ annotation ทิ้ง + drop history snapshot (ไม่เหลือขยะใน undo)
  แล้ว gesture นั้นทำงานตามปกติต่อ (ถ้ายังเป็น Text tool คลิกที่ว่าง =
  เริ่มพิมพ์อันใหม่)
- **สลับ tool ระหว่างพิมพ์** = commit เช่นกัน (กันหลุด session ค้าง)
- **Esc** = ยกเลิก; อันที่เพิ่งสร้าง → ลบทิ้ง, อันเดิมที่ double-click มาแก้ →
  คืนข้อความ/สภาพเดิม (drop snapshot ทั้งคู่)

**Cursor ตามโหมด:**
- กำลังพิมพ์ + เมาส์นอกกรอบ text = ลูกศรปกติ (สื่อว่า "คลิกเพื่อออก")
- Text tool ไม่ได้พิมพ์ = I-beam (พร้อมวางข้อความ), เหนือกรอบที่พิมพ์อยู่ =
  I-beam ของ field เอง
- Tool อื่น = crosshair (เหมือนเดิม)

**แก้ไข:** double-click ที่ text annotation (tool ไหนก็ได้) → เข้าโหมดพิมพ์อีกครั้ง
(pushHistory ก่อนแก้)

**ย้าย:** ลากตัวข้อความ = move (state machine เดิม, `moved(by:)` offset origin)

**Resize:** ตอน selected แสดงกรอบ dashed + **handle สี่เหลี่ยมมุมขวาล่างอันเดียว**
(text ไม่ใช้ 4-corner handles แบบ rect)
- ลาก handle → `fontSize` scale ต่อเนื่องตามอัตราส่วนระยะทแยง
  (จากมุมซ้ายบนถึง cursor เทียบกับระยะเดิม), clamp **6–400 pt**, ไม่ snap preset
- กล่องข้อความโตตามอัตโนมัติ, ค่าใน dropdown อัปเดตสด
- undo 1 snapshot ต่อการลาก, ลาก <3px = drop snapshot (pattern resize เดิม)
- ไม่มีวงกลมซ้าย/ขวาแบบ CleanShot (นั่นไว้ปรับความกว้าง word-wrap — เราเป็น
  single-line ยังไม่ทำ)

**ข้อความ:** หลายบรรทัดได้ (Enter = ขึ้นบรรทัดใหม่) — วัดขนาด/วาด/export ด้วย
`boundingRect`/`draw(with:)` + `.usesLineFragmentOrigin` ทั้งสามทาง

## Size dropdown (toolbar)

- ปุ่ม "**N pt ⌄**" โผล่เมื่อ `tool == .text` หรือ selected/editing เป็น text
  (ตำแหน่งเดียวกับ blur slider ใน toolbar)
- N = ค่าของ text ที่เลือก/กำลังพิมพ์ ถ้ามี, ไม่งั้น tool default — แสดงปัดเป็น Int
- เมนู preset: **10, 13, 16, 20, 24, 30, 36, 48, 72, 96**
- เลือกขณะมี text ถูกเลือก/พิมพ์อยู่ → pushHistory + set ของอันนั้น
  **และ**อัปเดต tool default ด้วย (ครั้งหน้าได้ขนาดล่าสุด); ไม่มีอะไรถูกเลือก →
  set default เฉย ๆ (ไม่เข้า undo — pattern เดียวกับ blur level)
- ค่าจากการลาก handle อาจไม่อยู่ใน preset → ปุ่มแสดงค่าจริง เช่น "43 pt"

## bounds / hitTest

- ต้องวัดขนาดข้อความจริง: helper บน VM
  `textDisplaySize(_ string: String, fontSize: CGFloat) -> CGSize`
  ผ่าน `NSAttributedString` measurement (ฟอนต์ขนาด pixel)
- `Annotation.bounds(numberDiameter:)` ไม่พอสำหรับ text → เพิ่ม VM-level
  `bounds(of annotation: Annotation) -> CGRect` ครอบทุก kind
  (kind เดิม delegate ไปของเดิม, text ใช้ origin + measured size)
  แล้วให้ hitTest / selection indicator / handleHit / resize ใช้ตัวนี้
- hitTest ของ text: โดนทั้งก้อน (measured rect + tolerance) — เหมือน blur
  ไม่ใช่เฉพาะขอบแบบ rect/ellipse
- `handleHit` ของ text: คืนเฉพาะ `bottomRight`
- `withRect` ไม่ใช้กับ text (resize ผ่าน fontSize ไม่ใช่ rect) — resize branch
  ใน `dragChanged` แยกจัดการ text โดย scale fontSize

## Rendering

- **Preview** (Canvas เดิม): `context.draw(Text(string).font(.system(size:
  fontPixel × scale, weight: .bold)).foregroundColor(color), in: rect)` —
  rect จาก origin + measured size คูณ view scale; ข้าม annotation ที่กำลัง edit
- **Export** (`renderFinal`): วาดด้วย `NSAttributedString.draw(at: origin)`
  ฟอนต์ `boldSystemFont(ofSize: fontSize × displayScale)` สีตาม annotation —
  context flipped อยู่แล้ว (แบบเดียวกับ `drawNumber`)
- ข้อความลากออกนอกขอบภาพได้ (เหมือน shape อื่น) — ส่วนที่พ้นขอบถูก clip ตอน export

## Undo

1 snapshot ต่อ: สร้าง (commit ไม่ว่าง), แก้ข้อความเดิม, ลาก handle, เปลี่ยนขนาดผ่าน
dropdown (เฉพาะตอนมี selection), ย้าย, ลบ — ทุกอันใช้ machinery เดิม
(`pushHistory` ก่อน mutation + drop snapshot เมื่อ no-op)
Delete key ตอน selected (ไม่ได้พิมพ์อยู่) ลบผ่าน `deleteSelected` เดิมได้เลย
(text ไม่ต้อง renumber)

## Files ที่แตะ

| ไฟล์ | งาน |
|---|---|
| `EditorModels.swift` | tool case, kind case, `fontSize`, ปรับ `moved(by:)` |
| `EditorViewModel.swift` | `displayScale`, editing state + commit/cancel, measurement, `bounds(of:)`, hit/handle/drag branches, dropdown setter, `renderFinal` branch |
| `EditorView.swift` | dropdown ใน toolbar, TextField overlay, Canvas วาด text + selection handle เดี่ยว, double-click gesture, ปิด shortcuts ระหว่างพิมพ์ |

## การทดสอบ

โปรเจกต์ไม่มี test target — ใช้ build + manual checklist:

- [ ] พิมพ์อังกฤษ/ไทย แสดงถูกทั้ง preview และไฟล์ export (copy + save)
- [ ] คลิก-พิมพ์-Enter, Esc ยกเลิก, คลิกที่อื่น commit
- [ ] ข้อความว่าง → ไม่เหลือ annotation, undo ไม่มี step ค้าง
- [ ] double-click แก้ข้อความเดิม, Esc คืนค่าเดิม
- [ ] ลาก handle มุมขวาล่าง ขนาดเปลี่ยนสมูท, dropdown โชว์ค่าตาม
- [ ] เลือก preset จาก dropdown ตอนเลือก text / ตอนไม่เลือกอะไร (default)
- [ ] ย้าย, ลบ (Delete), undo ครบทุก action ข้างต้น
- [ ] พิมพ์ตัว b/n/o/r/t ระหว่าง edit — tool ไม่สลับ; ⌘C copy ข้อความไม่ใช่ภาพ
- [ ] ลากข้อความออกนอกขอบภาพ → export clip ถูกต้อง
- [ ] ภาพ non-retina (displayScale = 1) ขนาดฟอนต์ยังสมเหตุสมผล
