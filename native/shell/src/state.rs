//! What the app knows about the user's items and settings, from its files
//! in `%APPDATA%\FolderLocker`: `items.json` (written by
//! `lib/features/items/data`) and `settings.json`. The app replaces each
//! file in one step, so they're never read half-written.
//!
//! Explorer asks about every file it shows, so the files are read again
//! only when they changed. On Windows a change notification on the folder
//! says when; elsewhere (and as a safety net) the files are checked every
//! second at most.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant, SystemTime};

use serde::Deserialize;

/// How an item is protected (the app's `ProtectionMethod`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Method {
    Encrypt,
    Drive,
    BlockAccess,
    ReadOnly,
    HideOnly,
}

#[derive(Clone, Debug)]
pub struct Item {
    pub item_path: String,
    pub vault_path: Option<String>,
    pub method: Method,
    pub protected: bool,
    /// Like `V:\` while a drive item is open.
    pub mount_point: Option<String>,
}

impl Item {
    pub fn is_open_drive(&self) -> bool {
        self.method == Method::Drive && !self.protected && self.mount_point.is_some()
    }

    /// Whether the item is at its own path. Not while it's a vault, or open
    /// as a drive: then its path is free, and may hold something else.
    fn at_item_path(&self) -> bool {
        match self.method {
            Method::Encrypt | Method::Drive => !self.protected && !self.is_open_drive(),
            Method::BlockAccess | Method::ReadOnly | Method::HideOnly => true,
        }
    }

    /// Each path that belongs to the item, normalized, and how.
    fn paths(&self) -> Vec<(String, Role)> {
        let mut paths = Vec::new();
        if let (true, Some(mount_point)) = (self.is_open_drive(), &self.mount_point) {
            paths.push((normalize(mount_point), Role::Drive));
        }
        if let Some(vault) = self.vault_path.as_deref().map(normalize) {
            if self.method == Method::Drive {
                paths.push((format!("{vault}\\vault.flk"), Role::VaultHeader));
            }
            paths.push((vault, Role::Vault));
        }
        if self.at_item_path() {
            paths.push((normalize(&self.item_path), Role::Item));
        }
        paths
    }
}

/// How a path relates to an item.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    /// The item itself (a blocked folder, an unlocked folder…).
    Item,
    /// Its vault: a `.flk` file or a `.flkd` folder.
    Vault,
    /// `vault.flk` inside a `.flkd` folder.
    VaultHeader,
    /// The drive it is open as.
    Drive,
}

#[derive(Default, Debug)]
pub struct Items {
    items: Vec<Item>,
    /// Every path of every item, normalized: the item's index and role.
    paths: HashMap<String, (usize, Role)>,
}

impl Items {
    /// Reads the app's list. Unknown entries are skipped, so an older
    /// plug-in still understands a newer list.
    pub fn parse(json: &str) -> Self {
        #[derive(Deserialize)]
        struct File {
            #[serde(default)]
            items: Vec<serde_json::Value>,
        }
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Stored {
            item_path: String,
            vault_path: Option<String>,
            method: String,
            status: String,
            mount_point: Option<String>,
        }

        let Ok(file) = serde_json::from_str::<File>(json) else {
            return Self::default();
        };
        let items: Vec<Item> = file
            .items
            .into_iter()
            .filter_map(|value| serde_json::from_value::<Stored>(value).ok())
            .filter_map(|stored| {
                let method = match stored.method.as_str() {
                    "encrypt" => Method::Encrypt,
                    "drive" => Method::Drive,
                    "blockAccess" => Method::BlockAccess,
                    "readOnly" => Method::ReadOnly,
                    "none" => Method::HideOnly,
                    _ => return None,
                };
                Some(Item {
                    item_path: stored.item_path,
                    vault_path: stored.vault_path,
                    method,
                    protected: stored.status == "protected",
                    mount_point: stored.mount_point,
                })
            })
            .collect();
        let mut paths = HashMap::new();
        for (index, item) in items.iter().enumerate() {
            for (path, role) in item.paths() {
                // The first item wins if two claim a path.
                paths.entry(path).or_insert((index, role));
            }
        }
        Self { items, paths }
    }

    /// The item that [path] belongs to, and how.
    pub fn find(&self, path: &str) -> Option<(&Item, Role)> {
        let (index, role) = self.paths.get(&normalize(path))?;
        Some((&self.items[*index], *role))
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }
}

/// The app's settings that matter here.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Settings {
    /// "Explorer integration" in the app's settings.
    pub explorer_integration: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            explorer_integration: true,
        }
    }
}

impl Settings {
    pub fn parse(json: &str) -> Self {
        let value: serde_json::Value = serde_json::from_str(json).unwrap_or_default();
        Self {
            explorer_integration: value["explorerIntegration"].as_bool().unwrap_or(true),
        }
    }
}

/// The same path however it's written: `C:\Docs\A`, `c:/docs/a\`.
pub fn normalize(path: &str) -> String {
    path.replace('/', "\\")
        .trim_end_matches('\\')
        .to_lowercase()
}

