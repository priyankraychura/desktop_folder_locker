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
   because the installer is unsigned: *More info → Run anyway*. Since 1.2,
   installing for all users asks for administrator rights once; *Install
   for me only* doesn't.
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
  originals can sometimes be recovered with forensic tools. Phase 2 adds
  drive vaults, which never write unencrypted files to disk.
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

## Phase 2: open vaults as a virtual drive (Dokany) 🧪

An encrypted folder that opens as a drive, so nothing unencrypted is ever
written to the disk. The format, the helper's protocol and the security
notes are in [DRIVE_VAULT.md](DRIVE_VAULT.md).

| # | Milestone | What it contains | Status |
|---|-----------|------------------|--------|
| 2a | Vault format v2 | `Name.flkd` folder: the `.flk` header and key slots (`vault.flk`) and one encrypted file per file. Encrypted names (a random IV per folder, long names), 64 KiB blocks with random access, holes, case-insensitive lookups that keep the case | ✅ unit tests on Linux and Windows |
| 2b | Drive helper | `folder_locker_drive.exe`, in Rust: JSON lines over stdin/stdout, import and export with a full check, the Dokany file system, closes every drive when the app goes away, runs without Dokany and finds it once it's installed | ✅ end-to-end drive test on Windows with Dokany in CI |
| 2c | App integration | "Open it as a folder / a drive" when encrypting a folder; Open and Lock on the card, with the drive letter; Decrypt to a folder; the crash journal; drives closed from outside; Settings → Encrypted drives | ✅ logic and UI tests · 🧪 on a real PC |
| 2d | Packaging | The helper next to the app (CMake and the installer). Dokany comes with the installer (a pinned version, checked by its SHA-256): installed when missing, with one administrator prompt, or later from Settings. CI installs and uninstalls the whole setup. Version 1.2.0 | ✅ installer tested in CI · 🧪 on a real PC |

**Changes from the first plan**

- **Rust, not C#/.NET**: one small exe with nothing to install, and memory
  that can be wiped.
- **Standard input and output, not a named pipe**: only the app that
  started the helper can talk to it, and the helper knows right away when
  the app is gone.
- **Dokany comes with the installer**: it puts a driver in Windows, which
  needs administrator rights. The installer now installs for all users by
  default, so one prompt at the start covers both. *Install for me only*
  still works without one, and asks only if Dokany is installed along.

**Limits of drive vaults**

- They need Dokany, installed once with administrator rights (the
  installer or Settings does it).
- Without the password, the number of files and folders, the sizes and the
  dates can be seen (not names or contents).
- The drive has no permissions, alternate data streams or Recycle Bin.
- A few changes to the stored files are not detected: whole blocks set to
  zeros, a file cut at a block boundary, whole files swapped or put back to
  an older version (see DRIVE_VAULT.md §5).
- Only folders become drives; a single file is locked into a `.flk` vault.

**Manual test checklist for Phase 2 (Windows 10/11)**

1. Install with the Dokany task unticked. **Settings → Encrypted drives**
   says Dokany is missing and offers **Install Dokany**. The protect dialog
   offers the same under "A drive".
2. **Install Dokany** → Windows asks for administrator rights → Dokany's
   setup shows its progress → "Ready", without restarting the app.
3. Protect a folder → **Encrypt** → Open it as **A drive** → `Name.flkd`
   appears in its place.
4. **Open** → a drive such as `V:` opens in Explorer with the files. The
   card shows "Open as V:".
5. On the drive: edit and save a document in its program, copy a large
   file in, rename, move and delete files, and create folders. Explorer
   says deleting is permanent.
6. Look into `Name.flkd\data` → only scrambled names, and no file opens.
7. **Lock** → the drive goes away without asking for a password. **Open**
   again → every change is there.
8. Open a document from the drive in its program, then **Lock** → the app
   asks before closing the drive. **Cancel**, close the program, then
   **Lock** again → it closes without asking.
9. Eject the drive in Explorer → the card shows Locked.
10. Open a drive, then end Folder Locker in Task Manager → the drive goes
    away. Start the app again → the item shows Locked.
11. Double-click `vault.flk` inside `Name.flkd` → the password dialog
    opens it as a drive.
12. **⋯ → Decrypt to a folder…** → the normal folder is back and
    `Name.flkd` is gone.
13. Change the master password → drive vaults open with the new one.

## Phase 3: Explorer plug-in 🚧

Folder Locker feels built into Explorer: menus that know each item, locked
items that look locked, and locked folders that ask for the password when
opened.

