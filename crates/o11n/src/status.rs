use std::collections::{BTreeMap, BTreeSet};
use std::process::Command;
use std::sync::{Mutex, mpsc};

use crate::Error;
use crate::builder::Builder;
use crate::export::Entity;
use crate::keys::Kind;
use crate::store::{Org, Secret};
use crate::util::{self, TempDir};

// Dependency: nixos/services/mailserver.nix serves submission as mail.<endpoint>, on this port.
const SUBMISSION: u16 = 587;

// Dependency: nixos/services/nix-remote.nix and nixos/services/remote-builder-relay.nix serve the builder's daemon on
// the host's endpoint.
const BUILDERS: [&str; 2] = ["nix-remote", "remote-builder-relay"];

const WORKERS: usize = 8;

pub enum Check {
    Identity,
    PublicKey(String),
    Secret(String),
    Recipients,
    Secrets,
    SshKey,
    OnHost(String),
    Url(String),
    NixDaemon,
    NixStore,
    Submission(String),
    MailLogin(String),
}

impl Check {
    pub fn name(&self) -> String {
        match self {
            Self::Identity => "identity".into(),
            Self::PublicKey(key) => format!("public-key {key}"),
            Self::Secret(key) => format!("secret {key}"),
            Self::Recipients => "recipients".into(),
            Self::Secrets => "secrets".into(),
            Self::SshKey => "ssh-key".into(),
            Self::OnHost(key) => format!("on-host {key}"),
            Self::Url(url) => format!("url {url}"),
            Self::NixDaemon => "nix-daemon".into(),
            Self::NixStore => "nix-store".into(),
            Self::Submission(server) => format!("submission {server}"),
            Self::MailLogin(server) => format!("mail-login {server}"),
        }
    }
}

pub enum Outcome {
    Ok,
    Fail(String),
    Skip(String),
}

// Policy: what an outcome can't be had without, as a secret the operator can't decrypt, makes it a skip, not a fail,
// told by the first line of why.
fn needs<T>(result: Result<T, Error>) -> Result<T, Outcome> {
    result.map_err(|error| Outcome::Skip(error.to_string().lines().next().unwrap_or_default().to_owned()))
}

fn fails(result: Result<(), Error>) -> Outcome {
    match result {
        Ok(()) => Outcome::Ok,
        Err(error) => Outcome::Fail(error.to_string()),
    }
}

fn public_file(kind: Kind) -> bool {
    kind.has_public_key() && kind != Kind::Password
}

fn recipients_of(sops_file: &str) -> Vec<String> {
    let mut recipients: Vec<String> = sops_file
        .lines()
        .filter_map(|line| line.trim().strip_prefix("recipient: "))
        .map(|recipient| recipient.trim().to_owned())
        .collect();
    recipients.sort();
    recipients
}

fn curl() -> Command {
    let mut curl = Command::new("curl");
    curl.args(["-sS", "--max-time", "20"]);
    curl
}

