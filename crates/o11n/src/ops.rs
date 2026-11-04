use crate::Error;
use crate::export::Export;
use crate::store::Org;
use crate::util::log;

enum Op<'a> {
    Verify(&'a str),
    Check(&'a str),
    Rebuild,
}

impl<'a> Op<'a> {
    fn parse(op: &'a str) -> Result<Self, Error> {
        match op.split_once(':') {
            Some(("verify", key)) => Ok(Self::Verify(key)),
            Some(("check", key)) => Ok(Self::Check(key)),
            Some(("rebuild", _)) => Ok(Self::Rebuild),
            _ => Err(Error::new(format!("{op}: no such op"))),
        }
    }

    fn key(&self) -> Option<&'a str> {
        match self {
            Self::Verify(key) | Self::Check(key) => Some(key),
            Self::Rebuild => None,
        }
    }
}

impl Export {
    // Policy: an op on a key is for the members that have it, and a group none of whose members has it is a mistake.
    pub fn ops(&self, name: &str) -> Result<Vec<(String, &str)>, Error> {
        let groups = self.ops.get(name).ok_or_else(|| Error::new(format!("no ops {name}")))?;
        let mut planned = Vec::new();
        for (group, ops) in groups {
            let members = self.members(group)?;
            for op in ops {
                let key = Op::parse(op)?.key();
                let mut held = false;
                for id in &members {
                    let entity = self.entity(id)?;
                    if entity.class == "root" || key.is_some_and(|key| !entity.keys.contains_key(key)) {
                        continue;
                    }
                    held = true;
                    planned.push((id.clone(), op.as_str()));
                }
                if let Some(key) = key
                    && !held
                {
                    return Err(Error::new(format!("{op}: no member of {group} has a {key}")));
                }
            }
        }
        Ok(planned)
    }
}

impl Org {
    pub fn run_ops(&self, name: &str) -> Result<(), Error> {
        let planned = self.export.ops(name)?;
        let mut failed = 0;
        let mut rebuild = false;
        for (id, text) in &planned {
            let result = match Op::parse(text)? {
                Op::Verify(key) => self.verify_public_key(id, key),
                Op::Check(key) => self.check_on_host(id, key, 0),
                Op::Rebuild => {
                    rebuild = true;
                    Ok(())
                }
            };
            if let Err(error) = result {
                log(format!("{id} {text}: {error}"));
                failed += 1;
            }
        }
        if rebuild {
            self.reencrypt(true)?;
        }
        if failed > 0 {
            return Err(Error::new(format!(
                "{failed} of {} ops of {name} failed",
                planned.len()
            )));
        }
        Ok(())
    }
}
