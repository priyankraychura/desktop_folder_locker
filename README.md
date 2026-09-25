<p align="center">
  <img src="assets/icons/app_icon.png" width="96" alt="Cloak icon">
</p>

<h1 align="center">Cloak</h1>

<p align="center">
  Lock, encrypt and hide folders on Windows. Free, private, and built with Flutter.
</p>

<p align="center">
  <a href="https://github.com/priyankraychura/desktop_folder_locker/actions/workflows/ci.yml"><img src="https://github.com/priyankraychura/desktop_folder_locker/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
</p>

Cloak turns a folder or file into an **encrypted vault** (`Name.flk`)
in the same place. The vault shows a lock icon in Explorer. Double-click it,
type your password, and your folder comes back.

A folder can also become an **encrypted drive** (`Name.flkd`). Unlock it and
it opens as a drive such as `V:`. Its files are decrypted in memory only
while programs use them, so nothing unencrypted is ever written to the disk.

It works like Anvi Folder Locker, but it uses real encryption instead of a
kernel driver. Your files stay protected even if someone copies them or takes
the disk out of the PC, and the app can be built and shipped for $0.

| Protected items | Protect dialog |
|---|---|
| ![Protected items](docs/screenshots/05_items.png) | ![Protect dialog](docs/screenshots/06_protect_dialog.png) |
| **Open as a drive** | **Unlock dialog** |
| ![Open as a drive](docs/screenshots/07_protect_dialog_drive.png) | ![Unlock dialog](docs/screenshots/08_unlock_dialog.png) |
| **Settings** | **Dark mode** |
| ![Settings](docs/screenshots/09_settings.png) | ![Dark mode](docs/screenshots/11_items_dark.png) |
| **Setup** | **Lock screen** |
| ![Setup](docs/screenshots/01_setup.png) | ![Lock screen](docs/screenshots/13_lock.png) |

<sub>The test suite renders these screenshots (`test/visual`), so the paths
shown are temporary test folders.</sub>

## Features

