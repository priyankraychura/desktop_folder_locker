//! The folders Explorer shows, as the app asks for them: a folder that a
//! window opens is listed, through the DLL's export too, and isn't any
//! more once the window is closed.
//!
//! It opens an Explorer window, so it runs only when `FLK_SHELL_E2E` is
//! set (CI does).

#![cfg(windows)]

mod support;

use std::ffi::OsString;
use std::fs;
use std::os::windows::ffi::OsStringExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread::sleep;
use std::time::{Duration, Instant};

use folder_locker_shell::shown::{folder_of, shown_folders};
use support::{built_dll, long_path};
use windows::core::{s, Interface, HSTRING};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED,
};
use windows::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryW};
use windows::Win32::System::Variant::VARIANT;
use windows::Win32::UI::Shell::{IShellWindows, IWebBrowserApp, ShellWindows};

#[test]
fn lists_the_folders_that_explorer_shows() {
    if std::env::var_os("FLK_SHELL_E2E").is_none() {
        eprintln!("Skipped: set FLK_SHELL_E2E=1 to open an Explorer window.");
        return;
    }
    let temp = tempfile::tempdir().unwrap();
    // A comma and a hash, which a folder's URL would get wrong.
    let folder = long_path(temp.path()).join("Taxes, 2024 #1");
    fs::create_dir(&folder).unwrap();
    assert!(!is_shown(&folder));

    // As the app shows a folder it unlocked. This explorer.exe usually
    // hands the window to Explorer's process and ends.
    let mut explorer = Command::new("explorer.exe").arg(&folder).spawn().unwrap();
    std::thread::spawn(move || explorer.wait());
    wait_for("Explorer to show the folder", || is_shown(&folder));
    let exported = exported();
    assert!(
        exported.iter().any(|path| same(path, &folder)),
        "the export lists it too: {exported:?}"
    );

    close(&folder);
    wait_for("its window to close", || !is_shown(&folder));
}

fn is_shown(folder: &Path) -> bool {
    shown_folders()
        .unwrap()
        .iter()
        .any(|path| same(path, folder))
}

fn same(a: &Path, b: &Path) -> bool {
    match (fs::canonicalize(a), fs::canonicalize(b)) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    }
}

/// The folders, from the built DLL's export, called the way the app calls
/// it: once for the size, then with a buffer that's large enough.
fn exported() -> Vec<PathBuf> {
    type ShownFolders = unsafe extern "system" fn(*mut u16, u32) -> i32;
    let module = unsafe { LoadLibraryW(&HSTRING::from(built_dll().as_path())) }.unwrap();
    let export = unsafe { GetProcAddress(module, s!("FolderLockerShownFolders")) }
        .expect("the DLL exports FolderLockerShownFolders");
    let shown_folders: ShownFolders = unsafe { std::mem::transmute(export) };

    let mut buffer = Vec::new();
    loop {
        let size = unsafe { shown_folders(buffer.as_mut_ptr(), buffer.len() as u32) };
        assert!(size >= 0, "error {size:#x}");
        if size as usize <= buffer.len() {
            buffer.truncate(size as usize);
            break;
        }
        buffer = vec![0; size as usize];
    }
    buffer
        .split(|&unit| unit == 0)
        .filter(|path| !path.is_empty())
        .map(|path| PathBuf::from(OsString::from_wide(path)))
        .collect()
}

/// Closes the windows that show [folder], as the user would.
fn close(folder: &Path) {
    unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }
        .ok()
        .unwrap();
    let windows: IShellWindows =
        unsafe { CoCreateInstance(&ShellWindows, None, CLSCTX_ALL) }.unwrap();
    for index in 0..unsafe { windows.Count() }.unwrap() {
        let Ok(window) = (unsafe { windows.Item(&VARIANT::from(index)) }) else {
            continue;
        };
        if folder_of(&window).is_some_and(|path| same(&path, folder)) {
            unsafe { window.cast::<IWebBrowserApp>().unwrap().Quit() }.unwrap();
        }
    }
}

fn wait_for(what: &str, done: impl Fn() -> bool) {
    let start = Instant::now();
    while !done() {
        assert!(
            start.elapsed() < Duration::from_secs(30),
            "timed out waiting for {what}"
        );
        sleep(Duration::from_millis(250));
    }
}
