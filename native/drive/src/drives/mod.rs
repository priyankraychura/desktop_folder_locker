//! Mounted vaults.
//!
//! On Windows, each vault is served by Dokany on a thread of its own until
//! it is unmounted. Elsewhere, mounting reports that it's not supported, so
//! the rest of the helper can be developed and tested on any system.

use std::path::PathBuf;

#[cfg(not(windows))]
use serde_json::Value;

#[cfg(not(windows))]
use crate::protocol::Failure;

#[cfg(windows)]
mod handler;
#[cfg(windows)]
mod windows;

#[cfg(windows)]
pub use self::windows::{dokany_status, Drives};

/// What the app needs to mount a vault.
#[cfg_attr(not(windows), allow(dead_code))]
pub struct MountRequest {
    pub vault: PathBuf,
    pub key: String,
    pub label: String,
    pub drive_letter: Option<char>,
    pub read_only: bool,
}

#[cfg(not(windows))]
pub fn dokany_status() -> Value {
    serde_json::json!({"installed": false, "reason": "Drives need Windows"})
}

#[cfg(not(windows))]
pub struct Drives;

#[cfg(not(windows))]
impl Drives {
    pub fn new(_out: std::sync::Arc<crate::protocol::Output>) -> std::sync::Arc<Self> {
        std::sync::Arc::new(Self)
    }

    pub fn mount(&self, _request: MountRequest) -> Result<Value, Failure> {
        Err(Failure::new("unsupported", "Drives need Windows"))
    }

    pub fn unmount(&self, _vault: &std::path::Path) -> Result<Value, Failure> {
        Err(Failure::new("notMounted", "The vault is not mounted"))
    }

    pub fn list(&self) -> Value {
        Value::Array(Vec::new())
    }

    pub fn unmount_all(&self) {}
}
