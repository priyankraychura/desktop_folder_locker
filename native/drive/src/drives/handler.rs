//! Serves a vault to Windows through Dokany.
//!
//! Paths arrive as plaintext paths (`\Photos\cat.jpg`); every operation is
//! passed on to the vault. Times and attributes live on the stored items,
//! so they are read and changed there directly.

use std::fs::{File, OpenOptions};
use std::io;
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::os::windows::io::AsRawHandle;
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{mpsc, Arc};

use dokan::{
    CreateFileInfo, DiskSpaceInfo, FileInfo, FileSystemHandler, FileTimeOperation, FillDataError,
    FillDataResult, FindData, OperationInfo, OperationResult, VolumeInfo, IO_SECURITY_CONTEXT,
};
use flk_vault2::platform::{
    file_time, open_for_attributes, set_basic_info, system_time, KEPT_ATTRIBUTES,
};
use flk_vault2::{ContentFile, Error, Item, Vault};
use widestring::{U16CStr, U16CString};
use winapi::shared::ntdef::NTSTATUS;
use winapi::shared::ntstatus::{
    STATUS_ACCESS_DENIED, STATUS_BUFFER_OVERFLOW, STATUS_CANNOT_DELETE, STATUS_DIRECTORY_NOT_EMPTY,
    STATUS_FILE_CORRUPT_ERROR, STATUS_FILE_IS_A_DIRECTORY, STATUS_INVALID_DEVICE_REQUEST,
    STATUS_INVALID_PARAMETER, STATUS_NOT_A_DIRECTORY, STATUS_NOT_SUPPORTED,
    STATUS_OBJECT_NAME_COLLISION, STATUS_OBJECT_NAME_INVALID, STATUS_OBJECT_NAME_NOT_FOUND,
    STATUS_OBJECT_PATH_NOT_FOUND, STATUS_UNSUCCESSFUL,
};
use winapi::um::fileapi::{
    GetDiskFreeSpaceExW, GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION,
};
use winapi::um::winnt::{
    ACCESS_MASK, FILE_APPEND_DATA, FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_HIDDEN,
    FILE_ATTRIBUTE_NORMAL, FILE_ATTRIBUTE_READONLY, FILE_ATTRIBUTE_SYSTEM,
    FILE_CASE_PRESERVED_NAMES, FILE_UNICODE_ON_DISK, FILE_WRITE_DATA,
};

use crate::protocol::Failure;

// Create dispositions and options (wdm.h).
const FILE_SUPERSEDE: u32 = 0;
const FILE_OPEN: u32 = 1;
const FILE_CREATE: u32 = 2;
const FILE_OPEN_IF: u32 = 3;
const FILE_OVERWRITE: u32 = 4;
const FILE_OVERWRITE_IF: u32 = 5;
const FILE_DIRECTORY_FILE: u32 = 0x1;
const FILE_NON_DIRECTORY_FILE: u32 = 0x40;
const FILE_DELETE_ON_CLOSE: u32 = 0x1000;

const FILE_READ_ATTRIBUTES: u32 = 0x80;
const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;

/// Longest volume label Windows shows.
const MAX_LABEL: usize = 32;

pub struct Handler {
    vault: Vault,
    /// The context of handles Dokany opened itself (see
    /// [`FileSystemHandler::default_context`]); they are resolved by name.
    unopened: Handle,
    label: U16CString,
    serial: u32,
    ready: mpsc::Sender<Result<(), Failure>>,
    open_files: Arc<AtomicUsize>,
    data_dir: U16CString,
}

/// What an open handle on the drive refers to.
pub enum Handle {
    File(Arc<ContentFile>),
    /// A folder, or a handle Dokany opened itself: both are looked up by
    /// name for each request.
    Dir,
}

impl Handler {
    pub fn new(
        vault: Vault,
        label: &str,
        serial: u32,
        ready: mpsc::Sender<Result<(), Failure>>,
    ) -> Self {
        let label: String = label
            .chars()
            .filter(|c| *c != '\0')
            .take(MAX_LABEL)
            .collect();
        let data_dir = U16CString::from_os_str(vault.data_dir().as_os_str()).unwrap_or_default();
        Self {
            vault,
            unopened: Handle::Dir,
            label: U16CString::from_str(label).unwrap_or_default(),
            serial,
            ready,
            open_files: Arc::default(),
            data_dir,
        }
    }

