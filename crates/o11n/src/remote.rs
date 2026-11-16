use std::collections::BTreeMap;
use std::os::unix::fs::DirBuilderExt;
use std::path::Path;
use std::process::Command;

use clap::{Args, Subcommand};
use serde::Deserialize;
use serde_json::Value;

use crate::Error;
use crate::acting::Agent;
use crate::store::{Org, Secret};
use crate::util::{TempDir, exited, flake, log, run};

// Dependency: nixos/org/reverse-tunnel.nix forwards the stick's sshd to this port on the server.
const FORWARD_PORT: &str = "2603";

fn status(command: &mut Command) -> Result<(), Error> {
    let program = command.get_program().to_string_lossy().into_owned();
    exited(command.status().map_err(|e| Error::new(format!("{program}: {e}")))?)
}

fn quoted(word: &str) -> String {
    format!("'{}'", word.replace('\'', r"'\''"))
}

fn ssh_key(id: &str) -> Secret<'_> {
    Secret {
        id,
        key: "ssh-key",
        slot: 0,
    }
}

struct Stick {
    through: Vec<String>,
    server: String,
}

impl Stick {
    fn new(server: String) -> Self {
        Self {
            through: vec![
                "-p".into(),
                FORWARD_PORT.into(),
                "-o".into(),
                format!("ProxyJump=admin@{server}"),
                "-o".into(),
                "StrictHostKeyChecking=no".into(),
                "-o".into(),
                "UserKnownHostsFile=/dev/null".into(),
            ],
            server,
        }
    }

    fn ssh(&self, agent: &Agent) -> Command {
        let mut command = agent.command("ssh");
        command.args(&self.through).arg("root@localhost");
        command
    }
}

#[derive(Subcommand)]
pub enum TunnelAction {
    /// Opens the tunnel to a caller with the code, or one it makes up.
    Open { code: Option<String> },
    /// Closes the tunnel, and drops the caller.
    Close,
    /// Whether the tunnel is open, and a caller in.
    Status,
    /// Logs in to the machine that called in.
    Connect,
    /// Writes the machine's facts as hosts/<host>/facter.json, and shows its disks.
    Facts { host: String },
    /// Installs the host's system on the machine, which reboots into it, once what it needs is there.
    Reset {
        host: String,
        #[command(flatten)]
        how: ResetHow,
    },
}

#[derive(Args, Clone, Copy)]
pub struct ResetHow {
    /// Checks what the org has of what the installation needs, and stops there, with no machine.
    #[arg(long, conflicts_with = "resume")]
    check: bool,
    /// Keeps the machine's disks as an installation that failed left them, with what it had downloaded.
    #[arg(long)]
    resume: bool,
}

#[derive(Deserialize)]
struct SopsSecret {
    file: String,
    key: String,
}

#[derive(Deserialize)]
struct Plan {
    secrets: BTreeMap<String, SopsSecret>,
    devices: Vec<String>,
    system: String,
    networkmanager: String,
}

// Dependency: nixos-anywhere builds system.build.toplevel and system.build.diskoScript, on the machine once its disks
// are formatted when it builds there, so their derivations are evaluated here first.
const PLAN: &str = r#"c: let p = c.o11n.preserve or { enable = false; }; in {
  secrets = builtins.mapAttrs (_: s: { file = toString s.sopsFile; inherit (s) key; }) c.sops.secrets;
  devices = map (d: d.device) (builtins.attrValues c.disko.devices.disk);
  system = builtins.seq c.system.build.toplevel.drvPath (
    builtins.seq c.system.build.diskoScript.drvPath c.nixpkgs.hostPlatform.system
  );
  networkmanager = (if p.enable then p.storage else "") + "/etc/NetworkManager";
}"#;

impl Plan {
    // Dependency: nixos-anywhere's disko phase destroys and formats, and in its mount mode mounts what is there; without
    // phases it runs them all, and kexec does nothing on an installer.
    fn phases(
        &self,
        found: &str,
        host: &str,
        address: &str,
        resume: bool,
        through_stick: bool,
    ) -> Result<Option<String>, Error> {
        let mut lines = found.lines();
        let machine = lines.next().unwrap_or_default();
        if self.system.split('-').next() != Some(machine) {
            return Err(Error::new(format!(
                "the machine at {address} is {machine}, and {host}'s system is {}: call in from {host}'s machine, or set its system",
                self.system
            )));
        }
        let absent: Vec<&str> = lines.clone().filter(|line| line.starts_with('/')).collect();
        if !absent.is_empty() {
            return Err(Error::new(format!(
                "the machine at {address} has no {}: set the devices of {host}'s disk-layouts to its own, as ls -l /dev/disk/by-id shows them there",
                absent.join(", ")
            )));
        }
        let reboot = if through_stick { "" } else { ",reboot" };
        Ok(match (resume, lines.any(|line| line == "mounted")) {
            (false, _) => through_stick.then(|| "kexec,disko,install".to_owned()),
            (true, true) => Some(format!("install{reboot}")),
            (true, false) => Some(format!("disko,install{reboot}")),
        })
    }
}

