mod acting;
mod allotments;
mod builder;
mod deploy;
mod dns;
mod export;
mod groups;
mod host;
mod keycloak;
mod keys;
mod openwrt;
mod remote;
mod route;
mod secrets;
mod sops;
mod ssh;
mod state;
mod status;
mod store;
mod util;
mod version;

use std::fmt;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use clap::{Args, Parser, Subcommand};

use export::Export;
use store::{Org, Secret};

// Dependency: nixos/org/nix.nix keeps the org a host is built from here.
fn default_org() -> PathBuf {
    if Path::new("org.toml").exists() {
        PathBuf::from(".")
    } else {
        PathBuf::from("/etc/nix/inputs/self")
    }
}

/// Reads an evaluated org and acts on it.
#[derive(Parser)]
#[command(version)]
struct Cli {
    /// The org's clone: by default the working directory if it holds an org.toml, or else the org a host is built from.
    #[arg(long, env = "O11N_ORG_ROOT", default_value_os_t = default_org())]
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
    /// The keys of the entity, or those every entity of the class has.
    Keys { of: String },
    /// The members of the entity's grants.
    Grants { id: String },
    /// The entities that decrypt the entity's sops file.
    Recipients { id: String },
    /// Checks each entity of the groups, all of them by default, by what it has: its keys and secrets, its host, and
    /// what it serves; a line each, ok, fail or skip, a skip for what needs a secret the operator can't decrypt.
    Status {
        #[arg(default_value = "*")]
        groups: Vec<String>,
        /// The checks, without running them.
        #[arg(long)]
        list: bool,
        /// Only the checks that fail.
        #[arg(long, conflicts_with = "list")]
        failed: bool,
    },
    /// The address the name answers at: as it is, if dotted, or in each of the org's namespaces in turn.
    Route {
        name: String,
        #[arg(long, default_value_t = 22)]
        port: u16,
    },
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
    /// Runs the command as the entity: its identity as sops', its ssh-key in an ssh-agent of its own.
    As {
        id: String,
        #[arg(required = true, trailing_var_arg = true, allow_hyphen_values = true)]
        command: Vec<String>,
    },
    /// Logs in to the host as the entity, or runs the command there.
    Ssh {
        id: String,
        host: String,
        /// The user on the host, rather than the entity's name.
        #[arg(long)]
        user: Option<String>,
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        command: Vec<String>,
    },
    /// Installs the host's system with nixos-anywhere on the machine at <host>.<endpoint>, booted into an installer
    /// that lets root in with service-rescue's ssh-key.
    Reset { host: String },
    /// The text of a systemd unit of the host's configuration, or of another's.
    Unit {
        unit: String,
        host: String,
        /// The configuration whose unit it is, rather than the host's.
        #[arg(long)]
        from: Option<String>,
        /// Copies it to the host's /run/systemd/system as root, with service-rescue's ssh-key, rather than print it.
        #[arg(long)]
        inject: bool,
    },
    /// A server's reverse tunnel, which a machine booted from the rescue stick calls in through.
    Tunnel {
        server: String,
        #[command(subcommand)]
        action: remote::TunnelAction,
    },
    /// A stateful principal's state, on the hosts it's on.
    #[command(subcommand)]
    State(StateCommand),
    /// Builds the image of the org's rescue-usb.
    Image {
        #[arg(default_value = "iso-installer")]
        variant: String,
    },
    #[command(subcommand)]
    Remote(builder::RemoteCommand),
    /// A router that runs `OpenWrt`.
    #[command(subcommand)]
    Openwrt(openwrt::OpenwrtCommand),
    /// Builds the host's system and prints it.
    Build {
        host: String,
        #[command(flatten)]
        build_host: BuildHost,
        /// nix's options, when localhost builds.
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        nix_options: Vec<String>,
    },
    /// Builds the host's system and switches the host to it, which substitutes it from the build host.
    Apply {
        host: String,
        #[command(flatten)]
        build_host: BuildHost,
    },
    /// Encrypts every sops file to its recipients, and every identity to itself, its actors and the root identities, as
    /// the org declares them.
    Reencrypt,
}

