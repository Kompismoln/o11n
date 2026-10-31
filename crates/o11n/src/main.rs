mod export;
mod groups;
mod host;
mod keys;
mod secrets;
mod sops;
mod store;
mod util;

use std::fmt;
use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Args, Parser, Subcommand};

use export::Export;
use store::{Org, Secret};

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
    /// The ids that contain the text.
    Search { text: String },
    /// The ids of the groups' members: *, <class>-*, <class>:<role>[+<role>]... or <class>-<name>.
    Entities {
        #[arg(default_value = "*")]
        groups: Vec<String>,
    },
    /// The keys an entity of the class has.
    Keys { class: String },
    /// The members of the entity's grants.
    Grants { id: String },
    /// The entities that decrypt the entity's sops file.
    Recipients { id: String },
    /// Each entity an op of the name applies to, and the op.
    Ops { name: String },
    /// sops' creation rules for the members of the group, a recipient without an age key left out with a warning.
    SopsYaml { group: String },
    /// Where, in the org, a file of the entity's is.
    #[command(subcommand)]
    Path(PathCommand),
    /// An entity's age key, kept apart from its secrets and encrypted to itself, its actors and the root identities.
    #[command(subcommand)]
    Identity(IdentityCommand),
    /// An entity's secrets, in its sops file.
    #[command(subcommand)]
    Secret(SecretCommand),
    /// The public keys of an entity's secrets.
    #[command(subcommand)]
    PublicKey(PublicKeyCommand),
    /// A host's keys, on the host.
    #[command(subcommand)]
    Host(HostCommand),
    /// Encrypts every sops file to its recipients, and every identity to itself, its actors and the root identities, as
    /// the org declares them.
    Reencrypt,
}

#[derive(Subcommand)]
enum PathCommand {
    /// The entity's public key.
    PublicKey { id: String, key: String },
    /// The entity's sops file.
    SopsFile { id: String },
    /// The entity's identity.
    Identity { id: String },
}

#[derive(Args)]
struct From {
    /// The file whose contents are the secret, rather than one generated.
    #[arg(long)]
    from: Option<PathBuf>,
}

impl From {
    fn read(&self) -> Result<Option<String>, Error> {
        self.from
            .as_ref()
            .map(|path| std::fs::read_to_string(path).map_err(|e| Error::new(format!("{}: {e}", path.display()))))
            .transpose()
    }
}

#[derive(Args)]
struct KeyArgs {
    id: String,
    key: String,
    /// The slot of a key with slots, as a luks-key.
    #[arg(long, default_value_t = 0)]
    slot: u32,
}

impl KeyArgs {
    fn secret(&self) -> Secret<'_> {
        Secret {
            id: &self.id,
            key: &self.key,
            slot: self.slot,
        }
    }
}

#[derive(Subcommand)]
enum IdentityCommand {
    /// Creates the entity's identity, its public key and, but for a root, its sops file.
    Create {
        id: String,
        #[command(flatten)]
        from: From,
    },
    /// Replaces the identity of an entity other than a host, and encrypts to the new one what was to the old.
    Rotate {
        id: String,
        #[command(flatten)]
        from: From,
    },
    /// The entity's age key.
    Show { id: String },
    /// Moves each entity's age-key from its sops file to its identity file.
    Migrate,
}

#[derive(Subcommand)]
enum SecretCommand {
    /// Stores a new secret, generated or from a file, and writes its public key.
    Generate {
        #[command(flatten)]
        key: KeyArgs,
        #[command(flatten)]
        from: From,
    },
    /// The secret.
    Show {
        #[command(flatten)]
        key: KeyArgs,
    },
    /// Removes the secret.
    Remove {
        #[command(flatten)]
        key: KeyArgs,
    },
    /// The sha512-crypt hash of a password.
    Hash { id: String, key: String },
}

#[derive(Subcommand)]
enum PublicKeyCommand {
    /// Writes the public key the secret derives.
    Write { id: String, key: String },
    /// Fails unless the public key is the one the secret derives.
    Verify { id: String, key: String },
}

#[derive(Subcommand)]
enum HostCommand {
    /// Fails unless the host has its identity, a luks-key, or the ssh-key its public key is.
    Check {
        #[command(flatten)]
        key: KeyArgs,
    },
    /// Gives the host a new identity or luks-key, which the org stores once the host has taken it.
    Push {
        id: String,
        key: String,
        #[command(flatten)]
        from: From,
    },
    /// Has the host drop a luks-key, and then the org.
    Revoke {
        id: String,
        key: String,
        #[arg(long)]
        slot: u32,
    },
    /// Writes the ssh-key the host answers with as its public key.
    PullSshKey { id: String },
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