// Dependency: a flake's files are in the store as /nix/store/<hash>-<name>/<path>.
fn in_flake(file: &str) -> String {
    file.splitn(5, '/').last().unwrap_or(file).to_owned()
}

impl Org {
    fn keys_in(&self, agent: &Agent, ids: &[&str]) -> Result<(), Error> {
        for id in ids {
            agent.add(&self.required(ssh_key(id))?)?;
        }
        Ok(())
    }

    pub fn image(&self, variant: &str) -> Result<(), Error> {
        status(
            Command::new("nixos-rebuild")
                .args(["build-image", "--flake"])
                .arg(format!("{}#rescue-usb", flake(&self.root)?))
                .args(["--image-variant", variant]),
        )
    }

    pub fn unit(&self, unit: &str, host: &str, from: Option<&str>, inject: bool) -> Result<(), Error> {
        let config = from.unwrap_or(host);
        let text = run(
            Command::new("nix").args(["eval", "--raw"]).arg(format!(
                "{}#nixosConfigurations.{config}.config.systemd.units.\"{unit}\".text",
                flake(&self.root)?
            )),
            None,
        )?;
        if !inject {
            print!("{text}");
            return Ok(());
        }
        let address = self.export.route(host, 22)?;
        let temp = TempDir::new()?;
        let file = temp.file(unit, &text)?;
        let acting = self.acting("service-rescue")?;
        status(
            acting
                .command("scp")
                .arg(&file)
                .arg(format!("root@{address}:/run/systemd/system/{unit}")),
        )?;
        log(format!("{host} has {config}'s {unit} in /run/systemd/system"));
        Ok(())
    }

    pub fn reset(&self, host: &str, how: ResetHow) -> Result<(), Error> {
        let plan = self.plan(host)?;
        if how.check {
            return Ok(());
        }
        let address = self.export.on_endpoint(host);
        self.install(
            host,
            &address,
            None,
            &plan,
            how.resume,
            &format!("o11n reset {host} --resume"),
        )
    }

    // Policy: what the installed system can't do without is told before the machine is touched: the keys it is
    // installed with, a configuration that evaluates, and each secret it reads, decrypted as the host will.
    fn plan(&self, host: &str) -> Result<Plan, Error> {
        let id = format!("host-{host}");
        let identity = self.identity(&id)?;
        self.verify_public_key(&id, "age-key")?;
        if self.entity(&id)?.keys.contains_key("luks-key") {
            self.required(Secret {
                id: &id,
                key: "luks-key",
                slot: 0,
            })?;
        }
        self.required(ssh_key("service-rescue"))?;
        let json = run(
            Command::new("nix")
                .args(["eval", "--json"])
                .arg(format!("{}#nixosConfigurations.{host}.config", flake(&self.root)?))
                .args(["--apply", PLAN]),
            None,
        )?;
        let plan: Plan = serde_json::from_str(&json).map_err(|e| Error::new(format!("{host}'s configuration: {e}")))?;

        let temp = TempDir::new()?;
        let identity = temp.file("identity", &identity)?;
        let mut files: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
        for secret in plan.secrets.values() {
            files.entry(&secret.file).or_default().push(&secret.key);
        }
        let mut missing = Vec::new();
        for (file, keys) in files {
            let name = in_flake(file);
            if !Path::new(file).exists() {
                missing.push(format!("{name} isn't in the flake: git add it"));
                continue;
            }
            let decrypted = run(
                Command::new("sops")
                    .args(["decrypt", "--output-type", "json", file])
                    .env("SOPS_AGE_KEY_FILE", &identity),
                None,
            );
            let value: Value = match decrypted {
                Ok(json) => serde_json::from_str(&json).map_err(|e| Error::new(format!("{name}: {e}")))?,
                Err(error) => {
                    missing.push(format!("{id} can't decrypt {name}: o11n reencrypt\n{error}"));
                    continue;
                }
            };
            for key in keys {
                if key.split('/').try_fold(&value, |value, part| value.get(part)).is_none() {
                    missing.push(format!("{name} has no {key}"));
                }
            }
        }
        if !missing.is_empty() {
            return Err(Error::new(format!(
                "{host}'s configuration reads secrets it wouldn't have; o11n status --failed tells whose each is:\n{}",
                missing.join("\n")
            )));
        }
        log(format!(
            "{host} has its keys, a configuration that evaluates, and the {} secrets it reads",
            plan.secrets.len()
        ));
        Ok(plan)
    }

