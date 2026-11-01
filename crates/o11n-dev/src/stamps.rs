use std::fs;
use std::io::Write;
use std::process::{Command, Stdio};

use crate::{files, git};

pub const OPENING: &str = "<<<<<<< signed";
pub const DIVIDER: &str = "=======";
// Policy: never spelled whole, so that a search for it finds the stamps pending alone.
pub const CLOSING: &str = concat!(">>>>>>> @", "stamp");

#[derive(Clone, Copy, PartialEq)]
pub enum Side {
    Signed,
    Applied,
}

/// The text, named as `name` says, with each stamp as the side given, or why it can't be read so.
pub fn side(side: Side, name: &str, text: &str) -> Result<String, String> {
    let mut kept = String::new();
    let mut at: Option<Side> = None;
    let mut opened = 0;
    for (n, line) in text.split_terminator('\n').enumerate() {
        let n = n + 1;
        match (at, line) {
            (None, OPENING) => {
                at = Some(Side::Signed);
                opened = n;
                continue;
            }
            (Some(Side::Signed), DIVIDER) => {
                at = Some(Side::Applied);
                continue;
            }
            (Some(Side::Applied), CLOSING) => {
                at = None;
                continue;
            }
            _ => {}
        }
        if line.starts_with("<<<<<<<") || line.starts_with(">>>>>>>") {
            return Err(format!("{name}: line {n}: a conflict marker that isn't a stamp's"));
        }
        if at.is_none() || at == Some(side) {
            kept.push_str(line);
            kept.push('\n');
        }
    }
    if at.is_some() {
        return Err(format!("{name}: line {opened}: a stamp isn't closed"));
    }
    Ok(kept)
}

fn read(path: &str) -> Result<String, String> {
    fs::read_to_string(path).map_err(|e| format!("stamps: {path}: {e}"))
}

pub fn applied(doc: &str) -> Result<String, String> {
    side(Side::Applied, doc, &read(doc)?)
}

fn count(text: &str) -> usize {
    text.split_terminator('\n').filter(|line| *line == OPENING).count()
}

// Accommodating for GNU diff, whose group formats write a stamp around each change: a line diff of our own could align
// a change otherwise, and stamp what the operator signed differently.
fn marked(then: &str, now: &str) -> Result<String, String> {
    let dir = std::env::temp_dir().join(format!("o11n-dev-stamps-{}", std::process::id()));
    fs::create_dir_all(&dir).map_err(|e| format!("stamps: {}: {e}", dir.display()))?;
    let (was, is) = (dir.join("then"), dir.join("now"));
    let written = fs::write(&was, then)
        .and_then(|()| fs::write(&is, now))
        .map_err(|e| format!("stamps: {}: {e}", dir.display()));
    let output = written.and_then(|()| {
        Command::new("diff")
            .arg("--unchanged-group-format=%=")
            .arg(format!("--old-group-format={OPENING}\n%<{DIVIDER}\n{CLOSING}\n"))
            .arg(format!("--new-group-format={OPENING}\n{DIVIDER}\n%>{CLOSING}\n"))
            .arg(format!("--changed-group-format={OPENING}\n%<{DIVIDER}\n%>{CLOSING}\n"))
            .args([&was, &is])
            .stdin(Stdio::null())
            .output()
            .map_err(|e| format!("stamps: diff: {e}"))
    });
    let _ = fs::remove_dir_all(&dir);
    let output = output?;
    match output.status.code() {
        Some(0 | 1) => String::from_utf8(output.stdout).map_err(|e| format!("stamps: diff: {e}")),
        _ => Err(format!(
            "stamps: diff: {}",
            String::from_utf8_lossy(&output.stderr).trim_end()
        )),
    }
}

/// Each doc changed since the commit, with the path it had then, if any.
fn changes(base: &str) -> Result<Vec<(String, Option<String>)>, String> {
    let listed = git::run(&["diff", "-z", "--name-status", "-M", base, "--", "*.md"])?;
    if !listed.status.success() {
        return Err(format!(
            "stamps: git diff: {}",
            String::from_utf8_lossy(&listed.stderr).trim_end()
        ));
    }
    let listed = String::from_utf8(listed.stdout).map_err(|e| format!("stamps: git diff: {e}"))?;
    let mut fields = listed.split('\0').filter(|field| !field.is_empty());
    let mut changed = Vec::new();
    while let Some(status) = fields.next() {
        let mut path = || {
            fields
                .next()
                .map(str::to_owned)
                .ok_or("stamps: git diff: a status without its path")
        };
        match status.as_bytes()[0] {
            b'R' => {
                let was = path()?;
                changed.push((path()?, Some(was)));
            }
            b'A' => changed.push((path()?, None)),
            b'M' | b'T' => {
                let path = path()?;
                changed.push((path.clone(), Some(path)));
            }
            _ => {
                path()?;
            }
        }
    }
    let untracked = git::run(&["ls-files", "-z", "--others", "--exclude-standard", "--", "*.md"])?;
    if !untracked.status.success() {
        return Err(format!(
            "stamps: git ls-files: {}",
            String::from_utf8_lossy(&untracked.stderr).trim_end()
        ));
    }
    let untracked = String::from_utf8(untracked.stdout).map_err(|e| format!("stamps: git ls-files: {e}"))?;
    changed.extend(
        untracked
            .split('\0')
            .filter(|path| !path.is_empty())
            .map(|path| (path.to_owned(), None)),
    );
    Ok(changed)
}

