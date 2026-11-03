use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::Value;

use crate::Error;
use crate::export::{Entity, Export};
use crate::keys::Kind;
use crate::util::{self, TempDir, log, run};

pub struct Org {
    pub export: Export,
    pub root: PathBuf,
}

#[derive(Clone, Copy)]
pub struct Secret<'a> {
    pub id: &'a str,
    pub key: &'a str,
    pub slot: u32,
}

impl Secret<'_> {
    pub fn stored_key(&self) -> String {
        if self.slot == 0 {
            self.key.to_owned()
        } else {
            format!("{}--{}", self.key, self.slot)
        }
    }

    pub fn describe(&self) -> String {
        if self.slot == 0 {
            format!("{}'s {}", self.id, self.key)
        } else {
            format!("{}'s {} in slot {}", self.id, self.key, self.slot)
        }
    }
}

impl Org {
    pub fn path(&self, relative: &str) -> PathBuf {
        self.root.join(relative)
    }

    pub fn entity(&self, id: &str) -> Result<&Entity, Error> {
        self.export.entity(id)
    }

    pub fn domain(&self, id: &str) -> Result<Option<&str>, Error> {
        let entity = self.entity(id)?;
        Ok((entity.class == "service")
            .then(|| entity.name.strip_prefix("domain-"))
            .flatten())
    }

    pub fn kind(&self, secret: Secret) -> Result<Kind, Error> {
        let keys = &self.entity(secret.id)?.keys;
        let kind = Kind::named(keys.get(secret.key).ok_or_else(|| {
            Error::new(format!(
                "{} isn't one of {}'s keys: {}",
                secret.key,
                secret.id,
                keys.keys().map(String::as_str).collect::<Vec<_>>().join(", ")
            ))
        })?)?;
        if secret.slot != 0 && !kind.has_slots() {
            return Err(Error::new(format!("a {} has no slots", secret.key)));
        }
        Ok(kind)
    }

    pub fn public_path(&self, id: &str, key: &str) -> Result<PathBuf, Error> {
        let path = self
            .entity(id)?
            .public_keys
            .get(key)
            .ok_or_else(|| Error::new(format!("{id} has no {key}")))?;
        Ok(self.path(path))
    }

    pub fn write(&self, path: &Path, contents: &str, private: bool) -> Result<(), Error> {
        if util::read(path)?.as_deref() == Some(contents) {
            return Ok(());
        }
        util::write(path, contents, private)?;
        log(format!(
            "wrote {}",
            path.strip_prefix(&self.root).unwrap_or(path).display()
        ));
        Ok(())
    }

    fn sops_file(&self, id: &str) -> Result<PathBuf, Error> {
        let entity = self.entity(id)?;
        let path = entity
            .secrets
            .sops_file
            .as_ref()
            .ok_or_else(|| Error::new(format!("{id} has no sops file")))?;
        Ok(self.path(path))
    }

    // Dependency: sops-nix on a host reads a host's secrets at the top of its file, another's under its name.
    fn component(&self, id: &str, stored_key: &str) -> Result<Vec<String>, Error> {
        let entity = self.entity(id)?;
        Ok(if entity.class == "host" {
            vec![stored_key.to_owned()]
        } else {
            vec![entity.name.clone(), stored_key.to_owned()]
        })
    }

    fn sops_path(component: &[String]) -> String {
        component.iter().fold(String::new(), |path, name| {
            path + "[" + &Value::from(name.as_str()).to_string() + "]"
        })
    }

    fn decrypted(&self, id: &str) -> Result<Value, Error> {
        self.decrypted_with(id, None)
    }

    fn decrypted_with(&self, id: &str, identity: Option<&Path>) -> Result<Value, Error> {
        let file = self.sops_file(id)?;
        if !file.exists() {
            return Err(Error::new(format!(
                "{id} has no {}: o11n identity create {id}",
                file.display()
            )));
        }
        let mut sops = Command::new("sops");
        sops.args(["decrypt", "--output-type", "json"]).arg(&file);
        if let Some(identity) = identity {
            sops.env("SOPS_AGE_KEY_FILE", identity);
        }
        let json = run(&mut sops, None)?;
        let value: Value = serde_json::from_str(&json).map_err(|e| Error::new(format!("{}: {e}", file.display())))?;
        match value.get("identity").and_then(Value::as_str) {
            Some(identity) if identity == id => Ok(value),
            identity => Err(Error::new(format!(
                "{} is {}'s, not {id}'s",
                file.display(),
                identity.unwrap_or("no one")
            ))),
        }
    }

    pub fn secret(&self, secret: Secret) -> Result<Option<String>, Error> {
        self.secret_with(secret, None)
    }

