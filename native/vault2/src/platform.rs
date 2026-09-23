//! Times and attributes of stored items.
//!
//! A vault keeps the times and the Windows attributes (read-only, hidden,
//! system, archive) of each item on its stored file or folder, so they don't
//! need a place of their own.

use std::fs::{File, Metadata};
use std::io;
use std::path::Path;

/// Attributes a vault keeps: read-only, hidden, system, archive and
/// "not content indexed".
pub const KEPT_ATTRIBUTES: u32 = 0x1 | 0x2 | 0x4 | 0x20 | 0x2000;

/// The times and attributes of an item.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Stamp {
    /// Windows file times (100 ns since 1601), 0 when unknown.
    pub created: u64,
    pub accessed: u64,
    pub written: u64,
    /// Windows attributes, limited to [`KEPT_ATTRIBUTES`].
    pub attributes: u32,
}

/// Seconds between 1601-01-01 and 1970-01-01.
const FILETIME_UNIX_OFFSET: u64 = 11_644_473_600;

impl Stamp {
    #[cfg(windows)]
    pub fn of(metadata: &Metadata) -> Self {
        use std::os::windows::fs::MetadataExt;
        Self {
            created: metadata.creation_time(),
            accessed: metadata.last_access_time(),
            written: metadata.last_write_time(),
            attributes: metadata.file_attributes() & KEPT_ATTRIBUTES,
        }
    }

    #[cfg(not(windows))]
    pub fn of(metadata: &Metadata) -> Self {
        Self {
            created: metadata.created().map(file_time).unwrap_or(0),
            accessed: metadata.accessed().map(file_time).unwrap_or(0),
            written: metadata.modified().map(file_time).unwrap_or(0),
            attributes: if metadata.permissions().readonly() {
                0x1
            } else {
                0
            },
        }
    }

    /// Applies the stamp to the stored item at `path`.
    ///
    /// Call it after the item's content is complete: writing afterwards
    /// changes the modification time again.
    pub fn apply(&self, path: &Path, is_dir: bool) -> io::Result<()> {
        let file = open_for_attributes(path, is_dir)?;
        self.apply_to(&file, is_dir)
    }

    /// Applies the stamp through an open handle, which needs the right to
    /// change attributes.
    #[cfg(windows)]
    pub fn apply_to(&self, file: &File, _is_dir: bool) -> io::Result<()> {
        let attributes = match self.attributes & KEPT_ATTRIBUTES {
            0 => 0x80, // FILE_ATTRIBUTE_NORMAL: clears the others
            kept => kept,
        };
        set_basic_info(
            file,
            self.created as i64,
            self.accessed as i64,
            self.written as i64,
            attributes,
        )
    }

    #[cfg(not(windows))]
    pub fn apply_to(&self, file: &File, _is_dir: bool) -> io::Result<()> {
        let mut times = std::fs::FileTimes::new();
        if self.accessed != 0 {
            times = times.set_accessed(system_time(self.accessed));
        }
        if self.written != 0 {
            times = times.set_modified(system_time(self.written));
        }
        file.set_times(times)
    }
}

/// Converts a time to a Windows file time.
pub fn file_time(time: std::time::SystemTime) -> u64 {
    match time.duration_since(std::time::UNIX_EPOCH) {
        Ok(since) => {
            (since.as_secs() + FILETIME_UNIX_OFFSET) * 10_000_000
                + u64::from(since.subsec_nanos()) / 100
        }
        Err(before) => {
            let before = before.duration();
            (FILETIME_UNIX_OFFSET * 10_000_000).saturating_sub(
                before.as_secs() * 10_000_000 + u64::from(before.subsec_nanos()) / 100,
            )
        }
    }
}

/// Converts a Windows file time to a time.
pub fn system_time(file_time: u64) -> std::time::SystemTime {
    use std::time::{Duration, UNIX_EPOCH};
    let secs = file_time / 10_000_000;
    let nanos = Duration::from_nanos(file_time % 10_000_000 * 100);
    if secs >= FILETIME_UNIX_OFFSET {
        UNIX_EPOCH + Duration::from_secs(secs - FILETIME_UNIX_OFFSET) + nanos
    } else {
        UNIX_EPOCH - Duration::from_secs(FILETIME_UNIX_OFFSET - secs) + nanos
    }
}

/// Opens a stored file or folder only to change its times and attributes.
/// Works for read-only files too.
#[cfg(windows)]
pub fn open_for_attributes(path: &Path, is_dir: bool) -> io::Result<File> {
    use std::os::windows::fs::OpenOptionsExt;
    const FILE_READ_ATTRIBUTES: u32 = 0x80;
    const FILE_WRITE_ATTRIBUTES: u32 = 0x100;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
    std::fs::OpenOptions::new()
        .access_mode(FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES)
        .custom_flags(if is_dir {
            FILE_FLAG_BACKUP_SEMANTICS
        } else {
            0
        })
        .open(path)
}

#[cfg(not(windows))]
pub fn open_for_attributes(path: &Path, _is_dir: bool) -> io::Result<File> {
    File::open(path)
}

/// Sets times and attributes through a handle, like `SetFileInformationByHandle`
/// with `FILE_BASIC_INFO`: a time of 0 stays as it is, -1 stops the file
/// system from changing it for later operations on this handle, and -2
/// lets it change it again. Attributes of 0 stay as they are.
#[cfg(windows)]
pub fn set_basic_info(
    file: &File,
    created: i64,
    accessed: i64,
    written: i64,
    attributes: u32,
) -> io::Result<()> {
    use std::os::windows::io::AsRawHandle;
    use winapi::um::fileapi::{SetFileInformationByHandle, FILE_BASIC_INFO};
    use winapi::um::minwinbase::FileBasicInfo;

    let mut info: FILE_BASIC_INFO = unsafe { std::mem::zeroed() };
    unsafe {
        *info.CreationTime.QuadPart_mut() = created;
        *info.LastAccessTime.QuadPart_mut() = accessed;
        *info.LastWriteTime.QuadPart_mut() = written;
    }
    info.FileAttributes = attributes;
    let ok = unsafe {
        SetFileInformationByHandle(
            file.as_raw_handle() as _,
            FileBasicInfo,
            &mut info as *mut _ as *mut _,
            std::mem::size_of::<FILE_BASIC_INFO>() as u32,
        )
    };
    if ok == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_file_times() {
        let time = std::time::UNIX_EPOCH + std::time::Duration::new(1_700_000_000, 123_456_700);
        let converted = file_time(time);
        assert_eq!(
            converted,
            (1_700_000_000 + FILETIME_UNIX_OFFSET) * 10_000_000 + 1_234_567
        );
        assert_eq!(system_time(converted), time);
        assert_eq!(
            file_time(std::time::UNIX_EPOCH),
            FILETIME_UNIX_OFFSET * 10_000_000
        );
    }

    #[test]
    fn keeps_times_of_files_and_folders() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("file");
        std::fs::write(&file, b"x").unwrap();
        let stamp = Stamp {
            written: file_time(
                std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_000_000_000),
            ),
            accessed: file_time(
                std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_100_000_000),
            ),
            ..Stamp::default()
        };
        for (path, is_dir) in [(file.as_path(), false), (dir.path(), true)] {
            stamp.apply(path, is_dir).unwrap();
            let applied = Stamp::of(&std::fs::metadata(path).unwrap());
            assert_eq!(applied.written, stamp.written);
            assert_eq!(applied.accessed, stamp.accessed);
        }
    }
}
