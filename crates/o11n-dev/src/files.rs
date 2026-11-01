use std::fs;
use std::path::Path;
use std::process::Command;

use crate::git;
use crate::stamps::CLOSING;

/// The files that match any of the patterns, or every file without any: those git tracks or would track, or, in a
/// directory without git, those under it; each that is a file now, relative to the working directory. A pattern is a
/// glob whose `*` matches `/` as well, as both git's pathspecs and `find -path` read it.
pub fn matching(patterns: &[String]) -> Result<Vec<String>, String> {
    let in_git = match Command::new("git").args(["rev-parse", "--git-dir"]).output() {
        Ok(probed) => probed.status.success(),
        // Accommodating for nix's sandbox, which has no git: a directory there is one without git.
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => false,
        Err(e) => return Err(format!("git: {e}")),
    };
    let mut paths = if in_git {
        let mut args = vec!["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--"];
        args.extend(patterns.iter().map(String::as_str));
        let listed = git::run(&args)?;
        if !listed.status.success() {
            return Err(format!(
                "git ls-files: {}",
                String::from_utf8_lossy(&listed.stderr).trim_end()
            ));
        }
        String::from_utf8(listed.stdout)
            .map_err(|e| format!("git ls-files: {e}"))?
            .split('\0')
            .filter(|path| !path.is_empty())
            .map(str::to_owned)
            .collect()
    } else {
        let mut found = Vec::new();
        walk(Path::new("."), &mut found)?;
        found.retain(|path| patterns.is_empty() || patterns.iter().any(|pattern| globbed(pattern, path)));
        found
    };
    paths.retain(|path| Path::new(path).is_file());
    paths.sort();
    paths.dedup();
    Ok(paths)
}

/// The docs that hold no stamps pending.
pub fn unheld() -> Result<Vec<String>, String> {
    let mut docs = Vec::new();
    for doc in matching(&["*.md".to_owned()])? {
        let text = fs::read_to_string(&doc).map_err(|e| format!("{doc}: {e}"))?;
        if !text.lines().any(|line| line == CLOSING) {
            docs.push(doc);
        }
    }
    Ok(docs)
}

fn walk(dir: &Path, found: &mut Vec<String>) -> Result<(), String> {
    for entry in fs::read_dir(dir).map_err(|e| format!("{}: {e}", dir.display()))? {
        let entry = entry.map_err(|e| format!("{}: {e}", dir.display()))?;
        let path = entry.path();
        let kind = entry.file_type().map_err(|e| format!("{}: {e}", path.display()))?;
        if kind.is_dir() {
            walk(&path, found)?;
        } else if kind.is_file() {
            let relative = path.strip_prefix(".").unwrap_or(&path);
            found.push(relative.to_string_lossy().into_owned());
        }
    }
    Ok(())
}

fn globbed(pattern: &str, path: &str) -> bool {
    let (pattern, path) = (pattern.as_bytes(), path.as_bytes());
    let (mut p, mut s) = (0, 0);
    let mut star: Option<(usize, usize)> = None;
    while s < path.len() {
        if p < pattern.len() && (pattern[p] == b'?' || pattern[p] == path[s]) {
            p += 1;
            s += 1;
        } else if p < pattern.len() && pattern[p] == b'*' {
            star = Some((p, s));
            p += 1;
        } else if let Some((at, from)) = star {
            p = at + 1;
            s = from + 1;
            star = Some((at, from + 1));
        } else {
            return false;
        }
    }
    pattern[p..].iter().all(|&c| c == b'*')
}

#[cfg(test)]
mod tests {
    use super::globbed;

    #[test]
    fn a_star_matches_across_directories() {
        assert!(globbed("*.md", "doc.md"));
        assert!(globbed("*.md", "docs/parts/org.md"));
        assert!(globbed("test/bin/*", "test/bin/ssh"));
        assert!(globbed("*", "a/b"));
        assert!(globbed("?.nix", "a.nix"));
        assert!(!globbed("*.md", "doc.mdx"));
        assert!(!globbed("test/bin/*", "tools/test/bin/ssh"));
    }
}
