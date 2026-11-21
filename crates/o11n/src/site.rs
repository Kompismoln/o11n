use std::collections::BTreeMap;
use std::path::Path;
use std::process::{Command, Stdio};

use crate::{Error, util};

fn nix(args: &[&str]) -> Result<String, Error> {
    util::run(Command::new("nix").args(args), None)
}

// Dependency: lib/default.nix gives each portal of the org, by system, its site's `serve` and its `content`.
pub fn serve(root: &Path, app: Option<&str>, zola: &[String]) -> Result<(), Error> {
    let system = nix(&["eval", "--raw", "--impure", "--expr", "builtins.currentSystem"])?;
    let portals = format!("{}#portals.{system}", util::flake(root)?);
    let contents: BTreeMap<String, String> = serde_json::from_str(&nix(&[
        "eval",
        "--json",
        "--no-warn-dirty",
        &portals,
        "--apply",
        "builtins.mapAttrs (_: portal: portal.content)",
    ])?)
    .map_err(|e| Error::new(format!("the org's portals: {e}")))?;
    let names = || contents.keys().cloned().collect::<Vec<_>>().join(", ");
    let (app, content) = match app {
        Some(app) => contents
            .get_key_value(app)
            .ok_or_else(|| Error::new(format!("{app} isn't a portal: {}", names())))?,
        None if contents.len() == 1 => contents.iter().next().expect("one portal"),
        None if contents.is_empty() => return Err(Error::new("the org has no portal")),
        None => return Err(Error::new(format!("name the portal: {}", names()))),
    };
    let output = Command::new("nix")
        .args(["build", "--no-link", "--print-out-paths", "--no-warn-dirty"])
        .arg(format!("{portals}.{app}.serve"))
        .stderr(Stdio::inherit())
        .output()
        .map_err(|e| Error::new(format!("nix: {e}")))?;
    util::exited(output.status)?;
    let serve = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let status = Command::new(serve)
        .arg(root.join(content))
        .args(zola)
        .status()
        .map_err(|e| Error::new(format!("{app}'s server: {e}")))?;
    util::exited(status)
}
