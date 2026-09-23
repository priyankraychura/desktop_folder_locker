//! The parts of `vault.flk` the helper needs.
//!
//! The app reads and writes the key slots. The helper only reads the first
//! 64 bytes, which never change: magic `FLKVAULT`, format version (u16),
//! flags (u16), header size (u32), vault id (16 bytes), block size (u32)
//! and cipher (u8), all little-endian.

use std::fs::File;
use std::io::Read;
use std::path::Path;

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use flk_vault2::VaultKeys;
use zeroize::Zeroizing;

use crate::protocol::Failure;

pub const HEADER_FILE: &str = "vault.flk";
pub const DATA_DIR: &str = "data";

const MAGIC: &[u8; 8] = b"FLKVAULT";
const FORMAT_VERSION: u16 = 2;
const FLAG_DRIVE: u16 = 1;
const HEADER_SIZE: u32 = 4096;
const CIPHER_XCHACHA20_POLY1305: u8 = 1;

pub struct VaultHeader {
    pub vault_id: [u8; 16],
    pub block_size: usize,
}

impl VaultHeader {
    pub fn read(vault: &Path) -> Result<Self, Failure> {
        let mut prefix = [0; 64];
        File::open(vault.join(HEADER_FILE))
            .and_then(|mut file| file.read_exact(&mut prefix))
            .map_err(|error| Failure::new("notAVault", format!("Can't read the vault: {error}")))?;
        Self::parse(&prefix)
    }

    pub fn parse(prefix: &[u8; 64]) -> Result<Self, Failure> {
        if &prefix[..8] != MAGIC {
            return Err(Failure::new(
                "notAVault",
                "This is not a Folder Locker vault",
            ));
        }
        let version = u16::from_le_bytes([prefix[8], prefix[9]]);
        let flags = u16::from_le_bytes([prefix[10], prefix[11]]);
        let header_size = u32::from_le_bytes(prefix[12..16].try_into().expect("4 bytes"));
        if version != FORMAT_VERSION || flags & FLAG_DRIVE == 0 || header_size != HEADER_SIZE {
            return Err(Failure::new(
                "unsupportedVersion",
                "This is not a drive vault, or a newer version of Folder Locker made it",
            ));
        }
        let block_size = u32::from_le_bytes(prefix[32..36].try_into().expect("4 bytes"));
        if prefix[36] != CIPHER_XCHACHA20_POLY1305 {
            return Err(Failure::new(
                "unsupportedVersion",
                "Unsupported vault settings",
            ));
        }
        Ok(Self {
            vault_id: prefix[16..32].try_into().expect("16 bytes"),
            block_size: block_size as usize,
        })
    }

    /// Derives the vault's keys from its data key (base64).
    pub fn keys(&self, key: &str) -> Result<VaultKeys, Failure> {
        let decoded = Zeroizing::new(
            STANDARD
                .decode(key.trim())
                .map_err(|_| Failure::new("badRequest", "The key is not valid base64"))?,
        );
        let data_key: Zeroizing<[u8; 32]> = Zeroizing::new(
            decoded
                .as_slice()
                .try_into()
                .map_err(|_| Failure::new("badRequest", "The key must be 32 bytes"))?,
        );
        Ok(VaultKeys::derive(&data_key, &self.vault_id))
    }
}

#[cfg(test)]
pub fn test_prefix(vault_id: [u8; 16], block_size: u32) -> [u8; 64] {
    let mut prefix = [0; 64];
    prefix[..8].copy_from_slice(MAGIC);
    prefix[8..10].copy_from_slice(&FORMAT_VERSION.to_le_bytes());
    prefix[10..12].copy_from_slice(&FLAG_DRIVE.to_le_bytes());
    prefix[12..16].copy_from_slice(&HEADER_SIZE.to_le_bytes());
    prefix[16..32].copy_from_slice(&vault_id);
    prefix[32..36].copy_from_slice(&block_size.to_le_bytes());
    prefix[36] = CIPHER_XCHACHA20_POLY1305;
    prefix
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_drive_vault_headers_only() {
        let prefix = test_prefix([4; 16], 65536);
        let header = VaultHeader::parse(&prefix).unwrap();
        assert_eq!(header.vault_id, [4; 16]);
        assert_eq!(header.block_size, 65536);

        let mut classic = prefix;
        classic[8] = 1;
        classic[10] = 0;
        assert_eq!(
            VaultHeader::parse(&classic).err().unwrap().code,
            "unsupportedVersion"
        );
        let mut other = prefix;
        other[0] = b'X';
        assert_eq!(VaultHeader::parse(&other).err().unwrap().code, "notAVault");
    }

    #[test]
    fn checks_the_key() {
        let header = VaultHeader::parse(&test_prefix([4; 16], 65536)).unwrap();
        assert!(header.keys(&STANDARD.encode([1u8; 32])).is_ok());
        assert_eq!(header.keys("AAAA").err().unwrap().code, "badRequest");
        assert_eq!(header.keys("not base64!").err().unwrap().code, "badRequest");
    }
}
