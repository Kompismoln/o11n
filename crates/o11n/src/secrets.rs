use crate::Error;
use crate::keys::{self, Kind};
use crate::store::{Org, Secret};
use crate::util::{self, log};

impl Org {
    fn age_key_is_identity(id: &str) -> Error {
        Error::new(format!(
            "an age-key is an identity: o11n identity show|create|rotate {id}"
        ))
    }

    pub fn create_identity(&self, id: &str, from: Option<String>) -> Result<(), Error> {
        let root = self.entity(id)?.class == "root";
        if self.has_identity(id)? {
            return Err(Error::new(format!("{id}'s identity already exists")));
        }
        let identity = match from {
            Some(identity) => identity,
            None => keys::generate(Kind::Age, id, None)?,
        };
        let public = keys::public(Kind::Age, "age-key", &identity, None)?;
        self.write(&self.public_path(id, "age-key")?, &public, false)?;
        self.write_identity(id, &identity)?;
        if root {
            self.reencrypt(true)
        } else {
            self.create_sops_file(id)
        }
    }

    pub fn rotate_identity(&self, id: &str, from: Option<String>) -> Result<(), Error> {
        let class = &self.entity(id)?.class;
        if class == "host" {
            return Err(Error::new(format!(
                "a host's identity is rotated on the host: o11n host push {id} age-key"
            )));
        }
        if self.acting_as()?.as_deref() == Some(id) {
            return Err(Error::new(format!(
                "{id} can't rotate its own identity: act as another root identity"
            )));
        }
        let identity = match from {
            Some(identity) => identity,
            None => keys::generate(Kind::Age, id, None)?,
        };
        let public = keys::public(Kind::Age, "age-key", &identity, None)?;
        self.write(&self.public_path(id, "age-key")?, &public, false)?;
        self.write_identity(id, &identity)?;
        self.reencrypt_for(id)
    }

    // Optimization: sops leaves a file whose recipients are as they were, so each is updated; an identity is written
    // anew only where the entity is one of its actors, or for a root, everywhere.
    pub fn reencrypt_for(&self, id: &str) -> Result<(), Error> {
        if self.entity(id)?.class == "root" {
            return self.reencrypt(true);
        }
        self.reencrypt(false)?;
        for (other, entity) in &self.export.entities {
            if entity.actors.iter().any(|actor| actor == id) && self.has_identity(other)? {
                self.write_identity(other, &self.identity(other)?)?;
            }
        }
        Ok(())
    }

    pub fn reencrypt(&self, identities: bool) -> Result<(), Error> {
        for (id, entity) in &self.export.entities {
            if entity.class == "root" {
                continue;
            }
            self.update_sops_file(id)?;
            if identities && self.has_identity(id)? {
                self.write_identity(id, &self.identity(id)?)?;
            }
        }
        Ok(())
    }

    pub fn migrate_identities(&self) -> Result<(), Error> {
        for (id, entity) in &self.export.entities {
            if entity.class == "root"
                || self.has_identity(id)?
                || !self
                    .path(entity.secrets.sops_file.as_deref().unwrap_or_default())
                    .is_file()
            {
                continue;
            }
            let secret = Secret {
                id,
                key: "age-key",
                slot: 0,
            };
            let Some(identity) = self.secret(secret)? else {
                log(format!("warning: {id} has no age-key to move"));
                continue;
            };
            self.write_identity(id, &identity)?;
            self.unset(secret)?;
        }
        self.reencrypt(false)
    }

    pub fn show_identity(&self, id: &str) -> Result<String, Error> {
        self.identity(id)
    }

    pub fn generate_secret(&self, secret: Secret, from: Option<String>) -> Result<(), Error> {
        let kind = self.kind(secret)?;
        if kind == Kind::Age {
            return Err(Self::age_key_is_identity(secret.id));
        }
        let domain = self.domain(secret.id)?;
        let value = match from {
            Some(value) => value,
            None => keys::generate(kind, secret.id, domain)?,
        };
        keys::validate(kind, secret.key, &value, domain)?;
        self.store(secret, &value)?;
        if !matches!(kind, Kind::Passphrase { .. }) {
            self.write_public_key(secret.id, secret.key)?;
        }
        Ok(())
    }

