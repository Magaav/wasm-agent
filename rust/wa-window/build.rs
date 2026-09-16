// Embed the wasm-agent icon (resource id 1) into the Windows executable so the
// taskbar, alt-tab and Explorer show our logo.
fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    let manifest = std::env::var("CARGO_MANIFEST_DIR").expect("manifest dir");
    let out = std::env::var("OUT_DIR").expect("out dir");
    let assets = std::path::Path::new(&manifest).join("assets");
    let rc = assets.join("wa.rc");
    let object = std::path::Path::new(&out).join("wa_icon.o");
    let windres = std::env::var("WINDRES").unwrap_or_else(|_| "x86_64-w64-mingw32-windres".into());

    match std::process::Command::new(&windres)
        .arg("-I")
        .arg(&assets)
        .arg(&rc)
        .arg("-O")
        .arg("coff")
        .arg("-o")
        .arg(&object)
        .status()
    {
        Ok(status) if status.success() => println!("cargo:rustc-link-arg={}", object.display()),
        _ => println!("cargo:warning=windres unavailable; building without an icon"),
    }

    println!("cargo:rerun-if-changed=assets/wa.rc");
    println!("cargo:rerun-if-changed=assets/wa.ico");
}
