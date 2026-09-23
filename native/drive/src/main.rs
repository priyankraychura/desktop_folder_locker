//! `folder_locker_drive`: the helper that opens drive vaults for the
//! Folder Locker app.
//!
//! The app starts it and talks to it over stdin and stdout (see
//! [`protocol`]). When stdin closes (the app quit or crashed), every drive
//! is unmounted and the helper exits, so no vault stays open by accident.

// Release builds are started by the app with pipes and need no console.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod drives;
mod header;
mod jobs;
mod protocol;

use std::io::BufRead;
use std::sync::Arc;
use std::thread;

use serde_json::{json, Value};
use zeroize::Zeroize;

use drives::{Drives, MountRequest};
use jobs::Jobs;
use protocol::{Command, Failure, Output, Request};

struct Helper {
    out: Arc<Output>,
    jobs: Jobs,
    drives: Arc<Drives>,
}

fn main() {
    let out = Arc::new(Output::new());
    let helper = Arc::new(Helper {
        drives: Drives::new(out.clone()),
        jobs: Jobs::default(),
        out,
    });
    let stdin = std::io::stdin();
    for line in stdin.lock().lines() {
        let Ok(mut line) = line else {
            break;
        };
        if !line.trim().is_empty() {
            helper.handle(&line);
        }
        // It may have held a key.
        line.zeroize();
    }
    helper.jobs.cancel_all();
    helper.drives.unmount_all();
}

impl Helper {
    fn handle(self: &Arc<Self>, line: &str) {
        let request: Request = match serde_json::from_str(line) {
            Ok(request) => request,
            Err(error) => {
                let id = serde_json::from_str::<Value>(line)
                    .ok()
                    .and_then(|value| value.get("id").and_then(Value::as_u64))
                    .unwrap_or(0);
                self.out
                    .reply(id, Err(Failure::new("badRequest", error.to_string())));
                return;
            }
        };
        let id = request.id;
        match request.command {
            Command::Hello => self.out.reply(
                id,
                Ok(json!({
                    "version": env!("CARGO_PKG_VERSION"),
                    "dokany": drives::dokany_status(),
                })),
            ),
            Command::Cancel { target } => {
                let cancelled = self.jobs.cancel(target);
                self.out.reply(id, Ok(json!({"cancelled": cancelled})));
            }
            Command::List => self
                .out
                .reply(id, Ok(json!({"mounts": self.drives.list()}))),
            Command::Import {
                vault,
                mut key,
                source,
            } => self.run(id, move |helper, cancel| {
                let result = jobs::import(&helper.out, id, &vault, &key, &source, cancel);
                key.zeroize();
                result
            }),
            Command::Export {
                vault,
                mut key,
                target,
            } => self.run(id, move |helper, cancel| {
                let result = jobs::export(&helper.out, id, &vault, &key, &target, cancel);
                key.zeroize();
                result
            }),
            Command::Mount {
                vault,
                key,
                label,
                drive_letter,
                read_only,
            } => self.run(id, move |helper, _| {
                helper.drives.mount(MountRequest {
                    vault,
                    key,
                    label,
                    drive_letter,
                    read_only,
                })
            }),
            Command::Unmount { vault } => {
                self.run(id, move |helper, _| helper.drives.unmount(&vault))
            }
        }
    }

    /// Runs a request on a thread of its own, so others don't wait for it.
    fn run<F>(self: &Arc<Self>, id: u64, work: F)
    where
        F: FnOnce(&Helper, &std::sync::atomic::AtomicBool) -> Result<Value, Failure>
            + Send
            + 'static,
    {
        let helper = Arc::clone(self);
        let spawned = thread::Builder::new()
            .name(format!("request {id}"))
            .spawn(move || {
                let cancel = helper.jobs.start(id);
                let result = work(&helper, &cancel);
                helper.jobs.finish(id);
                helper.out.reply(id, result);
            });
        if let Err(error) = spawned {
            self.out
                .reply(id, Err(Failure::new("failed", error.to_string())));
        }
    }
}
