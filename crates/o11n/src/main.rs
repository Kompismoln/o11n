mod export;
mod groups;
mod sops;

use std::fmt;
use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};

use export::Export;

/// Reads an evaluated org and acts on it.
#[derive(Parser)]
#[command(version)]
struct Cli {
    /// The org's clone.
    #[arg(long, env = "O11N_ORG_ROOT", default_value = ".")]
    org: PathBuf,
    /// The org's export as JSON, instead of evaluating `org.export` of the org's flake.
    #[arg(long, env = "O11N_EXPORT")]
    export: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// The org's export.
    Export,
    /// What the export holds at the path of names given, a list one item a line.
    Get { path: Vec<String> },
    /// The ids of the groups' members: *, <class>-*, <class>:<role>[+<role>]... or <class>-<name>.
    Entities {
        #[arg(default_value = "*")]
        groups: Vec<String>,
    },
    /// The id an entity is named by, whole or by a part only it has.
    Resolve { name: String },
    /// The keys an entity of the class has.
    Keys { class: String },
    /// The members of the entity's grants.
    Grants { id: String },
    /// The entities that decrypt the entity's secrets.
    Recipients { id: String },
    /// The path, in the org, of the entity's public key.
    PublicKey { id: String, key: String },
    /// The path, in the org, of the entity's secrets.
    Secrets { id: String },
    /// Each entity an op of the name applies to, and the op.
    Ops { name: String },
    /// sops' creation rules for the members of the group.
    SopsYaml { group: String },
}

#[derive(Debug)]
pub struct Error {
    message: Option<String>,
    status: u8,
}

impl Error {
    #[must_use]
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: Some(message.into()),
            status: 1,
        }
    }

    /// A failure whose command has said why already.
    #[must_use]
    pub fn status(code: i32) -> Self {
        Self {
            message: None,
            status: u8::try_from(code).unwrap_or(1),
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.message.as_deref().unwrap_or("failed"))
    }
}

fn lines(lines: impl IntoIterator<Item = impl AsRef<str>>) {
    for line in lines {
        println!("{}", line.as_ref());
    }
}

fn get(json: &str, path: &[String]) -> Result<(), Error> {
    let mut value: serde_json::Value = serde_json::from_str(json).map_err(|e| Error::new(e.to_string()))?;
    for name in path {
        value = value
            .get_mut(name)
            .map(serde_json::Value::take)
            .ok_or_else(|| Error::new(format!("the export holds nothing at {}", path.join("."))))?;
    }
    let items = match value {
        serde_json::Value::Array(items) => items,
        value => vec![value],
    };
    for item in items {
        match item {
            serde_json::Value::String(text) => println!("{text}"),
            item => println!("{item}"),
        }
    }
    Ok(())
}

fn run(cli: Cli) -> Result<(), Error> {
    let json = match &cli.export {
        Some(path) => Export::read(path)?,
        None => Export::evaluate(&cli.org)?,
    };
    let org = Export::parse(&json)?;
    match cli.command {
        Command::Export => print!("{json}"),
        Command::Get { path } => get(&json, &path)?,
        Command::Entities { groups } => lines(org.expand(groups.iter().map(String::as_str))?),
        Command::Resolve { name } => println!("{}", org.resolve(&name)?),
        Command::Keys { class } => {
            let class = org
                .classes
                .get(&class)
                .ok_or_else(|| Error::new(format!("no class {class}")))?;
            lines(&class.keys);
        }
        Command::Grants { id } => lines(org.expand(org.entity(&id)?.grants.iter().map(String::as_str))?),
        Command::Recipients { id } => lines(org.recipients(&id)?),
        Command::PublicKey { id, key } => {
            let entity = org.entity(&id)?;
            let path = entity
                .public_keys
                .get(&key)
                .ok_or_else(|| Error::new(format!("{id} has no {key}")))?;
            println!("{path}");
        }
        Command::Secrets { id } => {
            let secrets = &org.entity(&id)?.secrets;
            let path = secrets.sops_file.as_ref().or(secrets.age_key_file.as_ref());
            println!("{}", path.ok_or_else(|| Error::new(format!("{id} has no secrets")))?);
        }
        Command::Ops { name } => {
            let groups = org.ops.get(&name).ok_or_else(|| Error::new(format!("no ops {name}")))?;
            for (group, ops) in groups {
                for id in org.members(group)? {
                    lines(ops.iter().map(|op| format!("{id} {op}")));
                }
            }
        }
        Command::SopsYaml { group } => {
            let mut missing = Vec::new();
            print!("{}", org.sops_yaml(&cli.org, &group, &mut missing)?);
            if !missing.is_empty() {
                return Err(Error::new(missing.join("\n")));
            }
        }
    }
    Ok(())
}

fn main() -> ExitCode {
    match run(Cli::parse()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            if let Some(message) = &error.message {
                eprintln!("o11n: {message}");
            }
            ExitCode::from(error.status)
        }
    }
}
