//! Encrypted file contents.
//!
//! ```text
//! header   "FLF2" | version 1 | 3 zero bytes | file id (24 random bytes)
//! block i  nonce (24 random bytes) | ciphertext (at most B bytes) | tag (16)
//!          at offset 32 + i · (B + 40), with file id ‖ i (u64 LE) as
//!          associated data
//! ```
//!
//! Every block is encrypted on its own, so any part of a file can be read or
//! changed without touching the rest. Blocks are bound to their file and
//! position, so they can't be swapped or moved without the change being
//! detected.
//!
//! An empty file has no header at all. A block whose stored bytes are all
//! zero is a *hole* and reads as zeros, so a file grows (`set_len`) without
//! writing anything, like a sparse file. The price is that zeroing a whole
//! block, or cutting a file at a block boundary, is not detected (the same
//! trade-off as gocryptfs).

use std::fs::{File, Metadata, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError, RwLock, RwLockReadGuard, RwLockWriteGuard};

use chacha20poly1305::aead::{AeadInPlace, KeyInit};
use chacha20poly1305::{Key, Tag, XChaCha20Poly1305, XNonce};
use rand_core::{OsRng, RngCore};

use crate::error::{Error, Result};
use crate::keys::VaultKeys;

/// Length of the header of a non-empty file.
pub const HEADER_LEN: u64 = 32;

/// What a stored block needs on top of its plaintext (nonce and tag).
pub const BLOCK_OVERHEAD: usize = NONCE_LEN + TAG_LEN;

/// Smallest and largest block sizes a vault may use.
pub const MIN_BLOCK_SIZE: usize = 4096;
pub const MAX_BLOCK_SIZE: usize = 1 << 20;

/// Block size of new vaults.
pub const DEFAULT_BLOCK_SIZE: usize = 64 * 1024;

const MAGIC: &[u8; 4] = b"FLF2";
const VERSION: u8 = 1;
const FILE_ID_LEN: usize = 24;
const NONCE_LEN: usize = 24;
const TAG_LEN: usize = 16;

type FileId = [u8; FILE_ID_LEN];

/// Encrypts and decrypts the blocks of one vault.
pub struct Codec {
    cipher: XChaCha20Poly1305,
    block_size: usize,
}

impl Codec {
    pub fn new(keys: &VaultKeys, block_size: usize) -> Result<Self> {
        if !(MIN_BLOCK_SIZE..=MAX_BLOCK_SIZE).contains(&block_size) {
            return Err(Error::corrupt(format!(
                "unsupported block size {block_size}"
            )));
        }
        Ok(Self {
            cipher: XChaCha20Poly1305::new(Key::from_slice(&keys.content)),
            block_size,
        })
    }

    pub fn block_size(&self) -> usize {
        self.block_size
    }

    /// The plaintext length of a stored file of `stored_len` bytes.
    ///
    /// Stray bytes after the last block (too few to hold one) are ignored.
    pub fn plain_len(&self, stored_len: u64) -> u64 {
        if stored_len <= HEADER_LEN {
            return 0;
        }
        let body = stored_len - HEADER_LEN;
        let stored_block = self.stored_block();
        let full = body / stored_block;
        let rest = body % stored_block;
        full * self.block_size as u64 + rest.saturating_sub(BLOCK_OVERHEAD as u64)
    }

    /// The stored length of a file with `plain_len` bytes of plaintext.
    pub fn stored_len(&self, plain_len: u64) -> u64 {
        if plain_len == 0 {
            return 0;
        }
        let block = self.block_size as u64;
        let rest = plain_len % block;
        HEADER_LEN
            + plain_len / block * self.stored_block()
            + if rest > 0 {
                rest + BLOCK_OVERHEAD as u64
            } else {
                0
            }
    }

    fn stored_block(&self) -> u64 {
        (self.block_size + BLOCK_OVERHEAD) as u64
    }

    fn block_offset(&self, index: u64) -> u64 {
        HEADER_LEN + index * self.stored_block()
    }

