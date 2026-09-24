//! Which right-click entry an item gets, and what it asks the app to do.
//!
//! One entry at most, whose title follows the item: lock what isn't
//! protected (or is unlocked), unlock what's locked, open drive vaults,
//! lock open drives. The app then does it (`cloak.exe --lock
//! "<path>"`, `--unlock`, `--open`), with its usual dialogs and checks.

use crate::state::{normalize, Item, Items, Method, Role};

/// What the app is asked to do.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verb {
    /// Protect a new item, or lock a listed one again.
    Lock,
    /// Unlock a listed item.
    Unlock,
    /// Open a vault: a `.flk` file or a `.flkd` folder.
    Open,
}

impl Verb {
    pub fn argument(self) -> &'static str {
        match self {
            Self::Lock => "--lock",
            Self::Unlock => "--unlock",
            Self::Open => "--open",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::Lock => "Lock with Cloak",
            Self::Unlock => "Unlock with Cloak",
            Self::Open => "Open with Cloak",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Command {
    pub verb: Verb,
    /// The path the app gets.
    pub target: String,
}

impl Command {
    fn new(verb: Verb, target: &str) -> Option<Self> {
        Some(Self {
            verb,
            target: target.to_owned(),
        })
    }

    /// The command line that starts [app] with it:
    /// `"<app>" --lock "<target>"`.
    pub fn command_line(&self, app: &str) -> String {
        format!(
            "{} {} {}",
            quote(app),
            self.verb.argument(),
            quote(&self.target)
        )
    }
}

/// [text] as one argument, the way the app reads it back
/// (`CommandLineToArgvW`). Paths hold no quotes, so only backslashes
/// before the closing quote need doubling: `V:\` becomes `"V:\\"`.
fn quote(text: &str) -> String {
    let trailing = text.len() - text.trim_end_matches('\\').len();
    format!("\"{text}{}\"", "\\".repeat(trailing))
}

/// The entry for the selected [path] (`None` to show none).
pub fn command_for(path: &str, is_dir: bool, items: &Items) -> Option<Command> {
    if let Some((item, role)) = items.find(path) {
        return listed(item, role, path);
    }
    let name = normalize(path);
    // `.flk` files have "Unlock with Cloak" of their own.
    if name.ends_with(".flk") {
        return None;
    }
    if is_dir && name.ends_with(".flkd") {
        return Command::new(Verb::Open, path);
    }
    // A whole drive can't be locked, nor what's inside a drive vault (its
    // hidden data) or in the Recycle Bin. The app refuses them too.
    let parts: Vec<&str> = name.split('\\').collect();
    let folders = &parts[..parts.len() - 1];
    if is_drive_root(&name)
        || folders
            .iter()
            .any(|folder| folder.ends_with(".flkd") || *folder == "$recycle.bin")
    {
        return None;
    }
    Command::new(Verb::Lock, path)
}

fn listed(item: &Item, role: Role, path: &str) -> Option<Command> {
    match role {
        // The .flk file type already offers this.
        Role::VaultHeader => None,
        Role::Vault if item.method == Method::Encrypt => None,
        // Open drive: close it. Locked: open it.
        Role::Drive | Role::Vault if item.is_open_drive() => {
            Command::new(Verb::Lock, &item.item_path)
        }
        Role::Vault if item.protected => Command::new(Verb::Open, path),
        // A drive decrypted to a folder has no vault left to click.
        Role::Vault | Role::Drive => None,
        Role::Item if item.protected => Command::new(Verb::Unlock, &item.item_path),
        Role::Item => Command::new(Verb::Lock, &item.item_path),
    }
}

/// `c:` (normalized `C:\`).
fn is_drive_root(normalized: &str) -> bool {
    let bytes = normalized.as_bytes();
    bytes.len() == 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':'
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIST: &str = r#"{"items": [
        {"itemPath": "C:\\Docs\\Taxes", "vaultPath": "C:\\Docs\\Taxes.flk",
         "method": "encrypt", "status": "protected"},
        {"itemPath": "C:\\Docs\\Notes", "vaultPath": "C:\\Docs\\Notes.flk",
         "method": "encrypt", "status": "unprotected"},
        {"itemPath": "C:\\Docs\\Photos", "vaultPath": "C:\\Docs\\Photos.flkd",
         "method": "drive", "status": "unprotected", "mountPoint": "V:\\"},
        {"itemPath": "C:\\Docs\\Scans", "vaultPath": "C:\\Docs\\Scans.flkd",
         "method": "drive", "status": "protected"},
        {"itemPath": "D:\\Music", "method": "blockAccess", "status": "protected"},
        {"itemPath": "D:\\Games", "method": "readOnly", "status": "unprotected"}
    ]}"#;

