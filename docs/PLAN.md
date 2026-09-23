# Folder Locker — Roadmap

A free Windows app, built with Flutter, that protects folders and files with
real encryption. It works like Anvi Folder Locker, but it doesn't need a kernel
driver, so it can be built and shipped for **$0**.

> **Why no kernel driver?** Anvi locks folders with a kernel "minifilter"
> driver. Shipping a driver today requires Microsoft's signature, an EV
> certificate (paid) and a Partner Center hardware account. Microsoft is also
> removing trust for the old cross-signing route Anvi used (April 2026 Windows
> update). Encryption protects the data itself (even if the disk is stolen), so
> we build on that instead and borrow drivers that are already signed (Dokany)
> when we need a virtual drive.

Status legend: ✅ done and tested · 🧪 built, needs a test on a real Windows PC · ⏳ planned

---

## Phase 1: core app (encrypt, hide, Explorer basics) 🧪

Goal: a polished, fully working desktop app that locks folders/files into
encrypted vault files, all in Flutter plus Windows APIs. No paid tools.

| # | Milestone | What it contains | Status |
|---|-----------|------------------|--------|
| 1.1 | Foundation | Flutter Windows project, feature-first folder structure, lint rules, design tokens + Material 3 theme (light/dark), CI on Linux and Windows (analyze, test, build, installer) | ✅ |
| 1.2 | Security core | Master password (Argon2id), recovery key (X25519 sealed box), app lock screen, auto-lock, change password, reset with recovery key | ✅ |
| 1.3 | Vault engine | `.flk` vault format (XChaCha20-Poly1305, 256 KiB chunks, key slots), lock/unlock for folders and files, verification before originals are deleted, crash-safe journal + recovery at startup, progress + cancel, background isolate | ✅ |
| 1.4 | Protection methods | **Encrypt** (master password or a custom password per item) and **Hide** (Hidden + System attributes); both can be combined | ✅ encrypt · 🧪 hide |
| 1.5 | Explorer basics | Vault files show a lock icon; **double-click opens the password dialog**; right-click "Lock with Folder Locker" on folders and files; single instance with argument forwarding | 🧪 |
| 1.6 | Modern UI/UX | Custom title bar, sidebar navigation, drag & drop, search and filters, empty states, progress dialog, toasts, keyboard shortcuts, onboarding | ✅ |
| 1.7 | Packaging | Inno Setup installer (per user, registers Explorer integration, removes it on uninstall), Visual C++ runtime bundled, README build guide | 🧪 |

**How it was tested**

- **Engine and app logic.** Automated tests run on Linux and on Windows in
  CI:
  - lock/unlock round trips;
  - tamper, truncation and crash-recovery cases;
  - password change and reset;
  - the full UI flows.
- **UI.** Every screen was rendered and reviewed in light and dark mode
  (`test/visual`).
- **Build.** CI builds the release app and the installer on Windows for
  every push.
- **Windows-only behaviour** needs one manual pass on a real PC, using the
  checklist below:
  - registry entries, Explorer icons and double-click;
  - hiding with file attributes;
  - the window and the installer.

**What the user gets in Phase 1**

1. First launch: create a master password and save the recovery key.
2. Drag a folder into the app (or right-click it in Explorer → *Lock with
   Folder Locker*) and choose **Encrypt** and/or **Hide**.
3. The folder turns into `Name.flk` with a lock icon, in the same place.
4. Double-clicking `Name.flk` opens the password dialog. After unlocking, the
   folder is restored and opened in Explorer.
5. *Lock again* from the app, or lock everything when closing it.

**Manual test checklist (Windows 10/11)**

1. Install from the CI artifact `folder-locker-setup`. SmartScreen warns
   because the installer is unsigned: *More info → Run anyway*. No
   administrator prompt should appear.
2. First start: create a master password, then copy the recovery key.
3. Drag a test folder into the app → **Encrypt** → `Name.flk` appears in the
   same place, with the lock icon.
4. Close the app. Double-click `Name.flk` → the app opens with the password
   dialog → the folder is restored and opened in Explorer.
5. Right-click a folder → *Show more options* (Windows 11) → **Lock with
   Folder Locker** → the protect dialog opens.
6. With the app open, double-click another vault → the same window comes
   to the front (no second window).
7. **Hide only** → the folder disappears from Explorer; **Show** brings it
   back.
8. A custom-password item → lock the app (`Ctrl+L`) → the item asks for its
   own password.
9. Change the master password → existing vaults open with the new one.
10. Lock screen → *Forgot password?* → reset with the recovery key.
11. Lock a large folder and end the app in Task Manager halfway → start it
    again → the item is either locked or back as it was, with nothing lost.
12. Turn off *Explorer integration* in Settings → the menu entry and the
    `.flk` icon go away. Turn it on again → they come back.
13. Uninstall → the menu entries and the `.flk` association are gone; vaults
    are still there and still encrypted.

**Known limitations (fixed in later phases)**

- While a folder is unlocked, its files are normal files on disk. The deleted
  originals can sometimes be recovered with forensic tools. Phase 2 removes
  this by never writing unencrypted files to disk.
- File permissions (ACLs) and alternate data streams are not stored in the
  vault. Read-only, hidden and system attributes are restored.
