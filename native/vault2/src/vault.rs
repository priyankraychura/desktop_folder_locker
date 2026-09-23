//! The encrypted folder tree of a drive vault.
//!
//! Every file and folder of the vault is stored as a file or folder with an
//! encrypted name (see [`crate::names`]), in the same hierarchy. Each stored
//! folder holds a random `dir.iv` for the names inside it.
//!
//! Paths are the plaintext paths seen on the drive, like `\Photos\cat.jpg`
//! (`/` works too). Names are case-insensitive like on Windows: each folder
//! gets an index from case-folded names to items, built when it's first
//! needed and kept up to date by every change made through the vault.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};

use rand_core::{OsRng, RngCore};

use crate::content::{Codec, ContentFile};
use crate::error::{Error, Result};
use crate::keys::VaultKeys;
use crate::names::{
    check_name, decrypt_name, encrypt_name, entry_name, fold, is_internal_entry, is_long_entry,
    sidecar_name, DirIv, DIR_IV_FILE, DIR_IV_LEN, KEY_CHECK_FILE,
};

/// Starts the names of temporary stored items. Stored names never start
/// with it, so listings skip them.
const TEMP_PREFIX: char = '.';

/// An open drive vault.
pub struct Vault {
    data: PathBuf,
    keys: VaultKeys,
    codec: Arc<Codec>,
    /// Stored folder path → its IV and name index.
    dirs: Mutex<HashMap<PathBuf, Arc<DirState>>>,
    /// Stored file path → the file, while it is open.
    files: Mutex<HashMap<PathBuf, Weak<ContentFile>>>,
    /// Held while items are created, removed or renamed.
    changes: Mutex<()>,
}

struct DirState {
    iv: DirIv,
    /// Case-folded name → entry; `None` until first needed.
    index: Mutex<Option<HashMap<String, Entry>>>,
}

#[derive(Clone, Debug)]
struct Entry {
    name: String,
    stored: String,
    is_dir: bool,
}

/// A file or folder of the vault.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Item {
    /// Where the item is stored.
    pub stored_path: PathBuf,
    /// Its name, as it was created ("" for the top folder).
    pub name: String,
    pub is_dir: bool,
}

/// One item of a folder listing.
#[derive(Debug)]
pub struct Listing {
    pub name: String,
    pub is_dir: bool,
    /// Length of the plaintext (0 for folders).
    pub len: u64,
    /// Metadata of the stored item: its times and attributes.
    pub metadata: fs::Metadata,
}

impl Vault {
    /// Creates the data folder of a new vault at `data`, which must not
    /// exist yet.
    pub fn create(data: &Path, keys: VaultKeys, block_size: usize) -> Result<Self> {
        fs::create_dir(data).map_err(Error::from_io)?;
        fs::write(data.join(DIR_IV_FILE), random_iv())?;
        fs::write(data.join(KEY_CHECK_FILE), keys.check)?;
        Self::open(data, keys, block_size)
    }

