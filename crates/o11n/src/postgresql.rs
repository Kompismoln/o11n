use crate::export::Entity;
use crate::status::Outcome;
use crate::store::Org;

impl Org {
    // Dependency: nixos/postgresql.nix has switch-system databases say, a line each, a database, the collation version
    // it was made with and the one postgresql has now, and reindexes one whose differ in postgresql-collation.
    pub fn collation_outcome(&self, id: &str, entity: &Entity, host: &str) -> Result<Outcome, Outcome> {
        let name = &entity
            .database
            .as_ref()
            .ok_or_else(|| Outcome::Fail(format!("{id} has no database")))?
            .name;
        let host_id = format!("host-{host}");
        let host_entity = self
            .entity(&host_id)
            .map_err(|error| Outcome::Fail(error.to_string()))?;
        let said = self.switch_system(&host_id, host_entity, "databases")?;
        if said.trim().is_empty() {
            return Err(Outcome::Skip(format!(
                "{host_id} runs a system that doesn't say its databases' collations"
            )));
        }
        let fields = said
            .lines()
            .map(|line| line.split(' ').collect::<Vec<_>>())
            .find(|fields| fields.first() == Some(&name.as_str()))
            .ok_or_else(|| Outcome::Fail(format!("{host_id} has no database {name}: o11n apply {host_id}")))?;
        let [_, made, now] = fields.as_slice() else {
            return Err(Outcome::Fail(format!(
                "switch-system databases on {host_id} says of {name}: {}",
                fields.join(" ")
            )));
        };
        if made == now {
            return Ok(Outcome::Ok);
        }
        Ok(Outcome::Fail(format!(
            "{name} on {host_id} was made with collation version {made}, and its postgresql has {now}, so its indexes on text may be out of order: journalctl -u postgresql-collation on {host_id}"
        )))
    }
}
