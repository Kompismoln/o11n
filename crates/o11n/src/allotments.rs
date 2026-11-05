use serde::Deserialize;
use std::collections::BTreeMap;

use crate::export::{Allotment, Entity};
use crate::status::Outcome;
use crate::store::Org;

// Policy: a replica unseen this long has drifted from its allotment for long enough to tell.
const UNSEEN: u64 = 7 * 24 * 60 * 60;

// Dependency: nixos/allotment-sync.nix has allotment-sync-status say this, which switch-system runs.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Said {
    #[serde(default)]
    error: Option<String>,
    #[serde(default)]
    state: Option<String>,
    #[serde(default)]
    errors: Vec<String>,
    #[serde(default)]
    conflicts: u64,
    #[serde(default)]
    peers: BTreeMap<String, Peer>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Peer {
    connected: bool,
    last_seen: String,
    last_seen_ago_s: i64,
    completion: f64,
    need_items: u64,
    need_bytes: u64,
}

impl Org {
    fn said(&self, id: &str, entity: &Entity, allotment: &Allotment) -> Result<Said, Outcome> {
        let said = self.switch_system(id, entity, "allotments")?;
        if said.trim().is_empty() {
            return Err(Outcome::Skip(format!(
                "{id} runs a system that doesn't say how its allotments sync"
            )));
        }
        let mut said: BTreeMap<String, Said> =
            serde_json::from_str(&said).map_err(|e| Outcome::Fail(format!("switch-system allotments: {e}")))?;
        let said = said
            .remove(&allotment.id)
            .ok_or_else(|| Outcome::Fail(format!("{id} runs no allotment-sync@{}: o11n apply {id}", allotment.id)))?;
        if let Some(error) = said.error {
            return Err(Outcome::Fail(format!(
                "allotment-sync@{}: {}",
                allotment.id,
                error.trim()
            )));
        }
        Ok(said)
    }

    fn allotment<'a>(entity: &'a Entity, allotment: &str) -> Result<&'a Allotment, Outcome> {
        entity
            .allotments
            .iter()
            .find(|candidate| candidate.id == allotment)
            .ok_or_else(|| Outcome::Fail(format!("there's no allotment {allotment}")))
    }

    pub fn allotment_sync(
        &self,
        id: &str,
        entity: &Entity,
        allotment: &str,
        replica: &str,
    ) -> Result<Outcome, Outcome> {
        let allotment = Self::allotment(entity, allotment)?;
        let said = self.said(id, entity, allotment)?;
        if !said.errors.is_empty() || said.state.as_deref() == Some("error") {
            return Ok(Outcome::Fail(format!(
                "allotment-sync@{} is in error: {}",
                allotment.id,
                said.errors.join("; ")
            )));
        }
        let peer = said.peers.get(replica).ok_or_else(|| {
            Outcome::Fail(format!(
                "allotment-sync@{} doesn't sync with {replica}: o11n apply {id}",
                allotment.id
            ))
        })?;
        if peer.connected {
            if peer.need_items == 0 && peer.completion >= 100.0 {
                return Ok(Outcome::Ok);
            }
            return Ok(Outcome::Fail(format!(
                "{replica} has {:.1}% of {}, {} items, {} bytes, to go",
                peer.completion, allotment.id, peer.need_items, peer.need_bytes
            )));
        }
        // Fact: Syncthing gives a device it has never seen a last seen of the epoch.
        if peer.last_seen.starts_with("1970-") {
            return Ok(Outcome::Fail(format!("{replica} has never connected")));
        }
        if u64::try_from(peer.last_seen_ago_s).unwrap_or(0) > UNSEEN {
            return Ok(Outcome::Fail(format!(
                "{replica} was last seen {}, over a week ago",
                peer.last_seen
            )));
        }
        Ok(Outcome::Skip(format!(
            "{replica} isn't connected, last seen {}",
            peer.last_seen
        )))
    }

    pub fn allotment_conflicts(&self, id: &str, entity: &Entity, allotment: &str) -> Result<Outcome, Outcome> {
        let allotment = Self::allotment(entity, allotment)?;
        let said = self.said(id, entity, allotment)?;
        if said.conflicts == 0 {
            return Ok(Outcome::Ok);
        }
        Ok(Outcome::Fail(format!(
            "{} has {} conflicting copies, named *.sync-conflict-*: keep one version of each and remove the rest",
            allotment.path, said.conflicts
        )))
    }
}
