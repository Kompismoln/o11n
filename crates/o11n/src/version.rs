use std::collections::BTreeMap;
use std::process::Command;

use serde_json::Value;

use crate::Error;
use crate::export::Entity;
use crate::status::Outcome;
use crate::store::Org;
use crate::util::{self, run};

type Deployed = BTreeMap<(String, String), String>;

fn skip(why: impl Into<String>) -> Outcome {
    Outcome::Skip(why.into())
}

fn fail(error: &Error) -> Outcome {
    Outcome::Fail(error.to_string())
}

impl Org {
    fn pinned_o11n(&self) -> Result<String, Outcome> {
        let path = self.root.join("flake.lock");
        let lock = util::read(&path)
            .map_err(|error| fail(&error))?
            .ok_or_else(|| skip("the org has no flake.lock"))?;
        let lock: Value = serde_json::from_str(&lock).map_err(|e| Outcome::Fail(format!("flake.lock: {e}")))?;
        let root = lock["root"].as_str().unwrap_or("root");
        let node = lock["nodes"][root]["inputs"]["o11n"]
            .as_str()
            .ok_or_else(|| skip("the org's flake.lock has no o11n input of its own"))?;
        lock["nodes"][node]["locked"]["narHash"]
            .as_str()
            .map(str::to_owned)
            .ok_or_else(|| skip("the org's flake.lock has no narHash of o11n"))
    }

    fn tree_hash(&self) -> Result<String, Outcome> {
        let flake = util::flake(&self.root).map_err(|error| fail(&error))?;
        let metadata = run(
            Command::new("nix")
                .args(["flake", "metadata", "--json", "--no-write-lock-file"])
                .arg(flake),
            None,
        )
        .map_err(|error| skip(error.to_string().lines().next().unwrap_or_default().to_owned()))?;
        let metadata: Value =
            serde_json::from_str(&metadata).map_err(|e| Outcome::Fail(format!("nix flake metadata: {e}")))?;
        metadata["locked"]["narHash"]
            .as_str()
            .map(str::to_owned)
            .ok_or_else(|| skip("nix flake metadata gives the org no narHash"))
    }

    pub fn switch_system(&self, id: &str, entity: &Entity, command: &str) -> Result<String, Outcome> {
        let acting = self
            .acting("service-nix-switch")
            .map_err(|error| skip(error.to_string().lines().next().unwrap_or_default().to_owned()))?;
        self.export
            .route(&entity.name, 22)
            .map_err(|error| match entity.endpoint {
                None => skip(format!("{error}, and it has no endpoint")),
                Some(_) => fail(&error),
            })?;
        let mut ssh = self
            .pinned_ssh(id, "nix-switch", acting.command("ssh"))
            .map_err(|error| fail(&error))?;
        run(ssh.command.arg(command), None).map_err(|error| fail(&error))
    }

    // Dependency: nixos/services/nix-switch.nix has switch-system say this of the host's booted, current and next
    // systems.
    fn deployed(&self, id: &str, entity: &Entity) -> Result<Deployed, Outcome> {
        let said = self.switch_system(id, entity, "status")?;
        Ok(said
            .lines()
            .filter_map(|line| {
                let mut fields = line.splitn(3, ' ');
                Some((
                    (fields.next()?.to_owned(), fields.next()?.to_owned()),
                    fields.next()?.to_owned(),
                ))
            })
            .collect())
    }

    // Policy: this o11n is the org's if it's the package the o11n the org pins builds, whatever else differs in their
    // trees.
    fn pinned_package(&self) -> Result<String, Outcome> {
        let flake = util::flake(&self.root).map_err(|error| fail(&error))?;
        run(
            Command::new("nix")
                .args(["eval", "--raw", "--no-write-lock-file", "--inputs-from"])
                .arg(flake)
                .arg("o11n#o11n.outPath"),
            None,
        )
        .map_err(|error| skip(error.to_string().lines().next().unwrap_or_default().to_owned()))
    }

    pub fn o11n_outcome(&self) -> Outcome {
        let running = std::env::current_exe()
            .ok()
            .and_then(|exe| std::fs::canonicalize(exe).ok())
            .and_then(|exe| {
                let mut components = exe.components().skip(1);
                (components.next()?.as_os_str() == "nix" && components.next()?.as_os_str() == "store")
                    .then(|| {
                        Some(format!(
                            "/nix/store/{}",
                            components.next()?.as_os_str().to_string_lossy()
                        ))
                    })
                    .flatten()
            });
        let Some(running) = running else {
            return skip("this o11n isn't in the nix store, as one cargo built");
        };
        match self.pinned_package() {
            Ok(pinned) if pinned == running => Outcome::Ok,
            Ok(pinned) => Outcome::Fail(format!("this o11n is {running}, and the org's builds {pinned}")),
            Err(outcome) => outcome,
        }
    }

    pub fn version_outcome(&self, id: &str, entity: &Entity) -> Result<Outcome, Outcome> {
        let deployed = self.deployed(id, entity)?;
        let current = |field: &str| deployed.get(&("current".to_owned(), field.to_owned()));
        let (Some(org), Some(o11n)) = (current("org"), current("o11n")) else {
            return Err(skip(format!("{id} runs a system that doesn't say its versions")));
        };
        let tree = self.tree_hash()?;
        let pinned = self.pinned_o11n()?;
        let mut drift = Vec::new();
        if *org != tree {
            drift.push(format!("the org's tree {org}, not this one's {tree}"));
        }
        if *o11n != pinned {
            drift.push(format!("o11n {o11n}, not the one the org pins, {pinned}"));
        }
        if drift.is_empty() {
            return Ok(Outcome::Ok);
        }
        Ok(Outcome::Fail(format!(
            "{id} runs {}: o11n apply {id}",
            drift.join(", and ")
        )))
    }

    pub fn reboot_outcome(&self, id: &str, entity: &Entity) -> Result<Outcome, Outcome> {
        let deployed = self.deployed(id, entity)?;
        let field = |system: &str, field: &str| deployed.get(&(system.to_owned(), field.to_owned()));
        let differing: Vec<String> = ["kernel", "kernel-modules"]
            .into_iter()
            .filter(|name| field("booted", name) != field("next", name))
            .map(|name| {
                format!(
                    "{name} {} boots as {}",
                    field("booted", name).map_or("none", String::as_str),
                    field("next", name).map_or("none", String::as_str)
                )
            })
            .collect();
        if differing.is_empty() {
            return Ok(Outcome::Ok);
        }
        Ok(Outcome::Fail(format!(
            "{id} runs {}: reboot it",
            differing.join(", and ")
        )))
    }
}
