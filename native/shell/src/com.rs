//! The COM server that Explorer loads: the class factory, the right-click
//! command and the lock badge.
//!
//! Explorer calls in on its own threads, so every entry point turns
//! errors and panics into an error code: a problem here must never take
//! Explorer down.

use std::ffi::c_void;
use std::os::windows::ffi::OsStrExt;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::atomic::{AtomicIsize, AtomicPtr, AtomicUsize, Ordering};
use std::sync::OnceLock;

use windows::core::{
    implement, Error, IUnknown, Interface, Ref, Result, BOOL, GUID, HRESULT, HSTRING, PCWSTR, PWSTR,
};
use windows::Win32::Foundation::{
    CloseHandle, CLASS_E_CLASSNOTAVAILABLE, CLASS_E_NOAGGREGATION, E_FAIL, E_NOTIMPL,
    E_OUTOFMEMORY, E_POINTER, E_UNEXPECTED, HINSTANCE, HMODULE, S_FALSE, S_OK,
};
use windows::Win32::System::Com::{
    CoTaskMemAlloc, CoTaskMemFree, IBindCtx, IClassFactory, IClassFactory_Impl,
};
use windows::Win32::System::LibraryLoader::GetModuleFileNameW;
use windows::Win32::System::SystemServices::DLL_PROCESS_ATTACH;
use windows::Win32::System::Threading::{
    CreateProcessW, CREATE_DEFAULT_ERROR_MODE, PROCESS_INFORMATION, STARTUPINFOW,
};
use windows::Win32::UI::Shell::{
    IEnumExplorerCommand, IExplorerCommand, IExplorerCommand_Impl, IShellIconOverlayIdentifier,
    IShellIconOverlayIdentifier_Impl, IShellItemArray, ECF_DEFAULT, ECS_ENABLED, ECS_HIDDEN,
    ISIOI_ICONFILE, ISIOI_ICONINDEX, SIGDN_FILESYSPATH,
};

use crate::badge::has_badge;
use crate::menu::{command_for, Command};
use crate::state::State;

/// The right-click command, `{3C1C048E-1C62-4B0B-87AC-55EDAD0E97BB}`.
pub const CLSID_MENU: GUID = GUID::from_u128(0x3c1c048e_1c62_4b0b_87ac_55edad0e97bb);
/// The same command for Windows 11's first menu level, which comes from a
/// package (`installer/sparse`): `{70A5D511-629B-4DF6-81E3-48CBA421BF7E}`.
/// Its own id, so the package and the per-user entry never stand in for
/// each other.
pub const CLSID_MENU_PACKAGED: GUID = GUID::from_u128(0x70a5d511_629b_4df6_81e3_48cba421bf7e);
/// The lock badge, `{38F771FD-E77E-4105-A560-9E02A7B507D5}`.
pub const CLSID_BADGE: GUID = GUID::from_u128(0x38f771fd_e77e_4105_a560_9e02a7b507d5);

/// The badge's icon, next to this DLL.
pub const BADGE_ICON: &str = "lock_badge.ico";

/// This DLL, to find the app next to it.
static MODULE: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

/// Live objects and `LockServer` calls: the DLL stays loaded while any.
static OBJECTS: AtomicUsize = AtomicUsize::new(0);
static LOCKS: AtomicIsize = AtomicIsize::new(0);

/// The user's items, shared by all objects.
fn state() -> &'static State {
    static STATE: OnceLock<State> = OnceLock::new();
    STATE.get_or_init(State::for_user)
}

#[no_mangle]
extern "system" fn DllMain(module: HINSTANCE, reason: u32, _reserved: *mut c_void) -> BOOL {
    if reason == DLL_PROCESS_ATTACH {
        MODULE.store(module.0, Ordering::Relaxed);
    }
    true.into()
}

/// # Safety
///
/// Called by COM with valid pointers (checked for null anyway).
#[no_mangle]
pub unsafe extern "system" fn DllGetClassObject(
    clsid: *const GUID,
    iid: *const GUID,
    object: *mut *mut c_void,
) -> HRESULT {
    catch_unwind(AssertUnwindSafe(|| {
        if clsid.is_null() || iid.is_null() || object.is_null() {
            return E_POINTER;
        }
        unsafe { *object = std::ptr::null_mut() };
        let clsid = unsafe { *clsid };
        if ![CLSID_MENU, CLSID_MENU_PACKAGED, CLSID_BADGE].contains(&clsid) {
            return CLASS_E_CLASSNOTAVAILABLE;
        }
        let factory: IClassFactory = Factory {
            clsid,
            _live: Live::new(),
        }
        .into();
        unsafe { factory.query(iid, object) }
    }))
    .unwrap_or(E_UNEXPECTED)
}