    fn secret_with(&self, secret: Secret, identity: Option<&Path>) -> Result<Option<String>, Error> {
        let value = self.decrypted_with(secret.id, identity)?;
        let component = self.component(secret.id, &secret.stored_key())?;
        Ok(component
            .iter()
            .try_fold(&value, |value, name| value.get(name))
            .and_then(Value::as_str)
            .map(str::to_owned))
    }

    pub fn required(&self, secret: Secret) -> Result<String, Error> {
        self.secret(secret)?
            .ok_or_else(|| Error::new(format!("there's no {}", secret.describe())))
    }

    pub fn required_as(&self, secret: Secret, identity: &Path) -> Result<String, Error> {
        self.secret_with(secret, Some(identity))?
            .ok_or_else(|| Error::new(format!("there's no {}", secret.describe())))
    }

    pub fn slots(&self, id: &str, key: &str) -> Result<Vec<u32>, Error> {
        let value = self.decrypted(id)?;
        let component = self.component(id, key)?;
        let parent = component[..component.len() - 1]
            .iter()
            .try_fold(&value, |value, name| value.get(name));
        let mut slots: Vec<u32> = parent
            .and_then(Value::as_object)
            .map(|secrets| {
                secrets
                    .keys()
                    .filter_map(|name| {
                        if name == key {
                            Some(0)
                        } else {
                            name.strip_prefix(&format!("{key}--"))
                                .and_then(|slot| slot.parse().ok())
                        }
                    })
                    .collect()
            })
            .unwrap_or_default();
        slots.sort_unstable();
        Ok(slots)
    }

    pub fn store(&self, secret: Secret, value: &str) -> Result<(), Error> {
        let file = self.sops_file(secret.id)?;
        let path = Self::sops_path(&self.component(secret.id, &secret.stored_key())?);
        run(
            Command::new("sops")
                .arg("set")
                .arg(&file)
                .arg(&path)
                .arg(Value::from(value).to_string()),
            None,
        )?;
        log(format!("stored {}", secret.describe()));
        Ok(())
    }

    pub fn unset(&self, secret: Secret) -> Result<(), Error> {
        let file = self.sops_file(secret.id)?;
        let path = Self::sops_path(&self.component(secret.id, &secret.stored_key())?);
        run(Command::new("sops").arg("unset").arg(&file).arg(&path), None)?;
        log(format!("removed {}", secret.describe()));
        Ok(())
    }

    fn sops_config(&self, temp: &TempDir, id: &str) -> Result<(PathBuf, Vec<String>), Error> {
        let mut missing = Vec::new();
        let yaml = self.export.sops_yaml(&self.root, id, &mut missing)?;
        Ok((temp.file("sops.yaml", &yaml)?, missing))
    }

    fn warn(missing: Vec<String>) {
        for line in missing {
            log(format!("warning: {line}"));
        }
    }

    pub fn edit_secrets(&self, id: &str) -> Result<(), Error> {
        let file = self.sops_file(id)?;
        let temp = TempDir::new()?;
        let (config, missing) = self.sops_config(&temp, id)?;
        Self::warn(missing);
        log(format!("editing {}", file.display()));
        let status = Command::new("sops")
            .arg("--config")
            .arg(&config)
            .arg("edit")
            .arg(&file)
            .status()
            .map_err(|e| Error::new(format!("sops: {e}")))?;
        util::exited(status)
    }

    pub fn create_sops_file(&self, id: &str) -> Result<(), Error> {
        let file = self.sops_file(id)?;
        let temp = TempDir::new()?;
        let (config, missing) = self.sops_config(&temp, id)?;
        Self::warn(missing);
        let encrypted = run(
            Command::new("sops")
                .arg("--config")
                .arg(&config)
                .args([
                    "encrypt",
                    "--input-type",
                    "yaml",
                    "--output-type",
                    "yaml",
                    "--filename-override",
                ])
                .arg(&file)
                .arg("/dev/stdin"),
            Some(&format!("identity: {id}\n")),
        )?;
        self.write(&file, &encrypted, false)
    }

    pub fn update_sops_file(&self, id: &str) -> Result<(), Error> {
        let file = self.sops_file(id)?;
        if !file.exists() {
            return Ok(());
        }
        let temp = TempDir::new()?;
        let (config, missing) = self.sops_config(&temp, id)?;
        let before = util::read(&file)?;
        run(
            Command::new("sops")
                .arg("--config")
                .arg(&config)
                .args(["updatekeys", "--yes"])
                .arg(&file),
            None,
        )?;
        if util::read(&file)? != before {
            log(format!(
                "encrypted {} to {id}'s recipients",
                file.strip_prefix(&self.root).unwrap_or(&file).display()
            ));
            Self::warn(missing);
        }
        Ok(())
    }

    fn is_root(&self, id: &str) -> Result<bool, Error> {
        Ok(self.entity(id)?.class == "root")
    }

