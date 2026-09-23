//! End to end: the helper imports a folder, mounts it as a drive through
//! Dokany, the drive is used like any other, and after unmounting and
//! mounting again everything is still there, while nothing readable is
//! stored.
//!
//! Needs Windows with Dokany installed; skipped otherwise, unless
//! `FLK_REQUIRE_DOKANY` is set (as in CI), which makes a missing Dokany an
//! error.
#![cfg(windows)]

use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime};

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use serde_json::{json, Value};

struct Helper {
    child: Child,
    stdin: Option<ChildStdin>,
    stdout: BufReader<ChildStdout>,
    next_id: u64,
}

impl Helper {
    fn start() -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_folder_locker_drive"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .expect("the helper starts");
        Self {
            stdin: child.stdin.take(),
            stdout: BufReader::new(child.stdout.take().unwrap()),
            child,
            next_id: 1,
        }
    }

    /// Sends a request and returns its reply, skipping events.
    fn request(&mut self, mut message: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        message["id"] = json!(id);
        let stdin = self.stdin.as_mut().unwrap();
        writeln!(stdin, "{message}").unwrap();
        stdin.flush().unwrap();
        loop {
            let mut line = String::new();
            self.stdout.read_line(&mut line).unwrap();
            assert!(!line.is_empty(), "the helper stopped");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == id && reply.get("event").is_none() {
                return reply;
            }
        }
    }

    fn ok(&mut self, message: Value) -> Value {
        let reply = self.request(message);
        assert_eq!(reply["ok"], true, "{reply}");
        reply["result"].clone()
    }

    fn mount(&mut self, vault: &Path, key: &str) -> PathBuf {
        let result = self.ok(json!({
            "cmd": "mount",
            "vault": vault,
            "key": key,
            "label": "Test vault",
        }));
        PathBuf::from(result["mountPoint"].as_str().unwrap())
    }
}

fn vault_header(vault_id: [u8; 16], block_size: u32) -> Vec<u8> {
    let mut header = vec![0; 4096];
    header[..8].copy_from_slice(b"FLKVAULT");
    header[8..10].copy_from_slice(&2u16.to_le_bytes());
    header[10..12].copy_from_slice(&1u16.to_le_bytes());
    header[12..16].copy_from_slice(&4096u32.to_le_bytes());
    header[16..32].copy_from_slice(&vault_id);
    header[32..36].copy_from_slice(&block_size.to_le_bytes());
    header[36] = 1;
    header
}

/// Unmounts without forcing, giving files that something else (a virus
/// scanner) opened a few seconds to close.
fn unmount_when_free(helper: &mut Helper, vault: &Path) {
    let started = Instant::now();
    loop {
        let reply = helper.request(json!({"cmd": "unmount", "vault": vault}));
        if reply["ok"] == true {
            return;
        }
        assert_eq!(reply["error"]["code"], "inUse", "{reply}");
        assert!(started.elapsed() < Duration::from_secs(20), "{reply}");
        thread::sleep(Duration::from_millis(500));
    }
}

fn wait_until_gone(drive: &Path) {
    let started = Instant::now();
    while drive.exists() && started.elapsed() < Duration::from_secs(10) {
        thread::sleep(Duration::from_millis(100));
    }
    assert!(!drive.exists(), "{} is still there", drive.display());
}

fn all_files(dir: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    for entry in fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            files.extend(all_files(&path));
        } else {
            files.push(path);
        }
    }
    files
}