// Policy: curl's failure is its stderr alone, which names it, without what -w wrote on stdout.
fn curled(curl: &mut Command) -> Result<String, Error> {
    let output = curl.output().map_err(|e| Error::new(format!("curl: {e}")))?;
    if !output.status.success() {
        return Err(Error::new(
            String::from_utf8_lossy(&output.stderr).trim_end().to_owned(),
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

impl Org {
    pub fn checks(&self, ids: &[String]) -> Result<Vec<(String, Check)>, Error> {
        let decrypting = self.decrypting()?;
        let mut planned = Vec::new();
        for id in ids {
            let entity = self.entity(id)?;
            let identified = entity.class == "root"
                || entity.keys.keys().any(|key| key != "age-key")
                || decrypting.contains(id)
                || self.has_identity(id)?;
            planned.extend(
                self.checks_of(entity, identified)?
                    .into_iter()
                    .map(|check| (id.clone(), check)),
            );
        }
        Ok(planned)
    }

    // Policy: an entity needs an identity for secrets of its own, or of another's it decrypts, as a grantee or an
    // actor; one with neither is let be without.
    fn decrypting(&self) -> Result<BTreeSet<String>, Error> {
        let mut ids = BTreeSet::new();
        for (id, entity) in &self.export.entities {
            ids.extend(
                self.export
                    .expand(entity.grants.iter().map(String::as_str))?
                    .into_iter()
                    .filter(|grantee| grantee != id),
            );
            ids.extend(entity.actors.iter().cloned());
        }
        Ok(ids)
    }

    fn checks_of(&self, entity: &Entity, identified: bool) -> Result<Vec<Check>, Error> {
        let mut checks = Vec::new();
        let root = entity.class == "root";
        if identified {
            if !root && entity.secrets.identity_file.is_some() {
                checks.push(Check::Identity);
            }
            if entity.secrets.sops_file.is_some() {
                checks.push(Check::Recipients);
                checks.push(Check::Secrets);
            }
            for (key, kind) in &entity.keys {
                if public_file(Kind::named(kind)?) && entity.public_keys.contains_key(key) {
                    checks.push(Check::PublicKey(key.clone()));
                }
            }
            for key in entity.keys.keys() {
                checks.push(Check::Secret(key.clone()));
            }
        }
        if entity.class == "host" {
            // Policy: a host without NixOS, as a phone, runs no ssh server or locksmith of o11n's.
            let nixos = entity.nixos != Some(false);
            if nixos && entity.public_keys.contains_key("ssh-key") {
                checks.push(Check::SshKey);
            }
            // Dependency: nixos/services/locksmith.sh, which the locksmith service puts on a host, confirms its keys.
            if nixos && entity.services.iter().any(|service| service == "locksmith") {
                for key in ["age-key", "luks-key"] {
                    if entity.keys.contains_key(key) {
                        checks.push(Check::OnHost(key.to_owned()));
                    }
                }
            }
            if entity
                .services
                .iter()
                .any(|service| BUILDERS.contains(&service.as_str()))
            {
                checks.push(Check::NixDaemon);
                checks.push(Check::NixStore);
            }
            if let Some(mailserver) = &self.export.mailserver
                && entity.services.iter().any(|service| service == "mailserver")
            {
                checks.push(Check::Submission(format!("mail.{}", mailserver.endpoint)));
            }
        }
        if let Some(url) = &entity.url {
            checks.push(Check::Url(url.clone()));
        }
        if let (Some(mailserver), Some(_)) = (&self.export.mailserver, &entity.mail)
            && entity.keys.contains_key("mail")
        {
            checks.push(Check::MailLogin(format!("mail.{}", mailserver.endpoint)));
        }
        Ok(checks)
    }

    pub fn check(&self, id: &str, check: &Check) -> Outcome {
        match self.outcome(id, check) {
            Ok(outcome) | Err(outcome) => outcome,
        }
    }

    fn outcome(&self, id: &str, check: &Check) -> Result<Outcome, Outcome> {
        let fail = |error: Error| Outcome::Fail(error.to_string());
        let entity = self.entity(id).map_err(fail)?;
        Ok(match check {
            Check::Identity => fails(match self.has_identity(id) {
                Ok(false) => Err(Error::new(format!("there's no identity: o11n identity create {id}"))),
                other => other.map(|_| ()),
            }),
            Check::PublicKey(key) => {
                let path = self.public_path(id, key).map_err(fail)?;
                fails(util::read(&path).and_then(|public| match public {
                    Some(_) => Ok(()),
                    None => Err(Error::new(format!(
                        "there's no {}",
                        path.strip_prefix(&self.root).unwrap_or(&path).display()
                    ))),
                }))
            }
            Check::Secret(key) => {
                let kind = self.kind(Secret { id, key, slot: 0 }).map_err(fail)?;
                if kind == Kind::Age {
                    needs(self.identity(id))?;
                } else {
                    needs(self.decrypted(id))?;
                }
                if kind.has_slots() {
                    return Ok(fails(self.slots_valid(id, key, kind)));
                }
                fails(self.verify_public_key(id, key))
            }
            Check::Recipients => fails(self.recipients_match(id)),
            Check::Secrets => {
                let extra = needs(self.extra_secrets(id))?;
                fails(if extra.is_empty() {
                    Ok(())
                } else {
                    Err(Error::new(format!(
                        "{} holds what o11n doesn't know: {}: declare each under the entity's keys, or take it out with o11n secret edit {id}",
                        entity.secrets.sops_file.as_deref().unwrap_or_default(),
                        extra.join(", ")
                    )))
                })
            }
            Check::SshKey => {
                self.reachable(entity)?;
                fails(self.confirm_on_host(id, "ssh-key", 0))
            }
            Check::OnHost(key) => {
                needs(self.required(Secret {
                    id: "service-locksmith",
                    key: "ssh-key",
                    slot: 0,
                }))?;
                let slots = if key == "age-key" {
                    needs(self.identity(id))?;
                    vec![0]
                } else {
                    needs(self.slots(id, key))?
                };
                self.reachable(entity)?;
                fails(
                    slots
                        .into_iter()
                        .try_for_each(|slot| self.confirm_on_host(id, key, slot)),
                )
            }
            Check::Url(url) => fails(Self::answers(url)),
            Check::NixDaemon => {
                let endpoint = Self::endpoint(id, entity).map_err(fail)?;
                // Fact: 401 is the builder's nginx refusing a request without the bearer, and 404 its gost, where a
                // proxy adds the bearer, as a Claude session's does.
                fails(
                    Builder::new(endpoint, None)
                        .probe()
                        .and_then(|answer| match answer.as_str() {
                            "401" | "404" => Ok(()),
                            answer => Err(Error::new(format!(
                                "https://{endpoint}/nix-daemon/probe answers {answer}, not 401 or 404"
                            ))),
                        }),
                )
            }
            Check::NixStore => {
                let endpoint = Self::endpoint(id, entity).map_err(fail)?;
                let token = self.builder_token(endpoint)?;
                fails(Builder::new(endpoint, token).store_answers())
            }
            Check::Submission(server) => fails(Self::submission(server, None)),
            Check::MailLogin(server) => {
                let address = &entity
                    .mail
                    .as_ref()
                    .ok_or_else(|| Outcome::Skip("no mail".into()))?
                    .address;
                let password = needs(self.required(Secret {
                    id,
                    key: "mail",
                    slot: 0,
                }))?;
                fails(Self::submission(server, Some((address, &password))))
            }
        })
    }

    // Policy: a key with slots has no public key, and is whichever of its slots the org holds, each as it should be.
    fn slots_valid(&self, id: &str, key: &str, kind: Kind) -> Result<(), Error> {
        let slots = self.slots(id, key)?;
        if slots.is_empty() {
            return Err(Error::new(format!("there's no {id}'s {key}")));
        }
        for slot in slots {
            let secret = Secret { id, key, slot };
            crate::keys::validate(kind, key, &self.required(secret)?, self.domain(id)?)
                .map_err(|error| Error::new(format!("{}: {error}", secret.describe())))?;
        }
        Ok(())
    }

    fn endpoint<'a>(id: &str, entity: &'a Entity) -> Result<&'a str, Error> {
        entity
            .endpoint
            .as_deref()
            .ok_or_else(|| Error::new(format!("{id} has no endpoint")))
    }

    // Policy: the bearer is nix-remote's secret-key, or else as `o11n remote` has it: O11N_REMOTE_BUILDER_TOKEN, or none
    // for the builder O11N_REMOTE_BUILDER names, as through a proxy that adds it.
    fn builder_token(&self, endpoint: &str) -> Result<Option<String>, Outcome> {
        let secret = self.required(Secret {
            id: "service-nix-remote",
            key: "secret-key",
            slot: 0,
        });
        match secret {
            Ok(token) => Ok(Some(token)),
            Err(error) => {
                let variable = |name| std::env::var(name).ok().filter(|value: &String| !value.is_empty());
                if let Some(token) = variable("O11N_REMOTE_BUILDER_TOKEN") {
                    return Ok(Some(token));
                }
                match variable("O11N_REMOTE_BUILDER") {
                    Some(builder) if crate::builder::host(&builder).split(':').next() == Some(endpoint) => Ok(None),
                    _ => needs(Err(error)),
                }
            }
        }
    }

    // Policy: a host without an endpoint, as a workstation, is expected to be out of reach at times.
    fn reachable(&self, entity: &Entity) -> Result<(), Outcome> {
        match self.export.route(&entity.name, 22) {
            Ok(_) => Ok(()),
            Err(error) if entity.endpoint.is_none() => Err(Outcome::Skip(format!("{error}, and it has no endpoint"))),
            Err(error) => Err(Outcome::Fail(error.to_string())),
        }
    }

    fn recipients_match(&self, id: &str) -> Result<(), Error> {
        let entity = self.entity(id)?;
        let Some(sops_file) = &entity.secrets.sops_file else {
            return Ok(());
        };
        let path = self.path(sops_file);
        let contents = util::read(&path)?.ok_or_else(|| Error::new(format!("there's no {sops_file}")))?;
        let mut expected: Vec<String> = self
            .export
            .sops_yaml(&self.root, id, &mut Vec::new())?
            .lines()
            .filter_map(|line| line.trim().strip_prefix("- age1").map(|key| format!("age1{key}")))
            .collect();
        expected.sort();
        let actual = recipients_of(&contents);
        if actual == expected {
            return Ok(());
        }
        let name = |key: &String| self.age_key_holder(key).unwrap_or_else(|| key.clone());
        let extra: Vec<String> = actual.iter().filter(|key| !expected.contains(key)).map(name).collect();
        let lacking: Vec<String> = expected.iter().filter(|key| !actual.contains(key)).map(name).collect();
        Err(Error::new(format!(
            "{sops_file} is encrypted to {} it shouldn't be, and not to {} it should: o11n reencrypt",
            if extra.is_empty() {
                "none".into()
            } else {
                extra.join(", ")
            },
            if lacking.is_empty() {
                "none".into()
            } else {
                lacking.join(", ")
            },
        )))
    }

    // Dependency: crates/o11n/src/store.rs stores a key with slots as <key>--<slot>, and a password's hash as
    // <key>-sha512; an age-key is an identity, in its own file, so one in a sops file is left over.
    pub fn extra_secrets(&self, id: &str) -> Result<Vec<String>, Error> {
        let entity = self.entity(id)?;
        let value = self.decrypted(id)?;
        let mut known = BTreeSet::new();
        let mut slotted = Vec::new();
        for (key, kind) in &entity.keys {
            let kind = Kind::named(kind)?;
            if kind == Kind::Age {
                continue;
            }
            known.insert(key.clone());
            if kind == Kind::Password {
                known.insert(format!("{key}-sha512"));
            }
            if kind.has_slots() {
                slotted.push(format!("{key}--"));
            }
        }
        let is_known = |name: &str| {
            known.contains(name)
                || slotted.iter().any(|prefix| {
                    name.strip_prefix(prefix.as_str())
                        .is_some_and(|slot| slot.parse::<u32>().is_ok())
                })
        };
        let mut extra = Vec::new();
        let top = value.as_object().into_iter().flatten();
        if entity.class == "host" {
            extra.extend(
                top.filter(|(name, _)| *name != "identity" && !is_known(name))
                    .map(|(name, _)| name.clone()),
            );
        } else {
            for (name, nested) in top {
                if name == "identity" {
                    continue;
                }
                if *name != entity.name {
                    extra.push(name.clone());
                    continue;
                }
                extra.extend(
                    nested
                        .as_object()
                        .into_iter()
                        .flatten()
                        .filter(|(key, _)| !is_known(key))
                        .map(|(key, _)| format!("{name}.{key}")),
                );
            }
        }
        Ok(extra)
    }

    pub fn print_extra_secrets(&self, groups: &[String]) -> Result<(), Error> {
        for id in self.export.expand(groups.iter().map(String::as_str))? {
            if self.entity(&id)?.secrets.sops_file.is_none() {
                continue;
            }
            match self.extra_secrets(&id) {
                Ok(extra) => {
                    for path in extra {
                        println!("{id} {path}");
                    }
                }
                Err(error) => util::log(format!(
                    "{id}: {}",
                    error.to_string().lines().next().unwrap_or_default()
                )),
            }
        }
        Ok(())
    }

    fn age_key_holder(&self, key: &str) -> Option<String> {
        self.export.entities.iter().find_map(|(id, entity)| {
            let path = entity.public_keys.get("age-key")?;
            (util::read(&self.path(path)).ok()??.trim() == key).then(|| id.clone())
        })
    }

    fn answers(url: &str) -> Result<(), Error> {
        let code = curled(curl().args(["-o", "/dev/null", "-w", "%{http_code}"]).arg(url))?;
        match code.trim().parse::<u16>() {
            Ok(code) if code < 500 => Ok(()),
            _ => Err(Error::new(format!("{url} answers {}", code.trim()))),
        }
    }

    // Policy: NOOP after STARTTLS, and AUTH with a login, sends nothing.
    fn submission(server: &str, login: Option<(&str, &str)>) -> Result<(), Error> {
        let mut curl = curl();
        curl.args(["--ssl-reqd", "-X", "NOOP"])
            .arg(format!("smtp://{server}:{SUBMISSION}"));
        let temp = TempDir::new()?;
        if let Some((user, password)) = login {
            let quoted = format!("{user}:{password}").replace('\\', "\\\\").replace('"', "\\\"");
            let config = temp.file("curl", &format!("user = \"{quoted}\"\n"))?;
            curl.arg("-K").arg(config);
        }
        curled(curl.stdin(std::process::Stdio::null())).map(|_| ())
    }

    pub fn status(&self, groups: &[String], list: bool, failed_only: bool) -> Result<(), Error> {
        let ids = self.export.expand(groups.iter().map(String::as_str))?;
        let planned = self.checks(&ids)?;
        if list {
            for (id, check) in &planned {
                println!("{id} {}", check.name());
            }
            return Ok(());
        }
        util::quiet();
        let queue = Mutex::new(planned.iter().enumerate());
        let (sender, receiver) = mpsc::channel();
        let mut failed = 0;
        std::thread::scope(|scope| {
            for _ in 0..WORKERS.min(planned.len()) {
                let sender = sender.clone();
                let queue = &queue;
                scope.spawn(move || {
                    loop {
                        let next = queue.lock().map(|mut queue| queue.next()).ok().flatten();
                        let Some((index, (id, check))) = next else { break };
                        if sender.send((index, self.check(id, check))).is_err() {
                            break;
                        }
                    }
                });
            }
            drop(sender);
            // Policy: the outcomes are told in the order planned, each as soon as those before it are.
            let mut done = BTreeMap::new();
            let mut next = 0;
            for (index, outcome) in receiver {
                done.insert(index, outcome);
                while let Some(outcome) = done.remove(&next) {
                    let (id, check) = &planned[next];
                    let line = match outcome {
                        Outcome::Fail(why) => {
                            failed += 1;
                            Some(format!("fail: {}", why.replace('\n', "\n  ")))
                        }
                        _ if failed_only => None,
                        Outcome::Ok => Some("ok".to_owned()),
                        Outcome::Skip(why) => Some(format!("skip: {}", why.replace('\n', "\n  "))),
                    };
                    if let Some(line) = line {
                        println!("{id} {} {line}", check.name());
                    }
                    next += 1;
                }
            }
        });
        if failed > 0 {
            return Err(Error::new(format!("{failed} of {} checks failed", planned.len())));
        }
        Ok(())
    }
}
