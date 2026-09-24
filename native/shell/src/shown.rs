//! The folders that Explorer shows, for the app: once no window shows an
//! unlocked folder any more, the app asks whether to lock it again.
//!
//! Every Explorer window, and every tab of one, is a shell window, which
//! shows a folder or a place that isn't on a disk (This PC, a search). The
//! app calls [`CloakShownFolders`] through FFI, away from its UI
//! thread: each question goes to Explorer's process.

use std::ffi::c_void;
use std::os::windows::ffi::OsStrExt;
use std::panic::catch_unwind;
use std::path::PathBuf;

use windows::core::{Interface, Result};
use windows::Win32::Foundation::{E_UNEXPECTED, RPC_E_CHANGED_MODE};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize, IDispatch, IServiceProvider,
    CLSCTX_ALL, COINIT_MULTITHREADED,
};
use windows::Win32::System::Variant::VARIANT;
use windows::Win32::UI::Shell::{
    IFolderView, IPersistFolder2, IShellBrowser, IShellWindows, SHGetNameFromIDList,
    SID_STopLevelBrowser, ShellWindows, SIGDN_FILESYSPATH,
};

/// The folders that Explorer windows and tabs show now. Places that
/// aren't folders on a disk are left out.
pub fn shown_folders() -> Result<Vec<PathBuf>> {
    let _com = Com::enter()?;
    let windows: IShellWindows = unsafe { CoCreateInstance(&ShellWindows, None, CLSCTX_ALL)? };
    let count = unsafe { windows.Count()? };
    Ok((0..count)
        .filter_map(|index| {
            // A window that closed meanwhile is simply missing.
            let window = unsafe { windows.Item(&VARIANT::from(index)) }.ok()?;
            folder_of(&window)
        })
        .collect())
}

/// The folder that one shell window shows, if it's on a disk.
pub fn folder_of(window: &IDispatch) -> Option<PathBuf> {
    unsafe {
        let browser: IShellBrowser = window
            .cast::<IServiceProvider>()
            .ok()?
            .QueryService(&SID_STopLevelBrowser)
            .ok()?;
        let folder: IPersistFolder2 = browser
            .QueryActiveShellView()
            .ok()?
            .cast::<IFolderView>()
            .ok()?
            .GetFolder()
            .ok()?;
        let id = folder.GetCurFolder().ok()?;
        let name = SHGetNameFromIDList(id, SIGDN_FILESYSPATH);
        CoTaskMemFree(Some(id as *const c_void));
        let name = name.ok()?;
        let path = name.to_string();
        CoTaskMemFree(Some(name.0 as *const c_void));
        path.ok().map(PathBuf::from)
    }
}

/// For the app, through FFI: the folders that Explorer shows, as UTF-16
/// paths that each end with a NUL. Writes them into `buffer` if they fit
/// in `capacity` units, and returns how many units they take: with a
/// larger number, the app calls again with a larger buffer. A negative
/// number is an error code (an `HRESULT`).
///
/// # Safety
///
/// `buffer` must point to `capacity` writable units, or be null.
#[no_mangle]
pub unsafe extern "system" fn CloakShownFolders(buffer: *mut u16, capacity: u32) -> i32 {
    let text = match catch_unwind(shown_folders) {
        Ok(Ok(folders)) => encode(&folders),
        Ok(Err(error)) => return error.code().0,
        Err(_) => return E_UNEXPECTED.0,
    };
    let Ok(length) = i32::try_from(text.len()) else {
        return E_UNEXPECTED.0;
    };
    if !buffer.is_null() && text.len() <= capacity as usize {
        unsafe { std::ptr::copy_nonoverlapping(text.as_ptr(), buffer, text.len()) };
    }
    length
}

fn encode(folders: &[PathBuf]) -> Vec<u16> {
    folders
        .iter()
        .flat_map(|folder| folder.as_os_str().encode_wide().chain(Some(0)))
        .collect()
}

/// COM on this thread while it lives.
struct Com {
    entered: bool,
}

impl Com {
    fn enter() -> Result<Self> {
        let result = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
        // The thread already uses COM, single-threaded: that works too.
        if result == RPC_E_CHANGED_MODE {
            return Ok(Self { entered: false });
        }
        result.ok()?;
        Ok(Self { entered: true })
    }
}

impl Drop for Com {
    fn drop(&mut self) {
        if self.entered {
            unsafe { CoUninitialize() };
        }
    }
}