/// Where the app keeps its files: `%APPDATA%\FolderLocker`.
pub fn data_dir() -> Option<PathBuf> {
    std::env::var_os("APPDATA").map(|appdata| Path::new(&appdata).join("FolderLocker"))
}

/// The app's files, read again when they change.
pub struct State {
    dir: Option<PathBuf>,
    cache: Mutex<Cache>,
}

#[derive(Default)]
struct Cache {
    items: Arc<Items>,
    settings: Settings,
    /// When the files were last looked at.
    checked: Option<Instant>,
    /// Their times and sizes then.
    stamps: [Option<Stamp>; 2],
    watch: Option<watch::Watch>,
}

type Stamp = (SystemTime, u64);

/// Without a change notification, how long a look at the files holds.
const RECHECK_AFTER: Duration = Duration::from_secs(1);
/// With one, in case it missed something (the folder was replaced…).
const RECHECK_WATCHED_AFTER: Duration = Duration::from_secs(10);

const ITEMS_FILE: &str = "items.json";
const SETTINGS_FILE: &str = "settings.json";

impl State {
    pub fn new(dir: Option<PathBuf>) -> Self {
        Self {
            dir,
            cache: Mutex::default(),
        }
    }

    /// For the current user.
    pub fn for_user() -> Self {
        Self::new(data_dir())
    }

    pub fn items(&self) -> Arc<Items> {
        self.fresh(|cache| cache.items.clone())
    }

    pub fn settings(&self) -> Settings {
        self.fresh(|cache| cache.settings)
    }

    /// Both at once.
    pub fn now(&self) -> (Arc<Items>, Settings) {
        self.fresh(|cache| (cache.items.clone(), cache.settings))
    }

    /// Lets go of the change notification and the files read so far. The
    /// next question reads the files again.
    pub fn release(&self) {
        *self.cache.lock().unwrap_or_else(PoisonError::into_inner) = Cache::default();
    }

    fn fresh<T>(&self, read: impl FnOnce(&Cache) -> T) -> T {
        let mut cache = self.cache.lock().unwrap_or_else(PoisonError::into_inner);
        let now = Instant::now();
        let (changed, holds_for) = match &cache.watch {
            Some(watch) => (watch.changed(), RECHECK_WATCHED_AFTER),
            None => (false, RECHECK_AFTER),
        };
        let current = cache
            .checked
            .is_some_and(|checked| now.duration_since(checked) < holds_for);
        if changed || !current {
            cache.checked = Some(now);
            if let Some(dir) = &self.dir {
                reload(&mut cache, dir);
            }
        }
        read(&cache)
    }
}

/// Reads the files that changed since the last look.
fn reload(cache: &mut Cache, dir: &Path) {
    // Watched from now on, before reading: a change while reading is seen
    // next time. The folder may not exist until the app first runs.
    if cache.watch.is_none() {
        cache.watch = watch::Watch::new(dir);
    }
    let read = |name: &str, stamp: &mut Option<Stamp>| -> Option<Option<String>> {
        let file = dir.join(name);
        let now = fs::metadata(&file)
            .ok()
            .and_then(|metadata| Some((metadata.modified().ok()?, metadata.len())));
        if now.is_some() && now == *stamp {
            return None;
        }
        *stamp = now;
        Some(fs::read_to_string(file).ok())
    };
    let [items_stamp, settings_stamp] = &mut cache.stamps;
    if let Some(json) = read(ITEMS_FILE, items_stamp) {
        cache.items = Arc::new(json.map(|json| Items::parse(&json)).unwrap_or_default());
    }
    if let Some(json) = read(SETTINGS_FILE, settings_stamp) {
        cache.settings = json.map(|json| Settings::parse(&json)).unwrap_or_default();
    }
}

/// A change notification on the app's folder (Windows).
#[cfg(windows)]
mod watch {
    use std::path::Path;

    use windows::core::HSTRING;
    use windows::Win32::Foundation::{HANDLE, WAIT_OBJECT_0};
    use windows::Win32::Storage::FileSystem::{
        FindCloseChangeNotification, FindFirstChangeNotificationW, FindNextChangeNotification,
        FILE_NOTIFY_CHANGE_FILE_NAME, FILE_NOTIFY_CHANGE_LAST_WRITE, FILE_NOTIFY_CHANGE_SIZE,
    };
    use windows::Win32::System::Threading::WaitForSingleObject;

    pub struct Watch(HANDLE);

    // The handle is only waited on and re-armed, under the cache's lock.
    unsafe impl Send for Watch {}

    impl Watch {
        pub fn new(dir: &Path) -> Option<Self> {
            let handle = unsafe {
                FindFirstChangeNotificationW(
                    &HSTRING::from(dir),
                    false,
                    FILE_NOTIFY_CHANGE_FILE_NAME
                        | FILE_NOTIFY_CHANGE_LAST_WRITE
                        | FILE_NOTIFY_CHANGE_SIZE,
                )
            }
            .ok()?;
            Some(Self(handle))
        }

