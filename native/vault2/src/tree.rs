//! Copying whole folders into and out of a vault.
//!
//! Used to turn a folder into a drive vault (import, then verify before the
//! original is deleted) and back (export).

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;

use crate::error::{Error, Result};
use crate::platform::Stamp;
use crate::vault::{Item, Vault};

/// Size of the pieces files are copied in.
const COPY_CHUNK: usize = 1 << 20;

/// What a folder holds.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TreeStats {
    pub files: u64,
    pub dirs: u64,
    pub bytes: u64,
}

/// Called with the number of bytes processed so far. Returning `false`
/// cancels the operation with [`Error::Cancelled`].
pub type Progress<'a> = &'a mut dyn FnMut(u64) -> bool;

/// Counts what `source` holds. Fails on links (symbolic links, junctions),
/// which a vault can't store.
pub fn scan(source: &Path) -> Result<TreeStats> {
    let mut stats = TreeStats::default();
    scan_dir(source, &mut stats)?;
    Ok(stats)
}

fn scan_dir(dir: &Path, stats: &mut TreeStats) -> Result<()> {
    for entry in fs::read_dir(dir).map_err(Error::from_io)? {
        let entry = entry?;
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path)?;
        check_source(&path, &metadata)?;
        if metadata.is_dir() {
            stats.dirs += 1;
            scan_dir(&path, stats)?;
        } else {
            stats.files += 1;
            stats.bytes += metadata.len();
        }
    }
    Ok(())
}

fn check_source(path: &Path, metadata: &fs::Metadata) -> Result<()> {
    if metadata.file_type().is_symlink() {
        return Err(Error::Unsupported(format!(
            "{} is a link (symbolic link or junction). Folders with links can't be encrypted.",
            path.display()
        )));
    }
    let name = path.file_name().and_then(|n| n.to_str()).ok_or_else(|| {
        Error::Unsupported(format!(
            "{} has a name that isn't valid Unicode",
            path.display()
        ))
    })?;
    if name.contains(['\\', '/']) {
        return Err(Error::Unsupported(format!(
            "{} has an invalid name",
            path.display()
        )));
    }
    Ok(())
}

/// Counts what `vault` holds.
pub fn vault_stats(vault: &Vault) -> Result<TreeStats> {
    let mut stats = TreeStats::default();
    vault_stats_dir(vault, &vault.root(), "", &mut stats)?;
    Ok(stats)
}

fn vault_stats_dir(vault: &Vault, item: &Item, path: &str, stats: &mut TreeStats) -> Result<()> {
    for entry in vault.list(item)? {
        if entry.is_dir {
            stats.dirs += 1;
            let child = format!("{path}\\{}", entry.name);
            let item = vault.lookup(&child)?.ok_or(Error::NotFound)?;
            vault_stats_dir(vault, &item, &child, stats)?;
        } else {
            stats.files += 1;
            stats.bytes += entry.len;
        }
    }
    Ok(())
}

/// Copies everything inside `source` into the top folder of `vault`, with
/// times and attributes.
pub fn import(vault: &Vault, source: &Path, progress: Progress) -> Result<TreeStats> {
    let mut stats = TreeStats::default();
    import_dir(vault, source, "", &mut stats, progress)?;
    Ok(stats)
}

fn import_dir(
    vault: &Vault,
    dir: &Path,
    vault_dir: &str,
    stats: &mut TreeStats,
    progress: Progress,
) -> Result<()> {
    for entry in sorted_entries(dir)? {
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path)?;
        check_source(&path, &metadata)?;
        let name = entry.file_name().into_string().expect("checked above");
        let child = format!("{vault_dir}\\{name}");
        if metadata.is_dir() {
            let item = vault.create_dir(&child)?;
            import_dir(vault, &path, &child, stats, progress)?;
            // After the content: adding items changes a folder's times.
            Stamp::of(&metadata).apply(&item.stored_path, true)?;
            stats.dirs += 1;
        } else {
            let (item, file) = vault.create_file(&child)?;
            let mut source = File::open(&path).map_err(Error::from_io)?;
            let mut buf = vec![0; COPY_CHUNK];
            let mut offset = 0;
            loop {
                let read = read_full(&mut source, &mut buf)?;
                if read == 0 {
                    break;
                }
                file.write_at(offset, &buf[..read])?;
                offset += read as u64;
                stats.bytes += read as u64;
                if !progress(stats.bytes) {
                    return Err(Error::Cancelled);
                }
            }
            // Closed first, so it doesn't change the times again.
            drop(file);
            Stamp::of(&metadata).apply(&item.stored_path, false)?;
            stats.files += 1;
        }
    }
    Ok(())
}

