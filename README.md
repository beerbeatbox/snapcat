# Snapcat

Snapcat คือแอปแคปหน้าจอบน macOS ที่อยู่บนเมนูบาร์ (menu-bar) เขียนด้วย Swift + SwiftUI + AppKit
กด hotkey แล้วเลือกพื้นที่ที่จะแคป ภาพจะถูกคัดลอกเข้า clipboard อัตโนมัติ พร้อมโชว์ตัวอย่างเล็ก ๆ
มุมล่างซ้าย hover แล้วมีสองปุ่ม: **Save** (เซฟ PNG ลง Desktop ทันที) หรือ **Edit**
เปิดหน้าต่างแก้ไข ใส่ blur / เลขลำดับ / วงรี / สี่เหลี่ยม เลือกสีได้ แล้ว Copy หรือ Save เป็น PNG

## Build

ต้องมี [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

```bash
cd ~/Projects/Snapcat
xcodegen generate
```

จากนั้นเปิด `Snapcat.xcodeproj` ใน Xcode แล้วกด Run หรือใช้ command line:

```bash
xcodebuild -project Snapcat.xcodeproj -scheme Snapcat -configuration Debug build
```

ไฟล์ `.app` ที่ build เสร็จจะอยู่ใน DerivedData
(`~/Library/Developer/Xcode/DerivedData/Snapcat-*/Build/Products/Debug/Snapcat.app`)

## Hotkey

- **⇧⌘4** — แคปพื้นที่ (region capture)

⚠️ ⇧⌘4 ชนกับ shortcut แคปจอของ macOS เอง ต้องปิดของระบบก่อน:
**System Settings → Keyboard → Keyboard Shortcuts… → Screenshots**
→ ปิด "Save picture of selected area as a file"
(ไม่งั้นระบบจะชิงคีย์ไปก่อน Snapcat จะไม่ได้รับ hotkey)

## สิทธิ์ครั้งแรก (Screen Recording)

ครั้งแรกที่แคป macOS จะขอสิทธิ์ Screen Recording
ไปที่ **System Settings → Privacy & Security → Screen & System Audio Recording**
เปิดให้ Snapcat แล้ว **เปิดแอปใหม่อีกครั้ง** (relaunch) สิทธิ์ถึงจะมีผล

## Editor shortcuts

- **B** — Blur
- **N** — Number (จุดเลขลำดับ)
- **O** — Oval (วงรี)
- **R** — Box (สี่เหลี่ยม)
- **⌘Z** — Undo
- **⌘C** — Copy
- **⌘S** — Save เป็น PNG
