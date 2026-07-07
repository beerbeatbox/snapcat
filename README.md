# Snapcat

Snapcat คือแอปแคปหน้าจอบน macOS ที่อยู่บนเมนูบาร์ (menu-bar) เขียนด้วย Swift + SwiftUI + AppKit
กด hotkey แล้วเลือกพื้นที่ที่จะแคป ภาพจะถูกคัดลอกเข้า clipboard อัตโนมัติ พร้อมโชว์ตัวอย่างเล็ก ๆ
มุมล่างซ้าย hover แล้วมีสองปุ่ม: **Save** (เซฟ PNG ลง Desktop ทันที) หรือ **Edit**
เปิดหน้าต่างแก้ไข ใส่ blur / เลขลำดับ / วงรี / สี่เหลี่ยม เลือกสีได้ แล้ว Copy หรือ Save เป็น PNG

## Download

ดาวน์โหลดเวอร์ชันล่าสุดได้ที่
[github.com/beerbeatbox/snapcat/releases/latest](https://github.com/beerbeatbox/snapcat/releases/latest)
— เปิดไฟล์ DMG แล้วลาก Snapcat ไปที่โฟลเดอร์ Applications

## Updates

Snapcat เช็คอัปเดตอัตโนมัติวันละครั้ง (ผ่าน Sparkle) หรือกดเช็คเองได้จากเมนูบาร์
→ **Check for Updates…**

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

## Release (สำหรับผู้ดูแล)

ออกรีลีสได้สองทาง: ผ่าน GitHub Actions (แนะนำ — สั่งจากที่ไหนก็ได้ รวมถึงให้
Claude Code สั่งหลังแก้โค้ดเสร็จ) หรือรันสคริปต์บนเครื่องตัวเอง

### ทางที่ 1 — GitHub Actions

```bash
gh workflow run release.yml -f version=0.2.0
gh run watch   # ดูสถานะ (ใช้เวลาราว 10-15 นาที รวม notarize)
```

หรือกด **Run workflow** ในแท็บ Actions บน GitHub ก็ได้
workflow จะ bump เวอร์ชัน, build + sign + notarize + staple, สร้าง zip/DMG,
generate `appcast.xml`, commit กลับขึ้น main แล้วสร้าง GitHub release ให้ครบ

ต้องตั้ง repo secrets ครั้งเดียวก่อนใช้ (Settings → Secrets → Actions):

| Secret | ค่า |
|---|---|
| `DEVELOPER_ID_P12` | ไฟล์ .p12 ของ cert "Developer ID Application" (export จาก Keychain) เข้ารหัส base64 |
| `DEVELOPER_ID_P12_PASSWORD` | รหัสที่ตั้งตอน export .p12 |
| `APPLE_ID` | อีเมล Apple ID |
| `APPLE_APP_PASSWORD` | app-specific password (สร้างที่ account.apple.com) |
| `SPARKLE_ED_PRIVATE_KEY` | เนื้อไฟล์ `sparkle_priv.pem` (คีย์เซ็น appcast) |

```bash
# export cert + private key จาก login keychain แล้วอัปเป็น secrets
security export -k login.keychain -t identities -f pkcs12 -o /tmp/certs.p12 -P '<ตั้งรหัส>'
base64 -i /tmp/certs.p12 | gh secret set DEVELOPER_ID_P12
rm /tmp/certs.p12
gh secret set DEVELOPER_ID_P12_PASSWORD -b '<รหัสเดียวกัน>'
gh secret set APPLE_ID -b '<Apple ID>'
gh secret set APPLE_APP_PASSWORD -b '<app-specific password>'
gh secret set SPARKLE_ED_PRIVATE_KEY < sparkle_priv.pem
```

นอกจากนี้ทุกครั้งที่ push ขึ้น main จะมี workflow `ci.yml` build Debug
(ไม่ sign) เพื่อเช็คว่าโค้ดยัง build ผ่าน

### ทางที่ 2 — บนเครื่องตัวเอง

ครั้งแรกต้องเก็บ credentials สำหรับ notarize ไว้ใน keychain ก่อน (ทำครั้งเดียว):

```bash
xcrun notarytool store-credentials snapcat-notary \
  --apple-id <APPLE_ID> --team-id YYVT547SZ7 --password <app-specific password>
```

จากนั้นออกรีลีสด้วยคำสั่งเดียว:

```bash
./scripts/release.sh <version>   # เช่น ./scripts/release.sh 0.2.0
```

สคริปต์จะ build + sign (Developer ID) + notarize + staple, สร้าง zip/DMG,
generate `appcast.xml`, สร้าง GitHub release แล้ว push appcast ขึ้น main
(ตัว appcast บน main คือสิ่งที่ทำให้แอปของผู้ใช้เห็นอัปเดต)
