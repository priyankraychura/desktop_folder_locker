//! End to end, as in Explorer: the built DLL is registered the way the app
//! registers it, and Windows' own right-click menu code (shell32) finds
//! it, loads it, shows its entry and runs it.
//!
//! It rewrites the current user's Cloak entries in the registry,
//! so it runs only when `FLK_SHELL_E2E` is set (CI does). Starting the app
//! writes them again.

#![cfg(windows)]

mod support;

use std::fs;
use std::path::Path;
use std::time::{Duration, Instant};

use cloak_shell::CLSID_MENU;
use support::{built_dll, remove_key, set, Place};
use windows::core::{HSTRING, PCSTR};
use windows::Win32::System::Com::{CoInitializeEx, IBindCtx, COINIT_APARTMENTTHREADED};
use windows::Win32::System::Registry::{HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE};
use windows::Win32::UI::Shell::{
    BHID_SFUIObject, IContextMenu, IShellItem, IsUserAnAdmin, SHCreateItemFromParsingName,
    CMF_NORMAL, CMINVOKECOMMANDINFO, SEE_MASK_FLAG_NO_UI, SEE_MASK_NOASYNC,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CreatePopupMenu, DestroyMenu, GetMenuItemCount, GetMenuItemID, GetMenuStringW, HMENU,
    MF_BYPOSITION, SW_SHOWNORMAL,
};

const CLSID: &str = "{3C1C048E-1C62-4B0B-87AC-55EDAD0E97BB}";
const VERB: &str = "FolderLocker.Lock";
/// Folders, files, and drives (for vaults open as drives).
const TARGETS: [&str; 3] = ["Directory", "*", "Drive"];

#[test]
fn explorer_shows_and_runs_the_entry() {
    if std::env::var_os("FLK_SHELL_E2E").is_none() {
        eprintln!("Skipped: set FLK_SHELL_E2E=1 to test the plug-in in Explorer's menu.");
        return;
    }
    assert_eq!(CLSID, format!("{{{CLSID_MENU:?}}}"));
    let place = Place::new();

    // The app's folder: the DLL, and in place of the app, a program that
    // writes down how it was started.
    let app = place.root.join("App");
    fs::create_dir(&app).unwrap();
    let dll = app.join("cloak_shell.dll");
    fs::copy(built_dll(), &dll).unwrap();
    fs::copy(env!("CARGO_BIN_EXE_flk-record-args"), app.join("cloak.exe")).unwrap();
    let record = place.root.join("started.txt");
    std::env::set_var("FLK_RECORD_ARGS", &record);

    unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) }
        .ok()
        .unwrap();
    let _registration = Registration::new(&dll);

    // A folder that isn't locked: lock it.
    let menu = Menu::of(&place.folder);
    let id = menu.entry("Lock with Cloak");
    menu.run(id);
    let expected = format!("--lock\t{}", place.folder.display());
    assert_eq!(
        started(&record, 1).last().map(String::as_str),
        Some(expected.as_str())
    );

    // A blocked folder: unlock it.
    let menu = Menu::of(&place.blocked);
    let id = menu.entry("Unlock with Cloak");
    menu.run(id);
    let expected = format!("--unlock\t{}", place.blocked.display());
    assert_eq!(
        started(&record, 2).last().map(String::as_str),
        Some(expected.as_str())
    );

    // Files too; not vault files, which have their own entry; not drives
    // that aren't vaults.
    Menu::of(&place.file).entry("Lock with Cloak");
    Menu::of(&place.drive_vault).entry("Open with Cloak");
    Menu::of(&place.vault).no_entry();
    let system = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".into());
    Menu::of(Path::new(&format!("{system}\\"))).no_entry();
}

/// The plug-in's registry entries, as the app writes them for the current
/// user. Removed again when dropped.
struct Registration {
    machine: bool,
}

impl Registration {
    fn new(dll: &Path) -> Self {
        // Left over from a run that stopped halfway.
        Self::remove(true);
        let class = format!(r"Software\Classes\CLSID\{CLSID}\InprocServer32");
        let dll = dll.to_str().unwrap();
        set(HKEY_CURRENT_USER, &class, "", dll);
        set(HKEY_CURRENT_USER, &class, "ThreadingModel", "Apartment");
        for target in TARGETS {
            let verb = format!(r"Software\Classes\{target}\shell\{VERB}");
            set(HKEY_CURRENT_USER, &verb, "ExplorerCommandHandler", CLSID);
        }
        // Elevated processes (like CI's) don't use COM classes registered
        // for the user, so for them it's registered for the machine too.
        let machine = unsafe { IsUserAnAdmin() }.as_bool();
        if machine {
            eprintln!("Elevated: registering the class for the machine too.");
            set(HKEY_LOCAL_MACHINE, &class, "", dll);
            set(HKEY_LOCAL_MACHINE, &class, "ThreadingModel", "Apartment");
        }
        Self { machine }
    }

