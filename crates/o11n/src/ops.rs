use crate::Error;
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
}

impl Org {
    pub fn run_ops(&self, name: &str) -> Result<(), Error> {
        let groups = self
            .export
            .ops
            .get(name)
            .ok_or_else(|| Error::new(format!("no ops {name}")))?;
        let mut planned = Vec::new();
        for (group, ops) in groups {
            for id in self.export.members(group)? {
                if self.entity(&id)?.class == "root" {
                    continue;
                }
                for op in ops {
                    planned.push((id.clone(), op.as_str(), Op::parse(op)?));
                }
            }
        }
        let mut failed = 0;
        let mut rebuild = false;
        for (id, text, op) in &planned {
            let result = match op {
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
