# Architecture

This document explains how Cloak is built. It covers:

- the code layers and folder structure;
- the `.flk` vault format and the key hierarchy;
- how operations stay safe when something goes wrong;
- drive vaults, which open as a Windows drive (their format and the helper
  program are in [DRIVE_VAULT.md](DRIVE_VAULT.md));
- the Windows integration;
- the security model and the tests.

## 1. Layers

```text
┌───────────────────────────────────────────────────────────────┐
│ features/*/presentation   screens, dialogs, widgets           │
├───────────────────────────────────────────────────────────────┤
│ features/*/application    Riverpod controllers and services   │
├──────────────────────────────┬────────────────────────────────┤
│ features/*/domain + data     │ core/  theme, widgets, storage │
├──────────────────────────────┴────────────────────────────────┤
│ engine/   vault format + operations (pure Dart + libsodium)   │
├──────────────────────────────┬────────────────────────────────┤
│ platform/ Windows: registry, │ native/ drive helper (Rust,    │
│ FFI, single instance, shell  │ a separate process) + Dokany;  │
│                              │ Explorer plug-in (Rust DLL)    │
└──────────────────────────────┴────────────────────────────────┘
```

Rules that keep the code consistent:

- **`engine/` never imports Flutter.** It is plain Dart that runs in
  background isolates and in unit tests. It only uses `sodium`, `path`,
  `ffi` and the small `platform/file_system_info.dart` helper.
- **Features are feature-first.** Each one has `domain` (immutable models
  with `toJson`/`fromJson`), `data` (storage), `application` (logic) and
  `presentation` (UI).
- **UI only talks to controllers.** Screens call methods on Riverpod
  notifiers such as `ProtectionController` and `SessionController`. They
  never touch the engine or the file system directly.
- **Shared UI lives in `core/widgets`.** This includes `AppDialog`,
  `PasswordField`, `NewPasswordFields`, `StatusBadge`, `IconTile`, cards,
  buttons and toasts. Colors and sizes come only from `core/theme`: design
  tokens, `AppPalette` tones and the Material 3 theme. This keeps every
  screen consistent.
- **Dependencies are injected.** `core/di/core_providers.dart` holds the
  app-wide providers: paths, crypto, engine runner, drive helper, settings,
  environment. Tests override them, for example with temporary folders,
  cheap Argon2id settings and a fake drive helper.
- **The drive helper is a separate program.** Only
  `engine/drive/drive_helper.dart` knows how to start and talk to it;
  everything else uses the `DriveService` interface (section 5.3).
- **The Explorer plug-in only reads and asks.** It reads `items.json` and
  starts the app with a launch argument; the app does the work, with its
  usual dialogs and checks (section 7).

## 2. Startup

`main.dart` calls `bootstrap(args)` in `app/bootstrap.dart`:

1. **Single instance.** It locks `instance.lock`. If another copy already
   runs (started by Explorer), this copy writes its arguments to `inbox/`
   and exits.
2. **Services.** It loads libsodium and the settings, then creates the
   Riverpod container.
3. **Explorer entries.** It makes the registry match the Explorer
   integration setting.
4. **Window.** It sets up the window with `window_manager`
   (`app/app_window.dart`) and shows it once the first frame is ready.
   The app is large, with a custom title bar. The window is compact
   instead, the size of a dialog with Windows' title bar, while the app is
   locked (the lock screen is just its password form), and for a request
   that needs only a dialog (below). Once set up, the app starts locked, so
   it starts compact.
5. **UI.** It starts the UI. `AppGate` shows setup, the lock screen or the
   home shell, depending on the session state.

While the list of items loads, the journal recovery runs in a background
isolate. It fixes operations that a crash interrupted (section 5), and the
home screen reports what it did.

Launch arguments are `--open "<vault>"`, `--lock "<path>"` and
`--unlock "<path>"`. They become `LaunchIntent`s in a queue, and the
`LaunchIntentHandler` widget runs them one at a time:

