use std::collections::{BTreeMap, BTreeSet};
use std::process::Command;
use std::sync::{Mutex, mpsc};

use crate::Error;
use crate::builder::Builder;
use crate::dns;
use crate::export::Entity;
use crate::keys::Kind;
use crate::ssh;
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
    InitrdKey,
    O11n,
    Version,
    Reboot,
    AllotmentSync(String, String),
    AllotmentConflicts(String),
    Archive(String, String),
    Collation(String),
    Url(String),
    NixDaemon,
    NixStore,
    Submission(String),
    MailLogin(String),
    Mx(String),
    Spf(String),
    Dkim(String),
    Dmarc(String),
    KeycloakMail(String),
    Openwrt,
    Lan(String),
    Glesys(String),
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
            Self::InitrdKey => "initrd-key".into(),
            Self::O11n => "o11n".into(),
            Self::Version => "version".into(),
            Self::Reboot => "reboot".into(),
            Self::AllotmentSync(allotment, replica) => format!("allotment-sync {allotment} {replica}"),
            Self::AllotmentConflicts(allotment) => format!("allotment-conflicts {allotment}"),
            Self::Archive(archive, host) => format!("archive {archive} {host}"),
            Self::Collation(host) => format!("collation {host}"),
            Self::Url(url) => format!("url {url}"),
            Self::NixDaemon => "nix-daemon".into(),
            Self::NixStore => "nix-store".into(),
            Self::Submission(server) => format!("submission {server}"),
            Self::MailLogin(server) => format!("mail-login {server}"),
            Self::Mx(domain) => format!("mx {domain}"),
            Self::Spf(domain) => format!("spf {domain}"),
            Self::Dkim(domain) => format!("dkim {domain}"),
            Self::Dmarc(domain) => format!("dmarc {domain}"),
            Self::KeycloakMail(realm) => format!("keycloak-mail {realm}"),
            Self::Openwrt => "openwrt".into(),
            Self::Lan(host) => format!("lan {host}"),
            Self::Glesys(record) => format!("glesys {record}"),
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
pub fn needs<T>(result: Result<T, Error>) -> Result<T, Outcome> {
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

pub fn curl() -> Command {
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
        let mut planned = vec![("org".to_owned(), Check::O11n)];
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
                if entity.keys.contains_key("luks-key") {
                    checks.push(Check::InitrdKey);
                }
            }
            if nixos && entity.services.iter().any(|service| service == "nix-switch") {
                checks.push(Check::Version);
                checks.push(Check::Reboot);
                for allotment in &entity.allotments {
                    for replica in &allotment.replicas {
                        checks.push(Check::AllotmentSync(allotment.id.clone(), replica.clone()));
                    }
                    checks.push(Check::AllotmentConflicts(allotment.id.clone()));
                }
            }
            if entity.openwrt.is_some() {
                checks.push(Check::Openwrt);
            }
            if let Some(router) = &entity.router {
                checks.extend(router.lan.keys().map(|host| Check::Lan(host.clone())));
                checks.extend(router.records.iter().map(|record| Check::Glesys(record.clone())));
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
                // Policy: a domain with mailboxes is to receive at the server, and one a principal's address is on,
                // which it sends as, is to pass a receiver's SPF, DKIM and DMARC.
                for (domain, settings) in &mailserver.domains {
                    if settings.mailbox {
                        checks.push(Check::Mx(domain.clone()));
                    }
                    if settings.sent {
                        checks.push(Check::Spf(domain.clone()));
                        checks.push(Check::Dkim(domain.clone()));
                        checks.push(Check::Dmarc(domain.clone()));
                    }
                }
            }
        }
        checks.extend(Self::serving_checks(entity));
        if let (Some(mailserver), Some(_)) = (&self.export.mailserver, &entity.mail)
            && entity.keys.contains_key("mail")
        {
            checks.push(Check::MailLogin(format!("mail.{}", mailserver.endpoint)));
        }
        // Policy: a domain a principal sends as beyond the org's addresses is the principal's, as are its SPF, DKIM
        // and DMARC.
        if let (Some(mailserver), Some(mail)) = (&self.export.mailserver, &entity.mail)
            && mail.send
        {
            let mut domains: Vec<&str> = mail
                .send_as
                .iter()
                .filter_map(|address| address.rsplit_once('@').map(|(_, domain)| domain))
                .filter(|domain| !mailserver.domains.get(*domain).is_some_and(|settings| settings.sent))
                .collect();
            domains.sort_unstable();
            domains.dedup();
            for domain in domains {
                checks.push(Check::Spf(domain.to_owned()));
                checks.push(Check::Dkim(domain.to_owned()));
                checks.push(Check::Dmarc(domain.to_owned()));
            }
        }
        Ok(checks)
    }

    fn serving_checks(entity: &Entity) -> Vec<Check> {
        let mut checks = Vec::new();
        if let Some(state) = &entity.state {
            for archive in state.archives.keys() {
                for host in &state.hosts {
                    checks.push(Check::Archive(archive.clone(), host.clone()));
                }
            }
        }
        if let Some(database) = &entity.database {
            checks.extend(database.hosts.iter().map(|host| Check::Collation(host.clone())));
        }
        if let Some(url) = &entity.url {
            checks.push(Check::Url(url.clone()));
        }
        if let (Some(keycloak), Some(mail)) = (&entity.keycloak, &entity.mail)
            && mail.send
        {
            for realm in &keycloak.realms {
                checks.push(Check::KeycloakMail(realm.clone()));
            }
        }
        checks
    }

    pub fn check(&self, id: &str, check: &Check) -> Outcome {
        if let Check::O11n = check {
            return self.o11n_outcome();
        }
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
            Check::SshKey => self.ssh_key(id, entity)?,
            Check::OnHost(key) => self.on_host(id, entity, key)?,
            Check::InitrdKey => self.initrd_key(id, entity)?,
            Check::O11n => self.o11n_outcome(),
            Check::Version => self.version_outcome(id, entity)?,
            Check::Reboot => self.reboot_outcome(id, entity)?,
            Check::AllotmentSync(allotment, replica) => self.allotment_sync(id, entity, allotment, replica)?,
            Check::AllotmentConflicts(allotment) => self.allotment_conflicts(id, entity, allotment)?,
            Check::Archive(archive, host) => self.archive_outcome(id, archive, host)?,
            Check::Collation(host) => self.collation_outcome(id, entity, host)?,
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
            Check::Mx(domain) => fails(self.mx(domain)),
            Check::Spf(domain) => fails(self.spf(domain)),
            Check::Dkim(domain) => fails(self.dkim(domain)),
            Check::Dmarc(domain) => fails(Self::dmarc(domain)),
            Check::KeycloakMail(realm) => self.keycloak_mail(id, entity, realm)?,
            Check::Openwrt => self.openwrt_outcome(id, entity)?,
            Check::Lan(host) => self.lan_outcome(id, entity, host)?,
            Check::Glesys(record) => self.glesys_outcome(id, entity, record)?,
        })
    }

    fn mail_server(&self) -> Result<String, Error> {
        self.export
            .mailserver
            .as_ref()
            .map(|mailserver| format!("mail.{}", mailserver.endpoint))
            .ok_or_else(|| Error::new("the org has no [mailserver]"))
    }

    fn mx(&self, domain: &str) -> Result<(), Error> {
        let server = self.mail_server()?;
        let exchangers = dns::exchangers(domain)?;
        if exchangers.contains(&server) {
            return Ok(());
        }
        Err(Error::new(format!(
            "{domain}'s MX is {}, not {server}, so its mailboxes get no mail: publish {domain} MX 10 {server}",
            if exchangers.is_empty() {
                "none".to_owned()
            } else {
                exchangers.join(", ")
            }
        )))
    }

    // Policy: from each address of the server, which is where it sends from.
    fn spf(&self, domain: &str) -> Result<(), Error> {
        let server = self.mail_server()?;
        let addresses = dns::addresses(&server)?;
        if addresses.is_empty() {
            return Err(Error::new(format!("{server} has no address")));
        }
        let mut failing = Vec::new();
        for address in addresses {
            let result = dns::spf(domain, address).map_err(|e| Error::new(format!("SPF of {domain}: {e}")))?;
            if result != dns::Spf::Pass {
                failing.push(format!("{} for {address}", result.name()));
            }
        }
        if failing.is_empty() {
            return Ok(());
        }
        Err(Error::new(format!(
            "SPF of {domain} gives {}, which {server} sends from: add a:{server} to it",
            failing.join(", ")
        )))
    }

    fn dkim(&self, domain: &str) -> Result<(), Error> {
        let selector = self
            .export
            .mailserver
            .as_ref()
            .map(|mailserver| mailserver.dkim_selector.as_str())
            .unwrap_or_default();
        let name = format!("{selector}._domainkey.{domain}");
        // Fact: a DKIM record's v= is optional, and its p= the key, empty for one revoked.
        let keys: Vec<String> = dns::lookup(&name, dns::Type::Txt)?
            .iter()
            .filter_map(|text| {
                text.split(';')
                    .filter_map(|tag| tag.trim().split_once('='))
                    .find(|(tag, _)| tag.trim() == "p")
                    .map(|(_, key)| key.split_whitespace().collect::<String>())
            })
            .filter(|key| !key.is_empty())
            .collect();
        // Dependency: nixos/services/mailserver.nix keeps the server's keys under /var/dkim, on storage on a host
        // that preserves.
        match keys.as_slice() {
            [_] => Ok(()),
            [] => Err(Error::new(format!(
                "{name} has no DKIM key: publish the server's {domain}.{selector}.txt, under its dkim keyDirectory, there"
            ))),
            _ => Err(Error::new(format!(
                "{name} has {} DKIM keys: keep the server's",
                keys.len()
            ))),
        }
    }

    fn dmarc(domain: &str) -> Result<(), Error> {
        let name = format!("_dmarc.{domain}");
        let record = dns::record(&name, "v=DMARC1")?;
        let policy = record
            .split(';')
            .filter_map(|tag| tag.trim().split_once('='))
            .find(|(tag, _)| tag.trim() == "p")
            .map(|(_, policy)| policy.trim().to_ascii_lowercase());
        match policy.as_deref() {
            Some("none" | "quarantine" | "reject") => Ok(()),
            _ => Err(Error::new(format!(
                "{name} has no policy, p=none, quarantine or reject, which receivers take as no DMARC"
            ))),
        }
    }

    // Policy: where connections are shared, the host shows its ssh-key on the connection that logs in as locksmith or
    // nix-switch, which the checks after it share, rather than to ssh-keyscan, which sshd's PerSourcePenalties count
    // against the address for not logging in.
    fn ssh_key(&self, id: &str, entity: &Entity) -> Result<Outcome, Outcome> {
        self.reachable(entity)?;
        let serves = |name: &str| entity.services.iter().any(|service| service == name);
        let background = ["-f", "-N"];
        let opened = if !ssh::shared() {
            None
        } else if serves("locksmith")
            && self
                .required(Secret {
                    id: "service-locksmith",
                    key: "ssh-key",
                    slot: 0,
                })
                .is_ok()
        {
            Some(
                self.locksmith_ssh(id, &background)
                    .and_then(|(mut ssh, _identity)| util::run(&mut ssh.command, None)),
            )
        } else if let (true, Ok(acting)) = (serves("nix-switch"), self.acting("service-nix-switch")) {
            let mut ssh = acting.command("ssh");
            ssh.args(background);
            Some(
                self.pinned_ssh(id, "nix-switch", ssh)
                    .and_then(|mut ssh| util::run(&mut ssh.command, None)),
            )
        } else {
            None
        };
        Ok(fails(match opened {
            Some(opened) => opened
                .map(|_| ())
                .map_err(|error| Error::new(format!("{error}\no11n host pull-ssh-key {id}, if it's the host's own"))),
            None => self.confirm_on_host(id, "ssh-key", 0),
        }))
    }

    fn on_host(&self, id: &str, entity: &Entity, key: &str) -> Result<Outcome, Outcome> {
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
        Ok(fails(
            slots
                .into_iter()
                .try_for_each(|slot| self.confirm_on_host(id, key, slot)),
        ))
    }

    fn initrd_key(&self, id: &str, entity: &Entity) -> Result<Outcome, Outcome> {
        needs(self.required(Secret {
            id: "service-locksmith",
            key: "ssh-key",
            slot: 0,
        }))?;
        let deployed = Secret {
            id,
            key: "luks-key",
            slot: 0,
        };
        let deployed = if needs(self.slots(id, deployed.key))?.contains(&0) {
            needs(self.required(deployed))?
        } else {
            String::new()
        };
        self.reachable(entity)?;
        Ok(fails(self.confirm_initrd_key(id, &deployed)))
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
    pub fn reachable(&self, entity: &Entity) -> Result<(), Outcome> {
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
        ssh::share()?;
        // Policy: an entity's checks run in order, one after another, so that a host's share a connection, and the
        // entities side by side.
        let mut entities: Vec<Vec<usize>> = Vec::new();
        for (index, (id, _)) in planned.iter().enumerate() {
            match entities.iter_mut().find(|indices| planned[indices[0]].0 == *id) {
                Some(indices) => indices.push(index),
                None => entities.push(vec![index]),
            }
        }
        let queue = Mutex::new(entities.into_iter());
        let (sender, receiver) = mpsc::channel();
        let mut failed = 0;
        std::thread::scope(|scope| {
            for _ in 0..WORKERS.min(planned.len()) {
                let sender = sender.clone();
                let queue = &queue;
                let planned = &planned;
                scope.spawn(move || {
                    while let Some(indices) = queue.lock().map(|mut queue| queue.next()).ok().flatten() {
                        for index in indices {
                            let (id, check) = &planned[index];
                            if sender.send((index, self.check(id, check))).is_err() {
                                return;
                            }
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
        ssh::close();
        if failed > 0 {
            return Err(Error::new(format!("{failed} of {} checks failed", planned.len())));
        }
        Ok(())
    }
}