    /// How many files are open on the drive right now.
    pub fn open_files(&self) -> Arc<AtomicUsize> {
        self.open_files.clone()
    }

    fn existing(&self, file_name: &U16CStr) -> OperationResult<Item> {
        self.vault
            .lookup(&path_of(file_name)?)
            .map_err(lookup_status)?
            .ok_or(STATUS_OBJECT_NAME_NOT_FOUND)
    }

    fn open_new(&self, file: Arc<ContentFile>, new: bool) -> CreateFileInfo<Handle> {
        self.open_files.fetch_add(1, Ordering::Relaxed);
        CreateFileInfo {
            context: Handle::File(file),
            is_dir: false,
            new_file_created: new,
        }
    }
}

impl<'c, 'h: 'c> FileSystemHandler<'c, 'h> for Handler {
    type Context = Handle;

    fn default_context(&'h self) -> Option<&'c Self::Context> {
        Some(&self.unopened)
    }

    fn create_file(
        &'h self,
        file_name: &U16CStr,
        _security_context: &IO_SECURITY_CONTEXT,
        desired_access: ACCESS_MASK,
        file_attributes: u32,
        _share_access: u32,
        create_disposition: u32,
        create_options: u32,
        _info: &mut OperationInfo<'c, 'h, Self>,
    ) -> OperationResult<CreateFileInfo<Self::Context>> {
        if create_disposition > FILE_OVERWRITE_IF {
            return Err(STATUS_INVALID_PARAMETER);
        }
        let path = path_of(file_name)?;
        let want_dir = create_options & FILE_DIRECTORY_FILE != 0;
        let want_file = create_options & FILE_NON_DIRECTORY_FILE != 0;
        let delete_on_close = create_options & FILE_DELETE_ON_CLOSE != 0;

        match self.vault.lookup(&path).map_err(lookup_status)? {
            Some(item) if item.is_dir => {
                if want_file {
                    return Err(STATUS_FILE_IS_A_DIRECTORY);
                }
                if delete_on_close && item.name.is_empty() {
                    return Err(STATUS_ACCESS_DENIED);
                }
                match create_disposition {
                    FILE_OPEN | FILE_OPEN_IF => Ok(CreateFileInfo {
                        context: Handle::Dir,
                        is_dir: true,
                        new_file_created: false,
                    }),
                    FILE_CREATE => Err(STATUS_OBJECT_NAME_COLLISION),
                    _ => Err(STATUS_INVALID_PARAMETER),
                }
            }
            Some(item) => {
                if want_dir {
                    return Err(STATUS_NOT_A_DIRECTORY);
                }
                if create_disposition == FILE_CREATE {
                    return Err(STATUS_OBJECT_NAME_COLLISION);
                }
                let file = self.vault.open_file(&item).map_err(status)?;
                let stored = file
                    .with_file(handle_info)
                    .map_err(|e| io_status(&e))?
                    .dwFileAttributes;
                let read_only = stored & FILE_ATTRIBUTE_READONLY != 0;
                if read_only && desired_access & (FILE_WRITE_DATA | FILE_APPEND_DATA) != 0 {
                    return Err(STATUS_ACCESS_DENIED);
                }
                if read_only && delete_on_close {
                    return Err(STATUS_CANNOT_DELETE);
                }
                if matches!(
                    create_disposition,
                    FILE_SUPERSEDE | FILE_OVERWRITE | FILE_OVERWRITE_IF
                ) {
                    // Like NTFS: a hidden or system file is only replaced by
                    // one with the same attributes.
                    let hidden_or_system = FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM;
                    if read_only || stored & hidden_or_system & !file_attributes != 0 {
                        return Err(STATUS_ACCESS_DENIED);
                    }
                    file.set_len(0).map_err(status)?;
                    set_file_attributes(&file, file_attributes)?;
                }
                Ok(self.open_new(file, false))
            }
            None => {
                if matches!(create_disposition, FILE_OPEN | FILE_OVERWRITE) {
                    return Err(STATUS_OBJECT_NAME_NOT_FOUND);
                }
                if want_dir {
                    if !matches!(create_disposition, FILE_CREATE | FILE_OPEN_IF) {
                        return Err(STATUS_INVALID_PARAMETER);
                    }
                    let item = self.vault.create_dir(&path).map_err(status)?;
                    if file_attributes & KEPT_ATTRIBUTES != 0 {
                        let _ = set_dir_attributes(&item.stored_path, file_attributes);
                    }
                    return Ok(CreateFileInfo {
                        context: Handle::Dir,
                        is_dir: true,
                        new_file_created: true,
                    });
                }
                let (_, file) = self.vault.create_file(&path).map_err(status)?;
                if file_attributes & KEPT_ATTRIBUTES != 0 {
                    let _ = set_file_attributes(&file, file_attributes);
                }
                Ok(self.open_new(file, true))
            }
        }
    }

    fn cleanup(
        &'h self,
        file_name: &U16CStr,
        info: &OperationInfo<'c, 'h, Self>,
        _context: &'c Self::Context,
    ) {
        if info.delete_on_close() {
            if let Ok(path) = path_of(file_name) {
                let _ = self.vault.remove(&path);
            }
        }
    }

    fn close_file(
        &'h self,
        _file_name: &U16CStr,
        _info: &OperationInfo<'c, 'h, Self>,
        context: &'c Self::Context,
    ) {
        if let Handle::File(_) = context {
            self.open_files.fetch_sub(1, Ordering::Relaxed);
        }
    }

    fn read_file(
        &'h self,
        _file_name: &U16CStr,
        offset: i64,
        buffer: &mut [u8],
        _info: &OperationInfo<'c, 'h, Self>,
        context: &'c Self::Context,
    ) -> OperationResult<u32> {
        let Handle::File(file) = context else {
            return Err(STATUS_INVALID_DEVICE_REQUEST);
        };
        let offset = u64::try_from(offset).map_err(|_| STATUS_INVALID_PARAMETER)?;
        let read = file.read_at(offset, buffer).map_err(status)?;
        Ok(read as u32)
    }

    fn write_file(
        &'h self,
        _file_name: &U16CStr,
        offset: i64,
        buffer: &[u8],
        info: &OperationInfo<'c, 'h, Self>,
        context: &'c Self::Context,
    ) -> OperationResult<u32> {
        let Handle::File(file) = context else {
            return Err(STATUS_ACCESS_DENIED);
        };
        let written = if info.write_to_eof() {
            file.append(buffer)
        } else {
            let offset = u64::try_from(offset).map_err(|_| STATUS_INVALID_PARAMETER)?;
            if info.paging_io() {
                // Paging I/O never grows a file.
                file.write_within(offset, buffer)
            } else {
                file.write_at(offset, buffer)
            }
        };
        Ok(written.map_err(status)? as u32)
    }

    fn flush_file_buffers(
        &'h self,
        _file_name: &U16CStr,
        _info: &OperationInfo<'c, 'h, Self>,
        context: &'c Self::Context,
    ) -> OperationResult<()> {
        match context {
            Handle::File(file) => file.sync().map_err(status),
            Handle::Dir => Ok(()),
        }
    }

    fn get_file_information(
        &'h self,
        file_name: &U16CStr,
        _info: &OperationInfo<'c, 'h, Self>,
        context: &'c Self::Context,
    ) -> OperationResult<FileInfo> {
        match context {
            Handle::File(file) => {
                let info = file.with_file(handle_info).map_err(|e| io_status(&e))?;
                Ok(file_info(&info, file.len(), false))
            }
            Handle::Dir => {
                let item = self.existing(file_name)?;
                let size = self.vault.file_len(&item).map_err(status)?;
                let info = open_stored(&item.stored_path)
                    .and_then(|stored| handle_info(&stored))
                    .map_err(|e| io_status(&e))?;
                Ok(file_info(&info, size, item.is_dir))
            }
        }
    }

    fn find_files(
        &'h self,
        file_name: &U16CStr,
        mut fill_find_data: impl FnMut(&FindData) -> FillDataResult,
        _info: &OperationInfo<'c, 'h, Self>,
        _context: &'c Self::Context,
    ) -> OperationResult<()> {
        let item = self.existing(file_name)?;
        for entry in self.vault.list(&item).map_err(status)? {
            let Ok(name) = U16CString::from_str(&entry.name) else {
                continue;
            };
            let metadata = &entry.metadata;
            let found = FindData {
                attributes: visible_attributes(metadata.file_attributes(), entry.is_dir),
                creation_time: system_time(metadata.creation_time()),
                last_access_time: system_time(metadata.last_access_time()),
                last_write_time: system_time(metadata.last_write_time()),
                file_size: entry.len,
                file_name: name,
            };
            match fill_find_data(&found) {
                Ok(()) => {}
                // Windows checked the names already; skip rather than fail
                // the whole folder.
                Err(FillDataError::NameTooLong) => {}
                Err(FillDataError::BufferFull) => return Err(STATUS_BUFFER_OVERFLOW),
            }
        }
        Ok(())
    }

    fn set_file_attributes(
        &'h self,
        file_name: &U16CStr,
        file_attributes: u32,
        _info: &OperationInfo<'c, 'h, Self>,
        context: &'c Self::Context,
    ) -> OperationResult<()> {
        // 0 means "no change".
        if file_attributes == 0 {
            return Ok(());
        }
        match context {
            Handle::File(file) => set_file_attributes(file, file_attributes),
            Handle::Dir => {
                let item = self.existing(file_name)?;
                if item.name.is_empty() {
                    return Ok(());
                }
                set_dir_attributes(&item.stored_path, file_attributes)
            }
        }
    }

    fn set_file_time(
        &'h self,
        file_name: &U16CStr,
        creation_time: FileTimeOperation,
        last_access_time: FileTimeOperation,
        last_write_time: FileTimeOperation,
        _info: &OperationInfo<'c, 'h, Self>,
        context: &'c Self::Context,
    ) -> OperationResult<()> {
        let times = [creation_time, last_access_time, last_write_time].map(time_value);
        match context {
            Handle::File(file) => {
                // Through the handle that writes, or closing it would set
                // the modification time again.
                let set = file.with_writable_file(|stored| {
                    set_basic_info(stored, times[0], times[1], times[2], 0)
                });
                if set.is_ok() {
                    return Ok(());
                }
                let stored = open_for_attributes(&file.path(), false).map_err(|e| io_status(&e))?;
                set_times(&stored, times)
            }
            Handle::Dir => {
                let item = self.existing(file_name)?;
                if item.name.is_empty() {
                    return Ok(());
                }
                let stored =
                    open_for_attributes(&item.stored_path, true).map_err(|e| io_status(&e))?;
                set_times(&stored, times)
            }
        }
    }

    fn delete_file(
        &'h self,
        _file_name: &U16CStr,
        info: &OperationInfo<'c, 'h, Self>,
        context: &'c Self::Context,
    ) -> OperationResult<()> {
        let Handle::File(file) = context else {
            return Err(STATUS_ACCESS_DENIED);
        };
        if info.delete_on_close() {
            let stored = file.with_file(handle_info).map_err(|e| io_status(&e))?;
            if stored.dwFileAttributes & FILE_ATTRIBUTE_READONLY != 0 {
                return Err(STATUS_CANNOT_DELETE);
            }
        }
        // The file is removed in `cleanup`.
        Ok(())
    }

    fn delete_directory(
        &'h self,
        file_name: &U16CStr,
        info: &OperationInfo<'c, 'h, Self>,
        context: &'c Self::Context,
    ) -> OperationResult<()> {
        if !matches!(context, Handle::Dir) {
            return Err(STATUS_INVALID_DEVICE_REQUEST);
        }
        if !info.delete_on_close() {
            return Ok(());
        }
        let item = self.existing(file_name)?;
        if item.name.is_empty() {
            return Err(STATUS_ACCESS_DENIED);
        }
        if !self.vault.is_empty_dir(&item).map_err(status)? {
            return Err(STATUS_DIRECTORY_NOT_EMPTY);
        }
        Ok(())
    }

    fn move_file(
        &'h self,
        file_name: &U16CStr,
        new_file_name: &U16CStr,
        replace_if_existing: bool,
        _info: &OperationInfo<'c, 'h, Self>,
        _context: &'c Self::Context,
    ) -> OperationResult<()> {
        let from = path_of(file_name)?;
        let to = path_of(new_file_name)?;
        if to.starts_with(':') {
            // Renaming a stream: the drive has none.
            return Err(STATUS_NOT_SUPPORTED);
        }
        self.vault
            .rename(&from, &to, replace_if_existing)
            .map(|_| ())
            .map_err(|error| match error {
                Error::NotADirectory => STATUS_OBJECT_PATH_NOT_FOUND,
                other => status(other),
            })
    }

    fn set_end_of_file(
        &'h self,
        _file_name: &U16CStr,
        offset: i64,
        _info: &OperationInfo<'c, 'h, Self>,
        context: &'c Self::Context,
    ) -> OperationResult<()> {
        let Handle::File(file) = context else {
            return Err(STATUS_INVALID_DEVICE_REQUEST);
        };
        let len = u64::try_from(offset).map_err(|_| STATUS_INVALID_PARAMETER)?;
        file.set_len(len).map_err(status)
    }

    fn set_allocation_size(
        &'h self,
        _file_name: &U16CStr,
        alloc_size: i64,
        _info: &OperationInfo<'c, 'h, Self>,
        context: &'c Self::Context,
    ) -> OperationResult<()> {
        let Handle::File(file) = context else {
            return Err(STATUS_INVALID_DEVICE_REQUEST);
        };
        let size = u64::try_from(alloc_size).map_err(|_| STATUS_INVALID_PARAMETER)?;
        // Space is never reserved ahead; a smaller size cuts the file.
        if size < file.len() {
            file.set_len(size).map_err(status)?;
        }
        Ok(())
    }

    fn get_disk_free_space(
        &'h self,
        _info: &OperationInfo<'c, 'h, Self>,
    ) -> OperationResult<DiskSpaceInfo> {
        let (mut available, mut total, mut free) = (0u64, 0u64, 0u64);
        let ok = unsafe {
            GetDiskFreeSpaceExW(
                self.data_dir.as_ptr(),
                &mut available as *mut u64 as *mut _,
                &mut total as *mut u64 as *mut _,
                &mut free as *mut u64 as *mut _,
            )
        };
        if ok == 0 {
            return Err(io_status(&io::Error::last_os_error()));
        }
        Ok(DiskSpaceInfo {
            byte_count: total,
            free_byte_count: free,
            available_byte_count: available,
        })
    }

    fn get_volume_information(
        &'h self,
        _info: &OperationInfo<'c, 'h, Self>,
    ) -> OperationResult<VolumeInfo> {
        Ok(VolumeInfo {
            name: self.label.clone(),
            serial_number: self.serial,
            max_component_length: 255,
            fs_flags: FILE_CASE_PRESERVED_NAMES | FILE_UNICODE_ON_DISK,
            // Some programs only work on drives that say NTFS.
            fs_name: U16CString::from_str("NTFS").expect("no NUL"),
        })
    }

    fn mounted(
        &'h self,
        _mount_point: &U16CStr,
        _info: &OperationInfo<'c, 'h, Self>,
    ) -> OperationResult<()> {
        let _ = self.ready.send(Ok(()));
        Ok(())
    }

    fn unmounted(&'h self, _info: &OperationInfo<'c, 'h, Self>) -> OperationResult<()> {
        Ok(())
    }
}