    fn remove(machine: bool) {
        let class = format!(r"Software\Classes\CLSID\{CLSID}");
        let mut keys = vec![(HKEY_CURRENT_USER, class.clone())];
        if machine {
            keys.push((HKEY_LOCAL_MACHINE, class));
        }
        for target in TARGETS {
            let verb = format!(r"Software\Classes\{target}\shell\{VERB}");
            keys.push((HKEY_CURRENT_USER, verb));
        }
        for (root, key) in keys {
            remove_key(root, &key);
        }
    }
}

impl Drop for Registration {
    fn drop(&mut self) {
        Self::remove(self.machine);
    }
}

/// The right-click menu that Windows builds for an item, as Explorer
/// shows it.
struct Menu {
    handler: IContextMenu,
    popup: HMENU,
    entries: Vec<(String, u32)>,
}

const FIRST_ID: u32 = 1;
const LAST_ID: u32 = 0x7FFF;

impl Menu {
    fn of(path: &Path) -> Self {
        let item: IShellItem =
            unsafe { SHCreateItemFromParsingName(&HSTRING::from(path), None::<&IBindCtx>) }
                .unwrap();
        let handler: IContextMenu =
            unsafe { item.BindToHandler(None::<&IBindCtx>, &BHID_SFUIObject) }.unwrap();
        let popup = unsafe { CreatePopupMenu() }.unwrap();
        unsafe { handler.QueryContextMenu(popup, 0, FIRST_ID, LAST_ID, CMF_NORMAL) }
            .ok()
            .unwrap();
        let entries = (0..unsafe { GetMenuItemCount(Some(popup)) })
            .map(|position| {
                let mut text = [0u16; 512];
                let length = unsafe {
                    GetMenuStringW(popup, position as u32, Some(&mut text), MF_BYPOSITION)
                };
                let title = String::from_utf16_lossy(&text[..length.max(0) as usize]);
                (title, unsafe { GetMenuItemID(popup, position) })
            })
            .collect();
        let menu = Self {
            handler,
            popup,
            entries,
        };
        eprintln!("Menu of {}: {:?}", path.display(), menu.titles());
        menu
    }

    fn titles(&self) -> Vec<&str> {
        self.entries
            .iter()
            .map(|(title, _)| title.as_str())
            .collect()
    }

    /// The id of our one entry, which has [title].
    fn entry(&self, title: &str) -> u32 {
        let ours: Vec<_> = self
            .entries
            .iter()
            .filter(|(text, _)| text.contains("Cloak"))
            .collect();
        assert_eq!(ours.len(), 1, "one entry of ours in {:?}", self.titles());
        assert_eq!(ours[0].0, title);
        ours[0].1
    }

    fn no_entry(&self) {
        assert!(
            !self.titles().iter().any(|text| text.contains("Cloak")),
            "no entry of ours in {:?}",
            self.titles()
        );
    }

    /// Clicks the entry with [id].
    fn run(&self, id: u32) {
        let info = CMINVOKECOMMANDINFO {
            cbSize: size_of::<CMINVOKECOMMANDINFO>() as u32,
            // CMIC_MASK_NOASYNC and CMIC_MASK_FLAG_NO_UI: finish before
            // returning, and show no error dialogs.
            fMask: SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI,
            // MAKEINTRESOURCE: the entry's offset from FIRST_ID.
            lpVerb: PCSTR((id - FIRST_ID) as usize as *const u8),
            nShow: SW_SHOWNORMAL.0,
            ..Default::default()
        };
        unsafe { self.handler.InvokeCommand(&info) }.unwrap();
    }
}

impl Drop for Menu {
    fn drop(&mut self) {
        let _ = unsafe { DestroyMenu(self.popup) };
    }
}

/// The app's starts so far, once there are [count] (or after a while).
fn started(record: &Path, count: usize) -> Vec<String> {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let lines: Vec<String> = fs::read_to_string(record)
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect();
        if lines.len() >= count || Instant::now() > deadline {
            return lines;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}