    /// Encrypts one block into `out`, which is `plain.len() + 40` bytes.
    fn seal(&self, id: &FileId, index: u64, plain: &[u8], out: &mut [u8]) -> Result<()> {
        debug_assert_eq!(out.len(), plain.len() + BLOCK_OVERHEAD);
        let (nonce, rest) = out.split_at_mut(NONCE_LEN);
        OsRng.fill_bytes(nonce);
        let (body, tag) = rest.split_at_mut(plain.len());
        body.copy_from_slice(plain);
        let sealed = self
            .cipher
            .encrypt_in_place_detached(XNonce::from_slice(nonce), &aad(id, index), body)
            .map_err(|_| Error::corrupt("could not encrypt a block"))?;
        tag.copy_from_slice(&sealed);
        Ok(())
    }

    /// Decrypts one stored block into `out`, which is 40 bytes shorter.
    fn open(&self, id: &FileId, index: u64, stored: &[u8], out: &mut [u8]) -> Result<()> {
        if stored.len() <= BLOCK_OVERHEAD || out.len() != stored.len() - BLOCK_OVERHEAD {
            return Err(Error::corrupt("a file has a damaged block"));
        }
        let (nonce, rest) = stored.split_at(NONCE_LEN);
        let (body, tag) = rest.split_at(rest.len() - TAG_LEN);
        // A random nonce is never all zeros, so this is a hole.
        if is_zero(nonce) && is_zero(stored) {
            out.fill(0);
            return Ok(());
        }
        out.copy_from_slice(body);
        self.cipher
            .decrypt_in_place_detached(
                XNonce::from_slice(nonce),
                &aad(id, index),
                out,
                Tag::from_slice(tag),
            )
            .map_err(|_| {
                out.fill(0);
                Error::corrupt("a file was changed or damaged")
            })
    }
}

fn aad(id: &FileId, index: u64) -> [u8; FILE_ID_LEN + 8] {
    let mut aad = [0; FILE_ID_LEN + 8];
    aad[..FILE_ID_LEN].copy_from_slice(id);
    aad[FILE_ID_LEN..].copy_from_slice(&index.to_le_bytes());
    aad
}

fn is_zero(bytes: &[u8]) -> bool {
    bytes.iter().all(|&b| b == 0)
}

/// An open encrypted file.
///
/// All handles to the same file must share one instance (see
/// [`crate::Vault::open_file`]): it orders reads and changes, and keeps the
/// header and length in memory.
pub struct ContentFile {
    codec: Arc<Codec>,
    path: Mutex<PathBuf>,
    state: RwLock<State>,
}

struct State {
    file: File,
    writable: bool,
    /// `None` while the file is empty (it has no header then).
    id: Option<FileId>,
    stored_len: u64,
}

