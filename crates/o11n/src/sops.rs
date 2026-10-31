use std::fmt::Write;
use std::path::Path;

use crate::Error;
use crate::export::Export;

impl Export {
    /// sops' creation rules for the members of `group`: each entity's sops file, encrypted to its recipients' age keys,
    /// read from their public keys under `root`. A recipient without one is left out, and said in `missing`.
    pub fn sops_yaml(&self, root: &Path, group: &str, missing: &mut Vec<String>) -> Result<String, Error> {
        let mut yaml = String::from("creation_rules:\n");
        for id in self.members(group)? {
            let Some(sops_file) = &self.entity(&id)?.secrets.sops_file else {
                continue;
            };
            let _ = write!(yaml, "  - path_regex: {sops_file}\n    key_groups:\n      - age:\n");
            for recipient in self.recipients(&id)? {
                match self.age_key(root, &recipient)? {
                    Some(key) => {
                        let _ = writeln!(yaml, "        - {key}");
                    }
                    None => missing.push(format!("{id}: {recipient} has no age-key")),
                }
            }
        }
        Ok(yaml)
    }

    fn age_key(&self, root: &Path, id: &str) -> Result<Option<String>, Error> {
        let Some(path) = self.entity(id)?.public_keys.get("age-key") else {
            return Ok(None);
        };
        match std::fs::read_to_string(root.join(path)) {
            Ok(key) => Ok(Some(key.trim().to_owned())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(Error::new(format!("{path}: {e}"))),
        }
    }
}