#[derive(Subcommand)]
enum StateCommand {
    /// Downloads the principal's home from each host it's on, as root with service-rescue's ssh-key, compressed there,
    /// to <id>@<host>-<local time>.tar.zst, once it has said how much there is.
    Fetch {
        id: String,
        /// The directory to download to.
        #[arg(long, default_value = ".")]
        dir: PathBuf,
    },
    /// Lists the snapshots of the principal's archive, on each host it archives to.
    Snapshots {
        id: String,
        /// The host it archives to, of those it does.
        #[arg(long)]
        from: Option<String>,
    },
    /// Restores a snapshot of the principal's archive: into its home on a host, which has to be empty, or as
    /// <id>@<host>-<snapshot>.tar.zst in a directory.
    Restore {
        id: String,
        /// The host it archives to, of those it does, or its only one.
        #[arg(long)]
        from: Option<String>,
        /// The host the snapshot was taken on, by default the one restored to, or the principal's only one.
        #[arg(long)]
        of: Option<String>,
        /// The snapshot, by its id.
        #[arg(long, default_value = "latest")]
        snapshot: String,
        /// The host to restore into the principal's home on.
        #[arg(long, conflicts_with = "dir", required_unless_present = "dir")]
        to: Option<String>,
        /// The directory to download to.
        #[arg(long)]
        dir: Option<PathBuf>,
    },
    /// Forgets and prunes what each archive's prune doesn't keep, on each host the principal archives to that has one.
    Prune {
        id: String,
        /// The host it archives to, of those it does.
        #[arg(long)]
        from: Option<String>,
    },
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
struct BuildHost {
    /// The host that builds: one of the org's build-hosts, its first by default, or localhost.
    #[arg(long, env = "BUILD_HOST")]
    build_host: Option<String>,
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
    /// Edits the entity's sops file in sops' editor.
    Edit { id: String },
    /// What the sops files of the groups' members hold that isn't one of their keys, a line `<id> <path>` each, the
    /// path from the file's top; a file the operator can't decrypt is said and passed over.
    Extra {
        #[arg(default_value = "*")]
        groups: Vec<String>,
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
    /// Has the host drop a luks-key, and then the org, but for slot 0, which a deployment writes, and the one in the
    /// initrd the host boots next; or every identity but its current one, once its systems' secrets open without them.
    Revoke {
        id: String,
        key: String,
        #[arg(long)]
        slot: Option<u32>,
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
        Command::Keys { of } => {
            let keys = match org.entities.get(&of) {
                Some(entity) => &entity.keys,
                None => {
                    &org.classes
                        .get(&of)
                        .ok_or_else(|| Error::new(format!("no entity or class {of}")))?
                        .keys
                }
            };
            lines(keys.keys());
        }
        Command::Grants { id } => lines(org.expand(org.entity(&id)?.grants.iter().map(String::as_str))?),
        Command::Recipients { id } => lines(org.recipients(&id)?),
        Command::Route { name, port } => println!("{}", org.route(&name, port)?),
        _ => unreachable!(),
    }
    Ok(())
}

fn state(org: &Org, command: StateCommand) -> Result<(), Error> {
    match command {
        StateCommand::Fetch { id, dir } => org.fetch_state(&id, &dir),
        StateCommand::Snapshots { id, from } => org.snapshots(&id, from.as_deref()),
        StateCommand::Restore {
            id,
            from,
            of,
            snapshot,
            to,
            dir,
        } => org.restore(
            &id,
            from.as_deref(),
            of.as_deref(),
            &snapshot,
            match (to, dir) {
                (Some(host), _) => state::Target::Host(host),
                (None, dir) => state::Target::Dir(dir.unwrap_or_default()),
            },
        ),
        StateCommand::Prune { id, from } => org.prune(&id, from.as_deref()),
    }
}

fn act(org: &Org, command: Command) -> Result<(), Error> {
    if !matches!(
        command,
        Command::Path(_) | Command::SopsYaml { .. } | Command::Status { list: true, .. }
    ) {
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
            SecretCommand::Edit { id } => org.edit_secrets(&id)?,
            SecretCommand::Extra { groups } => org.print_extra_secrets(&groups)?,
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
        Command::As { id, command } => org.run_as(&id, &command)?,
        Command::Ssh {
            id,
            host,
            user,
            command,
        } => org.ssh(&id, &host, user, &command)?,
        Command::Build {
            host,
            build_host,
            nix_options,
        } => println!(
            "{}",
            org.build(&host, &org.build_host(build_host.build_host)?, &nix_options)?
        ),
        Command::Apply { host, build_host } => org.apply(&host, &org.build_host(build_host.build_host)?)?,
        Command::Reencrypt => org.reencrypt(true)?,
        Command::Reset { host } => org.reset(&host)?,
        Command::Unit {
            unit,
            host,
            from,
            inject,
        } => org.unit(&unit, &host, from.as_deref(), inject)?,
        Command::Tunnel { server, action } => org.tunnel(&server, action)?,
        Command::Image { variant } => org.image(&variant)?,
        Command::Openwrt(command) => org.openwrt(command)?,
        Command::State(command) => state(org, command)?,
        Command::Status { groups, list, failed } => org.status(&groups, list, failed)?,
        command => return query(&org.export, "", command),
    }
    Ok(())
}

fn run(cli: Cli) -> Result<(), Error> {
    // Policy: the remote builder serves o11n's own tree as well as an org's, so it reads no export.
    if let Command::Remote(command) = cli.command {
        return builder::remote(&cli.org, command);
    }
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
        | Command::Route { .. }) => query(&export, &json, command),
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
