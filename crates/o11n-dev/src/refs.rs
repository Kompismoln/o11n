use std::fs;
use std::path::Path;
use std::sync::LazyLock;

use regex::Regex;

use crate::{files, git, stamps};

// Accommodating for gawk's [[:space:]], which this reads as refcheck.sh read it: Rust's \s holds more.
const SPACE: &str = r" \t\n\x0B\x0C\r";

static PATH: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(&format!(r"`[A-Za-z0-9_.-]+/[^`{SPACE}<>$\{{\}}]*`")).unwrap());
static COMMIT: LazyLock<Regex> = LazyLock::new(|| Regex::new("[0-9a-f]+").unwrap());
static FORMER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(&format!(r"(\bformer|[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+'s)[{SPACE}]*`?$")).unwrap());
static IN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(&format!(r"^`?[{SPACE}]+in [A-Za-z0-9_-]+/[A-Za-z0-9_.-]+")).unwrap());

enum Reference {
    Path(String),
    Commit(String),
}

/// Whether the text says what spans `start..end` of it is elsewhere: after "former" or "<owner>/<repo>'s", or before
/// "in <owner>/<repo>".
fn elsewhere(text: &str, start: usize, end: usize) -> bool {
    FORMER.is_match(&text[..start]) || IN.is_match(&text[end..])
}

/// The references of a paragraph of prose that the text doesn't say are elsewhere, each with the line it's on.
fn paragraph(text: &str, first: usize, found: &mut Vec<(usize, Reference)>) {
    let line = |at: usize| first + text[..at].matches('\n').count();
    for m in PATH.find_iter(text) {
        if !elsewhere(text, m.start(), m.end()) {
            let path = &m.as_str()[1..m.as_str().len() - 1];
            found.push((line(m.start()), Reference::Path(path.to_owned())));
        }
    }
    for m in COMMIT.find_iter(text) {
        let commit = m.as_str();
        let before = text[..m.start()].chars().next_back();
        let after = text[m.end()..].chars().next();
        if (7..=40).contains(&commit.len())
            && commit.contains(|c: char| c.is_ascii_lowercase())
            && commit.contains(|c: char| c.is_ascii_digit())
            && !before.is_some_and(|c| c.is_ascii_alphanumeric() || "_/.:-".contains(c))
            && !after.is_some_and(|c| c.is_ascii_alphanumeric() || "_-".contains(c))
            && !elsewhere(text, m.start(), m.end())
        {
            found.push((line(m.start()), Reference::Commit(commit.to_owned())));
        }
    }
}

/// The references a doc makes outside its code blocks and what a stamp pending holds as signed, by paragraph of prose,
/// so that what says a reference is elsewhere still says so once prettier wraps it onto another line.
fn references(doc: &str) -> Vec<(usize, Reference)> {
    let mut found = Vec::new();
    let (mut lines, mut first) = (Vec::new(), 0);
    let (mut signed, mut fenced) = (false, false);
    for (n, line) in doc.split_terminator('\n').enumerate() {
        let mut kept = false;
        if line == stamps::OPENING {
            signed = true;
        } else if line == stamps::DIVIDER && signed {
            signed = false;
        } else if line.starts_with(">>>>>>> ") || signed {
        } else if line.trim_start_matches(|c| SPACE.contains(c)).starts_with("```") {
            fenced = !fenced;
        } else if !fenced && line.contains(|c| !SPACE.contains(c)) {
            if lines.is_empty() {
                first = n + 1;
            }
            lines.push(line);
            kept = true;
        }
        if !kept && !lines.is_empty() {
            paragraph(&lines.join("\n"), first, &mut found);
            lines.clear();
        }
    }
    if !lines.is_empty() {
        paragraph(&lines.join("\n"), first, &mut found);
    }
    found
}

/// Whether a path resolves: it's there, a glob of it matches what's there, or git ignores it as what a tool writes.
fn resolves(reference: &str) -> Result<bool, String> {
    let path = reference.split(':').next().unwrap_or(reference);
    if git::succeeds(&["check-ignore", "-q", path])? {
        return Ok(true);
    }
    Ok(if path.contains('*') {
        globbed(Path::new("."), path)
    } else {
        Path::new(path).exists()
    })
}

// Accommodating for refcheck.sh, which expanded a path with a `*` as bash does: segment by segment, a `*` matching
// neither `/` nor a leading `.`.
fn globbed(dir: &Path, pattern: &str) -> bool {
    let (segment, rest) = pattern
        .split_once('/')
        .map_or((pattern, None), |(segment, rest)| (segment, Some(rest)));
    let next = |path: &Path| rest.is_none_or(|rest| path.is_dir() && globbed(path, rest));
    if !segment.contains(['*', '?']) {
        let path = dir.join(segment);
        return path.exists() && next(&path);
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return false;
    };
    entries.filter_map(Result::ok).any(|entry| {
        let name = entry.file_name().to_string_lossy().into_owned();
        (segment.starts_with('.') || !name.starts_with('.')) && matched(segment, &name) && next(&entry.path())
    })
}

fn matched(pattern: &str, name: &str) -> bool {
    match (pattern.chars().next(), name.chars().next()) {
        (None, None) => true,
        (Some('*'), _) => {
            matched(&pattern[1..], name)
                || name
                    .chars()
                    .next()
                    .is_some_and(|c| matched(pattern, &name[c.len_utf8()..]))
        }
        (Some('?'), Some(c)) => matched(&pattern[1..], &name[c.len_utf8()..]),
        (Some(p), Some(c)) if p == c => matched(&pattern[p.len_utf8()..], &name[c.len_utf8()..]),
        _ => false,
    }
}

/// Each reference a doc makes that doesn't resolve: a path in backticks whose first part is at the clone's root, and
/// that git doesn't ignore as what a tool writes, or a commit that isn't on main.
pub fn check() -> Result<Vec<String>, String> {
    let main = git::said(&["rev-parse", "--verify", "-q", "origin/main"])?.or(git::said(&[
        "rev-parse",
        "--verify",
        "-q",
        "main",
    ])?);
    let mut flags = Vec::new();
    for doc in files::matching(&["*.md".to_owned()])? {
        let text = fs::read_to_string(&doc).map_err(|e| format!("{doc}: {e}"))?;
        for (n, reference) in references(&text) {
            match reference {
                Reference::Path(path) => {
                    let first = path.split('/').next().unwrap_or(&path);
                    if Path::new(first).exists() && !resolves(&path)? {
                        flags.push(format!("{doc}:{n}: `{path}` isn't there"));
                    }
                }
                Reference::Commit(commit) => {
                    let on_main = match &main {
                        Some(main) => git::succeeds(&["merge-base", "--is-ancestor", &commit, main])?,
                        None => false,
                    };
                    if !on_main {
                        flags.push(format!("{doc}:{n}: {commit} isn't a commit on main"));
                    }
                }
            }
        }
    }
    Ok(flags)
}
