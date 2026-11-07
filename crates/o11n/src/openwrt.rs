use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::fs::File;
use std::net::Ipv6Addr;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use clap::Subcommand;

use crate::Error;
use crate::acting::Acting;
use crate::dns;
use crate::export::Entity;
use crate::status::{Outcome, needs};
use crate::store::{Org, Secret};
use crate::util::{exited, flake, log, run};

// Dependency: org/openwrt.nix writes a secret into a file as @o11n-secret:<key>@.
const MARKER: &str = "@o11n-secret:";

// Dependency: the script below keeps what it replaced here, which a reboot drops.
const BACKUP: &str = "/tmp/o11n-rollback";

// Dependency: org/openwrt.nix writes the script that changes the router's UCI here.
const UCI: &str = "/etc/o11n/uci";

const RESCUE: &str = "service-rescue";

const ROLLBACK: Duration = Duration::from_secs(90);

#[derive(Subcommand)]
pub enum OpenwrtCommand {
    /// Writes the router's files, its secrets in them, changes its UCI with them, and reloads its configuration; unless
    /// o11n gets back in within 90 seconds, the router puts back what it had and reloads that.
    Apply { host: String },
    /// Builds the router's sysupgrade image, which holds its files but those with a secret, and prints it.
    Image { host: String },
    /// Copies the image to the router, checks it there, and flashes it, keeping nothing of what the router had.
    Flash { host: String, image: String },
}

/// The text with each secret's marker replaced by the secret.
fn filled(text: &str, mut secret: impl FnMut(&str) -> Result<String, Error>) -> Result<String, Error> {
    let mut out = String::new();
    let mut rest = text;
    while let Some(start) = rest.find(MARKER) {
        out.push_str(&rest[..start]);
        let after = &rest[start + MARKER.len()..];
        let end = after
            .find('@')
            .ok_or_else(|| Error::new(format!("an unterminated {MARKER} in {text}")))?;
        let value = secret(&after[..end])?;
        // Policy: a secret is written between UCI's single quotes, where a quote would end it.
        if value.contains(['\'', '\n']) {
            return Err(Error::new(format!(
                "the {} has a quote or a newline, which UCI can't hold",
                &after[..end]
            )));
        }
        out.push_str(&value);
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

fn plain(path: &str) -> bool {
    path.starts_with('/')
        && path
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '/' | '.' | '_' | '-'))
}

pub struct Written {
    contents: String,
    private: bool,
}

/// A script for the router's busybox sh that writes the files under root, the private ones for root alone, and keeps
/// what they replace under the backup, with a script that puts it back, `restore`.
fn writes(files: &BTreeMap<String, Written>, root: &str) -> Result<String, Error> {
    let mut out = format!(
        "set -eu\nbackup='{root}{BACKUP}'\nrm -rf \"$backup\"\nmkdir -p \"$backup/files\"\n: > \"$backup/restore\"\n"
    );
    for (index, (path, Written { contents, private })) in files.iter().enumerate() {
        if !plain(path) {
            return Err(Error::new(format!("{path} isn't a plain absolute path")));
        }
        let target = format!("{root}{path}");
        let dir = Path::new(&target)
            .parent()
            .map_or("/".into(), |p| p.display().to_string());
        let mut delimiter = String::from("O11N_EOF");
        while contents.lines().any(|line| line == delimiter) {
            delimiter.push('_');
        }
        let body = if contents.is_empty() {
            String::new()
        } else {
            format!("{}\n", contents.strip_suffix('\n').unwrap_or(contents))
        };
        let _ = write!(
            out,
            "mkdir -p '{dir}'\n\
             if [ -e '{target}' ]; then cp -p '{target}' \"$backup/files/{index}\"; \
             echo \"cp -p '$backup/files/{index}' '{target}'\" >> \"$backup/restore\"; \
             else echo \"rm -f '{target}'\" >> \"$backup/restore\"; fi\n\
             cat > '{target}.o11n' <<'{delimiter}'\n{body}{delimiter}\n\
             chmod {mode} '{target}.o11n'\n\
             mv '{target}.o11n' '{target}'\n",
            mode = if *private { "600" } else { "644" },
        );
    }
    Ok(out)
}

