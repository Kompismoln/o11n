use std::collections::BTreeMap;
use std::path::Path;
use std::process::{Command, Stdio};

use serde::Deserialize;

use crate::Error;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub struct Export {
    pub root_identities: Vec<String>,
    pub endpoint: String,
    #[serde(default)]
    pub namespaces: Vec<String>,
    #[serde(default)]
    pub build_hosts: Vec<String>,
    #[serde(default)]
    pub mailserver: Option<Mailserver>,
    pub classes: BTreeMap<String, Class>,
    pub entities: BTreeMap<String, Entity>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Mailserver {
    pub endpoint: String,
    #[serde(default)]
    pub dkim_selector: String,
    #[serde(default)]
    pub domains: BTreeMap<String, Domain>,
}

#[derive(Debug, Deserialize)]
pub struct Domain {
    pub mailbox: bool,
    pub sent: bool,
}

#[derive(Debug, Deserialize)]
pub struct Class {
    pub keys: BTreeMap<String, String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entity {
    pub class: String,
    pub name: String,
    pub grants: Vec<String>,
    pub actors: Vec<String>,
    pub keys: BTreeMap<String, String>,
    pub public_keys: BTreeMap<String, String>,
    pub secrets: Secrets,
    #[serde(default)]
    pub roles: Vec<String>,
    #[serde(default)]
    pub namespace: Option<String>,
    pub state: Option<State>,
    #[serde(default)]
    pub endpoint: Option<String>,
    #[serde(default)]
    pub services: Vec<String>,
    // Dependency: org/export.nix gives a host's services that serve on a vpn their names there, by service.
    #[serde(default)]
    pub served: BTreeMap<String, String>,
    #[serde(default)]
    pub mail: Option<Mail>,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub nixos: Option<bool>,
    #[serde(default)]
    pub allotments: Vec<Allotment>,
    #[serde(default)]
    pub keycloak: Option<Keycloak>,
    #[serde(default)]
    pub database: Option<Database>,
    #[serde(default)]
    pub nextcloud: Option<Nextcloud>,
    #[serde(default)]
    pub openwrt: Option<Openwrt>,
    #[serde(default)]
    pub router: Option<Router>,
}

#[derive(Debug, Deserialize)]
pub struct Router {
    pub address4: String,
    pub lan: BTreeMap<String, Lan>,
    pub records: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct Lan {
    pub address4: String,
    pub suffix: String,
    #[serde(default)]
    pub mac: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct Openwrt {
    pub files: BTreeMap<String, String>,
}

#[derive(Debug, Deserialize)]
pub struct Keycloak {
    pub realms: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct Nextcloud {
    pub homes: Vec<String>,
    pub external: Vec<String>,
    pub changes: Vec<String>,
    pub hosts: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct Database {
    pub name: String,
    pub hosts: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct Allotment {
    pub id: String,
    pub path: String,
    pub replicas: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Mail {
    pub address: String,
    #[serde(default)]
    pub send: bool,
    #[serde(default)]
    pub send_as: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct State {
    pub home: String,
    pub hosts: Vec<String>,
    #[serde(default)]
    pub archives: BTreeMap<String, Archive>,
}

#[derive(Debug, Deserialize)]
pub struct Archive {
    #[serde(default)]
    pub schedule: Option<String>,
    pub forget: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Secrets {
    pub sops_file: Option<String>,
    pub identity_file: Option<String>,
}

impl Export {
    pub fn parse(json: &str) -> Result<Self, Error> {
        serde_json::from_str(json).map_err(|e| Error::new(format!("the org's export: {e}")))
    }

    pub fn read(path: &Path) -> Result<String, Error> {
        std::fs::read_to_string(path).map_err(|e| Error::new(format!("{}: {e}", path.display())))
    }

    pub fn evaluate(root: &Path) -> Result<String, Error> {
        let output = Command::new("nix")
            .args(["eval", "--json", "--no-warn-dirty"])
            .arg(format!("{}#org.export", crate::util::flake(root)?))
            .stderr(Stdio::inherit())
            .output()
            .map_err(|e| Error::new(format!("nix: {e}")))?;
        if !output.status.success() {
            return Err(Error::status(output.status.code().unwrap_or(1)));
        }
        String::from_utf8(output.stdout).map_err(|e| Error::new(format!("nix: {e}")))
    }

    pub fn entity(&self, id: &str) -> Result<&Entity, Error> {
        self.entities
            .get(id)
            .ok_or_else(|| Error::new(format!("no entity {id}")))
    }
}
