use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Mutex, MutexGuard, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use dokan::{FileSystemMounter, MountFlags, MountOptions};
use flk_vault2::Vault;
use serde_json::{json, Value};
use widestring::U16CString;
use winapi::um::fileapi::GetLogicalDrives;
use winapi::um::libloaderapi::{LoadLibraryExW, LOAD_LIBRARY_SEARCH_SYSTEM32};
use zeroize::Zeroize;

use super::handler::Handler;
use super::MountRequest;
use crate::header::{VaultHeader, DATA_DIR};
use crate::protocol::{Failure, Output};

/// How long Dokany waits for one file operation before it gives up on the
/// drive.
const OPERATION_TIMEOUT: Duration = Duration::from_secs(60);
const MOUNT_TIMEOUT: Duration = Duration::from_secs(20);
const UNMOUNT_TIMEOUT: Duration = Duration::from_secs(15);

/// Loads Dokany's library, only from System32 (never from next to the
/// helper), and starts it. The helper links it with delay loading, so it
/// runs without Dokany, and this check comes before any Dokany call. Until
/// it succeeds, every call tries again: Dokany may be installed meanwhile.
fn dokany_loaded() -> bool {
    static LOADED: AtomicBool = AtomicBool::new(false);
    static LOADING: Mutex<()> = Mutex::new(());
    if LOADED.load(Ordering::Acquire) {
        return true;
    }
    let _loading = lock(&LOADING);
    if LOADED.load(Ordering::Acquire) {
        return true;
    }
    let name = U16CString::from_str("dokan2.dll").expect("no NUL");
    let module = unsafe {
        LoadLibraryExW(
            name.as_ptr(),
            std::ptr::null_mut(),
            LOAD_LIBRARY_SEARCH_SYSTEM32,
        )
    };
    if module.is_null() {
        return false;
    }
    dokan::init();
    LOADED.store(true, Ordering::Release);
    true
}

pub fn dokany_status() -> Value {
    if !dokany_loaded() {
        return json!({"installed": false, "reason": "Dokany is not installed"});
    }
    let driver = dokan::get_driver_version();
    json!({
        "installed": driver != 0,
        "version": dokan::get_lib_version(),
        "driver": driver,
        "reason": if driver == 0 { "The Dokany driver is not running" } else { "" },
    })
}

/// The mounted vaults, by vault folder.
pub struct Drives {
    out: Arc<Output>,
    mounts: Mutex<HashMap<String, Mount>>,
    /// One mount at a time, so two can't pick the same drive letter.
    mounting: Mutex<()>,
}

struct Mount {
    vault: PathBuf,
    mount_point: String,
    open_files: Arc<AtomicUsize>,
    /// Set once the drive is ready.
    ready: bool,
    thread: Option<JoinHandle<()>>,
}

impl Drives {
    pub fn new(out: Arc<Output>) -> Arc<Self> {
        Arc::new(Self {
            out,
            mounts: Mutex::default(),
            mounting: Mutex::default(),
        })
    }

    /// Mounts a vault and returns once the drive is ready.
    pub fn mount(self: &Arc<Self>, mut request: MountRequest) -> Result<Value, Failure> {
        let result = self.mount_now(&request);
        request.key.zeroize();
        result
    }

    fn mount_now(self: &Arc<Self>, request: &MountRequest) -> Result<Value, Failure> {
        if !dokany_loaded() {
            return Err(Failure::new("dokanyMissing", "Dokany is not installed"));
        }
        let _mounting = lock(&self.mounting);
        let key = vault_key(&request.vault);
        if let Some(mount) = lock(&self.mounts).get(&key) {
            return Err(Failure::new(
                "alreadyMounted",
                format!("The vault is already open as {}", mount.mount_point),
            ));
        }
        let header = VaultHeader::read(&request.vault)?;
        let keys = header.keys(&request.key)?;
        let vault = Vault::open(&request.vault.join(DATA_DIR), keys, header.block_size)?;
        let letter = free_drive_letter(request.drive_letter)
            .ok_or_else(|| Failure::new("noDriveLetter", "No drive letter is free"))?;
        let mount_point = format!("{letter}:\\");

        let (ready_tx, ready_rx) = mpsc::channel();
        let failed_tx = ready_tx.clone();
        let handler = Handler::new(
            vault,
            &request.label,
            serial_number(&header.vault_id),
            ready_tx,
        );
        let open_files = handler.open_files();
        let mut flags = MountFlags::CURRENT_SESSION;
        if request.read_only {
            flags |= MountFlags::WRITE_PROTECT;
        }
        lock(&self.mounts).insert(
            key.clone(),
            Mount {
                vault: request.vault.clone(),
                mount_point: mount_point.clone(),
                open_files: open_files.clone(),
                ready: false,
                thread: None,
            },
        );

        let drives = Arc::clone(self);
        let thread_key = key.clone();
        let thread_mount_point = mount_point.clone();
        let spawned = thread::Builder::new()
            .name(format!("drive {letter}"))
            .spawn(move || {
                if let Err(failure) = serve(&handler, &thread_mount_point, flags) {
                    let _ = failed_tx.send(Err(failure));
                }
                drop(handler);
                drives.ended(&thread_key);
            });
        let thread = match spawned {
            Ok(thread) => thread,
            Err(error) => {
                lock(&self.mounts).remove(&key);
                return Err(Failure::new("mountFailed", error.to_string()));
            }
        };
        let thread = match lock(&self.mounts).get_mut(&key) {
            Some(mount) => {
                mount.thread = Some(thread);
                None
            }
            // It ended already.
            None => Some(thread),
        };

        match ready_rx.recv_timeout(MOUNT_TIMEOUT) {
            Ok(Ok(())) => {
                if let Some(mount) = lock(&self.mounts).get_mut(&key) {
                    mount.ready = true;
                    return Ok(
                        json!({"mountPoint": mount_point, "driveLetter": letter.to_string()}),
                    );
                }
                Err(Failure::new("mountFailed", "The drive closed right away"))
            }
            Ok(Err(failure)) => {
                self.forget(&key, thread);
                Err(failure)
            }
            Err(_) => {
                let _ = unmount_point(&mount_point);
                self.forget(&key, thread);
                Err(Failure::new(
                    "mountFailed",
                    "Dokany did not start the drive in time",
                ))
            }
        }
    }

