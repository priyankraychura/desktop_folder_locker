//! Encrypted file and folder names.
//!
//! A name is encrypted deterministically, so the same name in the same
//! folder always gives the same stored name and can be looked up directly:
//!
//! ```text
//! siv    = BLAKE2b-192(key = name-iv key, dir iv ‖ name)
//! stored = base64url(siv ‖ XChaCha20-Poly1305(names key, nonce = siv,
//!                                             name, aad = dir iv))
//! ```
//!
//! Every folder has its own random `dir.iv`, so equal names in different
//! folders look different, and a name moved into another folder no longer
//! decrypts. Stored names longer than [`MAX_ENCODED_LEN`] characters are
//! kept under a short hash (`L…`), with the full name in a `L….name` file
//! next to it, because Windows allows at most 255 characters per name.

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use blake2::digest::consts::{U20, U24};
use blake2::digest::{Digest, Mac};
use blake2::{Blake2b, Blake2bMac};
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{Key, XChaCha20Poly1305, XNonce};

use crate::error::{Error, Result};
use crate::keys::VaultKeys;

/// Length of a folder's random IV (`dir.iv`).
pub const DIR_IV_LEN: usize = 16;

/// File holding a folder's IV. Never collides with a stored name, which
/// is always longer and has no dot.
pub const DIR_IV_FILE: &str = "dir.iv";

/// Longer stored names are kept under a hash.
pub const MAX_ENCODED_LEN: usize = 175;

/// Suffix of the file that holds a long stored name.
pub const SIDECAR_SUFFIX: &str = ".name";

/// File in the top folder that tells whether a key is right.
pub const KEY_CHECK_FILE: &str = "key.check";

const SIV_LEN: usize = 24;
const TAG_LEN: usize = 16;
const LONG_ENTRY_LEN: usize = 28;

pub type DirIv = [u8; DIR_IV_LEN];

/// Encrypts `name` for the folder with IV `dir_iv`.
pub fn encrypt_name(keys: &VaultKeys, dir_iv: &DirIv, name: &str) -> Result<String> {
    check_name(name)?;
    let siv = synthetic_iv(keys, dir_iv, name.as_bytes());
    let cipher = XChaCha20Poly1305::new(Key::from_slice(&keys.names));
    let sealed = cipher
        .encrypt(
            XNonce::from_slice(&siv),
            Payload {
                msg: name.as_bytes(),
                aad: dir_iv,
            },
        )
        .map_err(|_| Error::corrupt("could not encrypt a name"))?;
    let mut raw = Vec::with_capacity(SIV_LEN + sealed.len());
    raw.extend_from_slice(&siv);
    raw.extend_from_slice(&sealed);
    Ok(URL_SAFE_NO_PAD.encode(raw))
}

/// Decrypts a stored name of the folder with IV `dir_iv`.
pub fn decrypt_name(keys: &VaultKeys, dir_iv: &DirIv, encoded: &str) -> Result<String> {
    let raw = URL_SAFE_NO_PAD
        .decode(encoded)
        .map_err(|_| Error::corrupt("invalid stored name"))?;
    if raw.len() <= SIV_LEN + TAG_LEN {
        return Err(Error::corrupt("stored name is too short"));
    }
    let (siv, sealed) = raw.split_at(SIV_LEN);
    let cipher = XChaCha20Poly1305::new(Key::from_slice(&keys.names));
    let plain = cipher
        .decrypt(
            XNonce::from_slice(siv),
            Payload {
                msg: sealed,
                aad: dir_iv,
            },
        )
        .map_err(|_| Error::corrupt("a name was changed or moved"))?;
    // The IV must be the one the name derives, or the name was tampered with.
    if synthetic_iv(keys, dir_iv, &plain)[..] != *siv {
        return Err(Error::corrupt("a name was changed"));
    }
    String::from_utf8(plain).map_err(|_| Error::corrupt("invalid name"))
}

/// The directory entry that stores the name `encoded`.
pub fn entry_name(encoded: &str) -> String {
    if encoded.len() <= MAX_ENCODED_LEN {
        encoded.to_owned()
    } else {
        let hash = Blake2b::<U20>::digest(encoded.as_bytes());
        format!("L{}", URL_SAFE_NO_PAD.encode(hash))
    }
}

/// Whether `entry` stands for a long name (see [`entry_name`]).
pub fn is_long_entry(entry: &str) -> bool {
    entry.len() == LONG_ENTRY_LEN && entry.starts_with('L')
}

