use std::collections::BTreeMap;
use std::path::Path;
use std::process::{Command, Stdio};

use serde::Deserialize;

use crate::Error;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub struct Export {
    pub root_identities: Vec<String>,
    pub ops: BTreeMap<String, BTreeMap<String, Vec<String>>>,
    pub classes: BTreeMap<String, Class>,
    pub entities: BTreeMap<String, Entity>,
}

#[derive(Debug, Deserialize)]
pub struct Class {
    pub keys: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entity {
    pub class: String,
    pub grants: Vec<String>,
    pub public_keys: BTreeMap<String, String>,
    pub secrets: Secrets,
    #[serde(default)]
    pub roles: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Secrets {
    pub sops_file: Option<String>,
    pub age_key_file: Option<String>,
}

impl Export {
    pub fn parse(json: &str) -> Result<Self, Error> {
        serde_json::from_str(json).map_err(|e| Error::new(format!("the org's export: {e}")))
    }

    pub fn read(path: &Path) -> Result<String, Error> {
        std::fs::read_to_string(path).map_err(|e| Error::new(format!("{}: {e}", path.display())))
    }

    /// The JSON of `org.export` of the org's flake at `root`, nix's stderr passed through as it is.
    pub fn evaluate(root: &Path) -> Result<String, Error> {
        let output = Command::new("nix")
            .args(["eval", "--json", "--no-warn-dirty"])
            .arg(format!("{}#org.export", root.display()))
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
