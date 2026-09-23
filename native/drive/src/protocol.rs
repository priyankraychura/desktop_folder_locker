//! The messages between the app and the helper: one JSON object per line.
//!
//! ```text
//! app → helper  {"id": 1, "cmd": "mount", "vault": "C:\\Docs\\Taxes.flkd", ...}
//! helper → app  {"id": 1, "ok": true, "result": {"mountPoint": "V:\\"}}
//!               {"id": 1, "ok": false, "error": {"code": "...", "message": "..."}}
//!               {"id": 2, "event": "progress", "phase": "copy", "done": 1, "total": 9}
//!               {"event": "unmounted", "vault": "...", "mountPoint": "V:\\"}
//! ```
//!
//! Requests run at the same time; replies carry the request id. Keys are
//! the vault's data key in base64 (standard alphabet).

use std::io::Write;
use std::path::PathBuf;
use std::sync::{Mutex, PoisonError};

use serde::Deserialize;
use serde_json::{json, Value};

#[derive(Debug, Deserialize)]
pub struct Request {
    pub id: u64,
    #[serde(flatten)]
    pub command: Command,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "cmd", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Command {
    /// Reports the helper version and whether Dokany is installed.
    Hello,
    /// Creates the vault's data from the folder `source`, then compares
    /// the two.
    Import {
        vault: PathBuf,
        key: String,
        source: PathBuf,
    },
    /// Decrypts the vault into the new folder `target`, then compares the
    /// two.
    Export {
        vault: PathBuf,
        key: String,
        target: PathBuf,
    },
    /// Shows the vault as a drive.
    Mount {
        vault: PathBuf,
        key: String,
        label: String,
        /// A drive letter like `V`; a free one is used if it's taken.
        #[serde(default)]
        drive_letter: Option<char>,
        #[serde(default)]
        read_only: bool,
    },
    Unmount {
        vault: PathBuf,
    },
    /// Cancels the import or export with the id `target`.
    Cancel {
        target: u64,
    },
    /// Lists the mounted vaults.
    List,
}

/// A request that failed.
#[derive(Debug)]
pub struct Failure {
    pub code: &'static str,
    pub message: String,
}

impl Failure {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

impl From<flk_vault2::Error> for Failure {
    fn from(error: flk_vault2::Error) -> Self {
        use flk_vault2::Error;
        let code = match &error {
            Error::NotFound => "notFound",
            Error::AlreadyExists => "alreadyExists",
            Error::Corrupt(_) => "corrupt",
            Error::Mismatch(_) => "mismatch",
            Error::Unsupported(_) => "unsupported",
            Error::Cancelled => "cancelled",
            Error::WrongKey => "wrongKey",
            Error::Io(_) => "io",
            _ => "failed",
        };
        Self::new(code, error.to_string())
    }
}

/// Writes messages to stdout, one per line, from any thread.
pub struct Output {
    lock: Mutex<()>,
}

impl Output {
    pub fn new() -> Self {
        Self {
            lock: Mutex::new(()),
        }
    }

    pub fn send(&self, message: &Value) {
        let _guard = self.lock.lock().unwrap_or_else(PoisonError::into_inner);
        let mut out = std::io::stdout().lock();
        // A broken pipe means the app is gone; the helper then stops when
        // stdin closes.
        let _ = serde_json::to_writer(&mut out, message);
        let _ = out.write_all(b"\n");
        let _ = out.flush();
    }

    pub fn reply(&self, id: u64, result: Result<Value, Failure>) {
        self.send(&match result {
            Ok(result) => json!({"id": id, "ok": true, "result": result}),
            Err(failure) => json!({
                "id": id,
                "ok": false,
                "error": {"code": failure.code, "message": failure.message},
            }),
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_requests() {
        let request: Request = serde_json::from_str(
            r#"{"id": 7, "cmd": "mount", "vault": "C:\\v.flkd", "key": "AA==", "label": "Taxes", "driveLetter": "V"}"#,
        )
        .unwrap();
        assert_eq!(request.id, 7);
        match request.command {
            Command::Mount {
                label,
                drive_letter,
                read_only,
                ..
            } => {
                assert_eq!(label, "Taxes");
                assert_eq!(drive_letter, Some('V'));
                assert!(!read_only);
            }
            other => panic!("unexpected {other:?}"),
        }
        let hello: Request = serde_json::from_str(r#"{"id": 1, "cmd": "hello"}"#).unwrap();
        assert!(matches!(hello.command, Command::Hello));
        assert!(serde_json::from_str::<Request>(r#"{"id": 1, "cmd": "format"}"#).is_err());
    }
}
