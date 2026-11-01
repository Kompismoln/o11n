use std::process::{Command, Output};

pub fn run(args: &[&str]) -> Result<Output, String> {
    Command::new("git").args(args).output().map_err(|e| format!("git: {e}"))
}

/// What git printed, trimmed, or None where it fails.
pub fn said(args: &[&str]) -> Result<Option<String>, String> {
    let output = run(args)?;
    Ok(output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned()))
}

pub fn succeeds(args: &[&str]) -> Result<bool, String> {
    Ok(run(args)?.status.success())
}