    fn install(
        &self,
        host: &str,
        address: &str,
        stick: Option<(&Stick, &Agent)>,
        plan: &Plan,
        resume: bool,
        resuming: &str,
    ) -> Result<(), Error> {
        let id = format!("host-{host}");
        let temp = TempDir::new()?;
        let identity = self.identity(&id)?;
        let luks_key = if self.entity(&id)?.keys.contains_key("luks-key") {
            Some(temp.file(
                "luks-key",
                &self.required(Secret {
                    id: &id,
                    key: "luks-key",
                    slot: 0,
                })?,
            )?)
        } else {
            None
        };
        let rescue_key = temp.file("rescue-ssh-key", &self.required(ssh_key("service-rescue"))?)?;
        let extra_files = temp.path().join("extra-files");
        // Dependency: nixos-anywhere copies extra-files onto the machine's root with their modes.
        for (dir, mode) in [(extra_files.clone(), 0o755), (extra_files.join("keys"), 0o700)] {
            std::fs::DirBuilder::new()
                .mode(mode)
                .create(&dir)
                .map_err(|e| Error::new(format!("{}: {e}", dir.display())))?;
        }
        let age_key = temp.file(&format!("extra-files/keys/{id}"), &identity)?;

        let own;
        let (through, agent) = if let Some((stick, agent)) = stick {
            (stick.through.clone(), agent)
        } else {
            own = Agent::start(temp.path())?;
            self.keys_in(&own, &["service-rescue"])?;
            (Vec::new(), &own)
        };

        let probe = |script: &str| {
            run(
                agent
                    .command("ssh")
                    .args(&through)
                    .args(["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"])
                    .arg(format!("root@{address}"))
                    .arg(script),
                None,
            )
        };
        let mounted = "if mountpoint -q /mnt; then echo mounted; fi";
        let devices: Vec<String> = plan.devices.iter().map(|device| quoted(device)).collect();
        let found = probe(&format!(
            "uname -m; for device in {}; do [ -e \"$device\" ] || echo \"$device\"; done; {mounted}",
            devices.join(" ")
        ))
        .map_err(|error| Error::new(format!("SSH to root@{address} failed:\n{error}")))?;
        log(format!("SSH to root@{address} succeeded"));
        let phases = plan.phases(&found, host, address, resume, stick.is_some())?;

        let mut anywhere = agent.command("nixos-anywhere");
        anywhere
            .arg("-i")
            .arg(&rescue_key)
            .arg("--flake")
            .arg(format!("{}#{host}", flake(&self.root)?))
            .arg("--target-host")
            .arg(format!("root@{address}"))
            .args(["--ssh-option", "GlobalKnownHostsFile=/dev/null"])
            .args(["--disk-encryption-keys", &format!("/keys/{id}")])
            .arg(&age_key);
        if let Some(luks_key) = &luks_key {
            anywhere.args(["--disk-encryption-keys", "/luks-key"]).arg(luks_key);
        }
        anywhere
            .args(["--generate-hardware-config", "nixos-facter"])
            .arg(self.root.join(format!("hosts/{host}/facter.json")))
            .arg("--extra-files")
            .arg(&extra_files)
            .arg("--copy-host-keys");
        if let Some((stick, _)) = stick {
            anywhere
                .args(["-p", FORWARD_PORT, "--ssh-option"])
                .arg(format!("ProxyJump=admin@{}", stick.server))
                // Policy: the machine builds its system from the caches over its own line, rather than receive it
                // through the server, and reboots only once it has the wifi it called in on.
                .args(["--build-on", "remote"]);
        }
        if let Some(phases) = &phases {
            anywhere.args(["--phases", phases]);
        }
        if resume {
            anywhere.args(["--disko-mode", "mount"]);
        }
        let installed = status(&mut anywhere);
        if installed.is_err() && probe(mounted).is_ok_and(|found| found.trim() == "mounted") {
            log(format!(
                "the machine's disks are formatted and mounted, with what it downloaded: {resuming} goes on from there"
            ));
        }
        installed
    }