fn path_of(file_name: &U16CStr) -> OperationResult<String> {
    file_name
        .to_string()
        .map_err(|_| STATUS_OBJECT_NAME_INVALID)
}

/// Errors of finding an item: a missing folder on the way is a missing
/// path, not a missing name.
fn lookup_status(error: Error) -> NTSTATUS {
    match error {
        Error::NotFound | Error::NotADirectory => STATUS_OBJECT_PATH_NOT_FOUND,
        other => status(other),
    }
}

fn status(error: Error) -> NTSTATUS {
    match error {
        Error::NotFound => STATUS_OBJECT_NAME_NOT_FOUND,
        Error::AlreadyExists => STATUS_OBJECT_NAME_COLLISION,
        Error::NotADirectory => STATUS_NOT_A_DIRECTORY,
        Error::IsADirectory => STATUS_FILE_IS_A_DIRECTORY,
        Error::DirectoryNotEmpty => STATUS_DIRECTORY_NOT_EMPTY,
        Error::InvalidName => STATUS_OBJECT_NAME_INVALID,
        Error::NotAllowed => STATUS_ACCESS_DENIED,
        Error::Corrupt(_) => STATUS_FILE_CORRUPT_ERROR,
        Error::Io(error) => io_status(&error),
        _ => STATUS_UNSUCCESSFUL,
    }
}