impl ContentFile {
    /// Opens the stored file at `path`, for writing if it isn't read-only.
    ///
    /// If it can't be opened for writing (it is read-only, or another
    /// program holds it), it is opened for reading, and opened again for
    /// writing on the first change.
    pub fn open(codec: Arc<Codec>, path: &Path) -> Result<Self> {
        let (file, writable) = match OpenOptions::new().read(true).write(true).open(path) {
            Ok(file) => (file, true),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Err(Error::NotFound);
            }
            Err(error) => match File::open(path) {
                Ok(file) => (file, false),
                Err(_) => return Err(Error::from_io(error)),
            },
        };
        Self::from_file(codec, path, file, writable)
    }

    /// Creates a new, empty file at `path`. Fails if something is there.
    pub fn create(codec: Arc<Codec>, path: &Path) -> Result<Self> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(path)
            .map_err(Error::from_io)?;
        Self::from_file(codec, path, file, true)
    }

    fn from_file(codec: Arc<Codec>, path: &Path, file: File, writable: bool) -> Result<Self> {
        let stored_len = file.metadata()?.len();
        // Shorter than a header: a write was cut off before any data.
        let id = if stored_len < HEADER_LEN {
            None
        } else {
            let mut header = [0; HEADER_LEN as usize];
            read_exact_at(&file, &mut header, 0)?;
            if &header[..4] != MAGIC {
                return Err(Error::corrupt("a file has a damaged header"));
            }
            if header[4] != VERSION {
                return Err(Error::corrupt(
                    "a file was written by a newer version of Cloak",
                ));
            }
            Some(header[8..].try_into().expect("24 bytes"))
        };
        Ok(Self {
            codec,
            path: Mutex::new(path.to_owned()),
            state: RwLock::new(State {
                file,
                writable,
                id,
                stored_len,
            }),
        })
    }

    /// The length of the plaintext.
    pub fn len(&self) -> u64 {
        self.codec.plain_len(self.read_state().stored_len)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Where the file is stored now.
    pub fn path(&self) -> PathBuf {
        self.path
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    pub(crate) fn set_path(&self, path: PathBuf) {
        *self.path.lock().unwrap_or_else(PoisonError::into_inner) = path;
    }

    /// Metadata of the stored file (times and attributes; not the length).
    pub fn metadata(&self) -> Result<Metadata> {
        Ok(self.read_state().file.metadata()?)
    }

    /// Runs `action` with the stored file, for example to read its
    /// attributes.
    pub fn with_file<R>(&self, action: impl FnOnce(&File) -> R) -> R {
        action(&self.read_state().file)
    }

    /// Runs `action` with the stored file opened for writing if possible
    /// (not while it is read-only), for example to change its times.
    ///
    /// Times must be changed through this handle: a handle that wrote data
    /// sets the modification time again when it closes, unless the time
    /// was set through that same handle.
    pub fn with_writable_file<R>(&self, action: impl FnOnce(&File) -> R) -> R {
        let mut state = self.write_state();
        // Read-only files can't be opened for writing; use the read handle.
        let _ = self.make_writable(&mut state);
        action(&state.file)
    }

    /// Reads up to `buf.len()` bytes at `offset`. Returns how many were read
    /// (fewer only at the end of the file).
    pub fn read_at(&self, offset: u64, buf: &mut [u8]) -> Result<usize> {
        let state = self.read_state();
        let size = self.codec.plain_len(state.stored_len);
        if buf.is_empty() || offset >= size {
            return Ok(0);
        }
        let id = state
            .id
            .ok_or_else(|| Error::corrupt("a file has no header"))?;
        let end = size.min(offset.saturating_add(buf.len() as u64));
        let block = self.codec.block_size as u64;
        let first = offset / block;
        let last = (end - 1) / block;

        let start = self.codec.block_offset(first);
        let stop = state.stored_len.min(self.codec.block_offset(last + 1));
        let mut stored = vec![0; (stop - start) as usize];
        read_exact_at(&state.file, &mut stored, start)?;

        let mut plain = vec![0; self.codec.block_size];
        let mut done = 0;
        for (i, chunk) in stored
            .chunks(self.codec.stored_block() as usize)
            .enumerate()
        {
            let index = first + i as u64;
            let block_start = index * block;
            let len = chunk.len().saturating_sub(BLOCK_OVERHEAD);
            let from = (offset.max(block_start) - block_start) as usize;
            let to = (end.min(block_start + len as u64) - block_start) as usize;
            if from == 0 && to == len {
                // The whole block is wanted: decrypt straight into `buf`.
                self.codec
                    .open(&id, index, chunk, &mut buf[done..done + len])?;
            } else {
                self.codec.open(&id, index, chunk, &mut plain[..len])?;
                buf[done..done + to - from].copy_from_slice(&plain[from..to]);
            }
            done += to - from;
        }
        Ok(done)
    }

    /// Writes `data` at `offset`, growing the file if needed. A gap after
    /// the old end reads as zeros.
    pub fn write_at(&self, offset: u64, data: &[u8]) -> Result<usize> {
        let mut state = self.write_state();
        self.write_locked(&mut state, offset, data)
    }

    /// Writes `data` at the end of the file.
    pub fn append(&self, data: &[u8]) -> Result<usize> {
        let mut state = self.write_state();
        let end = self.codec.plain_len(state.stored_len);
        self.write_locked(&mut state, end, data)
    }

    /// Writes only the part of `data` that fits before the end of the file,
    /// like paging I/O, which never grows a file.
    pub fn write_within(&self, offset: u64, data: &[u8]) -> Result<usize> {
        let mut state = self.write_state();
        let len = self.codec.plain_len(state.stored_len);
        if offset >= len {
            return Ok(0);
        }
        let fits = data
            .len()
            .min((len - offset).min(usize::MAX as u64) as usize);
        self.write_locked(&mut state, offset, &data[..fits])
    }

    fn write_locked(&self, state: &mut State, offset: u64, data: &[u8]) -> Result<usize> {
        if data.is_empty() {
            return Ok(0);
        }
        let end = offset
            .checked_add(data.len() as u64)
            .filter(|&end| end <= i64::MAX as u64)
            .ok_or_else(too_large)?;
        self.make_writable(state)?;
        if offset > self.codec.plain_len(state.stored_len) {
            self.grow(state, offset)?;
        }
        let id = self.ensure_header(state)?;
        let size = self.codec.plain_len(state.stored_len);
        let block = self.codec.block_size as u64;
        let first = offset / block;
        let last = (end - 1) / block;

        let mut out = Vec::with_capacity(((last - first + 1) * self.codec.stored_block()) as usize);
        let mut plain = vec![0; self.codec.block_size];
        let mut old = vec![0; self.codec.stored_block() as usize];
        for index in first..=last {
            let block_start = index * block;
            let old_len = size.saturating_sub(block_start).min(block) as usize;
            let from = (offset.max(block_start) - block_start) as usize;
            let to = (end.min(block_start + block) - block_start) as usize;
            let new_len = old_len.max(to);
            // `from <= old_len` always holds: the file was grown to `offset`.
            if from > 0 || to < old_len {
                let old = &mut old[..old_len + BLOCK_OVERHEAD];
                read_exact_at(&state.file, old, self.codec.block_offset(index))?;
                self.codec.open(&id, index, old, &mut plain[..old_len])?;
            }
            let source = (block_start + from as u64 - offset) as usize;
            plain[from..to].copy_from_slice(&data[source..source + to - from]);
            let at = out.len();
            out.resize(at + new_len + BLOCK_OVERHEAD, 0);
            self.codec
                .seal(&id, index, &plain[..new_len], &mut out[at..])?;
        }
        let position = self.codec.block_offset(first);
        write_all_at(&state.file, &out, position)?;
        state.stored_len = state.stored_len.max(position + out.len() as u64);
        Ok(data.len())
    }

    /// Cuts or grows the file to `len` bytes. New bytes read as zeros.
    pub fn set_len(&self, len: u64) -> Result<()> {
        if len > i64::MAX as u64 {
            return Err(too_large());
        }
        let mut state = self.write_state();
        let size = self.codec.plain_len(state.stored_len);
        if len == size {
            return Ok(());
        }
        self.make_writable(&mut state)?;
        if len > size {
            return self.grow(&mut state, len);
        }
        if len == 0 {
            state.file.set_len(0)?;
            state.stored_len = 0;
            state.id = None;
            return Ok(());
        }
        let id = state
            .id
            .ok_or_else(|| Error::corrupt("a file has no header"))?;
        let block = self.codec.block_size as u64;
        let keep = (len % block) as usize;
        if keep > 0 {
            // The new last block gets shorter, so it is encrypted again.
            let index = len / block;
            let old_len = (size - index * block).min(block) as usize;
            let mut old = vec![0; old_len + BLOCK_OVERHEAD];
            read_exact_at(&state.file, &mut old, self.codec.block_offset(index))?;
            let mut plain = vec![0; old_len];
            self.codec.open(&id, index, &old, &mut plain)?;
            let mut sealed = vec![0; keep + BLOCK_OVERHEAD];
            self.codec.seal(&id, index, &plain[..keep], &mut sealed)?;
            write_all_at(&state.file, &sealed, self.codec.block_offset(index))?;
        }
        let stored_len = self.codec.stored_len(len);
        state.file.set_len(stored_len)?;
        state.stored_len = stored_len;
        Ok(())
    }

    /// Makes sure everything written so far is on the disk.
    pub fn sync(&self) -> Result<()> {
        let state = self.read_state();
        if state.writable {
            state.file.sync_data()?;
        }
        Ok(())
    }

    /// Grows the file to `len` bytes of plaintext: pads its last block with
    /// zeros, and leaves holes after it.
    fn grow(&self, state: &mut State, len: u64) -> Result<()> {
        let id = self.ensure_header(state)?;
        let size = self.codec.plain_len(state.stored_len);
        let block = self.codec.block_size as u64;
        let partial = (size % block) as usize;
        if partial > 0 {
            let index = size / block;
            let grown = (len - index * block).min(block) as usize;
            let mut old = vec![0; partial + BLOCK_OVERHEAD];
            read_exact_at(&state.file, &mut old, self.codec.block_offset(index))?;
            let mut plain = vec![0; grown];
            self.codec.open(&id, index, &old, &mut plain[..partial])?;
            let mut sealed = vec![0; grown + BLOCK_OVERHEAD];
            self.codec.seal(&id, index, &plain, &mut sealed)?;
            write_all_at(&state.file, &sealed, self.codec.block_offset(index))?;
        } else {
            // Drop stray bytes after the last block, so the new holes are
            // all zeros.
            let exact = HEADER_LEN.max(self.codec.stored_len(size));
            if state.stored_len != exact {
                state.file.set_len(exact)?;
            }
        }
        let stored_len = self.codec.stored_len(len);
        state.file.set_len(stored_len)?;
        state.stored_len = stored_len;
        Ok(())
    }

    fn ensure_header(&self, state: &mut State) -> Result<FileId> {
        if let Some(id) = state.id {
            return Ok(id);
        }
        let mut id = [0; FILE_ID_LEN];
        OsRng.fill_bytes(&mut id);
        let mut header = [0; HEADER_LEN as usize];
        header[..4].copy_from_slice(MAGIC);
        header[4] = VERSION;
        header[8..].copy_from_slice(&id);
        write_all_at(&state.file, &header, 0)?;
        state.id = Some(id);
        state.stored_len = state.stored_len.max(HEADER_LEN);
        Ok(id)
    }

    /// Opens the stored file again for writing if it was opened read-only
    /// (it was read-only then, and may not be anymore).
    fn make_writable(&self, state: &mut State) -> Result<()> {
        if !state.writable {
            state.file = OpenOptions::new()
                .read(true)
                .write(true)
                .open(self.path())
                .map_err(Error::from_io)?;
            state.writable = true;
        }
        Ok(())
    }

    fn read_state(&self) -> RwLockReadGuard<'_, State> {
        self.state.read().unwrap_or_else(PoisonError::into_inner)
    }

    fn write_state(&self) -> RwLockWriteGuard<'_, State> {
        self.state.write().unwrap_or_else(PoisonError::into_inner)
    }
}