/// Keeps the router's UCI with what `restore` puts back, and runs the script that changes it, restoring at once if it
/// fails.
fn configure(script: &str, root: &str) -> String {
    format!(
        "cp -a '{root}/etc/config' \"$backup/config\"\n\
         echo \"rm -rf '{root}/tmp/.uci' '{root}/etc/config'; cp -a '$backup/config' '{root}/etc/config'\" >> \"$backup/restore\"\n\
         if ! sh '{root}{script}'; then sh \"$backup/restore\"; exit 1; fi\n"
    )
}

/// Runs `restore` after `delay` unless `armed` is gone by then, and `reload` either way, both detached from the session.
// Fact: OpenWrt's busybox has no nohup; an ignored SIGHUP outlasts exec, so sh -c keeps ignoring the session's end.
fn arm(delay: u64, reload: &str) -> String {
    format!(
        "touch \"$backup/armed\"\n\
         ( trap '' HUP; sh -c 'sleep {delay}; if [ -e \"$0/armed\" ]; then sh \"$0/restore\"; rm -f \"$0/armed\"; \
         touch \"$0/rolled-back\"; {reload}; fi' \"$backup\" ) </dev/null >/dev/null 2>&1 &\n\
         ( trap '' HUP; sh -c 'sleep 1; {reload}' ) </dev/null >/dev/null 2>&1 &\n"
    )
}

/// The MAC and name dnsmasq leases the address to, by its lease file's lines: `<expiry> <mac> <ip> <name> <client id>`.
fn leased<'a>(leases: &'a str, address4: &str) -> Option<(&'a str, &'a str)> {
    leases.lines().find_map(|line| {
        let fields: Vec<&str> = line.split_whitespace().collect();
        (fields.get(2) == Some(&address4)).then(|| (fields[1], fields.get(3).copied().unwrap_or("*")))
    })
}

/// The suffix in each /64 of the global addresses `ip -o -6 addr` lists, as a host forms its own from what the router
/// advertises.
fn suffixed(addresses: &str, suffix: &str) -> Result<Vec<Ipv6Addr>, Error> {
    let suffix: Ipv6Addr = suffix
        .parse()
        .map_err(|e| Error::new(format!("the suffix {suffix}: {e}")))?;
    let mut targets = Vec::new();
    for word in addresses.split_whitespace() {
        let Some(address) = word
            .split_once('/')
            .and_then(|(address, _)| address.parse::<Ipv6Addr>().ok())
        else {
            continue;
        };
        let (prefix, suffix) = (address.segments(), suffix.segments());
        let target = Ipv6Addr::new(
            prefix[0], prefix[1], prefix[2], prefix[3], suffix[4], suffix[5], suffix[6], suffix[7],
        );
        if !targets.contains(&target) {
            targets.push(target);
        }
    }
    Ok(targets)
}

impl Org {
    fn router(&self, host: &str) -> Result<(String, &BTreeMap<String, String>), Error> {
        let id = format!("host-{host}");
        let files = &self
            .entity(&id)?
            .openwrt
            .as_ref()
            .ok_or_else(|| Error::new(format!("{host} runs no OpenWrt: give it openwrt in org.toml")))?
            .files;
        Ok((id, files))
    }

    /// What the script prints on the router, as root, skipped where the router is out of reach as a host without an
    /// endpoint is, or o11n has no ssh-key root takes.
    fn on_router(&self, id: &str, entity: &Entity, script: &str) -> Result<String, Outcome> {
        self.reachable(entity)?;
        let acting = needs(self.router_acting())?;
        let mut ssh = self
            .pinned_ssh(id, "root", acting.command("ssh"))
            .map_err(|error| Outcome::Fail(error.to_string()))?;
        run(ssh.command.arg(script), None).map_err(|error| Outcome::Fail(error.to_string()))
    }