    pub fn tunnel(&self, server: &str, action: TunnelAction) -> Result<(), Error> {
        let stick = Stick::new(self.export.on_endpoint(server));
        let on_server = |words: &[String]| -> Result<(), Error> {
            let acting = self.acting("user-admin")?;
            status(
                acting
                    .command("ssh")
                    .arg("-t")
                    .arg(format!("admin@{}", stick.server))
                    .args(["sudo", "reverse-tunnel"])
                    .args(words),
            )
        };
        let temp;
        let agent = match &action {
            TunnelAction::Open { code } => {
                return on_server(
                    &std::iter::once("open".into())
                        .chain(code.as_deref().map(quoted))
                        .collect::<Vec<_>>(),
                );
            }
            TunnelAction::Close => return on_server(&["close".into()]),
            TunnelAction::Status => return on_server(&["status".into()]),
            _ => {
                // Accommodating for ssh's ProxyCommand: both hops' keys are in one agent, as an `o11n as` nested in
                // another's would act as the outer one's identity, which can't read the other key.
                temp = TempDir::new()?;
                let agent = Agent::start(temp.path())?;
                self.keys_in(&agent, &["user-admin", "service-rescue"])?;
                agent
            }
        };
        match action {
            TunnelAction::Connect => status(&mut stick.ssh(&agent)),
            TunnelAction::Facts { host } => self.facts(&stick, &agent, &host),
            TunnelAction::Reset { host, how } => self.reset_through(server, &stick, &agent, &host, how),
            TunnelAction::Open { .. } | TunnelAction::Close | TunnelAction::Status => unreachable!(),
        }
    }

    fn facts(&self, stick: &Stick, agent: &Agent, host: &str) -> Result<(), Error> {
        let relative = format!("hosts/{host}/facter.json");
        let path = self.root.join(&relative);
        let facts = run(stick.ssh(agent).arg("nixos-facter"), None)?;
        crate::util::write(&path, &facts, false)?;
        run(
            Command::new("git")
                .arg("-C")
                .arg(&self.root)
                .args(["add", "--intent-to-add"])
                .arg(&relative),
            None,
        )?;
        log(format!("wrote {relative}; its disks:"));
        status(stick.ssh(agent).arg("ls -l /dev/disk/by-id/ | grep -v -- -part"))
    }

    fn reset_through(
        &self,
        server: &str,
        stick: &Stick,
        agent: &Agent,
        host: &str,
        how: ResetHow,
    ) -> Result<(), Error> {
        let plan = self.plan(host)?;
        if how.check {
            return Ok(());
        }
        let networkmanager = &plan.networkmanager;
        self.install(
            host,
            "localhost",
            Some((stick, agent)),
            &plan,
            how.resume,
            &format!("o11n tunnel {server} reset {host} --resume"),
        )?;
        status(stick.ssh(agent).arg(format!(
            "if [ -d /etc/NetworkManager/system-connections ]; then \
             mkdir -p /mnt{networkmanager} && cp -a /etc/NetworkManager/system-connections /mnt{networkmanager}/; fi"
        )))?;
        let _ = status(stick.ssh(agent).args(["systemctl", "reboot"]));
        log(format!("{host} is rebooting into its new system"));
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plan() -> Plan {
        Plan {
            secrets: BTreeMap::new(),
            devices: vec!["/dev/disk/by-id/ata-one".into()],
            system: "x86_64-linux".into(),
            networkmanager: "/etc/NetworkManager".into(),
        }
    }

    fn phases(found: &str, resume: bool, through_stick: bool) -> Result<Option<String>, String> {
        plan()
            .phases(found, "alpha", "localhost", resume, through_stick)
            .map_err(|error| error.to_string())
    }

    #[test]
    fn a_reset_formats_and_a_resumed_one_mounts_or_goes_on() {
        assert_eq!(phases("x86_64\n", false, false), Ok(None));
        assert_eq!(phases("x86_64\n", false, true), Ok(Some("kexec,disko,install".into())));
        assert_eq!(phases("x86_64\n", true, true), Ok(Some("disko,install".into())));
        assert_eq!(phases("x86_64\nmounted\n", true, true), Ok(Some("install".into())));
        assert_eq!(
            phases("x86_64\nmounted\n", true, false),
            Ok(Some("install,reboot".into()))
        );
    }

    #[test]
    fn another_machine_or_one_without_the_disks_is_refused() {
        assert!(phases("aarch64\n", false, true).unwrap_err().contains("is aarch64"));
        assert!(
            phases("x86_64\n/dev/disk/by-id/ata-one\n", false, true)
                .unwrap_err()
                .contains("has no /dev/disk/by-id/ata-one")
        );
    }

    #[test]
    fn a_file_of_the_flake_is_named_from_its_root() {
        assert_eq!(
            in_flake("/nix/store/abc-source/enc/host-alpha.yaml"),
            "enc/host-alpha.yaml"
        );
    }
}
