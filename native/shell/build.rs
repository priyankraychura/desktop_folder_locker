//! Release builds carry the Visual C++ runtime inside the DLL, so it needs
//! no `vcruntime140.dll` in Explorer's process: there may be none to find,
//! or an older one already loaded by another program's plug-in.

fn main() {
    static_vcruntime::metabuild();
}