    pub fn openwrt_outcome(&self, id: &str, entity: &Entity) -> Result<Outcome, Outcome> {
        let script = entity
            .openwrt
            .as_ref()
            .and_then(|openwrt| openwrt.files.get(UCI))
            .ok_or_else(|| Outcome::Fail(format!("{id}'s files have no {UCI}")))?;
        let expected = needs(filled(script, |key| self.required(Secret { id, key, slot: 0 })))?;
        let said = self.on_router(
            id,
            entity,
            &format!("cat {UCI} 2>/dev/null; echo o11n-changes; uci changes"),
        )?;
        let (applied, changes) = said.rsplit_once("o11n-changes\n").unwrap_or((&said, ""));
        let host = &entity.name;
        if applied.trim_end() != expected.trim_end() {
            return Ok(Outcome::Fail(format!(
                "{UCI} isn't the org's, so the router has other changes than it says: o11n openwrt apply {host}"
            )));
        }
        if !changes.trim().is_empty() {
            return Ok(Outcome::Fail(format!(
                "the router has changes it hasn't committed, which o11n openwrt apply {host} would commit with its \
                 own: {}",
                changes.trim().replace('\n', ", ")
            )));
        }
        Ok(Outcome::Ok)
    }

    // Policy: the reservation holds where the host has its address4 leased and answers at it, and at its suffix in
    // each prefix the router advertises.
    pub fn lan_outcome(&self, id: &str, entity: &Entity, host: &str) -> Result<Outcome, Outcome> {
        let lan = entity
            .router
            .as_ref()
            .and_then(|router| router.lan.get(host))
            .ok_or_else(|| Outcome::Fail(format!("{host} isn't behind {}", entity.name)))?;
        let behind = self
            .entity(&format!("host-{host}"))
            .map_err(|error| Outcome::Fail(error.to_string()))?;
        let absent = |why: String| {
            if behind.endpoint.is_some() {
                Outcome::Fail(why)
            } else {
                Outcome::Skip(format!("{why}, and {host} has no endpoint"))
            }
        };
        // Dependency: OpenWrt's dnsmasq keeps its leases in /tmp/dhcp.leases, and ifstatus names the lan's device.
        let said = self.on_router(
            id,
            entity,
            "cat /tmp/dhcp.leases; echo o11n-addresses; \
             ip -o -6 addr show dev \"$(ifstatus lan | jsonfilter -e '@.l3_device')\" scope global",
        )?;
        let (leases, addresses) = said.split_once("o11n-addresses\n").unwrap_or((&said, ""));
        let Some((mac, name)) = leased(leases, &lan.address4) else {
            return Err(absent(format!("the router has leased {} to no one", lan.address4)));
        };
        let holder = match &lan.mac {
            Some(own) => mac.eq_ignore_ascii_case(own),
            None => name == host,
        };
        if !holder {
            return Ok(Outcome::Fail(format!(
                "the router has leased {} to {mac} {name}, not {host}",
                lan.address4
            )));
        }
        let targets = suffixed(addresses, &lan.suffix).map_err(|error| Outcome::Fail(error.to_string()))?;
        if targets.is_empty() {
            return Ok(Outcome::Fail("the router's lan has no global IPv6 prefix".into()));
        }
        let mut ping = String::new();
        for target in std::iter::once(lan.address4.clone()).chain(targets.iter().map(ToString::to_string)) {
            let _ = write!(ping, "ping -c 1 -W 2 {target} >/dev/null 2>&1 || echo {target}; ");
        }
        let silent = self.on_router(id, entity, &ping)?;
        if silent.trim().is_empty() {
            Ok(Outcome::Ok)
        } else {
            Err(absent(format!(
                "{host} doesn't answer the router at {}",
                silent.split_whitespace().collect::<Vec<_>>().join(", ")
            )))
        }
    }

