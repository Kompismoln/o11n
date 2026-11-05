use crate::Error;
use crate::export::Export;

#[derive(Debug, PartialEq, Eq)]
pub enum Group<'a> {
    All,
    Class(&'a str),
    Roles(&'a str, Vec<&'a str>),
    Entity(&'a str),
}

impl<'a> Group<'a> {
    pub fn parse(group: &'a str) -> Result<Self, Error> {
        if group == "*" {
            Ok(Self::All)
        } else if let Some((class, roles)) = group.split_once(':') {
            Ok(Self::Roles(class, roles.split('+').collect()))
        } else if let Some(class) = group.strip_suffix("-*") {
            Ok(Self::Class(class))
        } else if group.contains('-') {
            Ok(Self::Entity(group))
        } else {
            Err(Error::new(format!(
                "{group} is no entity group: *, <class>-*, <class>:<role>[+<role>]... or <class>-<name>"
            )))
        }
    }
}

impl Export {
    pub fn members(&self, group: &str) -> Result<Vec<String>, Error> {
        Ok(match Group::parse(group)? {
            Group::All => self.entities.keys().cloned().collect(),
            Group::Class(class) => self.of_class(class).map(|(id, _)| id.clone()).collect(),
            Group::Roles(class, roles) => self
                .of_class(class)
                .filter(|(_, entity)| roles.iter().all(|role| entity.roles.iter().any(|r| r == role)))
                .map(|(id, _)| id.clone())
                .collect(),
            Group::Entity(id) => vec![self.entity(id).map(|_| id.to_owned())?],
        })
    }

    fn of_class<'s>(&'s self, class: &'s str) -> impl Iterator<Item = (&'s String, &'s crate::export::Entity)> {
        self.entities
            .iter()
            .filter(move |(_, entity)| class == "*" || entity.class == class)
    }

    pub fn expand<'g>(&self, groups: impl IntoIterator<Item = &'g str>) -> Result<Vec<String>, Error> {
        let mut ids = Vec::new();
        for group in groups {
            ids.extend(self.members(group)?);
        }
        ids.sort();
        ids.dedup();
        Ok(ids)
    }

    pub fn recipients(&self, id: &str) -> Result<Vec<String>, Error> {
        let entity = self.entity(id)?;
        let groups = std::iter::once(id)
            .chain(self.root_identities.iter().map(String::as_str))
            .chain(entity.grants.iter().map(String::as_str));
        self.expand(groups)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn org() -> Export {
        let entity = |class: &str, grants: &[&str], roles: &[&str]| {
            serde_json::json!({
                "class": class,
                "name": "",
                "grants": grants,
                "actors": [],
                "roles": roles,
                "keys": {},
                "publicKeys": {},
                "secrets": {},
            })
        };
        Export::parse(
            &serde_json::json!({
                "root-identities": ["root-1"],
                "endpoint": "example.com",
                "classes": {},
                "entities": {
                    "root-1": entity("root", &[], &[]),
                    "host-alice": entity("host", &[], &["server", "luks"]),
                    "host-bob": entity("host", &[], &["server"]),
                    "user-carol": entity("user", &["host:luks+server", "service-guest"], &[]),
                    "service-guest": entity("service", &["host-*"], &[]),
                },
            })
            .to_string(),
        )
        .unwrap()
    }

    #[test]
    fn parses_groups() {
        assert_eq!(Group::parse("*").unwrap(), Group::All);
        assert_eq!(Group::parse("host-*").unwrap(), Group::Class("host"));
        assert_eq!(
            Group::parse("*:luks+server").unwrap(),
            Group::Roles("*", vec!["luks", "server"])
        );
        assert_eq!(Group::parse("user-carol").unwrap(), Group::Entity("user-carol"));
        assert!(Group::parse("carol").is_err());
    }

    #[test]
    fn expands_groups() {
        let org = org();
        assert_eq!(org.members("host-*").unwrap(), ["host-alice", "host-bob"]);
        assert_eq!(org.members("host:server").unwrap(), ["host-alice", "host-bob"]);
        assert_eq!(org.members("*:luks+server").unwrap(), ["host-alice"]);
        assert_eq!(org.members("user-carol").unwrap(), ["user-carol"]);
        assert!(org.members("user-dave").is_err());
        assert_eq!(org.members("*").unwrap().len(), 5);
    }

    #[test]
    fn recipients_are_the_entity_the_roots_and_its_grants() {
        let org = org();
        assert_eq!(
            org.recipients("user-carol").unwrap(),
            ["host-alice", "root-1", "service-guest", "user-carol"]
        );
        assert_eq!(org.recipients("host-bob").unwrap(), ["host-bob", "root-1"]);
    }
}
