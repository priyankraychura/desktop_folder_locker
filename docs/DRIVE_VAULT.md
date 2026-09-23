# Drive vaults

A **drive vault** is an encrypted folder that opens as a Windows drive (for
example `V:`). Its files are decrypted in memory, only while a program
reads them, so **nothing unencrypted is ever written to the disk**. This is
Phase 2 of the [roadmap](PLAN.md).

This document covers:

- the pieces and how they talk to each other;
- the format on disk (vault format version 2);
- the helper program and its protocol;
- what is protected and what isn't.

The classic `.flk` vaults (one file per vault) are described in
[ARCHITECTURE.md](ARCHITECTURE.md). Both kinds share the header layout, the
key slots and the password handling.

## 1. Pieces

```text
Flutter app ──JSON lines over a pipe──► folder_locker_drive.exe ──► Dokany ──► V:\
  │                                         │
  │ passwords, key slots                    │ file names and contents
  ▼                                         ▼
Taxes.flkd\vault.flk                      Taxes.flkd\data\…
```

- **The app** (Dart) owns everything about passwords. It writes the header
  and the key slots, unwraps the vault's data key when the user types a
  password, and sends only that data key to the helper.
- **The helper** (`native/`, Rust) does everything with files: it encrypts a
  folder into a vault, serves the vault as a drive, and decrypts it back
  into a folder. The app starts it on first use and talks to it over its
  standard input and output.