    // Policy: the record is the router's WAN address as a public resolver has it, or the updater's last word says why
    // not.
    pub fn glesys_outcome(&self, id: &str, entity: &Entity, record: &str) -> Result<Outcome, Outcome> {
        let said = self.on_router(
            id,
            entity,
            "ifstatus wan | jsonfilter -e '@[\"ipv4-address\"][0].address'; echo o11n-log; \
             logread -e o11n-glesys | tail -n 1",
        )?;
        let (wan, last) = said.split_once("o11n-log\n").unwrap_or((&said, ""));
        let (wan, last) = (wan.trim(), last.trim());
        if wan.is_empty() {
            return Ok(Outcome::Fail("the router has no WAN address".into()));
        }
        let records = dns::lookup(record, dns::Type::A).map_err(|error| Outcome::Fail(error.to_string()))?;
        if records.iter().any(|address| address == wan) {
            return Ok(Outcome::Ok);
        }
        Ok(Outcome::Fail(format!(
            "{record} is {}, not the router's WAN address {wan}; o11n-glesys last logged: {}",
            if records.is_empty() {
                "nothing".to_owned()
            } else {
                records.join(", ")
            },
            if last.is_empty() { "nothing" } else { last }
        )))
    }

    // Policy: root on a router takes service-rescue's ssh-key, as on a NixOS host, and its users', which an operator
    // who can't act as service-rescue logs in with, as one whose router hasn't had service-rescue's yet.
    fn router_acting(&self) -> Result<Acting, Error> {
        let operator = self.acting_as()?;
        let own = |operator: &str| {
            self.required(Secret {
                id: operator,
                key: "ssh-key",
                slot: 0,
            })
        };
        match self.acting(RESCUE) {
            Ok(acting) => {
                if let Some(key) = operator.as_deref().and_then(|operator| own(operator).ok()) {
                    acting.add(&key)?;
                }
                Ok(acting)
            }
            Err(error) => match operator {
                Some(operator) if self.entity(&operator)?.keys.contains_key("ssh-key") => self.acting(&operator),
                _ => Err(Error::new(format!(
                    "{}, and the operator is none of the org's with an ssh-key",
                    error.to_string().lines().next().unwrap_or_default()
                ))),
            },
        }
    }

    pub fn openwrt(&self, command: OpenwrtCommand) -> Result<(), Error> {
        match command {
            OpenwrtCommand::Apply { host } => self.openwrt_apply(&host),
            OpenwrtCommand::Image { host } => {
                self.router(&host)?;
                let org = flake(&self.root)?;
                println!(
                    "{}",
                    run(
                        Command::new("nix")
                            .arg("build")
                            .arg(format!("{org}#openwrtConfigurations.{host}.image"))
                            .args(["--no-link", "--print-out-paths"]),
                        None,
                    )?
                    .trim()
                );
                Ok(())
            }
            OpenwrtCommand::Flash { host, image } => self.openwrt_flash(&host, Path::new(&image)),
        }
    }

    fn openwrt_apply(&self, host: &str) -> Result<(), Error> {
        let (id, files) = self.router(host)?;
        let mut written = BTreeMap::new();
        for (path, contents) in files {
            let filled = filled(contents, |key| self.required(Secret { id: &id, key, slot: 0 }))?;
            written.insert(
                path.clone(),
                Written {
                    private: filled != *contents || path.ends_with("/authorized_keys"),
                    contents: filled,
                },
            );
        }
        // Fact: busybox crond reads a crontab written behind its back only when it starts.
        let reload = if written.contains_key("/etc/crontabs/root") {
            "reload_config; /etc/init.d/cron enable; /etc/init.d/cron restart"
        } else {
            "reload_config"
        };
        if !written.contains_key(UCI) {
            return Err(Error::new(format!(
                "{host}'s files have no {UCI}, which o11n changes its UCI with"
            )));
        }
        let script = writes(&written, "")? + &configure(UCI, "") + &arm(ROLLBACK.as_secs(), reload);
        let acting = self.router_acting()?;

        log(format!("writing {} files on {host}", written.len()));
        let mut ssh = self.pinned_ssh(&id, "root", acting.command("ssh"))?;
        run(ssh.command.arg("sh -s"), Some(&script))?;

        // Policy: getting back in is what keeps the files; a router that doesn't let o11n in puts back its own.
        let started = Instant::now();
        std::thread::sleep(Duration::from_secs(5));
        loop {
            let mut ssh = self.pinned_ssh(&id, "root", acting.command("ssh"))?;
            ssh.command.args(["-o", "ConnectTimeout=5"]);
            if run(ssh.command.arg(format!("rm {BACKUP}/armed")), None).is_ok() {
                log(format!("{host} let o11n back in and keeps its new files"));
                return Ok(());
            }
            if started.elapsed() + Duration::from_secs(10) > ROLLBACK {
                return Err(Error::new(format!(
                    "{host} didn't let o11n back in, so it puts back what it had in {BACKUP} {} seconds after the \
                     write, and reloads that",
                    ROLLBACK.as_secs()
                )));
            }
            std::thread::sleep(Duration::from_secs(3));
        }
    }

