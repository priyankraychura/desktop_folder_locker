//! Stands in for `folder_locker.exe` in the plug-in's tests: appends its
//! arguments, one line per start, to the file in `FLK_RECORD_ARGS`.

use std::io::Write;

fn main() {
    let Some(file) = std::env::var_os("FLK_RECORD_ARGS") else {
        return;
    };
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let Ok(mut out) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(file)
    {
        let _ = writeln!(out, "{}", args.join("\t"));
    }
}
