//! End to end, as in Explorer: the built DLL is registered as an icon
//! overlay the way the installer registers it, and Windows' own overlay
//! code (shell32) loads it and asks it about files and folders.
//!
//! Overlays are registered for the whole machine, so this needs
//! administrator rights, and it runs only when `FLK_SHELL_E2E` is set (CI
//! does both).

#![cfg(windows)]

mod support;

use std::fs;
use std::path::Path;

use cloak_shell::{BADGE_ICON, CLSID_BADGE};
use support::{built_dll, remove_key, set, Place};
use windows::core::{Interface, HSTRING};
use windows::Win32::Foundation::S_OK;
use windows::Win32::System::Com::{
    CoInitializeEx, CoTaskMemFree, IBindCtx, COINIT_APARTMENTTHREADED,
};
use windows::Win32::System::Registry::HKEY_LOCAL_MACHINE;
use windows::Win32::UI::Shell::Common::ITEMIDLIST;
use windows::Win32::UI::Shell::{
    IShellFolder, IShellIconOverlay, IsUserAnAdmin, SHBindToParent, SHParseDisplayName,
};

const CLSID: &str = "{38F771FD-E77E-4105-A560-9E02A7B507D5}";
const CLASS_KEY: &str = r"Software\Classes\CLSID\{38F771FD-E77E-4105-A560-9E02A7B507D5}";
/// Windows uses the first 15 overlays by name, so the installer's name
/// starts with a space.
const OVERLAY_KEY: &str =
    r"Software\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers\ FolderLocker";

#[test]
fn explorer_shows_the_badge_on_protected_items() {
    if std::env::var_os("FLK_SHELL_E2E").is_none() {
        eprintln!("Skipped: set FLK_SHELL_E2E=1 to test the badge in Explorer.");
        return;
    }
    if !unsafe { IsUserAnAdmin() }.as_bool() {
        eprintln!("Skipped: overlays are registered for the machine, as administrator.");
        return;
    }
    assert_eq!(CLSID, format!("{{{CLSID_BADGE:?}}}"));
    let place = Place::new();

    let app = place.root.join("App");
    fs::create_dir(&app).unwrap();
    let dll = app.join("cloak_shell.dll");
    fs::copy(built_dll(), &dll).unwrap();
    let resources = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../windows/runner/resources");
    fs::copy(resources.join(BADGE_ICON), app.join(BADGE_ICON)).unwrap();

    let _registration = Registration::new(&dll);
    unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) }
        .ok()
        .unwrap();

    // Only the plug-in knows that this folder is blocked (it's listed as
    // blocked, nothing more), and that the setting below turns badges off:
    // an overlay that follows both is the badge.
    let badge = overlay_of(&place.blocked);
    assert!(badge.is_some(), "no overlay on the blocked folder");
    eprintln!("The badge is overlay {badge:?}.");
    assert_eq!(overlay_of(&place.folder), None);
    assert_eq!(overlay_of(&place.file), None);

    // Explorer integration turned off in the app: no badges.
    let settings = place.root.join(r"AppData\FolderLocker\settings.json");
    fs::write(settings, r#"{"explorerIntegration": false}"#).unwrap();
    assert_eq!(overlay_of(&place.blocked), None);
}

/// The overlay that Explorer shows on [path], if any.
fn overlay_of(path: &Path) -> Option<i32> {
    let mut id: *mut ITEMIDLIST = std::ptr::null_mut();
    unsafe { SHParseDisplayName(&HSTRING::from(path), None::<&IBindCtx>, &mut id, 0, None) }
        .unwrap();
    let mut child: *mut ITEMIDLIST = std::ptr::null_mut();
    let folder: IShellFolder = unsafe { SHBindToParent(id, Some(&mut child)) }.unwrap();
    let overlays: IShellIconOverlay = folder.cast().unwrap();
    // 0 (OI_DEFAULT) on the way in: answer now rather than later.
    let mut index = 0;
    let result = unsafe {
        (Interface::vtable(&overlays).GetOverlayIndex)(overlays.as_raw(), child, &mut index)
    };
    unsafe { CoTaskMemFree(Some(id.cast_const().cast())) };
    (result == S_OK).then_some(index)
}

/// The overlay's registry entries, as the installer writes them. Removed
/// again when dropped.
struct Registration;

impl Registration {
    fn new(dll: &Path) -> Self {
        // Left over from a run that stopped halfway.
        drop(Self);
        let server = format!(r"{CLASS_KEY}\InprocServer32");
        set(HKEY_LOCAL_MACHINE, &server, "", dll.to_str().unwrap());
        set(HKEY_LOCAL_MACHINE, &server, "ThreadingModel", "Apartment");
        set(HKEY_LOCAL_MACHINE, OVERLAY_KEY, "", CLSID);
        Self
    }
}

impl Drop for Registration {
    fn drop(&mut self) {
        remove_key(HKEY_LOCAL_MACHINE, OVERLAY_KEY);
        remove_key(HKEY_LOCAL_MACHINE, CLASS_KEY);
    }
}
