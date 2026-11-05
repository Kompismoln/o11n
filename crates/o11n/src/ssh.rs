use std::path::PathBuf;
use std::process::Command;
use std::sync::OnceLock;

use crate::Error;
use crate::store::Org;
use crate::util::{self, TempDir};

static SHARED: OnceLock<TempDir> = OnceLock::new();

// Fact: a unix socket's path is at most 107 bytes, and ssh names one %C, 40 characters, in the directory.
const SOCKET_DIR: usize = 60;

/// Has ssh share a connection to each user at each host until `close`, if the temporary directory leaves room for its
/// sockets.
pub fn share() -> Result<(), Error> {
    let temp = TempDir::new()?;
    if temp.path().as_os_str().len() <= SOCKET_DIR {
        let _ = SHARED.set(temp);
    }
    Ok(())
}

pub fn close() {
    let Some(temp) = SHARED.get() else { return };
    for socket in std::fs::read_dir(temp.path()).into_iter().flatten().flatten() {
        let _ = Command::new("ssh")
            .arg("-o")
            .arg(format!("ControlPath={}", socket.path().display()))
            .args(["-O", "exit", "shared"])
            .output();
    }
    let _ = std::fs::remove_dir_all(temp.path());
}

pub fn shared() -> bool {
    SHARED.get().is_some()
}

pub struct Ssh {
    pub command: Command,
    _known_hosts: TempDir,
}

impl Org {
    // Policy: a host is known by the ssh-key the org has the public key of, and by no other, wherever o11n reaches it.
    pub fn pinned_ssh(&self, id: &str, user: &str, mut command: Command) -> Result<Ssh, Error> {
        let name = &self.entity(id)?.name;
        let address = self.export.route(name, 22)?;
        let path = self.public_path(id, "ssh-key")?;
        let public = util::read(&path)?.ok_or_else(|| {
            Error::new(format!(
                "there's no {}: o11n host pull-ssh-key {id}",
                path.strip_prefix(&self.root).unwrap_or(&path).display()
            ))
        })?;
        let known_hosts = TempDir::new()?;
        let file = known_hosts.file("known_hosts", &format!("{id} {}\n", public.trim()))?;
        command
            .args(["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes"])
            .args(["-o", "GlobalKnownHostsFile=/dev/null"])
            .arg("-o")
            .arg(format!("UserKnownHostsFile={}", file.display()))
            .arg("-o")
            .arg(format!("HostKeyAlias={id}"));
        if let Some(shared) = SHARED.get() {
            let sockets: PathBuf = shared.path().join("%C");
            command
                .args(["-o", "ControlMaster=auto", "-o", "ControlPersist=yes"])
                .arg("-o")
                .arg(format!("ControlPath={}", sockets.display()));
        }
        command.arg(format!("{user}@{address}"));
        Ok(Ssh {
            command,
            _known_hosts: known_hosts,
        })
    }
}