#[no_mangle]
pub extern "system" fn DllCanUnloadNow() -> HRESULT {
    if OBJECTS.load(Ordering::SeqCst) == 0 && LOCKS.load(Ordering::SeqCst) <= 0 {
        S_OK
    } else {
        S_FALSE
    }
}

/// Turns a panic into an error code instead of unwinding into Explorer.
fn guard<T>(work: impl FnOnce() -> Result<T>) -> Result<T> {
    catch_unwind(AssertUnwindSafe(work)).unwrap_or_else(|_| Err(E_UNEXPECTED.into()))
}

/// Counts a live object (see [`DllCanUnloadNow`]).
struct Live;

impl Live {
    fn new() -> Self {
        OBJECTS.fetch_add(1, Ordering::SeqCst);
        Self
    }
}

impl Drop for Live {
    fn drop(&mut self) {
        OBJECTS.fetch_sub(1, Ordering::SeqCst);
    }
}

#[implement(IClassFactory)]
struct Factory {
    clsid: GUID,
    _live: Live,
}

impl IClassFactory_Impl for Factory_Impl {
    fn CreateInstance(
        &self,
        outer: Ref<IUnknown>,
        iid: *const GUID,
        object: *mut *mut c_void,
    ) -> Result<()> {
        guard(|| {
            if object.is_null() {
                return Err(E_POINTER.into());
            }
            unsafe { *object = std::ptr::null_mut() };
            if !outer.is_null() {
                return Err(CLASS_E_NOAGGREGATION.into());
            }
            let created: IUnknown = match self.clsid {
                CLSID_MENU | CLSID_MENU_PACKAGED => MenuCommand { _live: Live::new() }.into(),
                CLSID_BADGE => Badge { _live: Live::new() }.into(),
                _ => return Err(CLASS_E_CLASSNOTAVAILABLE.into()),
            };
            unsafe { created.query(iid, object).ok() }
        })
    }

    fn LockServer(&self, lock: BOOL) -> Result<()> {
        if lock.as_bool() {
            LOCKS.fetch_add(1, Ordering::SeqCst);
        } else {
            LOCKS.fetch_sub(1, Ordering::SeqCst);
        }
        Ok(())
    }
}

/// The right-click entry (see [`crate::menu`]).
#[implement(IExplorerCommand)]
pub struct MenuCommand {
    _live: Live,
}

impl IExplorerCommand_Impl for MenuCommand_Impl {
    fn GetTitle(&self, items: Ref<IShellItemArray>) -> Result<PWSTR> {
        guard(|| {
            let command = selected_command(items)?.ok_or_else(|| Error::from(E_FAIL))?;
            co_string(command.verb.title())
        })
    }

    fn GetIcon(&self, _items: Ref<IShellItemArray>) -> Result<PWSTR> {
        guard(|| co_string(&format!("{},0", app_path()?.display())))
    }

    fn GetToolTip(&self, _items: Ref<IShellItemArray>) -> Result<PWSTR> {
        Err(E_NOTIMPL.into())
    }

    fn GetCanonicalName(&self) -> Result<GUID> {
        Ok(CLSID_MENU)
    }

    fn GetState(&self, items: Ref<IShellItemArray>, _ok_to_be_slow: BOOL) -> Result<u32> {
        guard(|| {
            let state = match selected_command(items)? {
                Some(_) => ECS_ENABLED,
                None => ECS_HIDDEN,
            };
            Ok(state.0 as u32)
        })
    }

    fn Invoke(&self, items: Ref<IShellItemArray>, _bind: Ref<IBindCtx>) -> Result<()> {
        guard(|| {
            let command = selected_command(items)?.ok_or_else(|| Error::from(E_FAIL))?;
            start_app(&command)
        })
    }

    fn GetFlags(&self) -> Result<u32> {
        Ok(ECF_DEFAULT.0 as u32)
    }

    fn EnumSubCommands(&self) -> Result<IEnumExplorerCommand> {
        Err(E_NOTIMPL.into())
    }
}

/// The lock badge (see [`crate::badge`]). Explorer asks about every file
/// it shows, so this has to be quick: the answer comes from memory.
#[implement(IShellIconOverlayIdentifier)]
pub struct Badge {
    _live: Live,
}