    fn identity_file(&self, id: &str) -> Result<PathBuf, Error> {
        let entity = self.entity(id)?;
        let path = entity
            .secrets
            .identity_file
            .as_ref()
            .ok_or_else(|| Error::new(format!("{id} has no identity file")))?;
        Ok(self.path(path))
    }

    pub fn has_identity(&self, id: &str) -> Result<bool, Error> {
        Ok(self.identity_file(id)?.exists())
    }

    pub fn identity_recipients(&self, id: &str) -> Result<Vec<String>, Error> {
        let mut ids: Vec<String> = self.export.root_identities.clone();
        ids.push(id.to_owned());
        ids.extend(self.entity(id)?.actors.iter().cloned());
        ids.sort();
        ids.dedup();
        Ok(ids)
    }

    // Policy: the operator's identity is where sops reads it, so that one variable names it for both.
    fn operator() -> Result<String, Error> {
        let path =
            std::env::var_os("SOPS_AGE_KEY_FILE").ok_or_else(|| Error::new("SOPS_AGE_KEY_FILE names no identity"))?;
        util::read(Path::new(&path))?.ok_or_else(|| Error::new(format!("no identity in {}", path.display())))
    }

    pub fn acting_as(&self) -> Result<Option<String>, Error> {
        let public = crate::keys::public(Kind::Age, "age-key", &Self::operator()?, None)?;
        for (id, entity) in &self.export.entities {
            if let Some(path) = entity.public_keys.get("age-key")
                && util::read(&self.path(path))?.as_deref() == Some(public.as_str())
            {
                return Ok(Some(id.clone()));
            }
        }
        Ok(None)
    }

    pub fn identity(&self, id: &str) -> Result<String, Error> {
        let file = self.identity_file(id)?;
        let contents =
            util::read(&file)?.ok_or_else(|| Error::new(format!("{id} has no identity at {}", file.display())))?;
        if self.is_root(id)? {
            return Ok(contents);
        }
        let operator: age::x25519::Identity = Self::operator()?
            .lines()
            .rfind(|line| line.starts_with("AGE-SECRET-KEY-"))
            .ok_or_else(|| Error::new("SOPS_AGE_KEY_FILE holds no age identity"))?
            .parse()
            .map_err(|e| Error::new(format!("SOPS_AGE_KEY_FILE: {e}")))?;
        let decryptor = age::Decryptor::new(age::armor::ArmoredReader::new(contents.as_bytes()))
            .map_err(|e| Error::new(format!("{}: {e}", file.display())))?;
        let mut reader = decryptor
            .decrypt(std::iter::once(&operator as &dyn age::Identity))
            .map_err(|e| Error::new(format!("{}: {e}", file.display())))?;
        let mut identity = String::new();
        std::io::Read::read_to_string(&mut reader, &mut identity)
            .map_err(|e| Error::new(format!("{}: {e}", file.display())))?;
        Ok(identity)
    }

    pub fn write_identity(&self, id: &str, identity: &str) -> Result<(), Error> {
        let file = self.identity_file(id)?;
        if self.is_root(id)? {
            return self.write(&file, identity, true);
        }
        let mut recipients = Vec::new();
        let mut names = Vec::new();
        for recipient in self.identity_recipients(id)? {
            let path = self.public_path(&recipient, "age-key")?;
            let Some(public) = util::read(&path)? else {
                log(format!(
                    "warning: {id}'s identity isn't encrypted to {recipient}, who has no age-key"
                ));
                continue;
            };
            names.push(recipient);
            let recipient: age::x25519::Recipient = public
                .trim()
                .parse()
                .map_err(|e| Error::new(format!("{}: {e}", path.display())))?;
            recipients.push(recipient);
        }
        if recipients.is_empty() {
            return Err(Error::new(format!(
                "{id}'s identity has no one to be encrypted to: create a root identity"
            )));
        }
        let encryptor = age::Encryptor::with_recipients(recipients.iter().map(|r| r as &dyn age::Recipient))
            .map_err(|e| Error::new(format!("{id}'s identity: {e}")))?;
        let mut encrypted = Vec::new();
        let armored = age::armor::ArmoredWriter::wrap_output(&mut encrypted, age::armor::Format::AsciiArmor)
            .map_err(|e| Error::new(e.to_string()))?;
        let mut writer = encryptor.wrap_output(armored).map_err(|e| Error::new(e.to_string()))?;
        std::io::Write::write_all(&mut writer, identity.as_bytes()).map_err(|e| Error::new(e.to_string()))?;
        writer
            .finish()
            .and_then(age::armor::ArmoredWriter::finish)
            .map_err(|e| Error::new(e.to_string()))?;
        util::write(&file, &String::from_utf8_lossy(&encrypted), false)?;
        log(format!("encrypted {id}'s identity to {}", names.join(", ")));
        Ok(())
    }
}