    pub fn show_secret(&self, secret: Secret) -> Result<String, Error> {
        if self.kind(secret)? == Kind::Age {
            return Err(Self::age_key_is_identity(secret.id));
        }
        self.required(secret)
    }

    pub fn remove_secret(&self, secret: Secret) -> Result<(), Error> {
        if self.kind(secret)? == Kind::Age {
            return Err(Self::age_key_is_identity(secret.id));
        }
        self.required(secret)?;
        self.unset(secret)
    }

    fn derivable(&self, id: &str, key: &str) -> Result<(Kind, String), Error> {
        let secret = Secret { id, key, slot: 0 };
        let kind = self.kind(secret)?;
        let value = if kind == Kind::Age {
            self.identity(id)?
        } else {
            self.required(secret)?
        };
        Ok((kind, value))
    }

    fn hash_key(key: &str) -> String {
        format!("{key}-sha512")
    }

    // Policy: a public key that still matches is left as it is, as a hash or a certificate derived again differs.
    pub fn write_public_key(&self, id: &str, key: &str) -> Result<(), Error> {
        let (kind, value) = self.derivable(id, key)?;
        let domain = self.domain(id)?;
        match kind {
            Kind::Passphrase { .. } => Err(Error::new(format!("a {key} has no public key"))),
            Kind::Password => {
                let hash_key = Self::hash_key(key);
                let stored = Secret {
                    id,
                    key: &hash_key,
                    slot: 0,
                };
                if let Some(hash) = self.secret(stored)?
                    && keys::matches(kind, key, &value, &hash, domain)?
                {
                    return Ok(());
                }
                self.store(stored, &keys::public(kind, key, &value, domain)?)
            }
            _ => {
                let path = self.public_path(id, key)?;
                if let Some(public) = util::read(&path)?
                    && keys::matches(kind, key, &value, &public, domain)?
                {
                    return Ok(());
                }
                self.write(&path, &keys::public(kind, key, &value, domain)?, false)
            }
        }
    }

    pub fn hash_password(&self, id: &str, key: &str) -> Result<String, Error> {
        let (kind, value) = self.derivable(id, key)?;
        if kind != Kind::Password {
            return Err(Error::new(format!("a {key} is no password")));
        }
        keys::public(kind, key, &value, None)
    }

    pub fn verify_public_key(&self, id: &str, key: &str) -> Result<(), Error> {
        let (kind, value) = self.derivable(id, key)?;
        let domain = self.domain(id)?;
        let (place, stored) = match kind {
            Kind::Passphrase { .. } => return keys::validate(kind, key, &value, domain),
            Kind::Password => {
                let hash_key = Self::hash_key(key);
                let stored = self.secret(Secret {
                    id,
                    key: &hash_key,
                    slot: 0,
                })?;
                (format!("{id}'s {hash_key}"), stored)
            }
            _ => {
                let path = self.public_path(id, key)?;
                (
                    path.strip_prefix(&self.root).unwrap_or(&path).display().to_string(),
                    util::read(&path)?,
                )
            }
        };
        let stored = stored.ok_or_else(|| Error::new(format!("there's no {place}")))?;
        if keys::matches(kind, key, &value, &stored, domain)? {
            return Ok(());
        }
        let derived = keys::public(kind, key, &value, domain)?;
        Err(Error::new(format!(
            "{place} isn't the {key}'s public key:\n{}",
            difference(&stored, &derived)
        )))
    }
}

fn difference(stored: &str, derived: &str) -> String {
    let mut lines: Vec<String> = stored.lines().map(|line| format!("< {line}")).collect();
    lines.extend(derived.lines().map(|line| format!("> {line}")));
    lines.join("\n")
}