    // Accommodating for nix eval, whose stderr has said why already.
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

fn lines(lines: impl IntoIterator<Item = impl AsRef<str>>) {
    for line in lines {
        println!("{}", line.as_ref());
    }
}

fn query(org: &Export, json: &str, command: Command) -> Result<(), Error> {
    match command {
        Command::Export => print!("{json}"),
        Command::Get { path } => get(json, &path)?,
        Command::Search { text } => lines(org.entities.keys().filter(|id| id.contains(&text))),
        Command::Entities { groups } => lines(org.expand(groups.iter().map(String::as_str))?),
        Command::Keys { class } => {
            let class = org
                .classes
                .get(&class)
                .ok_or_else(|| Error::new(format!("no class {class}")))?;
            lines(&class.keys);
        }
        Command::Grants { id } => lines(org.expand(org.entity(&id)?.grants.iter().map(String::as_str))?),
        Command::Recipients { id } => lines(org.recipients(&id)?),
        Command::Ops { name } => {
            let groups = org.ops.get(&name).ok_or_else(|| Error::new(format!("no ops {name}")))?;
            for (group, ops) in groups {
                for id in org.members(group)? {
                    lines(ops.iter().map(|op| format!("{id} {op}")));
                }
            }
        }
        _ => unreachable!(),
    }
    Ok(())
}

fn act(org: &Org, command: Command) -> Result<(), Error> {
    if !matches!(command, Command::Path(_) | Command::SopsYaml { .. }) {
        match org.acting_as() {
            Ok(Some(id)) => util::log(format!("acting as {id}")),
            Ok(None) => util::log("acting as an identity the org doesn't have"),
            Err(_) => {}
        }
    }
    match command {
        Command::SopsYaml { group } => {
            let mut missing = Vec::new();
            print!("{}", org.export.sops_yaml(&org.root, &group, &mut missing)?);
            for line in missing {
                util::log(format!("warning: {line}"));
            }
        }
        Command::Path(path) => {
            let entity = |id: &str| org.export.entity(id);
            let path = match path {
                PathCommand::PublicKey { id, key } => entity(&id)?
                    .public_keys
                    .get(&key)
                    .cloned()
                    .ok_or_else(|| Error::new(format!("{id} has no {key}")))?,
                PathCommand::SopsFile { id } => entity(&id)?
                    .secrets
                    .sops_file
                    .clone()
                    .ok_or_else(|| Error::new(format!("{id} has no sops file")))?,
                PathCommand::Identity { id } => entity(&id)?
                    .secrets
                    .identity_file
                    .clone()
                    .ok_or_else(|| Error::new(format!("{id} has no identity")))?,
            };
            println!("{path}");
        }
        Command::Identity(command) => match command {
            IdentityCommand::Create { id, from } => org.create_identity(&id, from.read()?)?,
            IdentityCommand::Rotate { id, from } => org.rotate_identity(&id, from.read()?)?,
            IdentityCommand::Show { id } => print!("{}", org.show_identity(&id)?),
            IdentityCommand::Migrate => org.migrate_identities()?,
        },
        Command::Secret(command) => match command {
            SecretCommand::Generate { key, from } => org.generate_secret(key.secret(), from.read()?)?,
            SecretCommand::Show { key } => print!("{}", org.show_secret(key.secret())?),
            SecretCommand::Remove { key } => org.remove_secret(key.secret())?,
            SecretCommand::Hash { id, key } => println!("{}", org.hash_password(&id, &key)?),
        },
        Command::PublicKey(command) => match command {
            PublicKeyCommand::Write { id, key } => org.write_public_key(&id, &key)?,
            PublicKeyCommand::Verify { id, key } => org.verify_public_key(&id, &key)?,
        },
        Command::Host(command) => match command {
            HostCommand::Check { key } => org.check_on_host(&key.id, &key.key, key.slot)?,
            HostCommand::Push { id, key, from } => org.push_to_host(&id, &key, from.read()?)?,
            HostCommand::Revoke { id, key, slot } => org.revoke_on_host(&id, &key, slot)?,
            HostCommand::PullSshKey { id } => org.pull_ssh_key(&id)?,
        },
        Command::Reencrypt => org.reencrypt(true)?,
        command => return query(&org.export, "", command),
    }
    Ok(())
}

fn run(cli: Cli) -> Result<(), Error> {
    let json = match &cli.export {
        Some(path) => Export::read(path)?,
        None => Export::evaluate(&cli.org)?,
    };
    let export = Export::parse(&json)?;
    match cli.command {
        command @ (Command::Export
        | Command::Get { .. }
        | Command::Search { .. }
        | Command::Entities { .. }
        | Command::Keys { .. }
        | Command::Grants { .. }
        | Command::Recipients { .. }
        | Command::Ops { .. }) => query(&export, &json, command),
        command => act(&Org { export, root: cli.org }, command),
    }
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
