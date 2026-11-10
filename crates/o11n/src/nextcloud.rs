use crate::export::Entity;
use crate::status::Outcome;
use crate::store::Org;

impl Org {
    // Dependency: nixos/apps/nextcloud.nix has switch-system nextcloud say, a line each, <app> home <user> and
    // <app> external <user>/<folder>, then ok or why not.
    pub fn nextcloud_outcome(&self, entity: &Entity, kind: &str, name: &str, host: &str) -> Result<Outcome, Outcome> {
        let host_id = format!("host-{host}");
        let host_entity = self
            .entity(&host_id)
            .map_err(|error| Outcome::Fail(error.to_string()))?;
        let said = self.switch_system(&host_id, host_entity, "nextcloud")?;
        if said.trim().is_empty() {
            return Err(Outcome::Skip(format!(
                "{host_id} runs a system that doesn't say how its nextclouds' storages are"
            )));
        }
        let prefix = format!("{} {kind} {name} ", entity.name);
        let told = said
            .lines()
            .find_map(|line| line.strip_prefix(&prefix))
            .ok_or_else(|| {
                Outcome::Fail(format!(
                    "{host_id} says nothing of {}'s {kind} {name}: o11n apply {host_id}",
                    entity.name
                ))
            })?;
        if told == "ok" {
            return Ok(Outcome::Ok);
        }
        Ok(Outcome::Fail(format!(
            "{}'s {kind} {name} on {host_id}: {told}",
            entity.name
        )))
    }
}