    fn openwrt_flash(&self, host: &str, image: &Path) -> Result<(), Error> {
        let (id, _) = self.router(host)?;
        let acting = self.router_acting()?;
        let file = File::open(image).map_err(|e| Error::new(format!("{}: {e}", image.display())))?;

        log(format!("copying {} to {host}", image.display()));
        let mut ssh = self.pinned_ssh(&id, "root", acting.command("ssh"))?;
        exited(
            ssh.command
                .arg("cat > /tmp/o11n-sysupgrade.bin && sysupgrade -T /tmp/o11n-sysupgrade.bin")
                .stdin(Stdio::from(file))
                .status()
                .map_err(|e| Error::new(format!("ssh: {e}")))?,
        )?;

        // Fact: sysupgrade reboots the router, which drops the connection, so its exit says nothing.
        log(format!("flashing {host}, which keeps nothing and reboots"));
        let mut ssh = self.pinned_ssh(&id, "root", acting.command("ssh"))?;
        let _ = ssh.command.arg("sysupgrade -n /tmp/o11n-sysupgrade.bin").status();
        log(format!(
            "{host} answers with a new ssh-key once it's up: o11n host pull-ssh-key {id}, then o11n openwrt apply \
             {host} for the files with secrets"
        ));
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::util::TempDir;

    #[test]
    fn markers_take_their_secrets() {
        let text = "option key '@o11n-secret:wifi-key@'\noption ssid 'x'\n";
        let out = filled(text, |key| Ok(format!("<{key}>"))).unwrap();
        assert_eq!(out, "option key '<wifi-key>'\noption ssid 'x'\n");
        assert!(filled(text, |_| Ok("it's".into())).is_err());
        assert!(filled("@o11n-secret:open", |_| Ok(String::new())).is_err());
    }

    #[test]
    fn the_script_writes_and_restores() {
        let temp = TempDir::new().unwrap();
        let root = temp.path().display().to_string();
        std::fs::create_dir_all(format!("{root}/etc/config")).unwrap();
        std::fs::write(format!("{root}/etc/config/network"), "old\n").unwrap();
        let written = |contents: &str, private| Written {
            contents: contents.to_owned(),
            private,
        };
        let files = BTreeMap::from([
            ("/etc/config/network".to_owned(), written("new\n", false)),
            (
                "/etc/dropbear/authorized_keys".to_owned(),
                written("ssh-ed25519 AAAA alice", true),
            ),
        ]);
        let script = writes(&files, &root).unwrap();
        let status = Command::new("sh").arg("-c").arg(&script).status().unwrap();
        assert!(status.success());
        let read = |path: &str| std::fs::read_to_string(format!("{root}{path}")).unwrap();
        assert_eq!(read("/etc/config/network"), "new\n");
        assert_eq!(read("/etc/dropbear/authorized_keys"), "ssh-ed25519 AAAA alice\n");
        let mode = |path: &str| {
            use std::os::unix::fs::PermissionsExt;
            std::fs::metadata(format!("{root}{path}")).unwrap().permissions().mode() & 0o777
        };
        assert_eq!(mode("/etc/dropbear/authorized_keys"), 0o600);
        assert_eq!(mode("/etc/config/network"), 0o644);

        let restore = format!("{root}{BACKUP}/restore");
        assert!(Command::new("sh").arg(&restore).status().unwrap().success());
        assert_eq!(read("/etc/config/network"), "old\n");
        assert!(!Path::new(&format!("{root}/etc/dropbear/authorized_keys")).exists());
    }

    #[test]
    fn an_armed_router_puts_back_what_it_had() {
        let temp = TempDir::new().unwrap();
        let root = temp.path().display().to_string();
        std::fs::create_dir_all(format!("{root}/etc/config")).unwrap();
        std::fs::write(format!("{root}/etc/config/network"), "old\n").unwrap();
        let files = BTreeMap::from([(
            "/etc/config/network".to_owned(),
            Written {
                contents: "new\n".to_owned(),
                private: false,
            },
        )]);
        let script = writes(&files, &root).unwrap() + &arm(1, "echo >> reloaded");
        let status = Command::new("sh")
            .arg("-c")
            .arg(&script)
            .current_dir(&root)
            .status()
            .unwrap();
        assert!(status.success());
        let read = |path: &str| std::fs::read_to_string(format!("{root}{path}")).unwrap();
        assert_eq!(read("/etc/config/network"), "new\n");
        std::thread::sleep(Duration::from_millis(2500));
        assert_eq!(read("/etc/config/network"), "old\n");
        assert_eq!(read("/reloaded"), "\n\n");
        assert!(Path::new(&format!("{root}{BACKUP}/rolled-back")).exists());
    }

    #[test]
    fn a_failing_change_puts_back_the_uci() {
        let temp = TempDir::new().unwrap();
        let root = temp.path().display().to_string();
        std::fs::create_dir_all(format!("{root}/etc/config")).unwrap();
        std::fs::write(format!("{root}/etc/config/network"), "old\n").unwrap();
        let read = |path: &str| std::fs::read_to_string(format!("{root}{path}")).unwrap();
        let apply = |change: &str| {
            let files = BTreeMap::from([(
                UCI.to_owned(),
                Written {
                    contents: format!("echo new > '{root}/etc/config/network'\n{change}\n"),
                    private: true,
                },
            )]);
            let script = writes(&files, &root).unwrap() + &configure(UCI, &root);
            Command::new("sh").arg("-c").arg(&script).status().unwrap().success()
        };

        assert!(!apply("exit 1"));
        assert_eq!(read("/etc/config/network"), "old\n");
        assert!(!Path::new(&format!("{root}{UCI}")).exists());

        assert!(apply("true"));
        assert_eq!(read("/etc/config/network"), "new\n");
        assert!(
            Command::new("sh")
                .arg(format!("{root}{BACKUP}/restore"))
                .status()
                .unwrap()
                .success()
        );
        assert_eq!(read("/etc/config/network"), "old\n");
    }

    #[test]
    fn a_lease_is_found_by_its_address() {
        let leases = "1794050000 02:00:00:00:00:01 192.168.1.11 alpha 01:02:00:00:00:00:01\n\
                      1794050000 02:00:00:00:00:02 192.168.1.120 * 01:02:00:00:00:00:02\n";
        assert_eq!(leased(leases, "192.168.1.11"), Some(("02:00:00:00:00:01", "alpha")));
        assert_eq!(leased(leases, "192.168.1.120"), Some(("02:00:00:00:00:02", "*")));
        assert_eq!(leased(leases, "192.168.1.1"), None);
    }

    #[test]
    fn the_suffix_goes_in_each_prefix() {
        let addresses = "6: br-lan    inet6 2001:db8:1:20::1/60 scope global dynamic noprefixroute\\       valid_lft\n\
                         6: br-lan    inet6 fd30:3eca:536c::1/60 scope global noprefixroute\\       valid_lft\n\
                         6: br-lan    inet6 2001:db8:1:20::1/64 scope global\n";
        assert_eq!(
            suffixed(addresses, "::ade").unwrap(),
            vec![
                "2001:db8:1:20::ade".parse::<Ipv6Addr>().unwrap(),
                "fd30:3eca:536c::ade".parse().unwrap()
            ]
        );
    }

    #[test]
    fn a_path_has_to_be_plain() {
        let files = BTreeMap::from([(
            "/etc/config/it's".to_owned(),
            Written {
                contents: String::new(),
                private: false,
            },
        )]);
        assert!(writes(&files, "").is_err());
    }
}
