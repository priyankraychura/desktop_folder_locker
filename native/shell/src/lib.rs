//! Cloak's Explorer plug-in (`cloak_shell.dll`): the
//! right-click entry that knows each item, and the lock badge. The app
//! uses it too, to know which folders Explorer shows.
//!
//! An in-process COM server that Explorer loads. It only reads the app's
//! list of items and starts the app; the app does the rest. Every entry
//! point catches errors and panics, so a problem here can't take Explorer
//! down.

// The linker asks for the COM exports to be PRIVATE, which only concerns
// the import library that comes with the DLL. Nothing uses it.
#![allow(linker_messages)]

pub mod badge;
pub mod menu;
pub mod state;

#[cfg(windows)]
mod com;
#[cfg(windows)]
pub mod shown;
#[cfg(windows)]
pub use com::{
    DllCanUnloadNow, DllGetClassObject, BADGE_ICON, CLSID_BADGE, CLSID_MENU, CLSID_MENU_PACKAGED,
};
