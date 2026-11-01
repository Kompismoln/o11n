use std::fs;
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

use serde_json::{Map, Value};

use crate::stamps;

const INDEX: &str = "docs/index";

fn text<'a>(entry: &'a Value, key: &str) -> Option<&'a str> {
    entry.get(key).and_then(Value::as_str)
}

fn default(entry: &Value, default: &str) -> Vec<String> {
    let default = default.trim();
    if entry.get("prose").and_then(Value::as_bool).unwrap_or(false) {
        vec![String::new(), format!("Default: {default}")]
    } else if default.contains('\n') {
        ["", "Default:", "", "```nix", default, "```"]
            .map(str::to_owned)
            .to_vec()
    } else {
        vec![String::new(), format!("Default: `{default}`")]
    }
}

/// The part's index, as prettier formats it.
fn rendered(part: &str, entries: &[Value]) -> Result<String, String> {
    let mut lines = vec![
        format!("# `{part}`"),
        String::new(),
        "Written by `o11n-dev index` from the options of an org that are declared in the part's code, as `dev/index.nix` \
         reads them, each by its place in `org.toml`."
            .to_owned(),
        String::new(),
        "## Options".to_owned(),
    ];
    for entry in entries {
        let name = text(entry, "name").ok_or_else(|| format!("index: an entry of {part} without a name"))?;
        lines.extend([String::new(), format!("### `{name}`"), String::new()]);
        let files = entry
            .get("files")
            .and_then(Value::as_array)
            .map_or(&[][..], Vec::as_slice);
        let files: Vec<String> = files
            .iter()
            .filter_map(Value::as_str)
            .map(|file| format!("`{file}`"))
            .collect();
        let mut about = vec![files.join(", ")];
        about.extend(text(entry, "type").map(str::to_owned));
        lines.push(about.join(" · "));
        if let Some(value) = text(entry, "default") {
            lines.extend(default(entry, value));
        }
        if let Some(description) = text(entry, "description") {
            lines.extend([String::new(), description.trim().to_owned()]);
        }
    }
    let mut prettier = Command::new("prettier")
        .args(["--stdin-filepath", &format!("{INDEX}/{part}.md")])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("prettier: {e}"))?;
    if let Some(mut stdin) = prettier.stdin.take() {
        stdin
            .write_all((lines.join("\n") + "\n").as_bytes())
            .map_err(|e| format!("prettier: {e}"))?;
    }
    let output = prettier.wait_with_output().map_err(|e| format!("prettier: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "prettier: {}",
            String::from_utf8_lossy(&output.stderr).trim_end()
        ));
    }
    let formatted = String::from_utf8(output.stdout).map_err(|e| format!("prettier: {e}"))?;
    Ok(formatted.trim_end_matches('\n').to_owned())
}

/// Writes `docs/index/<part>.md` for each part the index has entries for, and removes those of parts it has none
/// for; with `check`, writes nothing and flags each that differs from what it would write, its stamps pending read as
/// written now.
pub fn index(check: bool) -> Result<Vec<String>, String> {
    let evaluated = Command::new("nix")
        .args(["eval", "--json", "--no-warn-dirty", ".#index"])
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("nix: {e}"))?;
    if !evaluated.status.success() {
        return Err(format!(
            "nix eval .#index: {}",
            String::from_utf8_lossy(&evaluated.stderr).trim_end()
        ));
    }
    let said = String::from_utf8(evaluated.stdout).map_err(|e| format!("nix eval .#index: {e}"))?;
    let index: Map<String, Value> = serde_json::from_str(&said).map_err(|e| format!("index: {e}"))?;
    let mut parts: Vec<(&String, &Vec<Value>)> = index
        .iter()
        .filter_map(|(part, entries)| {
            entries
                .as_array()
                .filter(|entries| !entries.is_empty())
                .map(|e| (part, e))
        })
        .collect();
    parts.sort_by_key(|(part, _)| *part);

    let mut flags = Vec::new();
    for (part, entries) in &parts {
        let path = format!("{INDEX}/{part}.md");
        let text = rendered(part, entries)?;
        let current = stamps::applied(&path)
            .ok()
            .map(|applied| applied.trim_end_matches('\n').to_owned());
        if Path::new(&path).is_file() && current.as_deref() == Some(text.as_str()) {
            continue;
        }
        if check {
            flags.push(format!("{path}: isn't what `dev/write.sh index` writes"));
        } else {
            fs::create_dir_all(INDEX).map_err(|e| format!("{INDEX}: {e}"))?;
            fs::write(&path, text + "\n").map_err(|e| format!("{path}: {e}"))?;
            println!("{path}: written");
        }
    }

    let mut docs: Vec<String> = match fs::read_dir(INDEX) {
        Ok(entries) => entries
            .filter_map(Result::ok)
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .filter(|name| {
                !name.starts_with('.') && Path::new(name).extension().is_some_and(|extension| extension == "md")
            })
            .collect(),
        Err(_) => Vec::new(),
    };
    docs.sort();
    for name in docs {
        let path = format!("{INDEX}/{name}");
        if !Path::new(&path).is_file() || parts.iter().any(|(part, _)| format!("{part}.md") == name) {
            continue;
        }
        if check {
            flags.push(format!("{path}: indexes a part with nothing to index"));
        } else {
            fs::remove_file(&path).map_err(|e| format!("{path}: {e}"))?;
            println!("{path}: removed");
        }
    }
    Ok(flags)
}
