fn main() {
    // Dokany's library is loaded only once the helper has checked that
    // Dokany is installed, so the helper starts (and can say so) without it.
    let target = std::env::var("TARGET").unwrap_or_default();
    if target.contains("windows") && target.contains("msvc") {
        println!("cargo:rustc-link-arg-bins=/DELAYLOAD:dokan2.dll");
        println!("cargo:rustc-link-arg-bins=delayimp.lib");
    }
}