fn too_large() -> Error {
    Error::Io(io::Error::new(
        io::ErrorKind::InvalidInput,
        "the file would be too large",
    ))
}

#[cfg(unix)]
fn read_exact_at(file: &File, buf: &mut [u8], offset: u64) -> io::Result<()> {
    std::os::unix::fs::FileExt::read_exact_at(file, buf, offset)
}

#[cfg(unix)]
fn write_all_at(file: &File, buf: &[u8], offset: u64) -> io::Result<()> {
    std::os::unix::fs::FileExt::write_all_at(file, buf, offset)
}

#[cfg(windows)]
fn read_exact_at(file: &File, mut buf: &mut [u8], mut offset: u64) -> io::Result<()> {
    use std::os::windows::fs::FileExt;
    while !buf.is_empty() {
        match file.seek_read(buf, offset) {
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(n) => {
                buf = &mut buf[n..];
                offset += n as u64;
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

#[cfg(windows)]
fn write_all_at(file: &File, mut buf: &[u8], mut offset: u64) -> io::Result<()> {
    use std::os::windows::fs::FileExt;
    while !buf.is_empty() {
        match file.seek_write(buf, offset) {
            Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
            Ok(n) => {
                buf = &buf[n..];
                offset += n as u64;
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const BLOCK: usize = MIN_BLOCK_SIZE;

    fn codec() -> Arc<Codec> {
        Arc::new(Codec::new(&VaultKeys::derive(&[9; 32], b"vault"), BLOCK).unwrap())
    }

    /// A small deterministic generator, so failures can be reproduced.
    struct Rng(u64);

    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            self.0
        }

        fn below(&mut self, limit: u64) -> u64 {
            self.next() % limit
        }

        fn bytes(&mut self, len: usize) -> Vec<u8> {
            (0..len).map(|_| self.next() as u8).collect()
        }
    }

    fn read_all(file: &ContentFile) -> Vec<u8> {
        let mut buf = vec![0; file.len() as usize];
        assert_eq!(file.read_at(0, &mut buf).unwrap(), buf.len());
        buf
    }

    #[test]
    fn lengths_match_the_layout() {
        let codec = codec();
        let block = BLOCK as u64;
        for plain in [0, 1, block - 1, block, block + 1, 5 * block, 5 * block + 7] {
            let stored = codec.stored_len(plain);
            assert_eq!(codec.plain_len(stored), plain, "{plain}");
        }
        assert_eq!(codec.stored_len(1), HEADER_LEN + 41);
        // Stray bytes too short for a block are ignored.
        assert_eq!(codec.plain_len(codec.stored_len(block) + 40), block);
    }

    #[test]
    fn round_trips_any_size() {
        let dir = tempfile::tempdir().unwrap();
        let mut rng = Rng(1);
        for (i, len) in [0, 1, 100, BLOCK - 1, BLOCK, BLOCK + 1, 3 * BLOCK + 17]
            .into_iter()
            .enumerate()
        {
            let path = dir.path().join(format!("f{i}"));
            let data = rng.bytes(len);
            let file = ContentFile::create(codec(), &path).unwrap();
            file.write_at(0, &data).unwrap();
            assert_eq!(file.len(), len as u64);
            drop(file);

            let stored = std::fs::read(&path).unwrap();
            assert_eq!(stored.len() as u64, codec().stored_len(len as u64));
            if len >= 16 {
                // The plaintext doesn't show in the stored bytes.
                assert!(!stored.windows(16).any(|w| w == &data[..16]));
            }
            let file = ContentFile::open(codec(), &path).unwrap();
            assert_eq!(read_all(&file), data);
        }
    }

    #[test]
    fn random_changes_match_a_plain_model() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("model");
        let mut file = ContentFile::create(codec(), &path).unwrap();
        let mut model: Vec<u8> = Vec::new();
        let mut rng = Rng(0x5eed);
        for step in 0..600 {
            match rng.below(10) {
                0..=4 => {
                    let offset = rng.below(6 * BLOCK as u64);
                    let len = rng.below(3 * BLOCK as u64) as usize + 1;
                    let data = rng.bytes(len);
                    file.write_at(offset, &data).unwrap();
                    let end = offset as usize + data.len();
                    if model.len() < end {
                        model.resize(end, 0);
                    }
                    model[offset as usize..end].copy_from_slice(&data);
                }
                5 | 6 => {
                    let len = rng.below(7 * BLOCK as u64);
                    file.set_len(len).unwrap();
                    model.resize(len as usize, 0);
                }
                7 => {
                    // Reopen: everything must come from the disk.
                    drop(file);
                    file = ContentFile::open(codec(), &path).unwrap();
                }
                _ => {
                    let offset = rng.below(model.len() as u64 + 10);
                    let mut buf = vec![0; rng.below(2 * BLOCK as u64) as usize + 1];
                    let n = file.read_at(offset, &mut buf).unwrap();
                    let start = (offset as usize).min(model.len());
                    let expected = &model[start..(start + buf.len()).min(model.len())];
                    assert_eq!(&buf[..n], expected, "step {step}");
                }
            }
            assert_eq!(file.len(), model.len() as u64, "step {step}");
            assert_eq!(
                std::fs::metadata(&path).unwrap().len(),
                codec().stored_len(model.len() as u64),
                "step {step}"
            );
        }
        assert_eq!(read_all(&file), model);
    }

    #[test]
    fn appends_and_writes_within_the_length() {
        let dir = tempfile::tempdir().unwrap();
        let file = ContentFile::create(codec(), &dir.path().join("file")).unwrap();
        file.append(b"abc").unwrap();
        file.append(b"def").unwrap();
        assert_eq!(file.write_within(4, b"XYZW").unwrap(), 2);
        assert_eq!(file.write_within(6, b"no").unwrap(), 0);
        assert_eq!(read_all(&file), b"abcdXY");
    }

    #[test]
    fn grows_with_holes_and_empties_without_a_header() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sparse");
        let file = ContentFile::create(codec(), &path).unwrap();
        file.set_len(10 * BLOCK as u64 + 5).unwrap();
        assert_eq!(read_all(&file), vec![0; 10 * BLOCK + 5]);
        file.write_at(3 * BLOCK as u64 + 1, b"abc").unwrap();
        let data = read_all(&file);
        assert_eq!(&data[3 * BLOCK + 1..3 * BLOCK + 4], b"abc");
        assert!(data.iter().filter(|&&b| b != 0).count() == 3);

        file.set_len(0).unwrap();
        assert_eq!(std::fs::metadata(&path).unwrap().len(), 0);
        file.write_at(0, b"new").unwrap();
        assert_eq!(read_all(&file), b"new");
    }

    #[test]
    fn detects_changed_blocks() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("file");
        let data = Rng(7).bytes(3 * BLOCK);
        ContentFile::create(codec(), &path)
            .unwrap()
            .write_at(0, &data)
            .unwrap();
        let original = std::fs::read(&path).unwrap();
        let stored_block = BLOCK + BLOCK_OVERHEAD;
        let at = |i: usize| HEADER_LEN as usize + i * stored_block;

        let expect_corrupt = |bytes: Vec<u8>| {
            std::fs::write(&path, bytes).unwrap();
            let file = ContentFile::open(codec(), &path).unwrap();
            let mut buf = vec![0; 3 * BLOCK];
            assert!(matches!(file.read_at(0, &mut buf), Err(Error::Corrupt(_))));
        };

        let mut flipped = original.clone();
        flipped[at(1) + 100] ^= 1;
        expect_corrupt(flipped);

        let mut swapped = original.clone();
        swapped[at(0)..at(1)].copy_from_slice(&original[at(1)..at(2)]);
        swapped[at(1)..at(2)].copy_from_slice(&original[at(0)..at(1)]);
        expect_corrupt(swapped);

        // A block from another file with the same key doesn't fit either.
        let other = dir.path().join("other");
        ContentFile::create(codec(), &other)
            .unwrap()
            .write_at(0, &data)
            .unwrap();
        let mut mixed = original.clone();
        mixed[at(2)..].copy_from_slice(&std::fs::read(&other).unwrap()[at(2)..]);
        expect_corrupt(mixed);

        // Another key can't read it at all.
        std::fs::write(&path, &original).unwrap();
        let wrong = Arc::new(Codec::new(&VaultKeys::derive(&[8; 32], b"vault"), BLOCK).unwrap());
        let file = ContentFile::open(wrong, &path).unwrap();
        assert!(file.read_at(0, &mut [0; 10]).is_err());
    }

    #[test]
    fn rejects_damaged_headers_but_accepts_cut_off_ones() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("file");
        std::fs::write(&path, [0x42; 64]).unwrap();
        assert!(matches!(
            ContentFile::open(codec(), &path),
            Err(Error::Corrupt(_))
        ));

        std::fs::write(&path, b"FLF2").unwrap();
        let file = ContentFile::open(codec(), &path).unwrap();
        assert_eq!(file.len(), 0);
        file.write_at(0, b"fine").unwrap();
        assert_eq!(read_all(&file), b"fine");
    }

    #[test]
    fn writes_to_read_only_files_after_they_become_writable() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("file");
        ContentFile::create(codec(), &path)
            .unwrap()
            .write_at(0, b"one")
            .unwrap();
        let mut permissions = std::fs::metadata(&path).unwrap().permissions();
        permissions.set_readonly(true);
        std::fs::set_permissions(&path, permissions.clone()).unwrap();
        let file = ContentFile::open(codec(), &path).unwrap();
        assert_eq!(read_all(&file), b"one");

        #[allow(clippy::permissions_set_readonly_false)]
        permissions.set_readonly(false);
        std::fs::set_permissions(&path, permissions).unwrap();
        file.write_at(3, b"two").unwrap();
        assert_eq!(read_all(&file), b"onetwo");
    }
}