- **[Dokany](https://github.com/dokan-dev/dokany)** is a free, open-source
  file-system driver that Microsoft has already signed. The user installs it
  once. The helper uses it to create the drive in user mode, so Folder
  Locker needs no driver of its own.

Code map:

| Where | What |
|---|---|
| `lib/engine/vault/drive_vault.dart` | creates the vault folder and its header, opens the data key |
| `lib/engine/drive/drive_service.dart` | what the app needs from the helper (an interface, faked in tests) |
| `lib/engine/drive/drive_helper.dart` | starts the helper and speaks its protocol |
| `lib/engine/drive/drive_operations.dart` | folder → vault and vault → folder, with the crash journal |
| `native/vault2` | the format: keys, names, contents, the folder tree, import and export |
| `native/drive` | the helper: protocol, jobs, the Dokany file system |
| `native/vendor/dokan` | the Dokany bindings for Rust, with one fix (see its `PATCHES.md`) |

## 2. On disk

```text
Taxes.flkd\              read-only attribute, so Explorer reads desktop.ini
  vault.flk              header and key slots (4096 bytes)
  desktop.ini            the folder's icon and tooltip (hidden)
  folder.ico             the vault icon (hidden)
  data\                  (hidden)
    dir.iv               random IV for the names in this folder (16 bytes)
    key.check            tells a wrong key right away (32 bytes)
    3kR…w                a file (encrypted name)
    Ym9…A\               a folder (encrypted name)
      dir.iv
      …
    LQ2…8                a file or folder with a long name…
    LQ2…8.name           …and its full encrypted name
```

The folder tree has the same shape as the original: one stored file per
file and one stored folder per folder.

`desktop.ini` and `folder.ico` are only the folder's look in Explorer: the
vault icon, a tooltip, and nothing but `vault.flk` in sight (the other
entries are hidden system files, which Explorer doesn't show by default).
So opening the folder leads straight to the password dialog, on any PC,
without the app's Explorer plug-in. The helper writes them after an import,
and again when it opens a vault made before they existed. The vault works
without them.

### 2.1 Header (`vault.flk`)

`vault.flk` uses the same 4096-byte layout as a `.flk` vault
([ARCHITECTURE.md §3.1](ARCHITECTURE.md#31-header)), with three differences:

| Offset | Size | Field | `.flk` | drive vault |
|---|---|---|---|---|
| 8 | 2 | format version | `1` | `2` |
| 10 | 2 | flags | `0` | `1` (drive) |
| 32 | 4 | chunk / block size | `262144` | `65536` |

The key-slot areas A and B, the slot types (master password, own password,
recovery key) and the crash-safe slot rewrite are the same. Changing the
master password or creating a new recovery key only rewrites `vault.flk`;
the files are never touched. App versions before 1.2 refuse version 2
("made by a newer version").

`vault.flk` inside a `.flkd` folder keeps the `.flk` icon and file type, so
double-clicking it opens the app's password dialog too.

### 2.2 Keys

```text
data key (32 random bytes, wrapped in the key slots as in a .flk vault)
  ├─ content key  = HKDF-SHA256(data key, salt = vault id, info = "folder-locker/v2/content")
  ├─ names key    = HKDF-SHA256(…, info = "folder-locker/v2/names")
  ├─ name-IV key  = HKDF-SHA256(…, info = "folder-locker/v2/name-iv")
  └─ check value  = HKDF-SHA256(…, info = "folder-locker/v2/key-check")  → data\key.check
```

The helper compares `key.check` with the value it derives (in constant
time) before anything else, and answers `wrongKey` if they differ. The
check value is a one-way output of HKDF, so it reveals nothing about the
other keys.

### 2.3 Names

Names are encrypted deterministically, so the helper can find
`\Docs\report.txt` without listing and decrypting whole folders:

```text
siv    = BLAKE2b-192(key = name-IV key, dir iv ‖ name)
stored = base64url(siv ‖ XChaCha20-Poly1305(names key, nonce = siv,
                                            name, aad = dir iv))
```

- **Every folder has its own random `dir.iv`.** The same name in two
  folders looks different, and a stored item moved into another folder no
  longer decrypts.
- **Tampering is detected.** The tag covers the name, and the IV must be
  the one the name derives.
- **Long names.** Windows allows 255 characters per name. A stored name
  longer than 175 characters is kept as `L` + base64url(BLAKE2b-160 of the
  stored name), 28 characters, with the full stored name in a `.name` file
  next to it.
- **Case-insensitive, like Windows.** `Report.txt` and `REPORT.TXT` are the
  same item. Each open folder gets an index of case-folded names, built on
  first use and updated by every change. The case the user typed is kept.
- **Temporary items start with a dot** (`.new-…`, `.old-…`). A stored name
  never does (base64url has no dot), so listings skip them. A new folder is
  built under a temporary name with its `dir.iv` and then renamed, so a
  folder never exists without its IV. A removed folder is renamed away
  first, so it disappears in one step.

### 2.4 Contents

```text
header   "FLF2" | version 1 | 3 zero bytes | file id (24 random bytes)
block i  nonce (24 random bytes) | ciphertext (at most 64 KiB) | tag (16)
         at offset 32 + i · (65536 + 40)
         aad = file id ‖ i (u64, little-endian)
```

- **Every block is encrypted on its own** (XChaCha20-Poly1305), so a
  program can read or change any part of a file without the rest being
  decrypted or rewritten. Each write uses a new random nonce.
- **Blocks are bound to their file and position** through the associated
  data. Swapping, moving or reordering blocks is detected, and so is any
  change to a block.
- **An empty file is empty**: no header.
- **Holes.** A block whose stored bytes are all zero reads as zeros. This is
  how a file grows (for example when a program sets its size first) without
  writing anything, like a sparse file.
- **Times and attributes** (read-only, hidden, system, archive) are those of
  the stored file or folder, so they need no extra metadata.

## 3. From folder to drive and back

The app runs these steps with the same crash journal as `.flk` vaults
([ARCHITECTURE.md §5](ARCHITECTURE.md#5-operations-and-crash-safety)), so
startup recovery finishes or rolls back an interrupted operation.

**Lock** (a folder becomes `Name.flkd`):

1. **Scan** the folder. Links, junctions and invalid names are refused,
   and the free disk space is checked.
2. **Rename** the folder to `Name.<id>.flk-locking`. If a program has a file
   open inside, this fails before anything else happens.
3. **Create** `Name.<id>.flkd-partial\vault.flk` with a new data key and
   the key slots.
4. **Import.** The helper encrypts every file into `data\`, then decrypts
   everything again and compares it with the original, byte for byte.
5. **Rename** the partial folder to `Name.flkd`, then delete the original.

**Open** checks the password in the app, sends the data key to the helper
and mounts the vault. The item shows "Open as V:" and **Lock** closes the
drive. Locking needs no password, because nothing has to be encrypted
again: every change was encrypted as it was written.

A drive with files open in programs (a document in Word, a video that
plays) is never closed by surprise:

- **Lock** in the app asks first ("Close anyway"), because unsaved changes
  in those files would be lost.
- Locking by itself (after the set time, with the app, or **Lock all
  items**) skips it and tries again later, like an unlocked folder with a
  file in use.
- Quitting the app closes every drive, and the exit dialog says so.

A file counts as open while a program has a handle to it for reading or
changing its contents. Handles that only look at names, times or
attributes don't count, and the helper waits up to two seconds for files
that are open only for a moment (a virus scanner, a thumbnail).

**Decrypt to a folder** (in the item's menu) does the reverse: the helper
decrypts the vault into `Name.<id>.flk-restoring`, compares it with the
vault, the folder is renamed into place (`Name (2)` if the name is taken),
and the vault is deleted. The item becomes a normal unlocked folder, which
can be locked again in any way.

## 4. The helper

`folder_locker_drive.exe` lives next to `folder_locker.exe`. For
development, the `FOLDER_LOCKER_DRIVE` environment variable can point to
another build (`native\target\debug\folder_locker_drive.exe`).

- **No window.** Release builds are Windows GUI programs that talk only
  through the pipes the app gives them.
- **Stops with the app.** When its standard input closes, because the app
  quit or crashed, the helper unmounts every drive and exits. No drive
  stays open without the app.
- **Dokany is optional.** `dokan2.dll` is loaded only from `System32`,
  never from the helper's folder, and only when needed. Without Dokany, the
  helper still starts and reports it. Until it finds Dokany, it looks again
  each time it's needed, so Dokany can be installed while the app runs.
- **One user.** Drives are mounted for the current logon session only.
  Other users of the PC don't see them.

### 4.1 Protocol

One JSON object per line (UTF-8) in each direction. Requests carry an `id`
and run at the same time; replies carry the same `id`.

```text
app → helper   {"id": 3, "cmd": "mount", "vault": "C:\\Docs\\Taxes.flkd", "key": "…", "label": "Taxes"}
helper → app   {"id": 3, "ok": true, "result": {"mountPoint": "V:\\", "driveLetter": "V"}}
               {"id": 3, "ok": false, "error": {"code": "wrongKey", "message": "…"}}
```

| `cmd` | Fields | Result |
|---|---|---|
| `hello` | | `version`, `dokany` (`installed`, `outdated`, `version`, `driver`, `reason`). `outdated` means a Dokany older than 2.0.6, which has to be removed before a newer one can be installed. |
| `import` | `vault`, `key`, `source` | `files`, `folders`, `bytes`. Creates `data\` from the folder `source`, then compares the two. |
| `export` | `vault`, `key`, `target` | `files`, `folders`, `bytes`. Decrypts into the new folder `target`, then compares the two. |
| `mount` | `vault`, `key`, `label`, optional `driveLetter`, `readOnly` | `mountPoint`, `driveLetter`. Uses the first free letter from `V` to `Z`, then `U` down to `D`. |
| `unmount` | `vault`, optional `force` | `mountPoint`, `openFiles`. Without `force`, fails with `inUse` while programs have files open on the drive. |
| `cancel` | `target` (the id of an import or export) | `cancelled` |
| `list` | | `mounts`: `vault`, `mountPoint`, `openFiles` for each |

`key` is the vault's 32-byte data key in base64. The app writes it straight
from protected memory into a byte buffer that is wiped after sending; the
helper wipes the line after reading it and the keys when it no longer needs
them. The key only travels through the anonymous pipe between the app and
the helper it started.

**Events** (no reply expected):

| Event | When |
|---|---|
| `{"id": 5, "event": "progress", "phase": "copy", "done": 1048576, "total": 9437184}` | during an import or export, at most every 200 ms; `phase` is `copy`, then `verify` |
| `{"event": "unmounted", "vault": "…", "mountPoint": "V:\\"}` | a drive closed for any reason: locked in the app, ejected in Explorer, or the helper stopping |

**Error codes:**

| Code | Meaning |
|---|---|
| `wrongKey` | the key doesn't belong to this vault |
| `notAVault`, `unsupportedVersion` | not a drive vault, or one from a newer version |
| `corrupt` | stored data was changed or damaged |
| `mismatch` | the check after an import or export found a difference |
| `notFound`, `alreadyExists`, `io` | file-system errors (the message has the details) |
| `unsupported` | the folder holds something a vault can't store (a link or a junction) |
| `cancelled` | the import or export was cancelled |
| `dokanyMissing` | Dokany is not installed |
| `mountFailed`, `noDriveLetter` | the drive could not be created |
| `alreadyMounted`, `notMounted` | the vault is already open, or not open |
| `inUse` | programs have files open on the drive (`unmount` without `force`) |
| `unmountFailed` | Windows did not close the drive in time |
| `badRequest`, `failed` | an invalid request, or an unexpected error |

### 4.2 The drive

The drive looks like an NTFS drive to programs. It supports everything
that everyday programs do:

- reading and writing anywhere in a file, appending, and changing the size;
- creating, renaming, moving and deleting files and folders;
- times, and the read-only, hidden, system and archive attributes.

It doesn't support permissions (ACLs), alternate data streams, links, or
the Recycle Bin.

## 5. Security notes

**Protected, like a `.flk` vault:** a locked drive vault can't be read
without the password or the recovery key, even if someone copies it or
takes the disk out. Any change to a name or to a block of a file is
detected.

**Better than a `.flk` vault:**

- **No plain copies on the disk.** Opening a drive vault decrypts nothing
  to the disk, so there are no deleted originals left to recover later.
  (Only the original folder, at the moment it is first locked, is deleted
  the normal way: the same as for a `.flk` vault.)
- **Opening and locking are instant** once the folder is a drive vault,
  whatever its size, and locking needs no password.

**Please know:**

- **Dokany is needed.** It's free and signed by Microsoft. The installer
  installs it if it's missing, and so does **Install Dokany** in Settings
  (both use the same pinned version, checked by its SHA-256). Without it,
  drive vaults can't be opened, but **Decrypt to a folder** still works:
  that only needs the helper.
- **While the drive is open**, every program running as you can read it,
  like any unlocked folder. Lock it when you're done. Quitting the app (or
  a crash) closes it.
- **Deleting on the drive is permanent.** There is no Recycle Bin.
- **Some things are visible without the password**, as with other
  file-by-file encryption tools (Cryptomator, gocryptfs): the number of
  files and folders and how they're nested, the approximate length of each
  name, the exact size of each file, their times and attributes.
- **Some changes are not detected:**
  - a whole block set to zeros (it reads as a hole), or a file cut exactly
    at a block boundary;
  - a whole file swapped with another file of the same vault, or put back
    to an older version of itself;
  - files or folders deleted from `data\` (they simply disappear from the
    drive).

  Anyone able to do this could also delete the vault. They still can't
  read anything or add content of their own.
- The design uses well-known primitives (XChaCha20-Poly1305, BLAKE2b,
  HKDF-SHA256) from audited Rust crates and libsodium, but it has **not had
  an independent security audit**.

## 6. Tests

| Where | What |
|---|---|
| `native/vault2` (`cargo test`) | keys, names (round trips, long names, tampering, moved names), contents (random reads and writes against a model, holes, sizes at block edges, tampering, reordered blocks), the tree (create, list, rename and move, remove, case-insensitive lookup, a wrong key, leftover temporary items), import, verify, export |
| `native/drive` (`cargo test`) | the protocol, the header, import and export jobs with a wrong key and cancel |
| `native/drive/tests/drive.rs` | end to end on Windows with Dokany (run in CI): import, mount, read and write through the drive with Windows APIs, rename, delete, times, attributes, a second mount refused, a wrong key refused, unmount and mount again, the helper closing everything when the app goes away, and export |
| `test/engine/drive_helper_test.dart` | the app and the real helper together: header and key slots from Dart, the data key over the pipe, import, check and export, a wrong key |
| `test/features/drive_flow_test.dart` | the app's logic with a fake helper: lock, open, lock again, own passwords, recovery key, decrypt to a folder, failed imports, drives closed from outside, restarts, a new master password |