- `--open` asks for the vault's password, even while the app is locked.
  When the app isn't showing (Explorer started it for this, or it runs in
  the notification area), the window shows only that dialog, small, and
  hides afterwards. Anything that needs more (setup, a `--lock`) shows the
  app.
- `--lock` protects a new item (the protect dialog), or locks a listed
  unlocked item again without asking (the user chose it in Explorer).
- `--unlock` unlocks a listed item.

The app queues one request of its own, `LockAgainIntent`: the question
whether to lock a folder again once its last Explorer window closed
(section 5.2). Like `--open`, it needs only a dialog and works while the
app is locked. Locking and unlocking wait until the app is unlocked, and
a toast says so.

The app runs in the background, in the notification area, only while it
has something to look after: unlocked items, to remind about them and
ask to lock them again, or open drives, which it serves
(`WindowController`). Otherwise closing its window, or finishing a
request, quits it, and in the background it quits once the last item is
locked again. Without the icon, a request that unlocked a folder still
leaves the app hidden in the background while "Ask to lock when closed"
is on, to ask once the folder's Explorer window closes (starting the app
again shows it); an open drive shows the app instead.

An encrypted item locks again without a password, even after the app
locked or quit, or Windows restarted (`RelockKeys`): as it is unlocked,
while a key for it is at hand, the app makes the keys of its next vault
(`PreparedVault`: a new vault id and data key, and key slots that already
hold that data key for its passwords and the recovery key). The data key
is kept in `%APPDATA%\FolderLocker\relock`, protected with Windows' Data
Protection API for this user; it opens only that next vault, of files
that are unlocked on the disk meanwhile anyway. Each is used for one
vault, since payload nonces count from zero: a lock that failed after
writing with it drops it (`EngineException.keysUsed`). A new master
password or recovery key updates their slots.

## 3. Vault format (`.flk`, version 1)

A vault is one file: a 4096-byte header, then the encrypted payload.
Integers are little-endian.

Drive vaults (format version 2) use the same header, as `vault.flk` inside
a `Name.flkd` folder, and store each file on its own next to it (section
5.3 and [DRIVE_VAULT.md](DRIVE_VAULT.md)).

### 3.1 Header

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | magic `FLKVAULT` |
| 8 | 2 | format version (`1`) |
| 10 | 2 | flags (`0`) |
| 12 | 4 | header size (`4096`) |
| 16 | 16 | vault id (random) |
| 32 | 4 | chunk size (`262144`) |
| 36 | 1 | cipher (`1` = XChaCha20-Poly1305) |
| 37 | 27 | zero |
| 1024 | 1024 | key-slot area A |
| 2048 | 1024 | key-slot area B |

The first 64 bytes are the **prefix**. The prefix never changes, and it is
used as associated data (AAD) for every chunk and key slot. This means
chunks and slots can't be moved from one vault into another.

**Key-slot area** (1024 bytes):

```text
u64 generation | u8 slot count | 7 zero bytes | slots (160 bytes each)
… zero padding … | BLAKE2b-256(prefix ‖ area body) checksum (32 bytes)
```

Both areas are written when a vault is created. To change a password, the
app rewrites only the **older** area, with `generation + 1`, and flushes it.
Readers use the valid area with the higher generation. A crash during the
rewrite therefore always leaves one good copy.

**Key slot** (160 bytes): `u8 type | u8 version | u16 payload length |
payload | zero padding`.

| Type | Payload |
|---|---|
| 1 master password, 2 custom password | `u32 opsLimit`, `u32 memLimitKiB`, 16-byte salt, 24-byte nonce, 48-byte wrapped data key |
| 3 recovery | 8-byte fingerprint of the recovery public key, `u16` length, sealed box |

Unknown slot types are kept byte for byte when the slots are rewritten.
This way, a newer app version can add new slot types.

### 3.2 Payload

The plaintext stream is split into **256 KiB chunks**. Each chunk is
encrypted with XChaCha20-Poly1305 (16-byte tag):

```text
nonce(i) = u64 i | u8 final flag | 15 zero bytes      (24 bytes)
chunk(i) = AEAD(payloadKey, nonce(i), plaintext, aad = prefix)
```