- Folders that contain symbolic links or junctions are refused, so nothing is
  lost by accident.

---

## Phase 1.1: quick protection modes and unlocked items 🧪

Protection without encryption, for very large folders, and help with items
that are left unlocked.

| # | Milestone | What it contains | Status |
|---|-----------|------------------|--------|
| 1.1a | Block access and Read-only | An NTFS "deny Everyone" permission rule on the item, in place and instant. Only on items the user owns, on drives with permissions. Unlock removes exactly that rule. | ✅ rules tested on real NTFS in CI · 🧪 Explorer behaviour |
| 1.1b | Notification-area icon | Native tray icon in the Windows runner: menu (open, lock all items, lock app, quit), amber icon while items are unlocked, keeps running when the window is closed | 🧪 |
| 1.1c | Reminders and automatic re-locking | A notification when items stay unlocked; lock them again after N minutes; lock them when the app locks | ✅ |
| 1.1d | New recovery key | Shown once and confirmed; every vault is re-sealed crash-safely; vaults that could not be reached are finished after the next unlock | ✅ |

**Limits of Block access and Read-only**

- They are not encryption. The rule can be removed, or the files read, by
  the folder's owner (in Properties → Security), by an administrator, or
  from another operating system. Use Encrypt for anything private.
- Items inside the folder that have permission inheritance turned off
  don't get the rule.
- A blocked folder that is moved elsewhere shows as "Not found".

**Manual test checklist for Phase 1.1 (Windows 10/11)**

1. **Block access** on a folder → double-click it in Explorer → "Access
   denied". **Unlock** in the app → it opens normally again.
2. **Read-only** on a folder → files open, but saving, adding or deleting
   fails. **Unlock** → it can be changed again.
3. Right-click the blocked folder → **Lock with Folder Locker** → the app
   offers to unlock it.
4. Close the window → it disappears, and the icon stays next to the clock
   (a one-time notification explains this). Unlock an item → the icon gets
   the amber dot. Right-click the icon → **Lock all items**.
5. Set **Remind me** to 15 minutes, unlock an item and close the window → a
   notification appears after 15 minutes. Click it → the window opens.
6. **Settings → Recovery key → New key…** → save the key → *Forgot
   password?* on the lock screen accepts only the new key.

## Phase 2: open vaults as a virtual drive (Dokany) ⏳

- Small helper program (C#/.NET or Rust) using **Dokany** (LGPL, driver already
  signed). Flutter controls it through a named pipe (JSON messages).
- Vault format v2: directory-based, each file encrypted separately with
  encrypted names, random access, like Cryptomator.
- Unlock mounts the vault as a drive (for example `V:`); lock unmounts it. No
  unencrypted data is written to disk.
- Users install Dokany once (bundled in the installer or
  `winget install dokan-dev.dokany`).

## Phase 3: Explorer plug-in (C++ shell extension) ⏳

- A locked item can stay a *real folder* in Explorer. Opening it shows the
  password dialog (shell namespace extension).
- Lock icon overlay; Windows 11 top-level context menu (`IExplorerCommand`).
- User-mode DLL: no Microsoft driver signature needed. Signed for free with
  SignPath if the project is open source (avoids Smart App Control blocks).

## Phase 4: publishing ⏳

- Choose an open-source license (SignPath's free plan needs one).
- GitHub Releases with the Inno Setup installer (free). CI already builds
  it on every push.
- Microsoft Store (free for individual developers; Microsoft signs MSIX).
- SignPath Foundation code signing (free for open-source projects).
- Auto-update (WinSparkle through `auto_updater`) and a winget manifest.

---

## Decision log

| Decision | Why |
|----------|-----|
| Encryption instead of a kernel driver | Drivers need paid Microsoft signing; encryption protects data even when the disk is removed |
| libsodium through the `sodium` package | Native speed (~800 MiB/s vs ~23 MiB/s in pure Dart), audited primitives, built from source automatically by build hooks (uses the Visual Studio that Flutter already requires) |
| XChaCha20-Poly1305 + Argon2id | Modern, misuse-resistant AEAD; memory-hard password hashing |
| Single-file vault (`Name.flk`) | Lets Explorer show a lock icon and open our password dialog on double-click, with no shell extension |
| Recovery key via X25519 sealed box | The app can add a recovery slot to every vault without storing any recovery secret |
| JSON files with atomic writes (not SQLite) | Small data set, no native dependency, easy to back up and inspect |
| Riverpod | Testable dependency injection and state, no code generation |
| Per-user install (Inno Setup, `PrivilegesRequired=lowest`) | No administrator prompt; Explorer integration lives in HKCU anyway |
| Bundle the Visual C++ runtime DLLs | Flutter apps need them, and not every PC has the redistributable |
| Block access with one "deny Everyone" permission rule, only on items the user owns | Instant even for huge folders; the owner can always remove it, so nobody is locked out for good |
| Tray icon written in the runner (C++) instead of a plugin | About 250 lines, no extra dependency, and notifications work through the tray icon without registering the app |
| New recovery key: save the key first, then re-seal vaults, and finish later if needed | The old key must stop working right away; each vault update is crash-safe on its own |
