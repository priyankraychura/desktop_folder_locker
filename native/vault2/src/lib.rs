//! Cloak drive vaults (format version 2).
//!
//! A drive vault is a folder, `Name.flkd`, that holds `vault.flk` (the
//! header with the key slots, read and written by the app) and a `data`
//! folder with the encrypted tree. Every file and folder is stored on its
//! own, so a mounted vault reads and changes single files without writing
//! any plaintext to the disk. See `docs/DRIVE_VAULT.md` for the format.

pub mod content;
pub mod error;
pub mod keys;
pub mod names;
pub mod platform;
pub mod tree;
pub mod vault;

pub use content::{ContentFile, DEFAULT_BLOCK_SIZE};
pub use error::{Error, Result};
pub use keys::VaultKeys;
pub use platform::Stamp;
pub use vault::{Item, Listing, Vault};
