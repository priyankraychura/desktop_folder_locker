# Architecture

This document explains how Folder Locker is built. It covers:

- the code layers and folder structure;
- the `.flk` vault format and the key hierarchy;
- how operations stay safe when something goes wrong;
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
├───────────────────────────────────────────────────────────────┤
│ platform/ Windows: registry, FFI, single instance, shell      │
└───────────────────────────────────────────────────────────────┘
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
  app-wide providers: paths, crypto, engine runner, settings, environment.
  Tests override them, for example with temporary folders and cheap
  Argon2id settings.

## 2. Startup

`main.dart` calls `bootstrap(args)` in `app/bootstrap.dart`:

1. **Single instance.** It locks `instance.lock`. If another copy already
   runs (started by Explorer), this copy writes its arguments to `inbox/`
   and exits.
2. **Services.** It loads libsodium and the settings, then creates the
   Riverpod container.
3. **Explorer entries.** It makes the registry match the Explorer
   integration setting.
4. **Window.** It sets up the window with `window_manager`: size, custom
   title bar, and show only when the first frame is ready.
5. **UI.** It starts the UI. `AppGate` shows setup, the lock screen or the
   home shell, depending on the session state.

While the list of items loads, the journal recovery runs in a background
isolate. It fixes operations that a crash interrupted (section 5), and the
home screen reports what it did.

Launch arguments are `--open "<vault>"` and `--lock "<path>"`. They become
`LaunchIntent`s in a queue, and the `LaunchIntentHandler` widget shows the
right dialog. If the app is still locked, it asks for the master password
first.

## 3. Vault format (`.flk`, version 1)

A vault is one file: a 4096-byte header, then the encrypted payload.
Integers are little-endian.

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
plus slot 3.

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

## 6. App data

Everything lives in `%APPDATA%\FolderLocker`:

| File | Content |
|---|---|
| `keystore.json` | master password settings (section 4) |
| `items.json` | the list of protected items and their state |
| `settings.json` | preferences |
| `journal/` | one JSON file per running operation |
| `inbox/`, `instance.lock` | single-instance messages |

JSON files are written safely, so a crash never leaves half a file:

1. The app writes `file.tmp` and flushes it to disk.
2. It keeps the previous version as `file.bak`.
3. It renames the temp file into place.

If the main file is missing or damaged, the app reads the backup.

The vaults themselves are self-contained. If `items.json` is lost, you can
still open any vault by double-clicking it and typing its password or the
recovery key.

## 7. Windows integration

- **Explorer** (`platform/explorer_integration.dart`, per user under
  `HKCU\Software\Classes`, no admin rights). The installer writes the same
  keys and removes them on uninstall.

  | Key | Value |
  |---|---|
  | `.flk` | `FolderLocker.Vault` |
  | `FolderLocker.Vault\DefaultIcon` | `"<exe>",-102` (vault icon resource) |
  | `FolderLocker.Vault\shell\open\command` | `"<exe>" --open "%1"` |
  | `Directory\shell\FolderLocker.Lock\command` | `"<exe>" --lock "%1"` |
  | `*\shell\FolderLocker.Lock\command` | `"<exe>" --lock "%1"` |

  On Windows 11 the "Lock with…" entry appears under **Show more options**.
  A top-level entry needs a shell extension (Phase 3).
- **Hide** sets the Hidden and System attributes (`SetFileAttributesW`
  through FFI). Explorer's default settings then hide the item.
- **Single instance.** The first copy holds an exclusive lock on
  `instance.lock` and watches `inbox/`. Later copies write their arguments
  there, call `AllowSetForegroundWindow` and exit.
- **Window.** The runner doesn't show the window by itself. Dart shows it
  after the first frame, so there is no white flash. The title bar is
  custom-drawn with `window_manager`.

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
- **A compromised PC.** Malware, or anyone using the PC while the app is
  unlocked, can read what you can read.
- **Deleted originals.** After locking, the deleted original files may stay
  recoverable with forensic tools until they are overwritten. Phase 2
  (virtual drive) avoids writing plain files.
- **Hide-only items.** Hiding is convenience, not security.

**Memory hygiene:**

- Keys live in libsodium `SecureKey`s (locked, guarded memory) and are
  disposed after use.
- Temporary key copies are zeroed.
- Passwords are Dart strings, so they can't be wiped reliably. They are kept
  only as long as needed.

The cryptography is standard libsodium, but the design has **not been
independently audited**.

## 9. Tests

| Folder | What it covers |
|---|---|
| `test/engine` | byte encoding, key slots, header A/B areas, archive paths, crypto; lock/unlock round trips with nested folders, Unicode names, chunk-boundary sizes and empty files; tamper and truncation detection; startup recovery of interrupted locks and unlocks; cancel; the isolate runner |
| `test/features`, `test/core` | setup, unlock, change and reset of the master password; custom-password items; hide-only items; the path guard; launch arguments; JSON files with backup |
| `test/widget` | full UI flows: setup → recovery key → home → lock/unlock app; item cards: unlock, lock again, remove |
| `test/visual` | renders every main screen to PNG (only when `SCREENSHOTS_DIR` is set) |

The tests use cheap Argon2id settings (`KdfPolicy.fast`) and temporary
folders. On every push, CI runs:

- on Linux: format check, `flutter analyze` and all tests;
- on Windows: the tests, the release build and the installer.