    /// Opens the vault with the data folder `data`. Fails with
    /// [`Error::WrongKey`] if the keys don't belong to it.
    pub fn open(data: &Path, keys: VaultKeys, block_size: usize) -> Result<Self> {
        match fs::read(data.join(KEY_CHECK_FILE)) {
            Ok(check) if constant_time_eq(&check, &keys.check) => {}
            Ok(_) => return Err(Error::WrongKey),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Err(Error::corrupt("the vault's data folder is incomplete"));
            }
            Err(error) => return Err(error.into()),
        }
        let vault = Self {
            codec: Arc::new(Codec::new(&keys, block_size)?),
            data: data.to_owned(),
            keys,
            dirs: Mutex::default(),
            files: Mutex::default(),
            changes: Mutex::default(),
        };
        match vault.dir(data) {
            Err(Error::NotFound) => Err(Error::corrupt("the vault's data folder is missing")),
            other => other.map(|_| vault),
        }
    }

    pub fn data_dir(&self) -> &Path {
        &self.data
    }

    pub fn block_size(&self) -> usize {
        self.codec.block_size()
    }

    /// The top folder.
    pub fn root(&self) -> Item {
        Item {
            stored_path: self.data.clone(),
            name: String::new(),
            is_dir: true,
        }
    }

    /// Finds the item at `path`. Returns `None` if it doesn't exist, and
    /// [`Error::NotFound`] or [`Error::NotADirectory`] if a folder on the
    /// way is missing.
    pub fn lookup(&self, path: &str) -> Result<Option<Item>> {
        self.lookup_parts(&components(path)?)
    }

    /// Opens a file. Handles to the same file share the returned object.
    pub fn open_file(&self, item: &Item) -> Result<Arc<ContentFile>> {
        if item.is_dir {
            return Err(Error::IsADirectory);
        }
        let mut files = lock(&self.files);
        if let Some(file) = files.get(&item.stored_path).and_then(Weak::upgrade) {
            return Ok(file);
        }
        let file = Arc::new(ContentFile::open(self.codec.clone(), &item.stored_path)?);
        remember(&mut files, &item.stored_path, &file);
        Ok(file)
    }

    /// The length of a file's plaintext (0 for folders).
    pub fn file_len(&self, item: &Item) -> Result<u64> {
        if item.is_dir {
            return Ok(0);
        }
        if let Some(file) = self.open_file_at(&item.stored_path) {
            return Ok(file.len());
        }
        let stored = fs::metadata(&item.stored_path).map_err(Error::from_io)?;
        Ok(self.codec.plain_len(stored.len()))
    }

    /// Creates an empty file. Fails if an item with that name exists.
    pub fn create_file(&self, path: &str) -> Result<(Item, Arc<ContentFile>)> {
        let parts = components(path)?;
        let (name, parents) = parts.split_last().ok_or(Error::AlreadyExists)?;
        let _changes = lock(&self.changes);
        let (parent, dir) = self.parent(parents)?;
        if self.find(&parent, &dir, name)?.is_some() {
            return Err(Error::AlreadyExists);
        }
        let (stored, stored_path) = self.prepare_name(&parent, &dir, name)?;
        let file = Arc::new(ContentFile::create(self.codec.clone(), &stored_path)?);
        remember(&mut lock(&self.files), &stored_path, &file);
        index_insert(&dir, name, &stored, false);
        Ok((
            Item {
                stored_path,
                name: (*name).to_owned(),
                is_dir: false,
            },
            file,
        ))
    }

    /// Creates an empty folder. Fails if an item with that name exists.
    pub fn create_dir(&self, path: &str) -> Result<Item> {
        let parts = components(path)?;
        let (name, parents) = parts.split_last().ok_or(Error::AlreadyExists)?;
        let _changes = lock(&self.changes);
        let (parent, dir) = self.parent(parents)?;
        if self.find(&parent, &dir, name)?.is_some() {
            return Err(Error::AlreadyExists);
        }
        let (stored, stored_path) = self.prepare_name(&parent, &dir, name)?;
        if fs::symlink_metadata(&stored_path).is_ok() {
            return Err(Error::AlreadyExists);
        }
        // Built under a temporary name, so the folder never exists without
        // its IV.
        let iv = random_iv();
        let temp = parent.join(temp_name("new"));
        fs::create_dir(&temp)?;
        let built =
            fs::write(temp.join(DIR_IV_FILE), iv).and_then(|()| fs::rename(&temp, &stored_path));
        if let Err(error) = built {
            let _ = fs::remove_dir_all(&temp);
            return Err(Error::from_io(error));
        }
        lock(&self.dirs).insert(
            stored_path.clone(),
            Arc::new(DirState {
                iv,
                index: Mutex::new(Some(HashMap::new())),
            }),
        );
        index_insert(&dir, name, &stored, true);
        Ok(Item {
            stored_path,
            name: (*name).to_owned(),
            is_dir: true,
        })
    }

    /// Removes a file or an empty folder. Open handles to a removed file
    /// keep working.
    pub fn remove(&self, path: &str) -> Result<()> {
        let parts = components(path)?;
        let (name, parents) = parts.split_last().ok_or(Error::NotAllowed)?;
        let _changes = lock(&self.changes);
        let (parent, dir) = self.parent(parents)?;
        let entry = self.find(&parent, &dir, name)?.ok_or(Error::NotFound)?;
        let stored_path = parent.join(&entry.stored);
        if entry.is_dir {
            if !self.is_empty_dir_at(&stored_path)? {
                return Err(Error::DirectoryNotEmpty);
            }
            // Moved out of the way first, so it disappears in one step.
            let temp = parent.join(temp_name("old"));
            fs::rename(&stored_path, &temp).map_err(Error::from_io)?;
            let _ = fs::remove_dir_all(&temp);
            forget(&mut lock(&self.dirs), &stored_path);
        } else {
            fs::remove_file(&stored_path).map_err(Error::from_io)?;
            lock(&self.files).remove(&stored_path);
        }
        if is_long_entry(&entry.stored) {
            let _ = fs::remove_file(parent.join(sidecar_name(&entry.stored)));
        }
        index_remove(&dir, name);
        Ok(())
    }

    /// Renames or moves an item. With `replace`, an existing file at `to`
    /// is replaced; folders are never replaced.
    pub fn rename(&self, from: &str, to: &str, replace: bool) -> Result<Item> {
        let from_parts = components(from)?;
        let to_parts = components(to)?;
        let (Some((from_name, from_parents)), Some((to_name, to_parents))) =
            (from_parts.split_last(), to_parts.split_last())
        else {
            return Err(Error::NotAllowed);
        };
        let _changes = lock(&self.changes);
        let (from_parent, from_dir) = self.parent(from_parents)?;
        let source = self
            .find(&from_parent, &from_dir, from_name)?
            .ok_or(Error::NotFound)?;
        let source_path = from_parent.join(&source.stored);
        let (to_parent, to_dir) = self.parent(to_parents)?;
        if source.is_dir && to_parent.starts_with(&source_path) {
            // A folder can't move into itself.
            return Err(Error::NotAllowed);
        }
        let encoded = encrypt_name(&self.keys, &to_dir.iv, to_name)?;
        let stored = entry_name(&encoded);
        let target_path = to_parent.join(&stored);
        let item = Item {
            stored_path: target_path.clone(),
            name: (*to_name).to_owned(),
            is_dir: source.is_dir,
        };
        if target_path == source_path {
            return Ok(item);
        }

        let target = self.find(&to_parent, &to_dir, to_name)?;
        if let Some(target) = &target {
            let existing = to_parent.join(&target.stored);
            // The same item under another case is just renamed.
            if existing != source_path {
                if !replace {
                    return Err(Error::AlreadyExists);
                }
                if target.is_dir || source.is_dir {
                    return Err(Error::NotAllowed);
                }
                if existing != target_path {
                    fs::remove_file(&existing).map_err(Error::from_io)?;
                    if is_long_entry(&target.stored) {
                        let _ = fs::remove_file(to_parent.join(sidecar_name(&target.stored)));
                    }
                }
                lock(&self.files).remove(&existing);
            }
        }

        if is_long_entry(&stored) {
            fs::write(to_parent.join(sidecar_name(&stored)), &encoded)?;
        }
        fs::rename(&source_path, &target_path).map_err(Error::from_io)?;
        if is_long_entry(&source.stored) {
            let _ = fs::remove_file(from_parent.join(sidecar_name(&source.stored)));
        }

        index_remove(&from_dir, from_name);
        if let Some(target) = &target {
            index_remove(&to_dir, &target.name);
        }
        index_insert(&to_dir, to_name, &stored, source.is_dir);
        self.moved(&source_path, &target_path);
        Ok(item)
    }

    /// Lists a folder. Items whose names can't be decrypted (not made by
    /// the vault, or damaged) are left out.
    pub fn list(&self, dir: &Item) -> Result<Vec<Listing>> {
        if !dir.is_dir {
            return Err(Error::NotADirectory);
        }
        let state = self.dir(&dir.stored_path)?;
        let entries = {
            let mut index = lock(&state.index);
            let entries = self.read_entries(&dir.stored_path, &state.iv)?;
            if index.is_none() {
                *index = Some(
                    entries
                        .iter()
                        .map(|(entry, _)| (fold(&entry.name), entry.clone()))
                        .collect(),
                );
            }
            entries
        };
        let open: Vec<Option<Arc<ContentFile>>> = {
            let files = lock(&self.files);
            entries
                .iter()
                .map(|(entry, _)| {
                    files
                        .get(&dir.stored_path.join(&entry.stored))
                        .and_then(Weak::upgrade)
                })
                .collect()
        };
        Ok(entries
            .into_iter()
            .zip(open)
            .map(|((entry, metadata), open)| Listing {
                len: match (&open, entry.is_dir) {
                    (_, true) => 0,
                    (Some(file), false) => file.len(),
                    (None, false) => self.codec.plain_len(metadata.len()),
                },
                name: entry.name,
                is_dir: entry.is_dir,
                metadata,
            })
            .collect())
    }

    /// Whether a folder has no items.
    pub fn is_empty_dir(&self, dir: &Item) -> Result<bool> {
        if !dir.is_dir {
            return Err(Error::NotADirectory);
        }
        self.is_empty_dir_at(&dir.stored_path)
    }

    fn is_empty_dir_at(&self, stored_path: &Path) -> Result<bool> {
        let state = self.dir(stored_path)?;
        Ok(self.read_entries(stored_path, &state.iv)?.is_empty())
    }

    fn lookup_parts(&self, parts: &[&str]) -> Result<Option<Item>> {
        let Some(last) = parts.len().checked_sub(1) else {
            return Ok(Some(self.root()));
        };
        if let Some(item) = self.lookup_exact(parts) {
            return Ok(Some(item));
        }
        // Another case, or not there: go through the indexes.
        let mut dir_path = self.data.clone();
        for (i, part) in parts.iter().enumerate() {
            let dir = self.dir(&dir_path)?;
            let Some(entry) = self.find(&dir_path, &dir, part)? else {
                return if i == last {
                    Ok(None)
                } else {
                    Err(Error::NotFound)
                };
            };
            let path = dir_path.join(&entry.stored);
            if i == last {
                return Ok(Some(Item {
                    stored_path: path,
                    name: entry.name,
                    is_dir: entry.is_dir,
                }));
            }
            if !entry.is_dir {
                return Err(Error::NotADirectory);
            }
            dir_path = path;
        }
        unreachable!("the loop returns at the last part")
    }

    /// The fast way for the common case: every name has the exact case it
    /// was created with, so the stored path can be computed directly.
    fn lookup_exact(&self, parts: &[&str]) -> Option<Item> {
        let mut path = self.data.clone();
        for part in parts {
            let dir = self.dir(&path).ok()?;
            path.push(entry_name(&encrypt_name(&self.keys, &dir.iv, part).ok()?));
        }
        let metadata = fs::symlink_metadata(&path).ok()?;
        Some(Item {
            stored_path: path,
            name: (*parts.last()?).to_owned(),
            is_dir: metadata.is_dir(),
        })
    }

    /// The stored path and state of the folder at `parts`.
    fn parent(&self, parts: &[&str]) -> Result<(PathBuf, Arc<DirState>)> {
        let item = self.lookup_parts(parts)?.ok_or(Error::NotFound)?;
        if !item.is_dir {
            return Err(Error::NotADirectory);
        }
        let dir = self.dir(&item.stored_path)?;
        Ok((item.stored_path, dir))
    }

    fn dir(&self, stored_path: &Path) -> Result<Arc<DirState>> {
        if let Some(dir) = lock(&self.dirs).get(stored_path) {
            return Ok(dir.clone());
        }
        let iv = match fs::read(stored_path.join(DIR_IV_FILE)) {
            Ok(iv) => iv,
            Err(error) => {
                // The folder is gone, or it is a file.
                return Err(if fs::metadata(stored_path).is_ok_and(|m| m.is_dir()) {
                    Error::corrupt("a folder has lost its IV")
                } else {
                    Error::from_io(error)
                });
            }
        };
        let iv: DirIv = iv
            .try_into()
            .map_err(|_| Error::corrupt("a folder has a damaged IV"))?;
        let dir = Arc::new(DirState {
            iv,
            index: Mutex::default(),
        });
        Ok(lock(&self.dirs)
            .entry(stored_path.to_owned())
            .or_insert(dir)
            .clone())
    }

    /// Finds `name` in a folder, ignoring case.
    fn find(&self, dir_path: &Path, dir: &DirState, name: &str) -> Result<Option<Entry>> {
        // The index is built while its lock is held, so no change made
        // meanwhile is lost: changes update it only after the disk.
        let mut index = lock(&dir.index);
        if index.is_none() {
            *index = Some(
                self.read_entries(dir_path, &dir.iv)?
                    .into_iter()
                    .map(|(entry, _)| (fold(&entry.name), entry))
                    .collect(),
            );
        }
        Ok(index
            .as_ref()
            .and_then(|index| index.get(&fold(name)).cloned()))
    }

    fn read_entries(&self, dir_path: &Path, iv: &DirIv) -> Result<Vec<(Entry, fs::Metadata)>> {
        let mut entries = Vec::new();
        for dir_entry in fs::read_dir(dir_path).map_err(Error::from_io)? {
            let dir_entry = dir_entry?;
            let Ok(stored) = dir_entry.file_name().into_string() else {
                continue;
            };
            if is_internal_entry(&stored) || stored.starts_with(TEMP_PREFIX) {
                continue;
            }
            let encoded = if is_long_entry(&stored) {
                match fs::read_to_string(dir_path.join(sidecar_name(&stored))) {
                    Ok(encoded) if entry_name(&encoded) == stored => encoded,
                    _ => continue,
                }
            } else {
                stored.clone()
            };
            let Ok(name) = decrypt_name(&self.keys, iv, &encoded) else {
                continue;
            };
            let metadata = match dir_entry.metadata() {
                Ok(metadata) => metadata,
                // Removed meanwhile.
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(error) => return Err(error.into()),
            };
            entries.push((
                Entry {
                    name,
                    stored,
                    is_dir: metadata.is_dir(),
                },
                metadata,
            ));
        }
        Ok(entries)
    }

    /// Encrypts a new name for a folder, and writes the file that holds a
    /// long name.
    fn prepare_name(&self, parent: &Path, dir: &DirState, name: &str) -> Result<(String, PathBuf)> {
        let encoded = encrypt_name(&self.keys, &dir.iv, name)?;
        let stored = entry_name(&encoded);
        if is_long_entry(&stored) {
            fs::write(parent.join(sidecar_name(&stored)), &encoded)?;
        }
        let path = parent.join(&stored);
        Ok((stored, path))
    }

    fn open_file_at(&self, stored_path: &Path) -> Option<Arc<ContentFile>> {
        lock(&self.files).get(stored_path).and_then(Weak::upgrade)
    }

    /// Updates the caches after the stored item `old` moved to `new`.
    fn moved(&self, old: &Path, new: &Path) {
        let rebase = |path: &Path| -> PathBuf {
            match path.strip_prefix(old) {
                Ok(rest) if rest.as_os_str().is_empty() => new.to_owned(),
                Ok(rest) => new.join(rest),
                Err(_) => path.to_owned(),
            }
        };
        let mut dirs = lock(&self.dirs);
        let moved: Vec<PathBuf> = dirs
            .keys()
            .filter(|p| p.starts_with(old))
            .cloned()
            .collect();
        for path in moved {
            if let Some(state) = dirs.remove(&path) {
                dirs.insert(rebase(&path), state);
            }
        }
        drop(dirs);

        let mut files = lock(&self.files);
        let moved: Vec<PathBuf> = files
            .keys()
            .filter(|p| p.starts_with(old))
            .cloned()
            .collect();
        for path in moved {
            let Some(file) = files.remove(&path).and_then(|weak| weak.upgrade()) else {
                continue;
            };
            let new_path = rebase(&path);
            file.set_path(new_path.clone());
            files.insert(new_path, Arc::downgrade(&file));
        }
    }
}

