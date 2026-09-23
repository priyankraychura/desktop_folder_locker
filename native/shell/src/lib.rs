//! Folder Locker's Explorer plug-in (`folder_locker_shell.dll`): the
//! right-click entry that knows each item, and the lock badge.
//!
//! An in-process COM server that Explorer loads. It only reads the app's
//! list of items and starts the app; the app does the rest. Every entry
//! point catches errors and panics, so a problem here can't take Explorer
//! down.

pub mod menu;
pub mod state;

#[cfg(windows)]
mod com;
#[cfg(windows)]
pub use com::{DllCanUnloadNow, DllGetClassObject, CLSID_MENU};
