//! Long requests: turning a folder into a vault (import) and back
//! (export). Both compare the result with the original at the end.

use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use flk_vault2::tree::{self, TreeStats};
use flk_vault2::Vault;
use serde_json::{json, Value};

use crate::header::{VaultHeader, DATA_DIR};
use crate::protocol::{Failure, Output};

/// Cancel flags of the running jobs, by request id.
#[derive(Default)]
pub struct Jobs {
    running: Mutex<HashMap<u64, Arc<AtomicBool>>>,
}

impl Jobs {
    pub fn start(&self, id: u64) -> Arc<AtomicBool> {
        let flag = Arc::new(AtomicBool::new(false));
        self.lock().insert(id, flag.clone());
        flag
    }

    pub fn finish(&self, id: u64) {
        self.lock().remove(&id);
    }

    /// Returns whether a job with that id was running.
    pub fn cancel(&self, id: u64) -> bool {
        match self.lock().get(&id) {
            Some(flag) => {
                flag.store(true, Ordering::Relaxed);
                true
            }
            None => false,
        }
    }

    pub fn cancel_all(&self) {
        for flag in self.lock().values() {
            flag.store(true, Ordering::Relaxed);
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<u64, Arc<AtomicBool>>> {
        self.running.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// Sends progress events, at most a few per second.
struct Reporter<'a> {
    out: &'a Output,
    id: u64,
    phase: &'static str,
    total: u64,
    cancel: &'a AtomicBool,
    last: Option<Instant>,
}

impl<'a> Reporter<'a> {
    fn new(
        out: &'a Output,
        id: u64,
        phase: &'static str,
        total: u64,
        cancel: &'a AtomicBool,
    ) -> Self {
        let mut reporter = Self {
            out,
            id,
            phase,
            total,
            cancel,
            last: None,
        };
        reporter.send(0);
        reporter
    }

    fn report(&mut self, done: u64) -> bool {
        if self.cancel.load(Ordering::Relaxed) {
            return false;
        }
        if self
            .last
            .is_none_or(|last| last.elapsed() >= Duration::from_millis(200))
            || done == self.total
        {
            self.send(done);
        }
        true
    }

    fn send(&mut self, done: u64) {
        self.last = Some(Instant::now());
        self.out.send(&json!({
            "id": self.id,
            "event": "progress",
            "phase": self.phase,
            "done": done,
            "total": self.total,
        }));
    }
}

fn stats_json(stats: TreeStats) -> Value {
    json!({"files": stats.files, "folders": stats.dirs, "bytes": stats.bytes})
}

/// Creates the vault's encrypted data from `source`, and checks it.
pub fn import(
    out: &Output,
    id: u64,
    vault_dir: &Path,
    key: &str,
    source: &Path,
    cancel: &AtomicBool,
) -> Result<Value, Failure> {
    let header = VaultHeader::read(vault_dir)?;
    let keys = header.keys(key)?;
    if !source.is_dir() {
        return Err(Failure::new(
            "notFound",
            format!("{} is not a folder", source.display()),
        ));
    }
    let stats = tree::scan(source)?;
    let vault = Vault::create(&vault_dir.join(DATA_DIR), keys, header.block_size)?;
    let mut copy = Reporter::new(out, id, "copy", stats.bytes, cancel);
    tree::import(&vault, source, &mut |done| copy.report(done))?;
    let mut check = Reporter::new(out, id, "verify", stats.bytes, cancel);
    tree::verify(&vault, source, &mut |done| check.report(done))?;
    Ok(stats_json(stats))
}

/// Decrypts the vault into the new folder `target`, and checks it.
pub fn export(
    out: &Output,
    id: u64,
    vault_dir: &Path,
    key: &str,
    target: &Path,
    cancel: &AtomicBool,
) -> Result<Value, Failure> {
    let header = VaultHeader::read(vault_dir)?;
    let vault = Vault::open(
        &vault_dir.join(DATA_DIR),
        header.keys(key)?,
        header.block_size,
    )?;
    let stats = tree::vault_stats(&vault)?;
    let mut copy = Reporter::new(out, id, "copy", stats.bytes, cancel);
    tree::export(&vault, target, &mut |done| copy.report(done))?;
    let mut check = Reporter::new(out, id, "verify", stats.bytes, cancel);
    tree::verify(&vault, target, &mut |done| check.report(done))?;
    Ok(stats_json(stats))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::header::{test_prefix, HEADER_FILE};
    use base64::engine::general_purpose::STANDARD;
    use base64::Engine;

    #[test]
    fn imports_and_exports_a_folder() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("Taxes");
        std::fs::create_dir_all(source.join("2026")).unwrap();
        std::fs::write(source.join("2026/return.pdf"), vec![1u8; 200_000]).unwrap();
        std::fs::write(source.join("notes.txt"), b"hi").unwrap();
        let vault = temp.path().join("Taxes.flkd");
        std::fs::create_dir(&vault).unwrap();
        std::fs::write(vault.join(HEADER_FILE), test_prefix([9; 16], 65536)).unwrap();
        let key = STANDARD.encode([2u8; 32]);
        let out = Output::new();
        let cancel = AtomicBool::new(false);

        let result = import(&out, 1, &vault, &key, &source, &cancel).unwrap();
        assert_eq!(result["files"], 2);
        assert_eq!(result["bytes"], 200_002);

        let target = temp.path().join("Restored");
        export(&out, 2, &vault, &key, &target, &cancel).unwrap();
        assert_eq!(std::fs::read(target.join("notes.txt")).unwrap(), b"hi");

        let wrong = STANDARD.encode([3u8; 32]);
        let failed = export(&out, 3, &vault, &wrong, &temp.path().join("Wrong"), &cancel);
        assert_eq!(failed.err().unwrap().code, "wrongKey");
        assert!(!temp.path().join("Wrong").exists());

        cancel.store(true, Ordering::Relaxed);
        let cancelled = export(
            &out,
            4,
            &vault,
            &key,
            &temp.path().join("Cancelled"),
            &cancel,
        );
        assert_eq!(cancelled.err().unwrap().code, "cancelled");
    }
}