/// Splits a plaintext path into its names.
fn components(path: &str) -> Result<Vec<&str>> {
    let parts: Vec<&str> = path
        .split(['\\', '/'])
        .filter(|part| !part.is_empty())
        .collect();
    for part in &parts {
        check_name(part)?;
    }
    Ok(parts)
}

fn index_insert(dir: &DirState, name: &str, stored: &str, is_dir: bool) {
    if let Some(index) = lock(&dir.index).as_mut() {
        index.insert(
            fold(name),
            Entry {
                name: name.to_owned(),
                stored: stored.to_owned(),
                is_dir,
            },
        );
    }
}

fn index_remove(dir: &DirState, name: &str) {
    if let Some(index) = lock(&dir.index).as_mut() {
        index.remove(&fold(name));
    }
}

/// Registers an open file, and forgets closed ones now and then.
fn remember(files: &mut HashMap<PathBuf, Weak<ContentFile>>, path: &Path, file: &Arc<ContentFile>) {
    if files.len() >= 256 {
        files.retain(|_, weak| weak.strong_count() > 0);
    }
    files.insert(path.to_owned(), Arc::downgrade(file));
}

/// Forgets the folder at `path` and everything inside it.
fn forget(dirs: &mut HashMap<PathBuf, Arc<DirState>>, path: &Path) {
    dirs.retain(|dir, _| !dir.starts_with(path));
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0, |diff, (x, y)| diff | (x ^ y)) == 0
}

