use hkdf::Hkdf;
use sha2::Sha256;
use zeroize::{Zeroize, ZeroizeOnDrop};

/// Length of every key, in bytes.
pub const KEY_LEN: usize = 32;

/// The keys of an open drive vault, derived from its data key.
///
/// The data key itself is stored (wrapped) in the vault's key slots and
/// unwrapped by the app. Each purpose gets its own key through
/// HKDF-SHA256, with the vault id as salt, like the payload key of `.flk`
/// vaults. The keys are wiped from memory when dropped.
#[derive(Zeroize, ZeroizeOnDrop)]
pub struct VaultKeys {
    pub(crate) content: [u8; KEY_LEN],
    pub(crate) names: [u8; KEY_LEN],
    pub(crate) name_iv: [u8; KEY_LEN],
    /// Stored in the vault to tell a wrong key right away.
    pub(crate) check: [u8; KEY_LEN],
}

impl VaultKeys {
    pub fn derive(data_key: &[u8; KEY_LEN], vault_id: &[u8]) -> Self {
        let hkdf = Hkdf::<Sha256>::new(Some(vault_id), data_key);
        let mut keys = Self {
            content: [0; KEY_LEN],
            names: [0; KEY_LEN],
            name_iv: [0; KEY_LEN],
            check: [0; KEY_LEN],
        };
        for (info, out) in [
            (&b"folder-locker/v2/content"[..], &mut keys.content),
            (&b"folder-locker/v2/names"[..], &mut keys.names),
            (&b"folder-locker/v2/name-iv"[..], &mut keys.name_iv),
            (&b"folder-locker/v2/key-check"[..], &mut keys.check),
        ] {
            hkdf.expand(info, out)
                .expect("32 bytes is a valid HKDF-SHA256 output length");
        }
        keys
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_differ_per_purpose_and_vault() {
        let data_key = [7u8; KEY_LEN];
        let a = VaultKeys::derive(&data_key, b"vault-a");
        let b = VaultKeys::derive(&data_key, b"vault-b");
        assert_ne!(a.content, a.names);
        assert_ne!(a.names, a.name_iv);
        assert_ne!(a.content, b.content);
        let again = VaultKeys::derive(&data_key, b"vault-a");
        assert_eq!(a.content, again.content);
    }
}