fn io_status(error: &io::Error) -> NTSTATUS {
    match error.raw_os_error() {
        Some(code) => dokan::map_win32_error_to_ntstatus(code as u32),
        None if error.kind() == io::ErrorKind::InvalidInput => STATUS_INVALID_PARAMETER,
        None => STATUS_UNSUCCESSFUL,
    }
}

fn handle_info(file: &File) -> io::Result<BY_HANDLE_FILE_INFORMATION> {
    let mut info: BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
    if unsafe { GetFileInformationByHandle(file.as_raw_handle() as _, &mut info) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(info)
}

/// Opens a stored folder (or file) only to read its information.
fn open_stored(path: &Path) -> io::Result<File> {
    OpenOptions::new()
        .access_mode(FILE_READ_ATTRIBUTES)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
        .open(path)
}

fn file_info(info: &BY_HANDLE_FILE_INFORMATION, size: u64, is_dir: bool) -> FileInfo {
    let time = |t: winapi::shared::minwindef::FILETIME| {
        system_time(u64::from(t.dwHighDateTime) << 32 | u64::from(t.dwLowDateTime))
    };
    FileInfo {
        attributes: visible_attributes(info.dwFileAttributes, is_dir),
        creation_time: time(info.ftCreationTime),
        last_access_time: time(info.ftLastAccessTime),
        last_write_time: time(info.ftLastWriteTime),
        file_size: size,
        number_of_links: 1,
        file_index: u64::from(info.nFileIndexHigh) << 32 | u64::from(info.nFileIndexLow),
    }
}

/// The attributes the drive shows for a stored item: only those a vault
/// keeps (not, say, "compressed" or "offline" of the stored file).
fn visible_attributes(stored: u32, is_dir: bool) -> u32 {
    let kept = stored & KEPT_ATTRIBUTES;
    if is_dir {
        kept | FILE_ATTRIBUTE_DIRECTORY
    } else if kept == 0 {
        FILE_ATTRIBUTE_NORMAL
    } else {
        kept
    }
}

fn stored_attributes(attributes: u32) -> u32 {
    match attributes & KEPT_ATTRIBUTES {
        // Clears all the others.
        0 => FILE_ATTRIBUTE_NORMAL,
        kept => kept,
    }
}

fn set_file_attributes(file: &ContentFile, attributes: u32) -> OperationResult<()> {
    let value = stored_attributes(attributes);
    if file
        .with_writable_file(|stored| set_basic_info(stored, 0, 0, 0, value))
        .is_ok()
    {
        return Ok(());
    }
    // A read-only file: through a handle that may only change attributes.
    let stored = open_for_attributes(&file.path(), false).map_err(|e| io_status(&e))?;
    set_basic_info(&stored, 0, 0, 0, value).map_err(|e| io_status(&e))
}

fn set_dir_attributes(stored_path: &Path, attributes: u32) -> OperationResult<()> {
    let stored = open_for_attributes(stored_path, true).map_err(|e| io_status(&e))?;
    set_basic_info(&stored, 0, 0, 0, stored_attributes(attributes)).map_err(|e| io_status(&e))
}

/// Sets times through a handle of our own: "stop/resume updating" only
/// applies to the handle that asked, so it is left out.
fn set_times(stored: &File, times: [i64; 3]) -> OperationResult<()> {
    let [created, accessed, written] = times.map(|time| time.max(0));
    set_basic_info(stored, created, accessed, written, 0).map_err(|e| io_status(&e))
}

fn time_value(operation: FileTimeOperation) -> i64 {
    match operation {
        FileTimeOperation::SetTime(time) => file_time(time) as i64,
        FileTimeOperation::DontChange => 0,
        FileTimeOperation::DisableUpdate => -1,
        FileTimeOperation::ResumeUpdate => -2,
    }
}
