use std::fs::File;
use std::path::Path;
use std::process::Stdio;

use clap::Subcommand;

use crate::Error;
use crate::export::Entity;
use crate::status::Outcome;
use crate::store::Org;
use crate::util::{exited, run};

#[derive(Subcommand)]
pub enum TorrentAction {
    /// Adds each magnet link or URL, or a .torrent file of the operator's, which is sent on stdin.
    Add {
        #[arg(required = true)]
        links: Vec<String>,
        /// The allotment, by its principal's handle, that it downloads into, of those the server downloads into.
        #[arg(long, conflicts_with = "kind")]
        to: Option<String>,
        /// The kind it is, as the media-server's *arrs take it from where that goes: movies, tv or music.
        #[arg(long = "as", value_name = "KIND")]
        kind: Option<String>,
    },
    /// The server's torrents, each by the id the others take.
    List,
    /// Removes the torrents, keeping what they downloaded unless deleted.
    Remove {
        #[arg(required = true)]
        ids: Vec<u32>,
        /// Deletes what they downloaded too.
        #[arg(long)]
        delete: bool,
    },
}

impl Org {
    // Dependency: nixos/services/torrent-server.nix runs nixos/services/torrent-server.sh for the service's ssh-key,
    // with the command as these send it.
    pub fn torrent(&self, host: Option<&str>, action: &TorrentAction) -> Result<(), Error> {
        let id = self.torrent_server(host)?;
        let calls: Vec<(Vec<String>, Option<&Path>)> = match action {
            TorrentAction::Add { links, to, kind } => links
                .iter()
                .map(|link| {
                    let mut args = vec!["add".to_owned()];
                    for (option, value) in [("--to", to), ("--as", kind)] {
                        if let Some(value) = value {
                            if value.is_empty() || value.contains(char::is_whitespace) {
                                return Err(Error::new(format!(
                                    "{option} {value:?}: a name has no whitespace in it"
                                )));
                            }
                            args.extend([option.to_owned(), value.clone()]);
                        }
                    }
                    let path = Path::new(link);
                    if path.is_file() {
                        args.push("-".to_owned());
                        Ok((args, Some(path)))
                    } else if link.contains(char::is_whitespace) {
                        // Fact: ssh joins a command's arguments with spaces, and the server splits them there.
                        Err(Error::new(format!(
                            "{link}: a link has no whitespace in it, as a magnet link encodes it"
                        )))
                    } else {
                        args.push(link.clone());
                        Ok((args, None))
                    }
                })
                .collect::<Result<_, _>>()?,
            TorrentAction::List => vec![(vec!["list".to_owned()], None)],
            TorrentAction::Remove { ids, delete } => {
                let mut args = vec!["remove".to_owned()];
                if *delete {
                    args.push("--delete".to_owned());
                }
                args.extend(ids.iter().map(u32::to_string));
                vec![(args, None)]
            }
        };
        let user = &self.entity("service-torrent-server")?.name;
        let acting = self.acting("service-torrent-server")?;
        for (args, file) in calls {
            let mut ssh = self.pinned_ssh(&id, user, acting.command("ssh"))?;
            ssh.command.args(&args);
            match file {
                Some(path) => {
                    let file = File::open(path).map_err(|e| Error::new(format!("{}: {e}", path.display())))?;
                    ssh.command.stdin(Stdio::from(file));
                }
                None => {
                    ssh.command.stdin(Stdio::null());
                }
            }
            exited(ssh.command.status().map_err(|e| Error::new(format!("ssh: {e}")))?)?;
        }
        Ok(())
    }

    // Policy: the server answers its list to the service's ssh-key, which the operator acts with.
    pub fn torrent_server_outcome(&self, id: &str, entity: &Entity) -> Result<Outcome, Outcome> {
        let acting = self
            .acting("service-torrent-server")
            .map_err(|error| Outcome::Skip(error.to_string().lines().next().unwrap_or_default().to_owned()))?;
        self.reachable(entity)?;
        let user = &self
            .entity("service-torrent-server")
            .map_err(|e| Outcome::Fail(e.to_string()))?
            .name;
        let mut ssh = self
            .pinned_ssh(id, user, acting.command("ssh"))
            .map_err(|e| Outcome::Fail(e.to_string()))?;
        Ok(match run(ssh.command.arg("list"), None) {
            Ok(_) => Outcome::Ok,
            Err(error) => Outcome::Fail(error.to_string()),
        })
    }

    fn torrent_server(&self, host: Option<&str>) -> Result<String, Error> {
        let servers: Vec<String> = self
            .export
            .expand(["host-*"])?
            .into_iter()
            .filter(|id| {
                self.entity(id).is_ok_and(|entity| {
                    entity.class == "host" && entity.services.iter().any(|service| service == "torrent-server")
                })
            })
            .collect();
        match host {
            Some(host) => {
                let id = if host.starts_with("host-") {
                    host.to_owned()
                } else {
                    format!("host-{host}")
                };
                if servers.contains(&id) {
                    Ok(id)
                } else {
                    Err(Error::new(format!("{id} has no torrent-server service")))
                }
            }
            None => match servers.as_slice() {
                [id] => Ok(id.clone()),
                [] => Err(Error::new("no host has the torrent-server service")),
                _ => Err(Error::new(format!(
                    "{} have the torrent-server service: name one with --host",
                    servers.join(", ")
                ))),
            },
        }
    }
}