/// Writes a stamp around each change to a doc since the commit, against what the operator had signed of it there, and
/// says what it wrote; with `check`, writes nothing and flags each doc it would write.
pub fn write(commit: &str, check: bool) -> Result<Vec<String>, String> {
    let root = git::said(&["rev-parse", "--show-toplevel"])?.ok_or("stamps: write needs a clone")?;
    std::env::set_current_dir(&root).map_err(|e| format!("stamps: {root}: {e}"))?;
    let base = git::said(&["rev-parse", "--verify", "-q", &format!("{commit}^{{commit}}")])?
        .ok_or_else(|| format!("stamps: write: '{commit}' isn't a commit"))?;
    let against = git::said(&["log", "-1", "--format=%h %s", &base])?.unwrap_or_default();
    let mut out = std::io::stdout().lock();
    let say = |out: &mut std::io::StdoutLock, line: &str| writeln!(out, "{line}").map_err(|e| format!("stamps: {e}"));
    if !check {
        say(&mut out, &format!("against {against}"))?;
    }

    let mut flags = Vec::new();
    let mut written = false;
    for (path, was) in changes(&base)? {
        let then = match &was {
            Some(was) => {
                let signed = git::run(&["show", &format!("{base}:{was}")])?;
                if !signed.status.success() {
                    return Err(format!(
                        "stamps: git show: {}",
                        String::from_utf8_lossy(&signed.stderr).trim_end()
                    ));
                }
                side(
                    Side::Signed,
                    &format!("{was} at {base}"),
                    &String::from_utf8_lossy(&signed.stdout),
                )?
            }
            None => String::new(),
        };
        let current = read(&path)?;
        let stamped = marked(&then, &side(Side::Applied, &path, &current)?)?;
        if stamped == current {
            continue;
        }
        if check {
            flags.push(format!(
                "{path}: isn't stamped against {against}: STAMPED={commit} dev/write.sh stamps it"
            ));
            continue;
        }
        fs::write(&path, &stamped).map_err(|e| format!("stamps: {path}: {e}"))?;
        say(&mut out, &format!("{path}: {} stamps", count(&stamped)))?;
        written = true;
    }
    if !written && !check {
        say(&mut out, "nothing to write")?;
    }
    Ok(flags)
}

/// Flags each doc's conflict markers that aren't a stamp's or aren't closed, and, if `pending`, its stamps pending.
pub fn scan(pending: bool, dir: Option<&str>) -> Result<Vec<String>, String> {
    if let Some(dir) = dir.filter(|dir| !dir.is_empty()) {
        std::env::set_current_dir(dir).map_err(|e| format!("stamps: {dir}: {e}"))?;
    }
    let mut flags = Vec::new();
    for path in files::matching(&["*.md".to_owned()])? {
        let text = read(&path)?;
        match side(Side::Applied, &path, &text) {
            Err(why) => flags.push(why),
            Ok(_) if pending && count(&text) > 0 => flags.push(format!(
                "{path}: {} stamps pending: the operator stamps them before work proceeds",
                count(&text)
            )),
            Ok(_) => {}
        }
    }
    Ok(flags)
}

#[cfg(test)]
mod tests {
    use super::{CLOSING, DIVIDER, OPENING, Side, side};

    #[test]
    fn a_side_keeps_what_is_outside_the_stamps() {
        let text = format!("one\n{OPENING}\ntwo\n{DIVIDER}\nTWO\n{CLOSING}\nthree");
        assert_eq!(side(Side::Signed, "doc.md", &text).unwrap(), "one\ntwo\nthree\n");
        assert_eq!(side(Side::Applied, "doc.md", &text).unwrap(), "one\nTWO\nthree\n");
    }

    #[test]
    fn a_side_fails_for_markers_amiss() {
        assert_eq!(
            side(Side::Applied, "m.md", "one\n<<<<<<< HEAD\n").unwrap_err(),
            "m.md: line 2: a conflict marker that isn't a stamp's"
        );
        assert_eq!(
            side(Side::Applied, "o.md", &format!("one\n{OPENING}\ntwo\n")).unwrap_err(),
            "o.md: line 2: a stamp isn't closed"
        );
    }
}