| # | Milestone | What it contains | Status |
|---|-----------|------------------|--------|
| 3a | Locked drive vault folders | A `Name.flkd` folder shows the vault icon and a tooltip, and inside it only `vault.flk` (the encrypted data is hidden), so opening the folder leads straight to the password dialog. Plain `desktop.ini`: no plug-in or administrator rights needed, and it travels with the vault to other PCs | ✅ checked in the drive test on Windows (attributes, and the shell finds the icon) · 🧪 on a real PC |
| 3b | Explorer plug-in | `folder_locker_shell.dll`, a user-mode COM server in Rust: no driver, no signature needed to run. Never blocks or crashes Explorer: it only reads the app's list of items and starts the app, and every entry point catches errors. The installer moves a copy that Explorer still has loaded aside, so updates need no restart | ✅ its COM objects tested on Windows in CI · 🧪 on a real PC |
| 3c | Right-click menu that knows the item | One entry whose title and action follow the item: *Lock with Folder Locker* on new folders and files, *Unlock…* on blocked, read-only and hidden items, *Open…* on drive vaults, *Lock…* on unlocked items and on open drives (right-click `V:`); `.flk` vaults keep their file type's *Unlock…*. The app then does it without asking again. Registered per user, so no administrator rights. Top level on Windows 10; under *Show more options* on Windows 11 | ✅ end to end in CI: registered, shown by Windows' own menu code with the right titles, and run · 🧪 on a real PC |
| 3d | Lock badge | A padlock overlay on items that stay in place while protected (Block access, Read-only, Hide only). Registered for all users by the installer (Windows reads overlays only there), shown to each user whose Explorer integration is on, and up to date as soon as the app changes an item. Windows shows at most 15 overlays, and cloud apps use many, so the name starts with a space to come early | ✅ end to end in CI: registered, loaded by Windows' overlay code, shown only on protected items · 🧪 on a real PC |
| 3e | Windows 11 first-level menu | The same command in a package with external location (sparse package), which Windows 11 needs for its first menu level. Built and checked in CI with a test certificate; switched on in the installer with the free signing of Phase 4 | ⏳ |

**Changes from the first plan**

- **Rust instead of C++** for the plug-in, like the drive helper: one native
  toolchain, and memory safety matters most inside Explorer's own process.
- **`IExplorerCommand` instead of `IContextMenu`**: Explorer asks for the
  title and state and runs the command, so the plug-in never touches
  Explorer's menus. It's also the interface Windows 11's first menu level
  needs (3e).
- **No namespace extension.** Making a folder behave like a virtual folder
  inside Explorer is a large amount of fragile shell code, and a bug there
  breaks Explorer itself. Drive vaults already get the same result more
  simply: their folder shows the vault icon, contains only `vault.flk`, and
  opening that asks for the password and shows the files as a drive.

**Manual test checklist for Phase 3 (Windows 10/11)**

1. Install. Right-click a folder → **Lock with Folder Locker** (Windows
   11: under **Show more options**) → the app opens the protect dialog.
2. Protect it with **Block access** → right-click it → **Unlock with
   Folder Locker** → the app unlocks it without asking again.
3. Right-click it again → **Lock with Folder Locker** → it's blocked again,
   without a dialog.
4. Lock the app → **Unlock with…** on a blocked folder → the app says to
   unlock it first, then unlocks the folder once the app is unlocked.
5. Encrypt a folder as **A drive** → the `Name.flkd` folder shows the
   vault icon, its tooltip says what it is, and opening it shows only
   `vault.flk`.
6. Right-click `Name.flkd` → **Open with Folder Locker** → password →
   the drive opens. Right-click the drive (`V:`) → **Lock with Folder
   Locker** → the drive closes.
7. Right-click `C:`, a `.flk` file (it has the file type's own **Unlock
   with…**), or several items at once → no Folder Locker entry from the
   plug-in.
8. Installed for all users: sign out and in again → blocked, read-only and
   hidden items (with hidden files shown) have a padlock badge. Unlock
   one in the app → its badge goes away at once; lock it → it's back.
9. Update Folder Locker (Explorer always has the plug-in loaded for the
   badge) → no restart asked; the new version runs after the next sign-in.
   Uninstall → the entry is gone and no restart is asked.
10. Turn off **Settings → Explorer integration** → the entry, the vault
    icon and the badges go away. Turn it on → they come back.

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
| Per-user install (Inno Setup, `PrivilegesRequired=lowest`) | No administrator prompt; Explorer integration lives in HKCU anyway. *Changed in 1.2: all users by default, see below* |
| Bundle the Visual C++ runtime DLLs | Flutter apps need them, and not every PC has the redistributable |
| Block access with one "deny Everyone" permission rule, only on items the user owns | Instant even for huge folders; the owner can always remove it, so nobody is locked out for good |
| Tray icon written in the runner (C++) instead of a plugin | About 250 lines, no extra dependency, and notifications work through the tray icon without registering the app |
| New recovery key: save the key first, then re-seal vaults, and finish later if needed | The old key must stop working right away; each vault update is crash-safe on its own |
| Drive vaults store one encrypted file per file (like Cryptomator and gocryptfs) | Random access: after the first lock, opening and locking are instant at any size, and a change rewrites only the blocks it touches |
| A helper program in Rust for drives, started by the app and talking over stdin/stdout | One small exe with nothing to install; keys can be wiped; nobody else can talk to it; every drive closes when the app goes away |
| Dokany for the drive | Free, open source (LGPL) and already signed by Microsoft, so there is no driver of our own. WinFsp is faster, but its free license needs the app to be open source (Phase 4), and the helper would need rewriting. Windows' own options either write plain files to disk (ProjFS, Cloud Files) or are being retired (WebDAV) |
| Dokany comes with the installer, which installs for all users by default | Installing a driver needs administrator rights anyway, so one prompt covers everything, and nobody has to find a download. The version is pinned and checked by SHA-256, and it's the one CI tests the drive with. The app can install the same copy later |
| Passwords stay in the app; the helper only gets a vault's data key | One place for Argon2id, key slots and the recovery key, shared by both kinds of vault |
| The dokan Rust bindings are vendored with a small fix | The published version crashed on requests for handles the file system never opened; the fix is listed in `native/vendor/dokan/PATCHES.md` |
