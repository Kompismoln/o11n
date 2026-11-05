use std::path::PathBuf;
use std::process::{Command, ExitCode, Stdio};

use crate::git;

fn org() -> Result<PathBuf, String> {
    std::env::var_os("ORG")
        .filter(|org| !org.is_empty())
        .map(PathBuf::from)
        .ok_or_else(|| "ORG is unset, so there's no org".to_owned())
}

fn clone() -> Result<String, String> {
    git::said(&["rev-parse", "--show-toplevel"])?.ok_or_else(|| "not in o11n's clone".to_owned())
}

fn nix(org: &PathBuf) -> Command {
    let mut nix = Command::new("nix");
    nix.current_dir(org);
    nix
}

/// The org's eval stage, built with the clone's tree as its o11n.
pub fn check(args: &[String]) -> Result<ExitCode, String> {
    let status = nix(&org()?)
        .args(["build", "--no-link", "-L", ".#stages.eval", "--override-input", "o11n"])
        .arg(format!("git+file://{}", clone()?))
        .args(args)
        .status()
        .map_err(|e| format!("nix: {e}"))?;
    Ok(if status.success() {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    })
}

// Policy: a system built without o11n's tree, which nixos/org/nix.nix keeps behind o11n.source.enable, is equal at two
// revisions of o11n only if what it's built from is.
fn drv_path(org: &PathBuf, clone: &str, rev: &str, host: &str, args: &[String]) -> Result<String, String> {
    let output = nix(org)
        .args(["eval", "--raw", "--no-warn-dirty"])
        .args(args)
        .args(["--override-input", "o11n"])
        .arg(format!("git+file://{clone}?rev={rev}&shallow=1"))
        .arg(format!(".#nixosConfigurations.{host}"))
        .args([
            "--apply",
            "c: (c.extendModules { modules = [ { o11n.source.enable = false; } ]; }).config.system.build.toplevel.drvPath",
        ])
        .stderr(Stdio::inherit())
        .output()
        .map_err(|e| format!("nix: {e}"))?;
    if !output.status.success() {
        return Err(format!("{host} at {rev} doesn't evaluate"));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Whether each host's system differs between the two revisions of the clone, a line each, failing if any does.
pub fn compare(old: &str, new: &str, hosts: &[String], args: &[String]) -> Result<ExitCode, String> {
    let org = org()?;
    let clone = clone()?;
    let rev = |rev: &str| {
        git::said(&["rev-parse", "--verify", "-q", &format!("{rev}^{{commit}}")])?
            .ok_or_else(|| format!("no revision {rev}"))
    };
    let (old, new) = (rev(old)?, rev(new)?);
    let mut differ = false;
    for host in hosts {
        let (before, after) = (
            drv_path(&org, &clone, &old, host, args)?,
            drv_path(&org, &clone, &new, host, args)?,
        );
        if before == after {
            println!("{host} same");
        } else {
            println!("{host} differs: {before} {after}");
            differ = true;
        }
    }
    Ok(if differ { ExitCode::FAILURE } else { ExitCode::SUCCESS })
}