The last chunk has the final flag set. It may be short, or empty when the
payload is empty. This is the "STREAM" construction also used by age and
Tink. Any of these is detected:

- reordering, dropping or duplicating chunks;
- cutting the file short;
- appending data.

The nonces can be counters because every vault has its own random key.

### 3.3 Archive (the plaintext stream)

```text
"FLKARCH1" | u32 length | metadata JSON {kind, name, createdAt, counts}
entry:  u8 tag (1 folder, 2 file) | u16 length | UTF-8 path ("/" separated)
        | i64 modified (ms, -1 = unknown) | u32 attributes
        | file only: u64 size | size bytes of content
end:    u8 0 | u64 files | u64 folders | u64 total bytes
```

The reader checks these rules and treats any failure as a corrupt vault:

- The trailer counts must match what was read, and nothing may follow the
  end marker.
- Every path must be a valid Windows name, with no `..`, drive letters,
  reserved names or duplicate names. So a crafted vault can never write
  outside the folder being restored.
- A single-file vault must contain exactly one file.

## 4. Keys

```text
master password ──Argon2id(salt, 3 passes, 256 MiB)──► master key (32 B)
custom password ──Argon2id(own salt)─────────────────► item key (32 B)
recovery key (160 bits, shown once)
    └─BLAKE2b("folder-locker/recovery-seed/v1" ‖ key)─► X25519 key pair
                                                        public key → keystore.json

per vault:  data key (32 random bytes)
    ├─ slot 1: XChaCha20-Poly1305(master key, data key, aad = prefix ‖ 1)
    ├─ slot 2: XChaCha20-Poly1305(item key,   data key, aad = prefix ‖ 2)
    ├─ slot 3: sealed box to the recovery public key (vault id ‖ data key)
    └─ payload key = HKDF-SHA256(data key, salt = vault id,
                                 info = "folder-locker/payload/v1")
```

