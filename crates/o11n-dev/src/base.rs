use std::fs;
use std::io::ErrorKind;

use crate::{git, settings};

const TURN: &str = "dev/state/turn-start";

// Policy: stamps are written against what the operator last stamped on the branch, or, while the branch has no
// refs/stamped, against the commit the turn started at, or else where the branch left main, so that what wasn't
// stamped is stamped again rather than left out.
/// The commit to stamp against.
pub fn base() -> Result<String, String> {
    if let Some(branch) = git::said(&["symbolic-ref", "--quiet", "--short", "HEAD"])?
        && let Some(stamped) = git::said(&[
            "rev-parse",
            "--verify",
            "--quiet",
            &format!("refs/stamped/{branch}^{{commit}}"),
        ])?
        && git::succeeds(&["merge-base", "--is-ancestor", &stamped, "HEAD"])?
    {
        return Ok(stamped);
    }
    match fs::read_to_string(TURN) {
        Ok(turn) => return Ok(turn.trim().to_owned()),
        Err(e) if e.kind() == ErrorKind::NotFound => {}
        Err(e) => return Err(format!("{TURN}: {e}")),
    }
    let main = settings::read()?.main;
    for main in [format!("origin/{main}"), main] {
        if let Some(left) = git::said(&["merge-base", "HEAD", &main])? {
            return Ok(left);
        }
    }
    Err(format!(
        "no commit to stamp against: no refs/stamped/<branch> HEAD is on, no {TURN}, and no main HEAD shares history with"
    ))
}