/// The file next to a long-name entry that holds its full stored name.
pub fn sidecar_name(entry: &str) -> String {
    format!("{entry}{SIDECAR_SUFFIX}")
}

/// Whether a directory entry is bookkeeping rather than a stored item.
pub fn is_internal_entry(entry: &str) -> bool {
    entry == DIR_IV_FILE || entry == KEY_CHECK_FILE || entry.ends_with(SIDECAR_SUFFIX)
}

/// Case-folds a name like Windows does (one character for one), so that
/// `Report.txt` and `REPORT.TXT` name the same item.
pub fn fold(name: &str) -> String {
    name.chars()
        .map(|c| {
            let mut upper = c.to_uppercase();
            match (upper.next(), upper.next()) {
                (Some(u), None) => u,
                _ => c,
            }
        })
        .collect()
}

/// Rejects names Windows would never pass for one path component.
pub fn check_name(name: &str) -> Result<()> {
    if name.is_empty()
        || name == "."
        || name == ".."
        || name.chars().any(|c| matches!(c, '\\' | '/' | '\0'))
    {
        return Err(Error::InvalidName);
    }
    Ok(())
}

fn synthetic_iv(keys: &VaultKeys, dir_iv: &DirIv, name: &[u8]) -> [u8; SIV_LEN] {
    let mut mac = <Blake2bMac<U24> as Mac>::new_from_slice(&keys.name_iv)
        .expect("a 32-byte key is valid for BLAKE2b");
    mac.update(dir_iv);
    mac.update(name);
    mac.finalize().into_bytes().into()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn keys() -> VaultKeys {
        VaultKeys::derive(&[1; 32], b"vault")
    }

    #[test]
    fn round_trips_and_is_deterministic() {
        let keys = keys();
        let iv = [2; DIR_IV_LEN];
        for name in ["a", "Report 2026.pdf", "ünïcødé ✓ 📁", &"x".repeat(250)] {
            let encoded = encrypt_name(&keys, &iv, name).unwrap();
            assert_eq!(encoded, encrypt_name(&keys, &iv, name).unwrap());
            assert!(!encoded.contains('.'));
            assert_eq!(decrypt_name(&keys, &iv, &encoded).unwrap(), name);
        }
    }

    #[test]
    fn differs_per_folder_and_rejects_moved_names() {
        let keys = keys();
        let a = encrypt_name(&keys, &[1; DIR_IV_LEN], "same").unwrap();
        let b = encrypt_name(&keys, &[2; DIR_IV_LEN], "same").unwrap();
        assert_ne!(a, b);
        assert!(decrypt_name(&keys, &[2; DIR_IV_LEN], &a).is_err());
    }

    #[test]
    fn rejects_tampered_names() {
        let keys = keys();
        let iv = [3; DIR_IV_LEN];
        let encoded = encrypt_name(&keys, &iv, "secret").unwrap();
        let mut raw = URL_SAFE_NO_PAD.decode(&encoded).unwrap();
        let last = raw.len() - 1;
        raw[last] ^= 1;
        assert!(decrypt_name(&keys, &iv, &URL_SAFE_NO_PAD.encode(raw)).is_err());
        assert!(decrypt_name(&keys, &iv, "not base64 !").is_err());
    }

    #[test]
    fn long_names_use_a_short_entry() {
        let keys = keys();
        let iv = [4; DIR_IV_LEN];
        let short = encrypt_name(&keys, &iv, "short").unwrap();
        assert_eq!(entry_name(&short), short);
        assert!(!is_long_entry(&short));

        let long = encrypt_name(&keys, &iv, &"n".repeat(200)).unwrap();
        let entry = entry_name(&long);
        assert!(is_long_entry(&entry));
        assert_eq!(sidecar_name(&entry).len(), entry.len() + 5);
        assert!(is_internal_entry(&sidecar_name(&entry)));
        assert!(is_internal_entry(DIR_IV_FILE));
        assert!(!is_internal_entry(&entry));
    }

    #[test]
    fn folds_case_like_windows() {
        assert_eq!(fold("Report.txt"), fold("REPORT.TXT"));
        assert_eq!(fold("über"), "ÜBER");
        // Characters without a single uppercase form stay as they are.
        assert_eq!(fold("ß"), "ß");
    }

    #[test]
    fn rejects_invalid_names() {
        let keys = keys();
        let iv = [5; DIR_IV_LEN];
        for bad in ["", ".", "..", "a\\b", "a/b"] {
            assert!(encrypt_name(&keys, &iv, bad).is_err(), "{bad:?}");
        }
    }
}
