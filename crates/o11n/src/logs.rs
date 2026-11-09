use crate::Error;
use crate::store::Org;
use crate::util::{self, run};

impl Org {
    // Dependency: nixos/services/logs.nix runs the summary for the logs service's ssh-key, with the span as its
    // argument, and nothing else.
    pub fn logs(&self, groups: &[String], since: &str) -> Result<(), Error> {
        let ids: Vec<String> = self
            .export
            .expand(groups.iter().map(String::as_str))?
            .into_iter()
            .filter(|id| {
                self.entity(id).is_ok_and(|entity| {
                    entity.class == "host" && entity.services.iter().any(|service| service == "logs")
                })
            })
            .collect();
        if ids.is_empty() {
            return Err(Error::new(format!(
                "no host of {} has the logs service",
                groups.join(" ")
            )));
        }
        let user = &self.entity("service-logs")?.name;
        let acting = self.acting("service-logs")?;
        // Policy: the hosts are read side by side, and each told in turn, in the order of their ids.
        let said: Vec<Result<String, Error>> = std::thread::scope(|scope| {
            let reading: Vec<_> = ids
                .iter()
                .map(|id| {
                    let acting = &acting;
                    scope.spawn(move || {
                        let mut ssh = self.pinned_ssh(id, user, acting.command("ssh"))?;
                        run(ssh.command.arg(since), None)
                    })
                })
                .collect();
            reading
                .into_iter()
                .map(|reading| {
                    reading
                        .join()
                        .unwrap_or_else(|_| Err(Error::new("reading a host's logs panicked")))
                })
                .collect()
        });
        let mut failed = Vec::new();
        for (id, said) in ids.iter().zip(said) {
            match said {
                Ok(summary) => print!("{summary}"),
                Err(error) => {
                    let name = self.entity(id).map_or(id.as_str(), |entity| entity.name.as_str());
                    println!("===== {name} couldn't be read");
                    util::log(format!("{id}: {error}"));
                    failed.push(id.as_str());
                }
            }
        }
        if failed.is_empty() {
            Ok(())
        } else {
            Err(Error::new(format!("couldn't read the logs of {}", failed.join(", "))))
        }
    }
}