/// Checks that the vault holds exactly what `source` holds: the same
/// names, and files with the same bytes.
pub fn verify(vault: &Vault, source: &Path, progress: Progress) -> Result<()> {
    let mut done = 0;
    verify_dir(vault, source, &vault.root(), "", &mut done, progress)
}

fn verify_dir(
    vault: &Vault,
    dir: &Path,
    vault_item: &Item,
    vault_dir: &str,
    done: &mut u64,
    progress: Progress,
) -> Result<()> {
    let entries = sorted_entries(dir)?;
    let stored = vault.list(vault_item)?.len();
    if stored != entries.len() {
        return Err(mismatch(
            dir,
            format!("has {} items, the vault {stored}", entries.len()),
        ));
    }
    for entry in entries {
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path)?;
        check_source(&path, &metadata)?;
        let name = entry.file_name().into_string().expect("checked above");
        let child = format!("{vault_dir}\\{name}");
        let item = vault
            .lookup(&child)?
            .filter(|item| item.name == name && item.is_dir == metadata.is_dir())
            .ok_or_else(|| mismatch(&path, "is missing in the vault".to_owned()))?;
        if item.is_dir {
            verify_dir(vault, &path, &item, &child, done, progress)?;
            continue;
        }
        let file = vault.open_file(&item)?;
        if file.len() != metadata.len() {
            return Err(mismatch(&path, "has another size in the vault".to_owned()));
        }
        let mut source = File::open(&path).map_err(Error::from_io)?;
        let mut expected = vec![0; COPY_CHUNK];
        let mut actual = vec![0; COPY_CHUNK];
        let mut offset = 0;
        loop {
            let read = read_full(&mut source, &mut expected)?;
            let stored = file.read_at(offset, &mut actual[..read.max(1)])?;
            if read == 0 && stored == 0 {
                break;
            }
            if read != stored || expected[..read] != actual[..stored] {
                return Err(mismatch(&path, "differs from the vault".to_owned()));
            }
            offset += read as u64;
            *done += read as u64;
            if !progress(*done) {
                return Err(Error::Cancelled);
            }
        }
    }
    Ok(())
}

/// Copies everything in `vault` into the new folder `target`, with times
/// and attributes.
pub fn export(vault: &Vault, target: &Path, progress: Progress) -> Result<TreeStats> {
    fs::create_dir(target).map_err(Error::from_io)?;
    let mut stats = TreeStats::default();
    export_dir(vault, &vault.root(), "", target, &mut stats, progress)?;
    Ok(stats)
}

fn export_dir(
    vault: &Vault,
    vault_item: &Item,
    vault_dir: &str,
    target: &Path,
    stats: &mut TreeStats,
    progress: Progress,
) -> Result<()> {
    let mut listing = vault.list(vault_item)?;
    listing.sort_by(|a, b| a.name.cmp(&b.name));
    for entry in listing {
        let child = format!("{vault_dir}\\{}", entry.name);
        let path = target.join(&entry.name);
        let item = vault.lookup(&child)?.ok_or(Error::NotFound)?;
        let stamp = Stamp::of(&entry.metadata);
        if entry.is_dir {
            fs::create_dir(&path).map_err(Error::from_io)?;
            export_dir(vault, &item, &child, &path, stats, progress)?;
            stamp.apply(&path, true)?;
            stats.dirs += 1;
            continue;
        }
        let file = vault.open_file(&item)?;
        let mut out = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .map_err(Error::from_io)?;
        let mut buf = vec![0; COPY_CHUNK];
        let mut offset = 0;
        loop {
            let read = file.read_at(offset, &mut buf)?;
            if read == 0 {
                break;
            }
            out.write_all(&buf[..read])?;
            offset += read as u64;
            stats.bytes += read as u64;
            if !progress(stats.bytes) {
                return Err(Error::Cancelled);
            }
        }
        out.sync_all()?;
        drop(out);
        stamp.apply(&path, false)?;
        stats.files += 1;
    }
    Ok(())
}

