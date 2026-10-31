use std::process::Command;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;

use crate::Error;
use crate::keys::{self, Kind};
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
        let name = self.host_name(id)?;
        Ok(run(Command::new("find-route.sh").arg(name), None)?.trim().to_owned())
    }

    // Dependency: nixos/org/locksmith.sh takes one line as a secret to confirm, two as one to change it with.
    fn locksmith(&self, id: &str, key: &str, lines: &[&str]) -> Result<String, Error> {
        let address = self.address(id)?;
        let ssh_key = self.required(Secret {
            id: "service-locksmith",
            key: "ssh-key",
            slot: 0,
        })?;
        let temp = TempDir::new()?;
        let identity = temp.file("locksmith", &ssh_key)?;
        let payload: Vec<String> = lines.iter().map(|line| STANDARD.encode(line)).collect();
        run(
            Command::new("ssh")
                .args(["-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-i"])
                .arg(&identity)
                .arg(format!("locksmith@{address}"))
                .arg(key),
            Some(&(payload.join("\n") + "\n")),
        )
    }

    fn scanned_ssh_key(&self, id: &str) -> Result<String, Error> {
        let address = self.address(id)?;
        let scan = run(Command::new("ssh-keyscan").arg("-q").arg(&address), None)?;
        let fields: Vec<&str> = scan.lines().next().unwrap_or_default().split_whitespace().collect();
        match fields.as_slice() {
            [_, kind, key, ..] => Ok(format!("{kind} {key}\n")),
            _ => Err(Error::new(format!("ssh-keyscan: {address} gave no key"))),
        }
    }

    pub fn check_on_host(&self, id: &str, key: &str, slot: u32) -> Result<(), Error> {
        let secret = Secret { id, key, slot };
        match self.kind(secret)? {
            Kind::Age => {
                self.locksmith(id, key, &[&self.identity(id)?])?;
            }
            Kind::Passphrase { slots: true, .. } => {
                self.locksmith(id, key, &[&self.required(secret)?])?;
            }
            Kind::Ssh => {
                let path = self.public_path(id, key)?;
                let public =
                    crate::util::read(&path)?.ok_or_else(|| Error::new(format!("there's no {}", path.display())))?;
                let scanned = self.scanned_ssh_key(id)?;
                if public != scanned {
                    return Err(Error::new(format!(
                        "{id} has another ssh-key:\n< {}\n> {}",
                        public.trim(),
                        scanned.trim()
                    )));
                }
            }
            _ => return Err(Error::new(format!("a host's {key} can't be checked on it"))),
        }
        log(format!("{id} has its {key}"));
        Ok(())
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
            Kind::Passphrase { slots: true, .. } => {
                let slots = self.slots(id, key)?;
                let first = *slots
                    .first()
                    .ok_or_else(|| Error::new(format!("{id} has no {key} to add one with")))?;
                let current = self.required(Secret { id, key, slot: first })?;
                let slot = (0..=u32::try_from(slots.len()).unwrap_or(u32::MAX))
                    .find(|slot| !slots.contains(slot))
                    .unwrap_or_default();
                let value = match from {
                    Some(value) => value,
                    None => keys::generate(kind, id, None)?,
                };
                keys::validate(kind, key, &value, None)?;
                self.locksmith(id, key, &[&current, &value])?;
                log(format!(
                    "{id} took a {key} for slot {slot}, on the strength of slot {first}"
                ));
                self.store(Secret { id, key, slot }, &value)
            }
            _ => Err(Error::new(format!("a host's {key} isn't pushed to it"))),
        }
    }

    pub fn revoke_on_host(&self, id: &str, key: &str, slot: u32) -> Result<(), Error> {
        let secret = Secret { id, key, slot };
        if !self.kind(secret)?.has_slots() {
            return Err(Error::new(format!("a host's {key} isn't revoked on it")));
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
