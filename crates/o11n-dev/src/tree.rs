use std::env;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::Command;

/// With `O11N_ROOT` naming an o11n clone, builds that clone's o11n-dev and runs it in place of this one, unless this
/// one is it, so that the scripts of dev/ run the o11n-dev of the tree they're in. Returns without `O11N_ROOT`, as in
/// nix's sandbox, whose o11n-dev nix built from the tree, and fails for one that holds no o11n-dev to build.
pub fn run_built() -> Result<(), String> {
    let Some(root) = env::var_os("O11N_ROOT").filter(|root| !root.is_empty()) else {
        return Ok(());
    };
    let crate_dir = Path::new(&root).join("crates/o11n-dev");
    if !crate_dir.join("Cargo.toml").is_file() {
        return Err(format!(
            "O11N_ROOT, {}, holds no crates/o11n-dev to build",
            Path::new(&root).display()
        ));
    }
    let target = crate_dir.join("target");
    let built = target.join("debug/o11n-dev");
    let this = env::current_exe().map_err(|e| format!("this o11n-dev: {e}"))?;
    if built
        .canonicalize()
        .is_ok_and(|built| this.canonicalize().is_ok_and(|this| this == built))
    {
        return Ok(());
    }
    let output = Command::new("cargo")
        .args(["build", "--quiet", "--manifest-path"])
        .arg(crate_dir.join("Cargo.toml"))
        .arg("--target-dir")
        .arg(&target)
        .output()
        .map_err(|e| {
            format!(
                "cargo, to build the o11n-dev of O11N_ROOT, {}: {e}",
                Path::new(&root).display()
            )
        })?;
    if !output.status.success() {
        return Err(format!(
            "the o11n-dev of O11N_ROOT, {}, doesn't build:\n{}",
            Path::new(&root).display(),
            String::from_utf8_lossy(&output.stderr).trim_end()
        ));
    }
    let error = Command::new(&built).args(env::args_os().skip(1)).exec();
    Err(format!("{}: {error}", built.display()))
}