fn sorted_entries(dir: &Path) -> Result<Vec<fs::DirEntry>> {
    let mut entries = fs::read_dir(dir)
        .map_err(Error::from_io)?
        .collect::<std::io::Result<Vec<_>>>()?;
    entries.sort_by_key(|entry| entry.file_name());
    Ok(entries)
}

/// Reads until `buf` is full or the file ends.
fn read_full(source: &mut File, buf: &mut [u8]) -> Result<usize> {
    let mut filled = 0;
    while filled < buf.len() {
        match source.read(&mut buf[filled..]) {
            Ok(0) => break,
            Ok(n) => filled += n,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error.into()),
        }
    }
    Ok(filled)
}

fn mismatch(path: &Path, what: String) -> Error {
    Error::Mismatch(format!("{} {what}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::content::MIN_BLOCK_SIZE;
    use crate::keys::VaultKeys;
    use crate::platform::file_time;
    use std::time::{Duration, UNIX_EPOCH};

    fn vault_at(path: &Path) -> Vault {
        Vault::create(path, VaultKeys::derive(&[5; 32], b"id"), MIN_BLOCK_SIZE).unwrap()
    }

    fn sample(root: &Path) {
        fs::create_dir_all(root.join("Sub/Deeper")).unwrap();
        fs::create_dir(root.join("Empty")).unwrap();
        fs::write(root.join("a.txt"), b"alpha").unwrap();
        fs::write(root.join("Sub/b.bin"), vec![7u8; 3 * MIN_BLOCK_SIZE + 5]).unwrap();
        fs::write(root.join("Sub/Deeper/empty"), b"").unwrap();
        fs::write(root.join("x".repeat(200)), b"long name").unwrap();
    }

    #[test]
    fn imports_verifies_and_exports() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source");
        sample(&source);
        let old = UNIX_EPOCH + Duration::from_secs(1_500_000_000);
        File::options()
            .write(true)
            .open(source.join("a.txt"))
            .unwrap()
            .set_modified(old)
            .unwrap();

        let stats = scan(&source).unwrap();
        assert_eq!(
            stats,
            TreeStats {
                files: 4,
                dirs: 3,
                bytes: 5 + 3 * MIN_BLOCK_SIZE as u64 + 5 + 9,
            }
        );

        let vault = vault_at(&temp.path().join("data"));
        let mut last = 0;
        let imported = import(&vault, &source, &mut |done| {
            last = done;
            true
        })
        .unwrap();
        assert_eq!(imported, stats);
        assert_eq!(last, stats.bytes);
        verify(&vault, &source, &mut |_| true).unwrap();

        assert_eq!(vault_stats(&vault).unwrap(), stats);
        let target = temp.path().join("exported");
        assert_eq!(export(&vault, &target, &mut |_| true).unwrap(), stats);
        verify(&vault, &target, &mut |_| true).unwrap();
        let exported = fs::metadata(target.join("a.txt")).unwrap();
        assert_eq!(file_time(exported.modified().unwrap()), file_time(old));
    }

    #[test]
    fn verify_finds_differences() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source");
        sample(&source);
        let vault = vault_at(&temp.path().join("data"));
        import(&vault, &source, &mut |_| true).unwrap();

        fs::write(source.join("Sub/b.bin"), vec![8u8; 3 * MIN_BLOCK_SIZE + 5]).unwrap();
        assert!(matches!(
            verify(&vault, &source, &mut |_| true),
            Err(Error::Mismatch(_))
        ));
        fs::write(source.join("Sub/b.bin"), vec![7u8; 3 * MIN_BLOCK_SIZE + 5]).unwrap();
        verify(&vault, &source, &mut |_| true).unwrap();

        fs::write(source.join("new.txt"), b"").unwrap();
        assert!(matches!(
            verify(&vault, &source, &mut |_| true),
            Err(Error::Mismatch(_))
        ));
        fs::remove_file(source.join("new.txt")).unwrap();
        fs::rename(source.join("a.txt"), source.join("A.txt")).unwrap();
        assert!(matches!(
            verify(&vault, &source, &mut |_| true),
            Err(Error::Mismatch(_))
        ));
    }

    #[test]
    fn cancels_and_refuses_links() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source");
        sample(&source);
        let vault = vault_at(&temp.path().join("data"));
        assert!(matches!(
            import(&vault, &source, &mut |_| false),
            Err(Error::Cancelled)
        ));

        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(source.join("a.txt"), source.join("link")).unwrap();
            assert!(matches!(scan(&source), Err(Error::Unsupported(_))));
        }
    }
}
