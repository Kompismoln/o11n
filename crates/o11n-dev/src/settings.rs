use std::collections::BTreeMap;
use std::fs;
use std::io::ErrorKind;

use toml::{Table, Value};

const SETTINGS: &str = "settings.toml";

/// The hooks of dev/agent.sh that check, and what each can do with a stage that fails: refuse work for it or tell of
/// it. hand-over checks once it has pushed, so it has nothing left to refuse.
pub const HOOKS: &[(&str, &[&str])] = &[
    ("session-start", &["refuse", "tell"]),
    ("turn-start", &["refuse", "tell"]),
    ("hand-over", &["tell"]),
];

pub struct Settings {
    pub main: String,
    hooks: BTreeMap<(String, String), Vec<String>>,
}

impl Settings {
    /// The stages the hook does with as `kind` says, none where settings.toml names none.
    pub fn stages(&self, hook: &str, kind: &str) -> Result<&[String], String> {
        let (_, kinds) = HOOKS.iter().find(|(name, _)| *name == hook).ok_or_else(|| {
            format!(
                "no hook {hook} that checks: {}",
                names(HOOKS.iter().map(|(name, _)| *name))
            )
        })?;
        if !kinds.contains(&kind) {
            return Err(format!(
                "{hook} doesn't {kind}: it can {}",
                names(kinds.iter().copied())
            ));
        }
        Ok(self
            .hooks
            .get(&(hook.to_owned(), kind.to_owned()))
            .map_or(&[], Vec::as_slice))
    }
}

fn names<'a>(names: impl Iterator<Item = &'a str>) -> String {
    names.collect::<Vec<_>>().join(", ")
}

fn hooks(table: &Table) -> Result<BTreeMap<(String, String), Vec<String>>, String> {
    let mut read = BTreeMap::new();
    let declared = match table.get("hooks") {
        None => return Ok(read),
        Some(Value::Table(declared)) => declared,
        Some(_) => return Err(format!("{SETTINGS}: hooks isn't a table")),
    };
    for (hook, kinds) in declared {
        let Some((_, known)) = HOOKS.iter().find(|(name, _)| name == hook) else {
            return Err(format!(
                "{SETTINGS}: [hooks.{hook}] isn't a hook that checks: {}",
                names(HOOKS.iter().map(|(name, _)| *name))
            ));
        };
        let Value::Table(kinds) = kinds else {
            return Err(format!("{SETTINGS}: [hooks.{hook}] isn't a table"));
        };
        for (kind, stages) in kinds {
            if !known.contains(&kind.as_str()) {
                return Err(format!(
                    "{SETTINGS}: [hooks.{hook}]: {kind} isn't one of {}",
                    names(known.iter().copied())
                ));
            }
            let stages = stages
                .as_array()
                .filter(|stages| stages.iter().all(Value::is_str))
                .ok_or_else(|| format!("{SETTINGS}: [hooks.{hook}]: {kind} isn't a list of stages"))?;
            let stages = stages.iter().filter_map(Value::as_str).map(str::to_owned).collect();
            read.insert((hook.clone(), kind.clone()), stages);
        }
    }
    Ok(read)
}

/// The clone's settings.toml, each setting it leaves out as its default.
pub fn read() -> Result<Settings, String> {
    let table: Table = match fs::read_to_string(SETTINGS) {
        Ok(text) => text.parse().map_err(|e| format!("{SETTINGS}: {e}"))?,
        Err(e) if e.kind() == ErrorKind::NotFound => Table::new(),
        Err(e) => return Err(format!("{SETTINGS}: {e}")),
    };
    let main = match table.get("main") {
        None => "main".to_owned(),
        Some(Value::String(main)) => main.clone(),
        Some(_) => return Err(format!("{SETTINGS}: main isn't a branch's name")),
    };
    Ok(Settings {
        main,
        hooks: hooks(&table)?,
    })
}