    /// Removes a mount that failed, and waits for its thread.
    fn forget(&self, key: &str, thread: Option<JoinHandle<()>>) {
        let stored = lock(&self.mounts)
            .remove(key)
            .and_then(|mount| mount.thread);
        if let Some(thread) = thread.or(stored) {
            let _ = thread.join();
        }
    }

    /// Called on the mount's thread when its drive is gone, for any reason.
    fn ended(&self, key: &str) {
        let Some(mount) = lock(&self.mounts).remove(key) else {
            return;
        };
        if mount.ready {
            self.out.send(&json!({
                "event": "unmounted",
                "vault": mount.vault,
                "mountPoint": mount.mount_point,
            }));
        }
    }

    /// Unmounts a vault. Programs that still have files open on the drive
    /// lose access to them.
    pub fn unmount(&self, vault: &Path) -> Result<Value, Failure> {
        let key = vault_key(vault);
        let (mount_point, thread, open_files) = {
            let mut mounts = lock(&self.mounts);
            let mount = mounts
                .get_mut(&key)
                .filter(|mount| mount.ready)
                .ok_or_else(|| Failure::new("notMounted", "The vault is not open as a drive"))?;
            (
                mount.mount_point.clone(),
                mount.thread.take(),
                mount.open_files.load(Ordering::Relaxed),
            )
        };
        // If Dokany refuses, the wait below times out and says so.
        let _ = unmount_point(&mount_point);
        if let Some(thread) = thread {
            let started = Instant::now();
            while !thread.is_finished() && started.elapsed() < UNMOUNT_TIMEOUT {
                thread::sleep(Duration::from_millis(50));
            }
            if !thread.is_finished() {
                if let Some(mount) = lock(&self.mounts).get_mut(&key) {
                    mount.thread = Some(thread);
                }
                return Err(Failure::new(
                    "unmountFailed",
                    "Windows did not close the drive",
                ));
            }
            let _ = thread.join();
        }
        Ok(json!({"mountPoint": mount_point, "openFiles": open_files}))
    }

    pub fn list(&self) -> Value {
        lock(&self.mounts)
            .values()
            .filter(|mount| mount.ready)
            .map(|mount| {
                json!({
                    "vault": mount.vault,
                    "mountPoint": mount.mount_point,
                    "openFiles": mount.open_files.load(Ordering::Relaxed),
                })
            })
            .collect()
    }

    /// Unmounts everything, when the app is gone.
    pub fn unmount_all(&self) {
        let vaults: Vec<PathBuf> = lock(&self.mounts)
            .values()
            .map(|mount| mount.vault.clone())
            .collect();
        for vault in vaults {
            let _ = self.unmount(&vault);
        }
        if dokany_loaded() && lock(&self.mounts).is_empty() {
            dokan::shutdown();
        }
    }
}

/// Serves the drive until it is unmounted.
fn serve(handler: &Handler, mount_point: &str, flags: MountFlags) -> Result<(), Failure> {
    let mount_point = U16CString::from_str(mount_point).expect("no NUL");
    let options = MountOptions {
        flags,
        timeout: OPERATION_TIMEOUT,
        ..Default::default()
    };
    let mut mounter = FileSystemMounter::new(handler, &mount_point, &options);
    let file_system = mounter.mount().map_err(|error| {
        Failure::new(
            "mountFailed",
            format!("Dokany could not open the drive: {error}"),
        )
    })?;
    // Blocks until the drive is unmounted.
    drop(file_system);
    Ok(())
}

/// Asks Dokany to remove the drive; its thread ends once it's gone.
fn unmount_point(mount_point: &str) -> bool {
    let point = U16CString::from_str(mount_point).expect("no NUL");
    dokan::unmount(point)
}

fn free_drive_letter(preferred: Option<char>) -> Option<char> {
    let used = unsafe { GetLogicalDrives() };
    let free = |letter: char| {
        letter.is_ascii_uppercase() && used & (1 << (letter as u32 - 'A' as u32)) == 0
    };
    preferred
        .map(|letter| letter.to_ascii_uppercase())
        .filter(|&letter| free(letter))
        .or_else(|| {
            "VWXYZUTSRQPONMLKJIHGFED"
                .chars()
                .find(|&letter| free(letter))
        })
}

fn serial_number(vault_id: &[u8; 16]) -> u32 {
    u32::from_le_bytes([vault_id[0], vault_id[1], vault_id[2], vault_id[3]])
}

/// The same vault, however the app spells its path.
fn vault_key(vault: &Path) -> String {
    vault
        .to_string_lossy()
        .replace('/', "\\")
        .trim_end_matches('\\')
        .to_lowercase()
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}
