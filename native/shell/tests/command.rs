//! The right-click command, made the way Explorer makes it (through the
//! DLL's class factory) and asked about selections, in this process.
//! `explorer.rs` tests it with Explorer's own menu code.

#![cfg(windows)]

mod support;

use std::ffi::c_void;

use folder_locker_shell::{DllCanUnloadNow, DllGetClassObject, CLSID_MENU};
use support::{selection, take_string, Place};
use windows::core::{IUnknown, Interface, Result, GUID, HSTRING};
use windows::Win32::Foundation::{
    CLASS_E_CLASSNOTAVAILABLE, CLASS_E_NOAGGREGATION, E_NOTIMPL, S_FALSE, S_OK,
};
use windows::Win32::System::Com::{
    CoInitializeEx, IBindCtx, IClassFactory, COINIT_APARTMENTTHREADED,
};
use windows::Win32::UI::Shell::{
    IExplorerCommand, IShellItem, IShellItemArray, SHCreateItemFromParsingName,
    SHCreateShellItemArrayFromShellItem, ECF_DEFAULT, ECS_ENABLED, ECS_HIDDEN,
};

/// Explorer's `GetState` and `GetTitle`: the entry's title, if it shows.
fn entry(command: &IExplorerCommand, items: &IShellItemArray) -> Option<String> {
    let state = unsafe { command.GetState(items, false) }.unwrap();
    if state == ECS_HIDDEN.0 as u32 {
        assert!(unsafe { command.GetTitle(items) }.is_err());
        return None;
    }
    assert_eq!(state, ECS_ENABLED.0 as u32);
    Some(take_string(unsafe { command.GetTitle(items) }.unwrap()))
}

fn class_factory(clsid: &GUID) -> Result<IClassFactory> {
    let mut object: *mut c_void = std::ptr::null_mut();
    unsafe { DllGetClassObject(clsid, &IClassFactory::IID, &mut object) }.ok()?;
    Ok(unsafe { IClassFactory::from_raw(object) })
}

#[test]
fn the_entry_follows_each_item() {
    let place = Place::new();
    unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) }
        .ok()
        .unwrap();

    assert_eq!(DllCanUnloadNow(), S_OK, "nothing made yet");
    assert_eq!(
        class_factory(&GUID::zeroed()).unwrap_err().code(),
        CLASS_E_CLASSNOTAVAILABLE
    );
    let factory = class_factory(&CLSID_MENU).unwrap();
    assert_eq!(DllCanUnloadNow(), S_FALSE, "the factory is alive");
    let outer: IUnknown = factory.cast().unwrap();
    assert_eq!(
        unsafe { factory.CreateInstance::<_, IExplorerCommand>(&outer) }
            .unwrap_err()
            .code(),
        CLASS_E_NOAGGREGATION
    );
    drop(outer);
    let command: IExplorerCommand = unsafe { factory.CreateInstance(None::<&IUnknown>) }.unwrap();
    drop(factory);
    assert_eq!(DllCanUnloadNow(), S_FALSE, "the command is alive");

    let lock = Some("Lock with Folder Locker".to_owned());
    assert_eq!(entry(&command, &selection(&[&place.folder])), lock);
    assert_eq!(entry(&command, &selection(&[&place.file])), lock);
    assert_eq!(
        entry(&command, &selection(&[&place.blocked])),
        Some("Unlock with Folder Locker".to_owned())
    );
    assert_eq!(
        entry(&command, &selection(&[&place.drive_vault])),
        Some("Open with Folder Locker".to_owned())
    );
    // The file type has its own entry.
    assert_eq!(entry(&command, &selection(&[&place.vault])), None);
    // One item at a time.
    assert_eq!(
        entry(&command, &selection(&[&place.folder, &place.file])),
        None
    );
    // Not a file or folder: This PC.
    let this_pc: IShellItem = unsafe {
        SHCreateItemFromParsingName(
            &HSTRING::from("::{20D04FE0-3AEA-1069-A2D8-08002B30309D}"),
            None::<&IBindCtx>,
        )
    }
    .unwrap();
    let this_pc: IShellItemArray =
        unsafe { SHCreateShellItemArrayFromShellItem(&this_pc) }.unwrap();
    assert_eq!(entry(&command, &this_pc), None);
    // Nothing selected.
    assert_eq!(
        unsafe { command.GetState(None::<&IShellItemArray>, true) }.unwrap(),
        ECS_HIDDEN.0 as u32
    );
    // Nothing to run for a hidden entry.
    assert!(unsafe { command.Invoke(&selection(&[&place.vault]), None::<&IBindCtx>) }.is_err());

    let items = selection(&[&place.folder]);
    let icon = take_string(unsafe { command.GetIcon(&items) }.unwrap());
    assert!(icon.ends_with(r"\folder_locker.exe,0"), "{icon}");
    assert_eq!(unsafe { command.GetCanonicalName() }.unwrap(), CLSID_MENU);
    assert_eq!(unsafe { command.GetFlags() }.unwrap(), ECF_DEFAULT.0 as u32);
    assert_eq!(
        unsafe { command.GetToolTip(&items) }.unwrap_err().code(),
        E_NOTIMPL
    );

    drop(command);
    assert_eq!(DllCanUnloadNow(), S_OK, "all released");
    let factory = class_factory(&CLSID_MENU).unwrap();
    unsafe { factory.LockServer(true) }.unwrap();
    drop(factory);
    assert_eq!(DllCanUnloadNow(), S_FALSE, "locked");
    let factory = class_factory(&CLSID_MENU).unwrap();
    unsafe { factory.LockServer(false) }.unwrap();
    drop(factory);
    assert_eq!(DllCanUnloadNow(), S_OK, "unlocked");
}