- **Encrypt** folders and files into a single `.flk` vault. It uses
  XChaCha20-Poly1305 and Argon2id, from [libsodium](https://libsodium.org).
- **Open as a drive** (new in 1.2): an encrypted folder opens as a drive
  such as `V:`, and nothing unencrypted is written to the disk. After the
  first lock, opening and locking it are instant at any size, and locking
  needs no password. It uses the free
  [Dokany](https://github.com/dokan-dev/dokany) driver. See
  [docs/DRIVE_VAULT.md](docs/DRIVE_VAULT.md).
- **Block access** or make items **Read-only**, instantly, even for huge
  folders. The item stays in place, and a Windows permission rule stops
  anyone from opening it (or from changing it).
- **Hide** items from Explorer, alone or together with any other method.
- **Master password** for everything, or **a password of its own** for any
  item.
- **Recovery key**, shown once during setup. It resets the master password
  and opens every vault.
- **Explorer integration**:
  - vaults show a lock icon;
  - **double-click opens the password dialog**;
  - the right-click menu knows each item: **Lock with Cloak** on
    folders and files, **Unlock…** on blocked ones, **Open…** on drive
    vaults, and the app does it right away;
  - drive vault folders look locked: the vault icon, and only `vault.flk`
    inside;
  - blocked and read-only items show a padlock badge (when installed for
    all users).
- **Notification-area icon**: the app keeps running when you close the
  window. The icon shows when items are unlocked, and its menu locks
  everything in one click.
- **Reminders and automatic re-locking** for items you leave unlocked. You
  can also lock them automatically whenever the app locks.
- **Lock again when you close it**: close an unlocked folder's Explorer
  window and a small dialog asks to lock it again, also when you unlocked
  it from Explorer without opening the app. Locking it again needs no
  password, even after the app locked or Windows restarted.
- **New recovery key** at any time. Every vault switches to it safely.
- **Crash-safe**:
  - every new vault is decrypted and checked *before* the original is
    deleted;
  - a journal finishes or rolls back any operation that a crash or power
    loss interrupted.
- **Modern UI**:
  - light and dark themes, custom title bar and drag & drop;
  - search and filters, progress with cancel, toasts and auto-lock;
  - keyboard shortcuts.
- **Private**: no account, no cloud and no telemetry. Using the app needs
  no administrator rights; only installing it for all users (and Dokany)
  asks once.

## How it works

1. On first start you create a master password and save your recovery key.
2. Drag a folder into the app, or right-click it in Explorer and choose
   **Lock with Cloak**. Then choose how to protect it:
   - **Encrypt** (recommended),
   - **Block access**,
   - **Read-only**, or
   - **Hide only**.

   You can also hide it with any of these. With **Encrypt**, a folder can
   open as **a folder** or as **a drive**.
3. With **Encrypt**, the folder becomes `Name.flk`, with a lock icon, in the
   same place. The original files are deleted only after the vault has been
   verified. As a drive, it becomes the vault folder `Name.flkd` instead.
   With **Block access** or **Read-only**, it stays where it is and Windows
   refuses to open it (or to change it).
4. Double-click `Name.flk` to get the password dialog. The folder is
   restored and opened. A drive vault opens as a drive (for example `V:`)
   instead: click **Open** in the app, or double-click `vault.flk` inside
   `Name.flkd`.
5. Click **Lock** in the app, **Lock with Cloak** in Explorer, or
   **Lock all items** in the menu of its icon next to the clock, to lock it
   again. The app can remind you about
   unlocked items, lock them again by itself, and offer to lock them when
   you quit.

## Install

The app is not published yet. To try it:

1. Open the latest successful
   [CI run](https://github.com/priyankraychura/desktop_folder_locker/actions/workflows/ci.yml).
2. Download the **cloak-setup** artifact.
3. Run `Cloak-Setup-<version>.exe`. It installs for all users, with
   one administrator prompt at the start, or, if you choose **Install for me
   only**, for you without one.

The installer is not code-signed yet (planned in Phase 4), so Windows
SmartScreen warns about it. Click **More info → Run anyway**.

Cloak was called Folder Locker before. Installing it over Folder Locker
keeps your items, settings and vaults, and replaces the old app. (It stays
in the old folder under Program Files; uninstall Folder Locker first for a
fresh `Cloak` folder. Your items and vaults stay either way.)

Opening encrypted folders as drives needs
[Dokany](https://github.com/dokan-dev/dokany), a free driver. If it's
missing, the installer installs it too (the task is ticked by default), with
the same administrator prompt. You can also install it later with **Install
Dokany** in **Settings → Encrypted drives**, which also shows whether it's
ready.

### Microsoft Store version

CI also builds an MSIX package for the Microsoft Store
([installer/msix](installer/msix)), which the Store signs. It works like
the Setup version, with these differences:

- **Lock with Cloak** is on the first level of Windows 11's right-click
  menu.
- It has no lock badge: a package can't add one.
- It can't install Dokany. **Settings → Encrypted drives** links to
  Dokany's download instead.
- It installs for each user separately.

Both versions keep their data in the same place, so your items, settings
and vaults stay when you switch. Install only one of them at a time.

## Build from source

Requirements:

- Windows 10 or 11 (x64)
- [Flutter](https://docs.flutter.dev/get-started/install/windows/desktop)
  3.47 or newer (stable channel)
- Visual Studio 2022 or 2026 with the **Desktop development with C++**
  workload. Flutter needs it, and the `sodium` package uses it to compile
  libsodium from source automatically on the first build.
- [Rust](https://rustup.rs) (stable, the default MSVC toolchain) for the
  drive helper and the Explorer plug-in in `native/`.

```powershell
cd native; cargo build --release; cd ..   # the drive helper and plug-in
flutter pub get
flutter run -d windows            # run in debug mode
flutter test                      # run the tests
flutter build windows --release   # build\windows\x64\runner\Release
# Dokany's installer, checked against its known SHA-256, next to the app:
pwsh installer\get-dokany.ps1 -Destination build\windows\x64\runner\Release\dokany
```

`flutter build windows` copies the release helper and plug-in
(`cloak_drive.exe` and `cloak_shell.dll` from
`native\target\release`) next to the app, if they have been built. The app
registers the plug-in for Explorer when it starts. To try a debug build of
the helper instead, set `CLOAK_DRIVE` to its path. `cargo test` in
`native/` runs their tests; the drive test needs Dokany (see
[docs/DRIVE_VAULT.md](docs/DRIVE_VAULT.md)), and the Explorer test, which
rewrites your Explorer entries, runs only with `FLK_SHELL_E2E=1`.

To build the installer, install [Inno Setup 6](https://jrsoftware.org/isinfo.php),
then:

```powershell
# The app needs the Visual C++ runtime next to the exe.
copy C:\Windows\System32\msvcp140.dll     build\windows\x64\runner\Release
copy C:\Windows\System32\vcruntime140.dll   build\windows\x64\runner\Release
copy C:\Windows\System32\vcruntime140_1.dll build\windows\x64\runner\Release
& "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" /DAppVersion=1.3.1 installer\cloak.iss
```

The installer is written to `build\installer`. CI runs all these steps on
every push.

To build the Microsoft Store package from the same app folder (without
Dokany's installer), with the Windows SDK installed, using the identity
from Partner Center (**Product identity**):

```powershell
pwsh installer\msix\build-msix.ps1 -Source build\windows\x64\runner\Release `
    -Name <Package/Identity/Name> -Publisher <Package/Identity/Publisher> `
    -PublisherDisplayName <Package/Properties/PublisherDisplayName> `
    -Version 1.3.1 -Destination build\msix
```

CI builds it for upload, as the **cloak-store** artifact, once the
repository variables `STORE_IDENTITY_NAME`, `STORE_PUBLISHER` and
`STORE_PUBLISHER_DISPLAY_NAME` hold these three values.

You can develop the engine and the UI on Linux or macOS too: `flutter test`
and `cargo test` work there, and the Windows-only parts (registry, file
attributes, drives) do nothing. Build the helper with `cargo build` in
`native/` first, so the app's tests can talk to it. To regenerate the
screenshots:

```sh
SCREENSHOTS_DIR=docs/screenshots SCREENSHOTS_SCALE=1 flutter test test/visual
```

## Keyboard shortcuts

| Keys | Action |
|---|---|
| `Ctrl` + `O` | Protect a folder |
| `Ctrl` + `Shift` + `O` | Protect a file |
| `Ctrl` + `F` | Search |
| `Ctrl` + `L` | Lock the app |
| `Ctrl` + `1` / `Ctrl` + `2` | Protected items / Settings |

## Security notes and limitations

**What it protects:** anything that is encrypted. A vault can't be read or
changed without your password or recovery key, even if someone copies it or
removes the disk. Any change to a vault is detected.

**Please know:**

- **There is no back door.** If you forget your password *and* lose your
  recovery key, the data can't be recovered by anyone.
- **Hide alone is not security.** Anyone who turns on "show hidden and
  system files" can see a hidden item. Use Encrypt for anything private.
- **Block access and Read-only are not encryption either.** They stop
  other people and accidents on this PC. But the folder's owner (in
  Properties → Security) or an administrator can remove the rule, and
  another operating system ignores it.
- **While an item is unlocked**, its files are normal files on disk. Lock it
  again when you're done. After locking, the deleted originals can sometimes
  be recovered with forensic tools (less likely on SSDs). **Open as a
  drive** avoids this: a drive vault is never decrypted to the disk.
- **Drive vaults** need Dokany. While a drive is open, every program running
  as you can read it, and deleting on it is permanent (no Recycle Bin).
  Without the password, the number of files, their sizes and dates can be
  seen, but not their names or contents. Details are in
  [docs/DRIVE_VAULT.md](docs/DRIVE_VAULT.md).
- The vault keeps file contents, names, dates and the read-only, hidden and
  system attributes. It doesn't keep NTFS permissions or alternate data
  streams. Folders with symbolic links or junctions are refused.
- The design uses well-known primitives from libsodium, but it has **not had
  an independent security audit**.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the vault format and
the security model, and [docs/DRIVE_VAULT.md](docs/DRIVE_VAULT.md) for drive
vaults.

## Project structure

```text
lib/
  main.dart              entry point → app/bootstrap.dart
  app/                   startup, root widget, app-wide listeners
  core/                  shared building blocks
    theme/               design tokens, palette, Material 3 theme
    widgets/             reusable UI (buttons, cards, dialogs, fields…)
    storage/             app folders, atomic JSON files
    di/                  app-wide Riverpod providers
  engine/                vault engine: pure Dart + libsodium, no Flutter
    crypto/              libsodium wrapper, Argon2id settings, recovery key
    format/              .flk header, key slots, chunked encryption, archive
    vault/               write / read vaults, drive vault headers
    operations/          lock, unlock, re-key, crash journal
    drive/               the drive helper's client, drive lock and decrypt
  platform/              Windows: registry, FFI, single instance, shell
  features/
    auth/                master password, lock screen, auto-lock
    items/               protected items: list, protect/unlock, dialogs
    settings/            preferences
    setup/               first-run onboarding
    shell/               home window, sidebar, launch arguments
test/                    engine, feature, widget and screenshot tests
native/                  the native parts, in Rust (Cargo workspace)
  vault2/                drive vault format: keys, names, contents, tree
  drive/                 cloak_drive.exe: protocol, Dokany drive
  shell/                 cloak_shell.dll: the Explorer plug-in
  vendor/dokan/          Dokany bindings for Rust, with a fix
installer/               Inno Setup script, Dokany download, Windows 11
                         menu package (sparse/)
tool/                    icon generator
docs/                    roadmap, architecture, screenshots
```

Each feature has the same folders: `domain` (models), `data` (storage),
`application` (logic, Riverpod controllers) and `presentation` (screens and
widgets).

## Roadmap

| Phase | What | Status |
|---|---|---|
| 1 | Core app: encrypt, hide, Explorer basics, installer | Code complete, needs testing on a real Windows PC |
| 1.1 | Block access, Read-only, tray icon, reminders, auto re-lock, new recovery key | Code complete, tray and Explorer behaviour need a real PC |
| 2 | Open vaults as a virtual drive (Dokany), no plain files on disk | Code complete, the drive is tested on Windows in CI, the app needs a real PC |
| 3 | Explorer plug-in: menus that know each item, lock badges, locked folders that ask for the password | Code complete, the menu and badge are tested in Explorer's own code in CI, the app needs a real PC; Windows 11's first menu level ships with Phase 4's signing |
| 4 | Publishing: GitHub Releases, Microsoft Store, free code signing | Planned |

Details are in [docs/PLAN.md](docs/PLAN.md).

## License

Copyright (C) 2026 Priyank Raychura

Cloak is free software under the
[GNU General Public License, version 3](LICENSE) or (at your option) any
later version. You may use, share and change it, but copies and changed
versions must stay under the same license, credit the original, and come
with their source code.
