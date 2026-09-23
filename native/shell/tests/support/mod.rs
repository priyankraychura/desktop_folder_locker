//! Shared by the plug-in's Windows tests.

// Each test uses only some of it.
#![allow(dead_code)]

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::json;
use windows::core::{HSTRING, PWSTR};
use windows::Win32::System::Com::CoTaskMemFree;
use windows::Win32::UI::Shell::Common::ITEMIDLIST;
use windows::Win32::UI::Shell::{
    ILCreateFromPathW, ILFree, IShellItemArray, SHCreateShellItemArrayFromIDLists,
};

/// Files and folders to right-click, and the app's list of items, which
/// the plug-in reads from `%APPDATA%\FolderLocker` (set to point here).
pub struct Place {
    _temp: tempfile::TempDir,
    pub root: PathBuf,
    /// Not in the list.
    pub folder: PathBuf,
    pub file: PathBuf,
    /// Blocked (in the list).
    pub blocked: PathBuf,
    /// A vault file, and a drive vault folder that isn't in the list.
    pub vault: PathBuf,
    pub drive_vault: PathBuf,
}

impl Place {
    pub fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = long_path(temp.path());
        let place = Self {
            folder: root.join("New folder"),
            file: root.join("Report.pdf"),
            blocked: root.join("Music"),
            vault: root.join("Taxes.flk"),
            drive_vault: root.join("Photos.flkd"),
            root,
            _temp: temp,
        };
        for folder in [&place.folder, &place.blocked, &place.drive_vault] {
            fs::create_dir(folder).unwrap();
        }
        for file in [&place.file, &place.vault] {
            fs::write(file, b"").unwrap();
        }

        let data = place.root.join("AppData");
        fs::create_dir_all(data.join("FolderLocker")).unwrap();
        let list = json!({"version": 1, "items": [{
            "id": "1",
            "itemPath": place.blocked,
            "method": "blockAccess",
            "status": "protected",
        }]});
        fs::write(
            data.join("FolderLocker").join("items.json"),
            list.to_string(),
        )
        .unwrap();
        std::env::set_var("APPDATA", &data);
        place
    }
}

/// [path] with long names, as the shell reports it: %TEMP% can be
/// `C:\Users\RUNNER~1\…`.
fn long_path(path: &Path) -> PathBuf {
    let full = fs::canonicalize(path).unwrap();
    let text = full.to_str().unwrap();
    PathBuf::from(text.strip_prefix(r"\\?\").unwrap_or(text))
}

/// A selection in Explorer, as its commands get it.
pub fn selection(paths: &[&Path]) -> IShellItemArray {
    let ids: Vec<*mut ITEMIDLIST> = paths
        .iter()
        .map(|path| unsafe { ILCreateFromPathW(&HSTRING::from(*path)) })
        .collect();
    assert!(ids.iter().all(|id| !id.is_null()), "no such item");
    let list: Vec<*const ITEMIDLIST> = ids.iter().map(|id| id.cast_const()).collect();
    let array = unsafe { SHCreateShellItemArrayFromIDLists(&list) }.unwrap();
    for id in ids {
        unsafe { ILFree(Some(id.cast_const())) };
    }
    array
}

/// Reads and frees a string that COM allocated.
pub fn take_string(value: PWSTR) -> String {
    let text = unsafe { value.to_string() }.unwrap();
    unsafe { CoTaskMemFree(Some(value.0.cast_const().cast())) };
    text
}