#[test]
fn mounts_a_vault_as_a_drive() {
    let mut helper = Helper::start();
    let hello = helper.ok(json!({"cmd": "hello"}));
    if hello["dokany"]["installed"] != true {
        assert!(
            std::env::var_os("FLK_REQUIRE_DOKANY").is_none(),
            "Dokany is required: {hello}"
        );
        eprintln!("Dokany is not installed, skipping: {hello}");
        return;
    }

    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("Source");
    fs::create_dir_all(source.join("Docs")).unwrap();
    fs::write(source.join("Docs").join("report.txt"), b"quarterly report").unwrap();
    let big: Vec<u8> = (0..3_000_000u32).map(|i| (i * 7 + i / 13) as u8).collect();
    fs::write(source.join("big.bin"), &big).unwrap();

    let vault = temp.path().join("Source.flkd");
    fs::create_dir(&vault).unwrap();
    fs::write(vault.join("vault.flk"), vault_header([6; 16], 65536)).unwrap();
    let key = STANDARD.encode([7u8; 32]);
    let imported = helper.ok(json!({
        "cmd": "import",
        "vault": vault,
        "key": key,
        "source": source,
    }));
    assert_eq!(imported["files"], 2);

    let drive = helper.mount(&vault, &key);
    let at = |path: &str| drive.join(path);

    // Reading, with names in any case.
    assert_eq!(
        fs::read(at(r"Docs\report.txt")).unwrap(),
        b"quarterly report"
    );
    assert_eq!(
        fs::read(at(r"DOCS\REPORT.TXT")).unwrap(),
        b"quarterly report"
    );
    assert_eq!(fs::read(at("big.bin")).unwrap(), big);
    let mut names: Vec<String> = fs::read_dir(&drive)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    assert_eq!(names, ["Docs", "big.bin"]);
    assert_eq!(fs::metadata(at("big.bin")).unwrap().len(), big.len() as u64);

    // Writing, appending and changing a file in the middle.
    fs::write(at("new.txt"), b"hello").unwrap();
    let mut appending = OpenOptions::new().append(true).open(at("new.txt")).unwrap();
    appending.write_all(b" world").unwrap();
    drop(appending);
    assert_eq!(fs::read(at("new.txt")).unwrap(), b"hello world");

    let mut expected = big.clone();
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .open(at("big.bin"))
        .unwrap();
    file.seek(SeekFrom::Start(1_000_000)).unwrap();
    file.write_all(b"PATCH").unwrap();
    expected[1_000_000..1_000_005].copy_from_slice(b"PATCH");
    file.set_len(2_000_000).unwrap();
    expected.truncate(2_000_000);
    file.seek(SeekFrom::Start(999_998)).unwrap();
    let mut middle = [0; 9];
    file.read_exact(&mut middle).unwrap();
    assert_eq!(&middle, &expected[999_998..1_000_007]);
    drop(file);
    assert_eq!(fs::read(at("big.bin")).unwrap(), expected);

    // Folders, moving and deleting.
    fs::create_dir(at("Folder")).unwrap();
    fs::rename(at("new.txt"), at(r"Folder\renamed.txt")).unwrap();
    fs::rename(at(r"Folder\renamed.txt"), at(r"Folder\Renamed.txt")).unwrap();
    assert!(fs::remove_dir(at("Docs")).is_err(), "not empty");
    fs::remove_file(at(r"Docs\report.txt")).unwrap();
    fs::remove_dir(at("Docs")).unwrap();
    assert!(!at("Docs").exists());

    // Times and attributes.
    let old = SystemTime::UNIX_EPOCH + Duration::from_secs(1_600_000_000);
    File::options()
        .write(true)
        .open(at(r"Folder\Renamed.txt"))
        .unwrap()
        .set_modified(old)
        .unwrap();
    assert_eq!(
        fs::metadata(at(r"Folder\Renamed.txt"))
            .unwrap()
            .modified()
            .unwrap(),
        old
    );
    let mut permissions = fs::metadata(at("big.bin")).unwrap().permissions();
    permissions.set_readonly(true);
    fs::set_permissions(at("big.bin"), permissions).unwrap();
    assert!(OpenOptions::new().write(true).open(at("big.bin")).is_err());

    // Nothing readable is stored.
    for stored in all_files(&vault.join("data")) {
        let name = stored.file_name().unwrap().to_string_lossy().into_owned();
        assert!(!name.contains("big") && !name.contains("Renamed"), "{name}");
        let bytes = fs::read(&stored).unwrap();
        assert!(!bytes.windows(11).any(|w| w == b"hello world"), "{name}");
    }

    // A second mount of the same vault is refused.
    let again = helper.request(json!({"cmd": "mount", "vault": vault, "key": key, "label": "x"}));
    assert_eq!(again["error"]["code"], "alreadyMounted", "{again}");

    // A file open in a program keeps the drive open.
    let open = File::open(at("big.bin")).unwrap();
    let busy = helper.request(json!({"cmd": "unmount", "vault": vault}));
    assert_eq!(busy["error"]["code"], "inUse", "{busy}");
    drop(open);
    unmount_when_free(&mut helper, &vault);
    wait_until_gone(&drive);

    // Another key is refused.
    let wrong = helper.request(json!({
        "cmd": "mount",
        "vault": vault,
        "key": STANDARD.encode([8u8; 32]),
        "label": "x",
    }));
    assert_eq!(wrong["error"]["code"], "wrongKey", "{wrong}");

    // Everything is still there after mounting again.
    let drive = helper.mount(&vault, &key);
    let at = |path: &str| drive.join(path);
    assert_eq!(fs::read(at(r"folder\renamed.txt")).unwrap(), b"hello world");
    let names: Vec<String> = fs::read_dir(at("Folder"))
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    assert_eq!(names, ["Renamed.txt"]);
    assert_eq!(
        fs::metadata(at(r"Folder\Renamed.txt"))
            .unwrap()
            .modified()
            .unwrap(),
        old
    );
    assert_eq!(fs::read(at("big.bin")).unwrap(), expected);
    let mut permissions = fs::metadata(at("big.bin")).unwrap().permissions();
    assert!(permissions.readonly());
    #[allow(clippy::permissions_set_readonly_false)]
    permissions.set_readonly(false);
    fs::set_permissions(at("big.bin"), permissions).unwrap();
    assert!(!at("Docs").exists());

    // Forced, the drive closes even with a file open.
    let open = File::open(at("big.bin")).unwrap();
    helper.ok(json!({"cmd": "unmount", "vault": vault, "force": true}));
    wait_until_gone(&drive);
    drop(open);

    let drive = helper.mount(&vault, &key);
    let listed = helper.ok(json!({"cmd": "list"}));
    assert_eq!(listed["mounts"].as_array().unwrap().len(), 1);

    // When the app goes away, the helper unmounts everything and stops.
    drop(helper.stdin.take());
    let status = helper.child.wait().unwrap();
    assert!(status.success());
    wait_until_gone(&drive);

    // Turning the vault back into a folder gives the same files.
    let mut helper = Helper::start();
    let target = temp.path().join("Restored");
    helper.ok(json!({"cmd": "export", "vault": vault, "key": key, "target": target}));
    assert_eq!(
        fs::read(target.join("Folder").join("Renamed.txt")).unwrap(),
        b"hello world"
    );
    assert_eq!(fs::read(target.join("big.bin")).unwrap(), expected);
}
