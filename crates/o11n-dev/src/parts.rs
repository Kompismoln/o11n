use std::fs;

use toml::{Table, Value};

use crate::files;

const DECLARED: &str = "dev/parts.toml";

fn said(value: Option<&Value>) -> String {
    match value {
        None => "None".to_owned(),
        Some(Value::String(text)) => format!("'{text}'"),
        Some(other) => format!("'{other}'"),
    }
}

fn holds(entry: &str, path: &str) -> bool {
    path == entry
        || path
            .strip_prefix(entry.trim_end_matches('/'))
            .is_some_and(|rest| rest.starts_with('/'))
}

fn listed<'a>(declared: &'a Table, key: &str) -> &'a [Value] {
    declared.get(key).and_then(Value::as_array).map_or(&[], Vec::as_slice)
}

fn declares(list: &[Value], value: Option<&Value>) -> bool {
    value.is_some_and(|value| list.contains(value))
}

struct Part<'a> {
    name: &'a str,
    doc: Option<&'a str>,
    code: Vec<&'a str>,
}

/// What dev/parts.toml holds amiss, each a flag.
pub fn check() -> Result<Vec<String>, String> {
    let text = fs::read_to_string(DECLARED).map_err(|e| format!("{DECLARED}: {e}"))?;
    let declared: Table = text.parse().map_err(|e| format!("{DECLARED}: {e}"))?;
    let files = files::matching(&[])?;
    let stages = listed(&declared, "stages");
    let layers = listed(&declared, "layers");
    let empty = Table::new();
    let declared_parts = match declared.get("parts") {
        None => &empty,
        Some(Value::Table(parts)) => parts,
        Some(_) => return Err(format!("{DECLARED}: parts isn't a table")),
    };

    let mut flags = Vec::new();
    let mut parts = Vec::new();
    for (name, part) in declared_parts {
        let flag = |what: String| format!("{DECLARED}: [parts.{name}]: {what}");
        let Value::Table(part) = part else {
            flags.push(flag("isn't a table".to_owned()));
            continue;
        };
        if !declares(stages, part.get("stage")) {
            flags.push(flag(format!("stage {} isn't one of stages", said(part.get("stage")))));
        }
        if !declares(layers, part.get("layer")) {
            flags.push(flag(format!("layer {} isn't one of layers", said(part.get("layer")))));
        }
        let code: Vec<&str> = match part.get("code") {
            None => Vec::new(),
            Some(Value::Array(entries)) if entries.iter().all(Value::is_str) => {
                entries.iter().filter_map(Value::as_str).collect()
            }
            Some(_) => {
                flags.push(flag("code isn't a list of paths".to_owned()));
                Vec::new()
            }
        };
        for entry in &code {
            if !files.iter().any(|path| holds(entry, path)) {
                flags.push(flag(format!("`{entry}` isn't there")));
            }
        }
        let doc = match part.get("doc") {
            None => None,
            Some(Value::String(doc)) => Some(doc.as_str()),
            Some(_) => {
                flags.push(flag("doc isn't a path".to_owned()));
                None
            }
        };
        if let Some(doc) = doc
            && !files.iter().any(|path| path == doc)
        {
            flags.push(flag(format!("`{doc}` isn't there")));
        }
        parts.push(Part { name, doc, code });
    }

    for path in &files {
        let documented = parts
            .iter()
            .filter(|part| part.doc == Some(path.as_str()) || *path == format!("docs/index/{}.md", part.name));
        let held = |part: &Part| {
            part.code
                .iter()
                .filter(|entry| holds(entry, path))
                .map(|entry| entry.trim_end_matches('/').len())
                .max()
        };
        let closest = parts.iter().filter_map(held).max();
        let coded = parts.iter().filter(|part| closest.is_some() && held(part) == closest);
        let holders: Vec<&str> = documented.chain(coded).map(|part| part.name).collect();
        if holders.len() > 1 {
            flags.push(format!(
                "{DECLARED}: `{path}` is held by {} parts, {}, not one",
                holders.len(),
                holders.join(", ")
            ));
        }
        if path.starts_with("docs/index/") && holders.is_empty() {
            flags.push(format!("{DECLARED}: `{path}` indexes no part"));
        }
    }
    Ok(flags)
}
