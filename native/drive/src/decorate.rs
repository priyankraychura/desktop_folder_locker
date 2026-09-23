//! How a drive vault folder looks in Explorer: the vault icon, a tooltip,
//! and inside only `vault.flk`, with the encrypted data hidden. Opening the
//! folder thus leads straight to the password dialog, on any PC, without
//! the app's Explorer plug-in.
//!
//! It's plain `desktop.ini` folder customization: Explorer reads it from
//! folders with the read-only attribute (which Windows doesn't enforce on
//! folders). The icon is a file in the folder, so it travels with it.

use std::fs;
use std::io;
use std::path::Path;

use crate::header::DATA_DIR;

pub const DESKTOP_INI: &str = "desktop.ini";
pub const ICON_FILE: &str = "folder.ico";

const ICON: &[u8] = include_bytes!("../../../windows/runner/resources/vault_icon.ico");

const DESKTOP_INI_TEXT: &str = "[.ShellClassInfo]\r\n\
     IconResource=folder.ico,0\r\n\
     InfoTip=Encrypted by Folder Locker. Open vault.flk to unlock it.\r\n";

/// Gives the vault folder its look. Doing it again changes nothing.
pub fn decorate(vault: &Path) -> io::Result<()> {
    write_hidden(&vault.join(ICON_FILE), ICON)?;
    write_hidden(&vault.join(DESKTOP_INI), DESKTOP_INI_TEXT.as_bytes())?;
    attributes::add(&vault.join(DATA_DIR), attributes::HIDDEN_SYSTEM)?;
    attributes::add(vault, attributes::READ_ONLY)
}

/// Writes a hidden system file, unless it holds these bytes already.
fn write_hidden(path: &Path, contents: &[u8]) -> io::Result<()> {
    if fs::read(path).is_ok_and(|current| current == contents) {
        return attributes::add(path, attributes::HIDDEN_SYSTEM);
    }
    // Windows refuses to overwrite hidden or system files.
    attributes::clear(path)?;
    fs::write(path, contents)?;
    attributes::add(path, attributes::HIDDEN_SYSTEM)
}

#[cfg(windows)]
mod attributes {
    use std::io;
    use std::path::Path;

    use widestring::U16CString;
    use winapi::um::fileapi::{GetFileAttributesW, SetFileAttributesW, INVALID_FILE_ATTRIBUTES};
    use winapi::um::winnt::{
        FILE_ATTRIBUTE_HIDDEN, FILE_ATTRIBUTE_NORMAL, FILE_ATTRIBUTE_READONLY,
        FILE_ATTRIBUTE_SYSTEM,
    };

    pub const HIDDEN_SYSTEM: u32 = FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM;
    pub const READ_ONLY: u32 = FILE_ATTRIBUTE_READONLY;

    pub fn add(path: &Path, attributes: u32) -> io::Result<()> {
        let name = wide(path)?;
        let current = unsafe { GetFileAttributesW(name.as_ptr()) };
        if current == INVALID_FILE_ATTRIBUTES {
            return Err(io::Error::last_os_error());
        }
        if current & attributes == attributes {
            return Ok(());
        }
        set(&name, current | attributes)
    }

    /// Makes a file plain again, if it exists.
    pub fn clear(path: &Path) -> io::Result<()> {
        let name = wide(path)?;
        let current = unsafe { GetFileAttributesW(name.as_ptr()) };
        if current == INVALID_FILE_ATTRIBUTES {
            return Ok(());
        }
        set(&name, FILE_ATTRIBUTE_NORMAL)
    }

    fn set(name: &U16CString, attributes: u32) -> io::Result<()> {
        if unsafe { SetFileAttributesW(name.as_ptr(), attributes) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    fn wide(path: &Path) -> io::Result<U16CString> {
        U16CString::from_os_str(path.as_os_str())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "path has a NUL"))
    }
}

/// Other systems have no such attributes; the files are still written, so
/// the folder looks the same once it's on Windows.
#[cfg(not(windows))]
mod attributes {
    use std::io;
    use std::path::Path;

    pub const HIDDEN_SYSTEM: u32 = 0;
    pub const READ_ONLY: u32 = 0;

    pub fn add(_path: &Path, _attributes: u32) -> io::Result<()> {
        Ok(())
    }

    pub fn clear(_path: &Path) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_the_look_once() {
        let temp = tempfile::tempdir().unwrap();
        let vault = temp.path().join("Taxes.flkd");
        fs::create_dir_all(vault.join(DATA_DIR)).unwrap();

        decorate(&vault).unwrap();
        let ini = fs::read_to_string(vault.join(DESKTOP_INI)).unwrap();
        assert!(ini.starts_with("[.ShellClassInfo]\r\n"));
        assert!(ini.contains("IconResource=folder.ico,0\r\n"));
        assert_eq!(fs::read(vault.join(ICON_FILE)).unwrap(), ICON);
        // The icon file is a real icon.
        assert_eq!(&ICON[..4], &[0, 0, 1, 0]);

        // Again, with the files already there (hidden on Windows).
        decorate(&vault).unwrap();
        // An older look is replaced.
        attributes::clear(&vault.join(DESKTOP_INI)).unwrap();
        fs::write(vault.join(DESKTOP_INI), "[.ShellClassInfo]\r\n").unwrap();
        decorate(&vault).unwrap();
        assert_eq!(
            fs::read_to_string(vault.join(DESKTOP_INI)).unwrap(),
            DESKTOP_INI_TEXT
        );
    }
}