Each vault has slot 1 *or* slot 2, depending on the item's password mode,
plus slot 3. A drive vault has the same slots in its `vault.flk`. Its data
key goes to the drive helper, which derives its own keys from it
([DRIVE_VAULT.md §2.2](DRIVE_VAULT.md#22-keys)).

- **`keystore.json` holds no secret.** It contains:
  - the Argon2id settings and salt;
  - a *verifier*, which is a known text encrypted with the master key, so
    the app can check a typed password;
  - the recovery **public** key.
- **Open items don't need the master password again.** While the app is
  unlocked, the master key stays in libsodium's protected memory
  (`SecureKey`). Master-password items can then be opened without asking.
  Locking the app wipes the master key and all remembered item keys.
- **Changing the master password is fast.** The app rewrites only slot 1 of
  each master-password vault (section 3.1). It never re-encrypts the files.
  - The keystore is saved first, so the new password always works.
  - If a vault can't be updated (for example, its drive is unplugged), the
    item is flagged. It then opens with the old password or the recovery
    key.
- **The recovery key replaces the master password.** It is checked against
  the stored public key. It then opens each vault through slot 3, and the
  vault gets a new slot 1 for the new password. The recovery secret is
  never stored.
- **A new recovery key can be created at any time** (Settings). The flow:
  1. The key is shown once, and the user confirms they saved it.
  2. Its public key is saved in the keystore first, with an
     `updatePending` flag. From then on only the new key resets the master
     password.
  3. `ResealOperation` replaces slot 3 of every vault the app can open
     right now (master key, or a remembered item key). It only rewrites
     the key-slot area, crash-safely (section 3.1).
  4. Vaults it can't open keep the old slot for now: an item with its own
     password that is locked, or a vault on a drive that isn't connected.
     Items with their own password get the new key the next time they are
     locked again (a new vault is written).
  5. While the flag is set, every unlock of the app tries again and clears
     it once all vaults are current.

## 5. Operations and crash safety

The engine runs in **background isolates** (`EngineRunner`). Keys cross
isolates as `TransferrableSecureKey`s.

- **Progress** comes back on a port, at most every 80 ms.
- **Cancel** sets a flag in shared native memory. The job checks the flag
  between chunks, then rolls back.

**Lock** (`LockOperation`):

1. **Scan** the item. Nothing is changed yet. Links, junctions, invalid names
   and case-only duplicates are refused. The free disk space is checked.
2. **Journal** `started`.
3. **Rename** the item to `Name.<id>.flk-locking`. If a program still has a
   file open, this fails early.
4. **Write** `Name.<id>.flk-partial`.
5. **Verify.** Decrypt the whole vault again and compare the counts. Journal
   `verified`.
6. **Rename** the partial file to `Name.flk`. Journal `committed`.
7. **Delete** the original and remove the journal entry.

Any error before step 6 puts the original back.

**Unlock** (`UnlockOperation`):

1. **Check** the password against the key slots. Nothing is written first.
2. **Journal** `started`.
3. **Decrypt** into `Name.<id>.flk-restoring`.
4. **Rename** it to the final name. If that name is taken, a free name like
   `Name (2)` is used.
5. **Journal** `committed`.
6. **Delete** the vault.

**Startup recovery** (`JournalRecovery`) reads every journal entry left in
`%APPDATA%\FolderLocker\journal` and decides:

| Entry | Situation | Action |
|---|---|---|
| lock `committed`, or `verified` with the vault present | the vault is complete | finish: move the vault into place, delete the original |
| lock `started` | the vault may be incomplete | roll back: rename the item back, delete the partial file |
| unlock `committed` with the item present | the files are restored | finish: delete the vault and the work folder |
| unlock `started` | the restore may be incomplete | roll back: delete the work folder (the vault is untouched) |

If recovery fails, the entry stays for the next start. The UI reports what
was recovered.

### 5.1 Block access and Read-only

These methods leave the item in place and add one Windows permission entry
(`platform/access_control.dart`, Win32 security API through FFI).

- **The entry:** "deny Everyone", explicit, inherited by every file and
  subfolder. Windows copies it to everything inside, so the call runs in a
  background isolate.
- **Block access** denies listing, reading, running, writing, creating and
  deleting.
- **Read-only** denies only writing, creating, deleting and changing
  attributes.
- **Never denied:** reading attributes and permissions, and changing
  permissions. Explorer can still show the item, and its owner can always
  remove the entry again.
- **Only for items the user owns.** The owner must be the user, or a group
  that is enabled in their token. The drive must support permissions (NTFS),
  and the item must have a permission list at all.
- **Removal is exact.** The app's own entry is recognised by its exact
  mask, and nothing else is touched.
- **The item is saved as locked before the entry is added.** If the app
  stops halfway, "Unlock" still cleans up. A failed apply is rolled back,
  and an item whose rollback also fails stays in the list so it can be
  unlocked later.

### 5.2 Items left unlocked

- `UnlockedItemsWatcher` checks every 30 seconds:
  - It locks items again after the chosen time, but only when that needs
    no typed password. It never interrupts another operation. An item with
    a file in use is retried after 5 minutes.
  - It reports items that have been unlocked longer than the reminder time,
    once per unlock.
- `FolderWindowWatcher` knows which folders Explorer's windows and tabs
  show: Explorer tells each change as it happens (the Explorer watcher,
  section 7). An item that a window showed (it, or a folder inside it),
  and that no window shows any more, closed or navigated away from, gets
  the question "Lock it again?" right away, once until it shows again.
  Like Explorer's own question would, it shows in front, over the window
  that closed. Where Explorer can't be watched, the watcher asks it every
  2 seconds instead (through the plug-in, section 7), never both. "Ask
  when I close them" in Settings turns this off.
- Items unlocked with a typed password lock again without it: their key
  stays in memory while they're unlocked (`ItemKeyCache`), even while the
  app is locked. Locking the app wipes these keys, so an item unlocked
  before that needs the master password again: the question asks for it.
- `AppLocker` is the only way the app gets locked (sidebar, `Ctrl+L`, tray
  menu, auto-lock). With "Lock them when the app locks" on, it locks
  unlocked items first, while their keys are still in memory.
- Open drives count as unlocked items. A drive with files open in
  programs is skipped and tried again later, like an item with a file in
  use (section 5.3).

### 5.3 Drive vaults

Items with `ProtectionMethod.drive` are folders that become `Name.flkd`,
opened as a drive through Dokany. The format, the helper's protocol and
the security notes are in [DRIVE_VAULT.md](DRIVE_VAULT.md).

- **The helper.** `HelperDriveService` starts `cloak_drive.exe`
  (next to the app) on first use, and talks to it over its standard input
  and output. The data key goes into the pipe from protected memory, and
  the buffer is wiped. When the app exits, even by a crash, the pipe
  closes and the helper closes every drive.
- **Lock** (`DriveOperations.lock`) uses the lock journal of section 5:
  the folder is renamed to `Name.<id>.flk-locking`, the app writes
  `Name.<id>.flkd-partial\vault.flk` with the key slots, the helper
  encrypts every file and checks it, the vault folder is renamed into
  place, and then the original is deleted. Startup recovery treats the
  partial vault folder like a partial `.flk` file.
- **Open** unwraps the data key in a background isolate
  (`EngineRunner.openDriveKey`) and asks the helper to mount the vault.
  The item is saved as unlocked with its `mountPoint`; its vault stays
  (`hasVault`), so it can't leave the list.
- **Lock again** closes the drive and needs no key. If programs have files
  open on it, `lockAgain` throws `DriveErrorCode.inUse`, unless `force` is
  set: the card then asks "Close anyway", and automatic locking tries again
  later.
- **Drives that close by themselves** (ejected in Explorer, or the helper
  stopped) come as `unmounted` events, and the item shows as locked. At
  startup, items still marked as open are reset to locked: no drive
  outlives the app.
- **Decrypt to a folder** (`DriveOperations.export`) uses the unlock
  journal: the helper decrypts into `Name.<id>.flk-restoring` and checks
  it, the folder is renamed into place, and the vault is deleted.
- **Passwords** work as for `.flk` vaults: a new master password or
  recovery key rewrites the key slots in `vault.flk`, even while the drive
  is open.
- **Dokany** ships next to the app (`dokany\Dokan_x64.msi`, a pinned
  version fetched by `installer/get-dokany.ps1`). The installer runs it
  when Dokany is missing; `BundledDokanyInstaller`
  (`platform/dokany_setup.dart`) runs it later from Settings with
  `ShellExecuteEx("runas")`. The helper finds it without a restart.

## 6. App data

Everything lives in `%APPDATA%\FolderLocker`. The app was called Folder
Locker before, and what existing installs and vaults rely on keeps that
name: this folder, the registry ids (`FolderLocker.Vault`,
`FolderLocker.Lock`, the badge's ` FolderLocker`), the `.flk` extension and
the vault format's labels (`folder-locker/...`, section 4). The installer
removes the old app's files and shortcuts when it updates it.

| File | Content |
|---|---|
| `keystore.json` | master password settings (section 4) |
| `items.json` | the list of protected items and their state |
| `settings.json` | preferences |
| `journal/` | one JSON file per running operation |
| `inbox/`, `instance.lock` | single-instance messages |

JSON files are written safely, so a crash never leaves half a file:

1. The app writes `file.tmp` and flushes it to disk.
2. It copies the previous version to `file.bak`.
3. It renames the temp file over the original, in one step. The file is
   never missing, not even for a moment: the Explorer plug-in reads
   `items.json` as soon as it changes, and would otherwise see an empty
   list.

When another program (an antivirus, the search indexer) briefly holds the
file, each step is tried again a few times. If the main file is damaged,
the app reads the backup.

The vaults themselves are self-contained. If `items.json` is lost, you can
still open any vault by double-clicking it and typing its password or the
recovery key.

## 7. Windows integration

- **Explorer** (`platform/explorer_integration.dart`, per user under
  `HKCU\Software\Classes`, no admin rights). The installer writes the same
  keys and removes them on uninstall. At startup the app writes them again
  if they point elsewhere (the app moved, or the plug-in came or went).

  | Key | Value |
  |---|---|
  | `.flk` | `FolderLocker.Vault` |
  | `FolderLocker.Vault\DefaultIcon` | `"<exe>",-102` (vault icon resource) |
  | `FolderLocker.Vault\shell\open\command` | `"<exe>" --open "%1"` |
  | `CLSID\{3C1C048E-1C62-4B0B-87AC-55EDAD0E97BB}\InprocServer32` | `<app folder>\cloak_shell.dll`, `ThreadingModel` = `Apartment` |
  | `Directory`, `*` and `Drive` `\shell\FolderLocker.Lock` | `ExplorerCommandHandler` = the class id above |

  Installed for all users, the installer also registers the lock badge for
  the machine (`HKLM`), where Windows reads icon overlays:

  | Key (under `HKLM\Software`) | Value |
  |---|---|
  | `Classes\CLSID\{38F771FD-E77E-4105-A560-9E02A7B507D5}\InprocServer32` | `<app folder>\cloak_shell.dll`, `ThreadingModel` = `Apartment` |
  | `Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers\ FolderLocker` | the class id above |

  Without `cloak_shell.dll` next to the app (a development build
  without it), folders and files get the plain `FolderLocker.Lock` entry
  instead: "Lock with Cloak", `"<exe>" --lock "%1"`.

  On Windows 11 the entry appears under **Show more options**; the first
  menu level needs a signed package (Phase 3e).
- **Explorer plug-in** (`native/shell`, `cloak_shell.dll`). A
  small in-process COM server in Rust with two classes. The right-click
  entry implements `IExplorerCommand`, so Explorer asks it for the entry's
  title and state, and runs it:

  | The item | The entry | The app gets |
  |---|---|---|
  | A new folder or file | Lock with Cloak | `--lock <path>` |
  | A listed item that is unlocked | Lock with Cloak | `--lock <item>` |
  | A blocked, read-only or hidden item | Unlock with Cloak | `--unlock <item>` |
  | A drive vault (`.flkd`) that is locked, or not in the list | Open with Cloak | `--open <vault>` |
  | An open drive (`V:`) or its vault folder | Lock with Cloak | `--lock <item>` |
  | A `.flk` file, a whole drive, anything inside a `.flkd` folder or the Recycle Bin, several items | none (`.flk` files have the file type's own "Unlock with…") | |

  The lock badge implements `IShellIconOverlayIdentifier`: a padlock
  (`lock_badge.ico`, next to the DLL) on blocked, read-only and hidden
  items while they're protected, if the user's Explorer integration
  setting is on. Explorer asks it about every file it shows, so it answers
  from memory. Windows uses only the first 15 overlays by name (cloud apps
  register many, with leading spaces), so its name starts with a space.

  Both read `%APPDATA%\FolderLocker\items.json` and `settings.json`
  (which the app replaces in one step), again only when they changed. A
  change notification on that folder says when, so a badge changes as
  soon as the app tells Explorer an item changed. Everything else is the
  app's job: the plug-in only starts
  `cloak.exe` from its own folder, passing none of Explorer's
  handles. Every entry point catches errors and panics and returns an
  error code, so a problem in it can't take Explorer down. The release
  build carries the Visual C++ runtime inside (`static_vcruntime`), so it
  doesn't depend on whichever `vcruntime140.dll` Explorer has loaded.

  The app loads the DLL too, for one more export:
  `CloakShownFolders` lists the folders that Explorer windows and
  tabs show (`IShellWindows`, and each window's current folder as a file
  system path). Each call asks Explorer's process, so the app makes it in
  another isolate, one at a time (`NativeExplorerFolders`). The app
  only does that where it can't watch Explorer (next item).

  Windows 11's first menu level only shows commands from packages. The
  Windows 11 menu package (`installer/sparse`) is a package with external
  location: just a manifest and logos, pointing to the app's folder. It
  declares the same command under its own class id
  (`{70A5D511-629B-4DF6-81E3-48CBA421BF7E}`), which Windows runs in a
  host process (`dllhost`). Windows installs it only if it trusts the
  signature, so it ships with Phase 4's signing. Until then CI builds it,
  signs it with a throwaway certificate, installs it next to the built app
  and checks that Windows makes the command through it.

  Explorer keeps the DLL loaded for a while after it's used. A loaded DLL
  can't be replaced, but it can be renamed, so the installer moves it
  aside first (to `%TEMP%`, deleted at the next restart where Setup may do
  that): updating and uninstalling need no restart.
- **Drive vaults.** `vault.flk` inside a `Name.flkd` folder is a `.flk`
  file, so it has the vault icon and double-clicking it asks for the
  password and opens the drive. "Open with…" on a `.flkd` folder does the
  same. The folder shows the vault icon, hides its encrypted data and says
  what it is in a tooltip, through a `desktop.ini` that the helper writes
  ([DRIVE_VAULT.md](DRIVE_VAULT.md)). The drive itself comes from Dokany through the helper, which loads
  `dokan2.dll` only from System32.
- **Hide** sets the Hidden and System attributes (`SetFileAttributesW`
  through FFI). Explorer's default settings then hide the item.
- **Block access / Read-only** use `GetNamedSecurityInfoW` and
  `SetNamedSecurityInfoW` (section 5.1).
- **Explorer watcher** (`windows/runner/explorer_watcher.cpp`). Tells
  Dart which folders Explorer shows as soon as that changes, over the
  `cloak/explorer` method channel (`watch`, then `changed` with the
  folders and where the window whose change it was is on the screen).
  It listens to Explorer's events rather than asking again and again:
  ShellWindows' (`DShellWindowsEvents`: a window or tab opened or closed)
  and each window's own (`DWebBrowserEvents2`: it went to another folder,
  or quit). A window that quits is gone from the list at once. This is
  the same signal Explorer add-ons get, from outside Explorer: nothing
  of the app runs in Explorer's process for it, and it needs no
  administrator rights and no Explorer restart. It runs on a thread of
  its own, so a busy Explorer never holds up the app's window. Every 5
  seconds it looks again, in case an event went missing, and connects
  again after Explorer restarted. An Explorer that went away closes no
  folder.

  The question then shows over the Explorer window that closed, in front
  (`cloak/window`: `placeOver` and `toFront`). Windows lets only the app
  the user works with bring a window forward, so the runner borrows its
  input for a moment (`AttachThreadInput`); if Windows still refuses, the
  window goes on top of the others and flashes in the taskbar.
- **Notification-area icon** (`windows/runner/tray_icon.cpp`). Dart drives
  it over the `cloak/tray` method channel:
  - `show` sets the tooltip, the "items unlocked" icon and the menu;
  - `hide` removes the icon;
  - `notify` shows a balloon, which Windows 10 and 11 turn into a normal
    notification.

  Clicks and menu choices come back as `activate` and `menuItem`. The icon
  has a hidden window of its own, which gets its messages and owns its
  menu: the menu needs its owner in the foreground, and that mustn't bring
  the app's window forward. The icon is added again when Explorer
  restarts (`TaskbarCreated`). Its menu locks the unlocked items even
  while the app is locked; those that need a password ask for it, one by
  one. With "Keep running in the notification area" on, closing the
  window only hides it while the app has something to look after
  (section 2).
- **Single instance.** The first copy holds an exclusive lock on
  `instance.lock` and watches `inbox/`. Later copies write their arguments
  there, call `AllowSetForegroundWindow` and exit.
- **Window.** The runner doesn't show the window by itself. Dart shows it
  after the first frame, so there is no white flash. The title bar is
  custom-drawn with `window_manager`. While the app is locked, and for a
  request that needs only a dialog, the same window is compact: small and
  fixed, with Windows' title bar (`NativeAppWindow`). Unlocking puts it
  back where it was, maximized if it was. A minimized window changes when
  it's restored.

## 8. Security model

**Protected:** items that are locked, whether they are:

- copied;
- read from another operating system;
- on a disk taken out of the PC;
- changed by someone.

Opening a vault needs the password (Argon2id makes guessing slow) or the
recovery key. Any change to a vault is detected before its data is used.

**Not protected:**

- **Unlocked items.** Their files are normal files while they are unlocked.
  An open drive vault is decrypted only in memory, but every program
  running as the user can read the drive while it is open.
- **A compromised PC.** Malware, or anyone using the PC while the app is
  unlocked, can read what you can read.
- **Deleted originals.** After locking, the deleted original files may stay
  recoverable with forensic tools until they are overwritten. Drive vaults
  avoid this after the first lock: opening one never writes plain files.
- **Hide-only items.** Hiding is convenience, not security.
- **Blocked and read-only items** against their owner, administrators or
  another operating system. The permission entry stops other accounts and
  accidents, but it isn't encryption.

**Memory hygiene:**

- Keys live in libsodium `SecureKey`s (locked, guarded memory) and are
  disposed after use. The drive helper keeps a vault's keys only while its
  drive is open, and wipes them afterwards.
- Temporary key copies are zeroed.
- Passwords are Dart strings, so they can't be wiped reliably. They are kept
  only as long as needed.

The cryptography is standard libsodium, but the design has **not been
independently audited**.

## 9. Tests

| Folder | What it covers |
|---|---|
| `test/engine` | byte encoding, key slots, header A/B areas, archive paths, crypto; lock/unlock round trips with nested folders, Unicode names, chunk-boundary sizes and empty files; tamper and truncation detection; startup recovery of interrupted locks and unlocks; cancel; the isolate runner; the real drive helper (import, check, export, a wrong key) |
| `test/features`, `test/core` | setup, unlock, change and reset of the master password; new recovery key and its later completion; custom-password items; hide-only, blocked and read-only items (with an in-memory stand-in for the permission rules); drive items (with a fake helper): lock, open, close, drives in use, decrypt to a folder, restarts; reminders, automatic re-locking and locking items with the app; which closed folders get the question to lock them again; the path guard; launch arguments; the old `items.json` format; JSON files with backup |
| `test/platform` | real Windows permission entries on NTFS: block, read-only, replace and remove, on folders and files; the Explorer entries with and without the plug-in, written under a test key; the folders a real Explorer window shows, through the built plug-in (Windows only, run in CI) |
| `test/widget` | full UI flows: setup → recovery key → home → lock/unlock app; item cards: unlock, lock again, remove, and a drive's open, close and decrypt; the protect dialog's methods and "Open it as"; the Dokany row in Settings; the tray icon following the items and running its menu; Explorer's unlock and lock requests, and requests waiting for the app to be unlocked; the small window for a request, the question to lock a closed folder again (with the master password when the app locked since), and the app ending once nothing is left |
| `native/` (`cargo test`) | the drive vault format and the helper, on Linux and Windows; on Windows with Dokany, a drive mounted and used end to end ([DRIVE_VAULT.md §6](DRIVE_VAULT.md#6-tests)). The plug-in's choice of entry and badge for each kind of item; on Windows, its COM objects as Explorer uses them, and end to end: the entry registered, shown by Windows' own menu code (shell32) with the right title, and run; the badge registered, loaded by Windows' overlay code and shown only on protected items; the folders Explorer shows, with a real window opened and closed |
| `test/visual` | renders every main screen to PNG (only when `SCREENSHOTS_DIR` is set) |

The tests use cheap Argon2id settings (`KdfPolicy.fast`) and temporary
folders. On every push, CI runs:

- on Linux: format checks, `flutter analyze`, Clippy, and the Rust and
  Flutter tests;
- on Windows: Clippy, the plug-in's tests on its release build (end to
  end in Explorer's menu code, and with a real Explorer window), the release helper and plug-in, the
  Flutter tests, the release build and the installer, which is then
  installed, checked and uninstalled;
- on Windows with Dokany installed: the drive end-to-end test.
