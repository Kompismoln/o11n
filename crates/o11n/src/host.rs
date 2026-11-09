use std::process::Command;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;

use crate::Error;
use crate::keys::{self, Kind};
use crate::ssh::Ssh;
use crate::store::{Org, Secret};
use crate::util::{TempDir, log, run};

impl Org {
    fn host_name<'a>(&'a self, id: &str) -> Result<&'a str, Error> {
        let entity = self.entity(id)?;
        if entity.class != "host" {
            return Err(Error::new(format!("{id} is no host")));
        }
        Ok(&entity.name)
    }

    fn address(&self, id: &str) -> Result<String, Error> {
        self.export.route(self.host_name(id)?, 22)
    }

    // Dependency: nixos/services/locksmith.sh takes one line as a secret to confirm, two as one to change it with, and
    // the same twice as one to drop, a luks-key, or to keep alone, an identity.
    fn locksmith(&self, id: &str, key: &str, lines: &[&str]) -> Result<String, Error> {
        let (mut ssh, _identity) = self.locksmith_ssh(id, &[])?;
        let payload: Vec<String> = lines.iter().map(|line| STANDARD.encode(line)).collect();
        run(ssh.command.arg(key), Some(&(payload.join("\n") + "\n")))
    }

    pub fn locksmith_ssh(&self, id: &str, options: &[&str]) -> Result<(Ssh, TempDir), Error> {
        self.host_name(id)?;
        let ssh_key = self.required(Secret {
            id: "service-locksmith",
            key: "ssh-key",
            slot: 0,
        })?;
        let temp = TempDir::new()?;
        let identity = temp.file("locksmith", &ssh_key)?;
        let mut ssh = Command::new("ssh");
        ssh.args(options)
            .args(["-o", "IdentitiesOnly=yes", "-i"])
            .arg(&identity);
        Ok((self.pinned_ssh(id, "locksmith", ssh)?, temp))
    }

    fn scanned_ssh_key(&self, id: &str) -> Result<String, Error> {
        let address = self.address(id)?;
        // Fact: a host has an ed25519 key alone (nixos/org/ssh.nix), and each other type ssh-keyscan asks for is a
        // failed negotiation in its sshd's log.
        let scan = run(
            Command::new("ssh-keyscan").args(["-q", "-t", "ed25519"]).arg(&address),
            None,
        )?;
        let fields: Vec<&str> = scan.lines().next().unwrap_or_default().split_whitespace().collect();
        match fields.as_slice() {
            [_, kind, key, ..] => Ok(format!("{kind} {key}\n")),
            _ => Err(Error::new(format!("ssh-keyscan: {address} gave no key"))),
        }
    }

    pub fn check_on_host(&self, id: &str, key: &str, slot: u32) -> Result<(), Error> {
        self.confirm_on_host(id, key, slot)?;
        log(format!("{id} has its {key}"));
        Ok(())
    }

    // Dependency: org/entity.nix gives a host's ssh-key a public key and no secret.
    pub fn confirm_on_host(&self, id: &str, key: &str, slot: u32) -> Result<(), Error> {
        self.host_name(id)?;
        if key == "ssh-key" {
            let path = self.public_path(id, key)?;
            let public = crate::util::read(&path)?
                .ok_or_else(|| Error::new(format!("there's no {}: o11n host pull-ssh-key {id}", path.display())))?;
            let scanned = self.scanned_ssh_key(id)?;
            if public != scanned {
                return Err(Error::new(format!(
                    "{id} has another ssh-key: o11n host pull-ssh-key {id}, if it's the host:\n< {}\n> {}",
                    public.trim(),
                    scanned.trim()
                )));
            }
            return Ok(());
        }
        let secret = Secret { id, key, slot };
        match self.kind(secret)? {
            Kind::Age => {
                self.locksmith(id, key, &[&self.identity(id)?])?;
            }
            Kind::Passphrase { slots: true, .. } => {
                self.locksmith(id, key, &[&self.required(secret)?])?;
            }
            _ => return Err(Error::new(format!("a host's {key} can't be checked on it"))),
        }
        Ok(())
    }

    // Policy: the initrd the host boots next has a luks-key that opens its disk, and it's the one a deployment writes,
    // the org's slot 0, unless the org has none.
    pub fn confirm_initrd_key(&self, id: &str, deployed: &str) -> Result<(), Error> {
        self.host_name(id)?;
        self.locksmith(id, "initrd-key", &[deployed]).map(|_| ())
    }

    // Policy: the org stores a new identity or luks-key once the host has taken it, so that neither holds one the
    // other hasn't.
    pub fn push_to_host(&self, id: &str, key: &str, from: Option<String>) -> Result<(), Error> {
        let kind = self.kind(Secret { id, key, slot: 0 })?;
        match kind {
            Kind::Age => {
                self.verify_public_key(id, key)?;
                let current = self.identity(id)?;
                let identity = match from {
                    Some(identity) => identity,
                    None => keys::generate(kind, id, None)?,
                };
                let public = keys::public(kind, key, &identity, None)?;
                self.locksmith(id, key, &[&current, &identity])?;
                log(format!("{id} took its new identity"));
                self.write(&self.public_path(id, key)?, &public, false)?;
                self.write_identity(id, &identity)?;
                self.reencrypt_for(id)
            }
            // Policy: slot 0 is the luks-key a deployment writes, so the new one takes it, and the one it held, which
            // still opens the disk for the initrd until a deployment, moves to a free slot.
            Kind::Passphrase { slots: true, .. } => {
                let slots = self.slots(id, key)?;
                let first = *slots
                    .first()
                    .ok_or_else(|| Error::new(format!("{id} has no {key} to add one with")))?;
                let current = self.required(Secret { id, key, slot: first })?;
                let value = match from {
                    Some(value) => value,
                    None => keys::generate(kind, id, None)?,
                };
                keys::validate(kind, key, &value, None)?;
                self.locksmith(id, key, &[&current, &value])?;
                if first == 0 {
                    let free = (1..=u32::try_from(slots.len()).unwrap_or(u32::MAX))
                        .find(|slot| !slots.contains(slot))
                        .unwrap_or_default();
                    self.store(Secret { id, key, slot: free }, &current)?;
                    log(format!(
                        "{id} took a {key} for slot 0, and the one it held moved to slot {free}"
                    ));
                } else {
                    log(format!("{id} took a {key} for slot 0, on the strength of slot {first}"));
                }
                self.store(Secret { id, key, slot: 0 }, &value)
            }
            _ => Err(Error::new(format!("a host's {key} isn't pushed to it"))),
        }
    }

    pub fn revoke_on_host(&self, id: &str, key: &str, slot: Option<u32>) -> Result<(), Error> {
        let kind = self.kind(Secret { id, key, slot: 0 })?;
        if kind == Kind::Age {
            if slot.is_some() {
                return Err(Error::new(format!("a host's {key} has no slots")));
            }
            self.verify_public_key(id, key)?;
            let identity = self.identity(id)?;
            self.locksmith(id, key, &[&identity, &identity])?;
            log(format!("{id} dropped every identity but its current one"));
            return Ok(());
        }
        if !kind.has_slots() {
            return Err(Error::new(format!("a host's {key} isn't revoked on it")));
        }
        let slot = slot.ok_or_else(|| Error::new(format!("which of {id}'s {key}s: --slot <slot>")))?;
        let secret = Secret { id, key, slot };
        if slot == 0 {
            return Err(Error::new(format!(
                "slot 0 is the {key} a deployment writes: o11n host push {id} {key} gives it a new one, and the one it held another slot"
            )));
        }
        let value = self.required(secret)?;
        if self.slots(id, key)?.len() < 2 {
            return Err(Error::new(format!(
                "{} is the last {key} the org holds for {id}",
                secret.describe()
            )));
        }
        self.locksmith(id, key, &[&value, &value])?;
        log(format!("{id} dropped {}", secret.describe()));
        self.unset(secret)
    }

    pub fn pull_ssh_key(&self, id: &str) -> Result<(), Error> {
        let scanned = self.scanned_ssh_key(id)?;
        self.write(&self.public_path(id, "ssh-key")?, &scanned, false)
    }
}
