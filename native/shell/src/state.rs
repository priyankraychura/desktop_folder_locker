//! What the app knows about the user's items, from its list
//! (`%APPDATA%\FolderLocker\items.json`, written by
//! `lib/features/items/data`). The app replaces the file in one step, so
//! it's never read half-written.
//!
//! Explorer asks about many files quickly, so the list is read again only
//! when the file changed, and checked for changes at most once a second.

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

    fn role_of(&self, path: &str) -> Option<Role> {
        if self.is_open_drive()
            && self.mount_point.as_deref().map(normalize).as_deref() == Some(path)
        {
            return Some(Role::Drive);
        }
        if let Some(vault) = self.vault_path.as_deref().map(normalize) {
            if vault == path {
                return Some(Role::Vault);
            }
            if self.method == Method::Drive && path == format!("{vault}\\vault.flk") {
                return Some(Role::VaultHeader);
            }
        }
        (self.at_item_path() && normalize(&self.item_path) == path).then_some(Role::Item)
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
        let items = file
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
        Self { items }
    }

    /// The item that [path] belongs to, and how.
    pub fn find(&self, path: &str) -> Option<(&Item, Role)> {
        let path = normalize(path);
        self.items
            .iter()
            .find_map(|item| item.role_of(&path).map(|role| (item, role)))
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
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

/// The app's list, read again when it changes.
pub struct State {
    file: Option<PathBuf>,
    cache: Mutex<Cache>,
}

#[derive(Default)]
struct Cache {
    items: Arc<Items>,
    /// When the file was last looked at.
    checked: Option<Instant>,
    /// Its time and size then.
    stamp: Option<(SystemTime, u64)>,
}

const RECHECK_AFTER: Duration = Duration::from_secs(1);

impl State {
    pub fn new(file: Option<PathBuf>) -> Self {
        Self {
            file,
            cache: Mutex::default(),
        }
    }

    /// For the current user.
    pub fn for_user() -> Self {
        Self::new(data_dir().map(|dir| dir.join("items.json")))
    }

    pub fn items(&self) -> Arc<Items> {
        let mut cache = self.cache.lock().unwrap_or_else(PoisonError::into_inner);
        let now = Instant::now();
        if cache
            .checked
            .is_some_and(|checked| now.duration_since(checked) < RECHECK_AFTER)
        {
            return cache.items.clone();
        }
        cache.checked = Some(now);
        let Some(file) = &self.file else {
            return cache.items.clone();
        };
        let stamp = fs::metadata(file)
            .ok()
            .and_then(|metadata| Some((metadata.modified().ok()?, metadata.len())));
        if stamp.is_some() && stamp == cache.stamp {
            return cache.items.clone();
        }
        cache.stamp = stamp;
        cache.items = Arc::new(
            fs::read_to_string(file)
                .map(|json| Items::parse(&json))
                .unwrap_or_default(),
        );
        cache.items.clone()
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
    fn rereads_the_list_when_it_changes() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("items.json");
        let state = State::new(Some(file.clone()));
        assert!(state.items().is_empty(), "no list yet");

        fs::write(&file, LIST).unwrap();
        // Checked again only after a moment.
        state.cache.lock().unwrap().checked = None;
        assert_eq!(state.items().len(), 3);

        fs::write(&file, r#"{"items": []}"#).unwrap();
        state.cache.lock().unwrap().checked = None;
        assert!(state.items().is_empty());
    }
}