    fn entry(path: &str, is_dir: bool) -> Option<(&'static str, String)> {
        command_for(path, is_dir, &Items::parse(LIST))
            .map(|command| (command.verb.argument(), command.target))
    }

    #[test]
    fn new_items_can_be_locked() {
        assert_eq!(
            entry(r"C:\Docs\Report.pdf", false),
            Some(("--lock", r"C:\Docs\Report.pdf".into()))
        );
        assert_eq!(
            entry(r"C:\Docs\New", true),
            Some(("--lock", r"C:\Docs\New".into()))
        );
        assert_eq!(entry("C:\\", true), None, "not a whole drive");
        assert_eq!(entry("E:", true), None);
        // Not what's inside a drive vault, or in the Recycle Bin.
        assert_eq!(entry(r"E:\Backup\Old.flkd\data", true), None);
        assert_eq!(entry(r"E:\Backup\Old.flkd\desktop.ini", false), None);
        assert_eq!(entry(r"C:\$Recycle.Bin\S-1-5-21\$RABC123", true), None);
        assert_eq!(
            entry(r"C:\Docs\Old.flkd.txt", false),
            Some(("--lock", r"C:\Docs\Old.flkd.txt".into()))
        );
    }

    #[test]
    fn vaults_open() {
        // An unknown drive vault (copied from another PC).
        assert_eq!(
            entry(r"E:\Backup\Old.flkd", true),
            Some(("--open", r"E:\Backup\Old.flkd".into()))
        );
        // .flk files and vault.flk have the file type's own entry.
        assert_eq!(entry(r"E:\Backup\Old.flk", false), None);
        assert_eq!(entry(r"C:\Docs\Taxes.flk", false), None);
        assert_eq!(entry(r"C:\Docs\Scans.flkd\vault.flk", false), None);
        // A locked drive vault in the list.
        assert_eq!(
            entry(r"C:\Docs\Scans.flkd", true),
            Some(("--open", r"C:\Docs\Scans.flkd".into()))
        );
    }

    #[test]
    fn listed_items_follow_their_state() {
        // Unlocked: lock again.
        assert_eq!(
            entry(r"C:\Docs\Notes", true),
            Some(("--lock", r"C:\Docs\Notes".into()))
        );
        assert_eq!(
            entry(r"d:\games", true),
            Some(("--lock", r"D:\Games".into()))
        );
        // Blocked: unlock.
        assert_eq!(
            entry(r"D:\Music", true),
            Some(("--unlock", r"D:\Music".into()))
        );
        // An open drive, from its vault folder or from the drive itself.
        assert_eq!(
            entry("V:\\", true),
            Some(("--lock", r"C:\Docs\Photos".into()))
        );
        assert_eq!(
            entry(r"C:\Docs\Photos.flkd", true),
            Some(("--lock", r"C:\Docs\Photos".into()))
        );
    }

    #[test]
    fn command_lines_keep_each_path_whole() {
        let command = Command {
            verb: Verb::Lock,
            target: r"C:\My Docs\New folder".into(),
        };
        assert_eq!(
            command.command_line(r"C:\Program Files\Cloak\cloak.exe"),
            r#""C:\Program Files\Cloak\cloak.exe" --lock "C:\My Docs\New folder""#
        );
        let root = Command {
            verb: Verb::Unlock,
            target: "V:\\".into(),
        };
        assert_eq!(root.command_line("app.exe"), r#""app.exe" --unlock "V:\\""#);
    }

    #[test]
    fn titles_say_what_happens() {
        assert_eq!(Verb::Lock.title(), "Lock with Cloak");
        assert_eq!(Verb::Unlock.title(), "Unlock with Cloak");
        assert_eq!(Verb::Open.title(), "Open with Cloak");
    }
}
