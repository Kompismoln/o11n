mod base;
mod files;
mod git;
mod index;
mod parts;
mod refs;
mod settings;
mod stamps;
mod systems;
mod tree;

use std::io::Write;
use std::process::ExitCode;

use clap::{Parser, Subcommand};

/// Reads o11n's clone and decides for the scripts of dev/, from the clone's root.
#[derive(Parser)]
#[command(version)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// The commit to stamp against: refs/stamped/<branch> while HEAD is on it, else the commit the turn started at, in
    /// dev/state/turn-start, else where HEAD left the main branch settings.toml names.
    Base,
    /// The main branch settings.toml names.
    Main,
    /// The stages settings.toml has a hook of dev/agent.sh refuse work for or tell of when they fail, on a line.
    Hook { hook: String, kind: String },
    /// The files that match any of the patterns, or every file without any, as git tracks them or would, or, in a
    /// directory without git, as they are under it; each that is a file now, NUL-separated. A pattern's `*` matches `/`.
    Files {
        /// The docs that hold no stamps pending, instead.
        #[arg(long, conflicts_with = "patterns")]
        unheld: bool,
        patterns: Vec<String>,
    },
    /// The stamps pending in the docs: each a git conflict from `<<<<<<< signed` to `=======` as the operator last
    /// signed it, and on to the closing `>>>>>>>` as written now.
    #[command(subcommand)]
    Stamps(StampsCommand),
    /// The references the docs make.
    #[command(subcommand)]
    Refs(RefsCommand),
    /// The index of each part's interface, in docs/index/, from the flake's `index`, as `nix eval .#index` evaluates it.
    #[command(subcommand)]
    Index(IndexCommand),
    /// The parts of o11n, as dev/parts.toml declares them.
    #[command(subcommand)]
    Parts(PartsCommand),
    /// The systems of the org whose clone ORG names, with this clone's tree as their o11n.
    #[command(subcommand)]
    Systems(SystemsCommand),
}

#[derive(Subcommand)]
enum SystemsCommand {
    /// Builds the org's eval stage.
    Check {
        /// Passed to nix, as an org's stubs.
        #[arg(last = true)]
        args: Vec<String>,
    },
    /// Says of each host whether its system differs between two revisions of the clone, without o11n's tree, and
    /// fails if one does.
    Compare {
        old: String,
        new: String,
        #[arg(required = true)]
        hosts: Vec<String>,
        /// Passed to nix, as an org's stubs.
        #[arg(last = true)]
        args: Vec<String>,
    },
}

#[derive(Subcommand)]
enum StampsCommand {
    /// In a clone, writes a stamp around each change to a doc since the commit, against what the operator had signed
    /// of it there.
    Write {
        #[arg(default_value = "")]
        commit: String,
        /// Writes nothing, and flags, and fails for, each doc it would write.
        #[arg(long)]
        check: bool,
    },
    /// Flags a conflict marker that isn't a stamp's and a stamp that isn't closed, in a clone or a directory without
    /// git, and fails if it flags any.
    Check { dir: Option<String> },
    /// Flags what check does, and the stamps pending as well.
    Pending { dir: Option<String> },
    /// A doc as written now, its stamps pending applied.
    Applied { doc: String },
}

#[derive(Subcommand)]
enum RefsCommand {
    /// Flags, and fails for, each reference a doc makes, outside its code blocks and what a stamp pending holds as
    /// signed, that doesn't resolve: a path in backticks whose first part is at the clone's root, and that git doesn't
    /// ignore as what a tool writes, or a commit that isn't on main. A reference the text says is elsewhere is left
    /// alone: after "former" or "<owner>/<repo>'s", or before "in <owner>/<repo>".
    Check,
}

#[derive(Subcommand)]
enum IndexCommand {
    /// Writes docs/index/<part>.md for each part with entries, and removes those of parts with none.
    Write,
    /// Flags, and fails for, each doc of docs/index/ that differs from what write would write, its stamps pending read
    /// as written now.
    Check,
}

#[derive(Subcommand)]
enum PartsCommand {
    /// Flags, and fails for, what dev/parts.toml holds amiss: a stage or a layer that isn't one of its stages or
    /// layers, a part's code or doc that isn't there, a file two parts hold, and an index of no part.
    Check,
}

fn flagged(flags: &[String]) -> ExitCode {
    for flag in flags {
        eprintln!("flag: {flag}");
    }
    if flags.is_empty() {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}

fn listed(paths: &[String]) -> ExitCode {
    let mut out = std::io::stdout().lock();
    for path in paths {
        if out
            .write_all(path.as_bytes())
            .and_then(|()| out.write_all(b"\0"))
            .is_err()
        {
            return ExitCode::FAILURE;
        }
    }
    ExitCode::SUCCESS
}

fn main() -> ExitCode {
    if let Err(message) = tree::run_built() {
        return failed(&message);
    }
    let said = match Cli::parse().command {
        Command::Files { unheld, patterns } => {
            return match if unheld {
                files::unheld()
            } else {
                files::matching(&patterns)
            } {
                Ok(paths) => listed(&paths),
                Err(message) => failed(&message),
            };
        }
        Command::Base => return said(base::base()),
        Command::Main => return said(settings::read().map(|settings| settings.main)),
        Command::Hook { hook, kind } => {
            return said(
                settings::read().and_then(|settings| settings.stages(&hook, &kind).map(|stages| stages.join(" "))),
            );
        }
        Command::Stamps(command) => return stamped(command),
        Command::Refs(RefsCommand::Check) => refs::check(),
        Command::Index(IndexCommand::Write) => index::index(false),
        Command::Index(IndexCommand::Check) => index::index(true),
        Command::Parts(PartsCommand::Check) => parts::check(),
        Command::Systems(command) => {
            return match command {
                SystemsCommand::Check { args } => systems::check(&args),
                SystemsCommand::Compare { old, new, hosts, args } => systems::compare(&old, &new, &hosts, &args),
            }
            .unwrap_or_else(|message| failed(&message));
        }
    };
    match said {
        Ok(flags) => flagged(&flags),
        Err(message) => failed(&message),
    }
}

// Policy: stamps says why it fails in words of its own, `stamps: ...`, as its callers and tests read them.
fn stamped(command: StampsCommand) -> ExitCode {
    let flags = match command {
        StampsCommand::Write { commit, check } => stamps::write(&commit, check),
        StampsCommand::Check { dir } => stamps::scan(false, dir.as_deref()),
        StampsCommand::Pending { dir } => stamps::scan(true, dir.as_deref()),
        StampsCommand::Applied { doc } => stamps::applied(&doc).map(|text| {
            print!("{text}");
            Vec::new()
        }),
    };
    match flags {
        Ok(flags) if flags.is_empty() => ExitCode::SUCCESS,
        Ok(flags) => {
            for flag in flags {
                eprintln!("flag: {flag}");
            }
            ExitCode::FAILURE
        }
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}

fn said(answer: Result<String, String>) -> ExitCode {
    match answer {
        Ok(answer) => {
            println!("{answer}");
            ExitCode::SUCCESS
        }
        Err(message) => failed(&message),
    }
}

fn failed(message: &str) -> ExitCode {
    eprintln!("o11n-dev: {message}");
    ExitCode::FAILURE
}
