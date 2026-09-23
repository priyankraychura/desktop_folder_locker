//! The lock badge: an icon overlay on items that stay in place while
//! protected (blocked, read-only and hidden ones). Encrypted items need
//! none: their vault has its own icon.

use crate::state::{Items, Method, Role, Settings};

/// Whether [path] gets the lock badge.
pub fn has_badge(path: &str, items: &Items, settings: Settings) -> bool {
    settings.explorer_integration
        && matches!(
            items.find(path),
            Some((item, Role::Item)) if item.protected
                && matches!(
                    item.method,
                    Method::BlockAccess | Method::ReadOnly | Method::HideOnly
                )
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIST: &str = r#"{"items": [
        {"itemPath": "C:\\Docs\\Taxes", "vaultPath": "C:\\Docs\\Taxes.flk",
         "method": "encrypt", "status": "protected"},
        {"itemPath": "C:\\Docs\\Notes", "vaultPath": "C:\\Docs\\Notes.flk",
         "method": "encrypt", "status": "unprotected"},
        {"itemPath": "D:\\Music", "method": "blockAccess", "status": "protected"},
        {"itemPath": "D:\\Games", "method": "readOnly", "status": "protected"},
        {"itemPath": "D:\\Films", "method": "readOnly", "status": "unprotected"},
        {"itemPath": "D:\\Diary.txt", "method": "none", "status": "protected"}
    ]}"#;

    #[test]
    fn protected_items_in_place_get_the_badge() {
        let items = Items::parse(LIST);
        let on = Settings::default();
        assert!(has_badge(r"D:\Music", &items, on));
        assert!(has_badge(r"d:/music/", &items, on));
        assert!(has_badge(r"D:\Games", &items, on));
        assert!(has_badge(r"D:\Diary.txt", &items, on));
        // Unlocked, encrypted (their vault has its own icon), or not listed.
        assert!(!has_badge(r"D:\Films", &items, on));
        assert!(!has_badge(r"C:\Docs\Taxes.flk", &items, on));
        assert!(!has_badge(r"C:\Docs\Notes", &items, on));
        assert!(!has_badge(r"D:\Music\song.mp3", &items, on));
        // Explorer integration is off in the app.
        let off = Settings {
            explorer_integration: false,
        };
        assert!(!has_badge(r"D:\Music", &items, off));
    }
}