impl IShellIconOverlayIdentifier_Impl for Badge_Impl {
    fn IsMemberOf(&self, path: &PCWSTR, _attributes: u32) -> Result<()> {
        guard(|| {
            let no = || Error::from_hresult(S_FALSE);
            if path.is_null() {
                return Err(no());
            }
            let path = unsafe { path.to_string() }.map_err(|_| no())?;
            let (items, settings) = state().now();
            if has_badge(&path, &items, settings) {
                Ok(())
            } else {
                Err(no())
            }
        })
    }

    fn GetOverlayInfo(
        &self,
        file: PWSTR,
        capacity: i32,
        index: *mut i32,
        flags: *mut u32,
    ) -> Result<()> {
        guard(|| {
            if file.is_null() || index.is_null() || flags.is_null() {
                return Err(E_POINTER.into());
            }
            let icon = module_path()?.with_file_name(BADGE_ICON);
            let icon: Vec<u16> = icon.as_os_str().encode_wide().chain(Some(0)).collect();
            if icon.len() > usize::try_from(capacity).unwrap_or(0) {
                return Err(E_FAIL.into());
            }
            unsafe {
                std::ptr::copy_nonoverlapping(icon.as_ptr(), file.0, icon.len());
                *index = 0;
                *flags = ISIOI_ICONFILE | ISIOI_ICONINDEX;
            }
            Ok(())
        })
    }

    /// The highest: on a protected item, being locked matters most.
    fn GetPriority(&self) -> Result<i32> {
        Ok(0)
    }
}

/// The entry for the selection: only single file system items get one.
fn selected_command(items: Ref<IShellItemArray>) -> Result<Option<Command>> {
    let Some(items) = items.as_ref() else {
        return Ok(None);
    };
    if unsafe { items.GetCount()? } != 1 {
        return Ok(None);
    }
    let item = unsafe { items.GetItemAt(0)? };
    // Not a file or folder (like This PC): no entry.
    let Ok(name) = (unsafe { item.GetDisplayName(SIGDN_FILESYSPATH) }) else {
        return Ok(None);
    };
    let path = unsafe { take_string(name) };
    let is_dir = std::fs::metadata(&path).is_ok_and(|metadata| metadata.is_dir());
    Ok(command_for(&path, is_dir, &state().items()))
}

/// Starts the app, next to this DLL, with the command. It inherits none
/// of Explorer's handles (`std::process::Command` would pass on every
/// inheritable one).
fn start_app(command: &Command) -> Result<()> {
    let app = app_path()?;
    let line = command.command_line(&app.to_string_lossy());
    let mut line: Vec<u16> = line.encode_utf16().chain(Some(0)).collect();
    let startup = STARTUPINFOW {
        cb: size_of::<STARTUPINFOW>() as u32,
        ..Default::default()
    };
    let mut process = PROCESS_INFORMATION::default();
    unsafe {
        CreateProcessW(
            &HSTRING::from(app.as_os_str()),
            Some(PWSTR(line.as_mut_ptr())),
            None,
            None,
            false,
            CREATE_DEFAULT_ERROR_MODE,
            None,
            None,
            &startup,
            &mut process,
        )?;
        let _ = CloseHandle(process.hThread);
        let _ = CloseHandle(process.hProcess);
    }
    Ok(())
}

/// `folder_locker.exe` next to this DLL.
fn app_path() -> Result<PathBuf> {
    Ok(module_path()?.with_file_name("folder_locker.exe"))
}

/// This DLL's own path.
fn module_path() -> Result<PathBuf> {
    let module = HMODULE(MODULE.load(Ordering::Relaxed));
    let mut buffer = vec![0u16; 32_768];
    let length = unsafe { GetModuleFileNameW(Some(module), &mut buffer) } as usize;
    if length == 0 || length >= buffer.len() {
        return Err(E_FAIL.into());
    }
    Ok(PathBuf::from(String::from_utf16_lossy(&buffer[..length])))
}

/// A copy of [text] that COM frees (`CoTaskMemFree`).
fn co_string(text: &str) -> Result<PWSTR> {
    let wide: Vec<u16> = text.encode_utf16().chain(Some(0)).collect();
    let memory = unsafe { CoTaskMemAlloc(wide.len() * 2) }.cast::<u16>();
    if memory.is_null() {
        return Err(E_OUTOFMEMORY.into());
    }
    unsafe { std::ptr::copy_nonoverlapping(wide.as_ptr(), memory, wide.len()) };
    Ok(PWSTR(memory))
}

/// Reads and frees a string COM allocated.
unsafe fn take_string(value: PWSTR) -> String {
    let text = unsafe { value.to_string() }.unwrap_or_default();
    unsafe { CoTaskMemFree(Some(value.0.cast_const().cast())) };
    text
}