        /// Whether something in the folder changed since the last call. It
        /// is armed again before the caller reads the files, so a change
        /// while they read is reported next time.
        pub fn changed(&self) -> bool {
            if unsafe { WaitForSingleObject(self.0, 0) } != WAIT_OBJECT_0 {
                return false;
            }
            let _ = unsafe { FindNextChangeNotification(self.0) };
            true
        }
    }

    impl Drop for Watch {
        fn drop(&mut self) {
            let _ = unsafe { FindCloseChangeNotification(self.0) };
        }
    }
}

/// Elsewhere the files are only checked from time to time.
#[cfg(not(windows))]
mod watch {
    use std::path::Path;

    pub struct Watch;

    impl Watch {
        pub fn new(_dir: &Path) -> Option<Self> {
            None
        }

        pub fn changed(&self) -> bool {
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    pub const LIST: &str = r#"{"version": 1, "items": [
        {"id": "1", "itemPath": "C:\\Docs\\Taxes", "vaultPath": "C:\\Docs\\Taxes.flk",
         "method": "encrypt", "status": "protected"},
        {"id": "2", "itemPath": "C:\\Docs\\Photos", "vaultPath": "C:\\Docs\\Photos.flkd",
         "method": "drive", "status": "unprotected", "mountPoint": "V:\\"},
        {"id": "3", "itemPath": "D:\\Music", "method": "blockAccess", "status": "protected"},
        {"id": "4", "itemPath": "D:\\Games", "method": "teleport", "status": "protected"},
        {"id": "5"}
    ]}"#;

    #[test]
    fn reads_the_list_and_skips_what_it_does_not_know() {
        let items = Items::parse(LIST);
        assert_eq!(items.len(), 3);
        assert!(Items::parse("not json").is_empty());
        assert!(Items::parse("{}").is_empty());
    }

    #[test]
    fn finds_items_by_any_of_their_paths() {
        let items = Items::parse(LIST);
        let role = |path: &str| {
            items
                .find(path)
                .map(|(item, role)| (item.item_path.clone(), role))
        };
        assert_eq!(
            role(r"c:\docs\taxes.FLK"),
            Some((r"C:\Docs\Taxes".into(), Role::Vault))
        );
        // While Taxes is a vault, a new "Taxes" folder is something else.
        assert_eq!(role(r"C:\Docs\Taxes\"), None);
        assert_eq!(role(r"C:\Docs\Photos"), None, "open as a drive");
        assert_eq!(role("V:\\"), Some((r"C:\Docs\Photos".into(), Role::Drive)));
        assert_eq!(role("v:"), Some((r"C:\Docs\Photos".into(), Role::Drive)));
        assert_eq!(
            role(r"C:\Docs\Photos.flkd\vault.flk"),
            Some((r"C:\Docs\Photos".into(), Role::VaultHeader))
        );
        assert_eq!(role("D:/Music"), Some((r"D:\Music".into(), Role::Item)));
        assert_eq!(role(r"C:\Docs"), None);
        assert_eq!(role(r"C:\Docs\Taxes\a.txt"), None);
    }

    #[test]
    fn reads_the_settings() {
        assert!(Settings::parse(r#"{"themeMode": "dark"}"#).explorer_integration);
        assert!(!Settings::parse(r#"{"explorerIntegration": false}"#).explorer_integration);
        assert!(Settings::parse("not json").explorer_integration);
    }

    #[test]
    fn rereads_the_files_when_they_change() {
        let dir = tempfile::tempdir().unwrap();
        let state = State::new(Some(dir.path().to_owned()));
        assert!(state.items().is_empty(), "no list yet");
        assert!(state.settings().explorer_integration);

        fs::write(dir.path().join(ITEMS_FILE), LIST).unwrap();
        fs::write(
            dir.path().join(SETTINGS_FILE),
            r#"{"explorerIntegration": false}"#,
        )
        .unwrap();
        // Seen at once where Windows reports the change, or else after a
        // moment.
        state.cache.lock().unwrap().checked = None;
        assert_eq!(state.items().len(), 3);
        assert!(!state.settings().explorer_integration);

        fs::write(dir.path().join(ITEMS_FILE), r#"{"items": []}"#).unwrap();
        state.cache.lock().unwrap().checked = None;
        assert!(state.items().is_empty());

        // After letting go, everything is read again.
        fs::write(dir.path().join(ITEMS_FILE), LIST).unwrap();
        state.release();
        assert_eq!(state.items().len(), 3);
    }

    #[cfg(windows)]
    #[test]
    fn sees_changes_at_once_on_windows() {
        let dir = tempfile::tempdir().unwrap();
        let state = State::new(Some(dir.path().to_owned()));
        assert!(state.items().is_empty());
        assert!(state.cache.lock().unwrap().watch.is_some());

        // Long before the next look at the files: the change notification
        // tells right away.
        fs::write(dir.path().join(ITEMS_FILE), LIST).unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        while state.items().is_empty() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(state.items().len(), 3);
    }
}