fn random_iv() -> DirIv {
    let mut iv = [0; DIR_IV_LEN];
    OsRng.fill_bytes(&mut iv);
    iv
}

fn temp_name(kind: &str) -> String {
    let mut random = [0; 8];
    OsRng.fill_bytes(&mut random);
    let hex: String = random.iter().map(|b| format!("{b:02x}")).collect();
    format!("{TEMP_PREFIX}{kind}-{hex}")
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::content::MIN_BLOCK_SIZE;

    fn keys() -> VaultKeys {
        VaultKeys::derive(&[3; 32], b"vault id")
    }

    fn new_vault(dir: &tempfile::TempDir) -> Vault {
        Vault::create(&dir.path().join("data"), keys(), MIN_BLOCK_SIZE).unwrap()
    }

    fn names(vault: &Vault, path: &str) -> Vec<String> {
        let item = vault.lookup(path).unwrap().unwrap();
        let mut names: Vec<String> = vault
            .list(&item)
            .unwrap()
            .into_iter()
            .map(|l| l.name)
            .collect();
        names.sort();
        names
    }

    fn write(vault: &Vault, path: &str, data: &[u8]) {
        let (_, file) = vault.create_file(path).unwrap();
        file.write_at(0, data).unwrap();
    }

    fn read(vault: &Vault, path: &str) -> Vec<u8> {
        let item = vault.lookup(path).unwrap().expect("exists");
        let file = vault.open_file(&item).unwrap();
        let mut buf = vec![0; file.len() as usize];
        file.read_at(0, &mut buf).unwrap();
        buf
    }

    #[test]
    fn creates_lists_and_reopens() {
        let temp = tempfile::tempdir().unwrap();
        let vault = new_vault(&temp);
        vault.create_dir(r"\Photos").unwrap();
        vault.create_dir(r"\Photos\2026").unwrap();
        write(&vault, r"\Photos\2026\cat.jpg", b"meow");
        write(&vault, r"\notes.txt", b"hello");
        let long = "a very long name ".repeat(12);
        write(&vault, &format!(r"\Photos\{long}"), b"long");

        assert_eq!(names(&vault, r"\"), ["Photos", "notes.txt"]);
        assert_eq!(names(&vault, r"\Photos"), ["2026".to_owned(), long.clone()]);
        let listing = vault.list(&vault.root()).unwrap();
        let notes = listing.iter().find(|l| l.name == "notes.txt").unwrap();
        assert_eq!(notes.len, 5);

        // Nothing readable is stored.
        for entry in walk(&temp.path().join("data")) {
            let name = entry.file_name().unwrap().to_string_lossy().into_owned();
            assert!(!name.contains("Photos") && !name.contains("notes") && !name.contains("cat"));
        }

        drop(vault);
        let vault = Vault::open(&temp.path().join("data"), keys(), MIN_BLOCK_SIZE).unwrap();
        assert_eq!(read(&vault, "/Photos/2026/cat.jpg"), b"meow");
        assert_eq!(read(&vault, &format!("/Photos/{long}")), b"long");
        assert_eq!(names(&vault, r"\Photos"), ["2026".to_owned(), long]);
    }

    #[test]
    fn refuses_another_key() {
        let temp = tempfile::tempdir().unwrap();
        drop(new_vault(&temp));
        let other = VaultKeys::derive(&[4; 32], b"vault id");
        assert!(matches!(
            Vault::open(&temp.path().join("data"), other, MIN_BLOCK_SIZE),
            Err(Error::WrongKey)
        ));
        assert!(matches!(
            Vault::open(&temp.path().join("missing"), keys(), MIN_BLOCK_SIZE),
            Err(Error::Corrupt(_))
        ));
    }

    #[test]
    fn names_are_case_insensitive_but_keep_their_case() {
        let temp = tempfile::tempdir().unwrap();
        let vault = new_vault(&temp);
        vault.create_dir(r"\Docs").unwrap();
        write(&vault, r"\Docs\Report.TXT", b"1");

        let found = vault.lookup(r"\DOCS\report.txt").unwrap().unwrap();
        assert_eq!(found.name, "Report.TXT");
        assert!(matches!(
            vault.create_file(r"\docs\REPORT.txt"),
            Err(Error::AlreadyExists)
        ));
        assert!(matches!(
            vault.create_dir(r"\DOCS"),
            Err(Error::AlreadyExists)
        ));

        // A new vault object has no index yet: the slow path finds it too.
        drop(vault);
        let vault = Vault::open(&temp.path().join("data"), keys(), MIN_BLOCK_SIZE).unwrap();
        assert_eq!(read(&vault, r"\docs\report.txt"), b"1");
    }

    #[test]
    fn tells_missing_items_from_missing_folders() {
        let temp = tempfile::tempdir().unwrap();
        let vault = new_vault(&temp);
        write(&vault, r"\file", b"");
        assert_eq!(vault.lookup(r"\nothing").unwrap(), None);
        assert!(matches!(
            vault.lookup(r"\nothing\deeper"),
            Err(Error::NotFound)
        ));
        assert!(matches!(
            vault.lookup(r"\file\deeper"),
            Err(Error::NotADirectory)
        ));
        assert!(matches!(
            vault.create_file(r"\nothing\new"),
            Err(Error::NotFound)
        ));
        assert!(matches!(vault.lookup(r"\a\..\b"), Err(Error::InvalidName)));
        assert_eq!(vault.lookup("").unwrap(), Some(vault.root()));
    }

    #[test]
    fn removes_files_and_empty_folders_only() {
        let temp = tempfile::tempdir().unwrap();
        let vault = new_vault(&temp);
        vault.create_dir(r"\dir").unwrap();
        write(&vault, r"\dir\file", b"x");
        let long = "l".repeat(150);
        write(&vault, &format!(r"\dir\{long}"), b"y");

        assert!(matches!(
            vault.remove(r"\dir"),
            Err(Error::DirectoryNotEmpty)
        ));
        vault.remove(r"\DIR\FILE").unwrap();
        vault.remove(&format!(r"\dir\{long}")).unwrap();
        assert!(vault
            .is_empty_dir(&vault.lookup(r"\dir").unwrap().unwrap())
            .unwrap());
        vault.remove(r"\dir").unwrap();
        assert!(names(&vault, "").is_empty());
        assert!(matches!(vault.remove(""), Err(Error::NotAllowed)));
        assert!(matches!(vault.remove(r"\gone"), Err(Error::NotFound)));
        // Only the root IV and the key check are left.
        assert_eq!(walk(&temp.path().join("data")).len(), 2);
    }

    #[test]
    fn renames_and_moves() {
        let temp = tempfile::tempdir().unwrap();
        let vault = new_vault(&temp);
        vault.create_dir(r"\a").unwrap();
        vault.create_dir(r"\a\inner").unwrap();
        vault.create_dir(r"\b").unwrap();
        write(&vault, r"\a\inner\deep.txt", b"deep");
        write(&vault, r"\a\file.txt", b"file");
        let open = vault
            .open_file(&vault.lookup(r"\a\file.txt").unwrap().unwrap())
            .unwrap();

        // Case only.
        vault.rename(r"\a\file.txt", r"\a\FILE.txt", false).unwrap();
        assert_eq!(names(&vault, r"\a"), ["FILE.txt", "inner"]);
        // Into another folder, with a long name; the open handle follows.
        let long = "moved ".repeat(40);
        vault
            .rename(r"\a\FILE.txt", &format!(r"\b\{long}"), false)
            .unwrap();
        open.write_at(4, b"+more").unwrap();
        assert_eq!(read(&vault, &format!(r"\b\{long}")), b"file+more");
        // A folder with everything inside it.
        vault.rename(r"\a", r"\b\a2", false).unwrap();
        assert_eq!(read(&vault, r"\b\a2\inner\deep.txt"), b"deep");
        assert_eq!(vault.lookup(r"\a").unwrap(), None);
        // Not into itself.
        assert!(matches!(
            vault.rename(r"\b", r"\b\a2\b", false),
            Err(Error::NotAllowed)
        ));

        // Replacing.
        write(&vault, r"\x", b"x");
        write(&vault, r"\y", b"y");
        assert!(matches!(
            vault.rename(r"\x", r"\Y", false),
            Err(Error::AlreadyExists)
        ));
        vault.rename(r"\x", r"\Y", true).unwrap();
        assert_eq!(read(&vault, r"\y"), b"x");
        assert_eq!(names(&vault, ""), ["Y", "b"]);
        assert!(matches!(
            vault.rename(r"\Y", r"\b", true),
            Err(Error::NotAllowed)
        ));
        // The file that held the long name goes away with it.
        let sidecars = || {
            walk(&temp.path().join("data"))
                .into_iter()
                .filter(|p| p.to_string_lossy().ends_with(".name"))
                .count()
        };
        assert_eq!(sidecars(), 1);
        vault
            .rename(&format!(r"\b\{long}"), r"\b\short", false)
            .unwrap();
        assert_eq!(sidecars(), 0);
        assert_eq!(read(&vault, r"\b\short"), b"file+more");
    }

    #[test]
    fn skips_foreign_and_temporary_items() {
        let temp = tempfile::tempdir().unwrap();
        let vault = new_vault(&temp);
        write(&vault, r"\real", b"1");
        let data = temp.path().join("data");
        fs::write(data.join("desktop.ini"), b"x").unwrap();
        fs::write(
            data.join("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
            b"x",
        )
        .unwrap();
        fs::create_dir(data.join(".new-0011")).unwrap();
        assert_eq!(names(&vault, ""), ["real"]);
    }

    fn walk(dir: &Path) -> Vec<PathBuf> {
        let mut found = Vec::new();
        for entry in fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                found.extend(walk(&path));
            } else {
                found.push(path);
            }
        }
        found
    }
}
