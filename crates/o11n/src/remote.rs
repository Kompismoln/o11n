use std::os::unix::fs::DirBuilderExt;
use std::process::Command;

use clap::Subcommand;

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
    /// Installs the host's system on the machine, which reboots into it.
    Reset { host: String },
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

    pub fn reset(&self, host: &str) -> Result<(), Error> {
        let address = self.export.on_endpoint(host);
        self.install(host, &address, None)
    }

    fn install(&self, host: &str, address: &str, stick: Option<(&Stick, &Agent)>) -> Result<(), Error> {
        let id = format!("host-{host}");
        let temp = TempDir::new()?;
        let identity = self.identity(&id)?;
        let luks_key = temp.file(
            "luks-key",
            &self.required(Secret {
                id: &id,
                key: "luks-key",
                slot: 0,
            })?,
        )?;
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

        status(
            agent
                .command("ssh")
                .args(&through)
                .args(["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"])
                .arg(format!("root@{address}"))
                .arg("true"),
        )
        .map_err(|_| Error::new(format!("SSH to root@{address} failed")))?;
        log(format!("SSH to root@{address} succeeded"));

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
            .arg(&age_key)
            .args(["--disk-encryption-keys", "/luks-key"])
            .arg(&luks_key)
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
                .args(["--build-on", "remote", "--phases", "kexec,disko,install"]);
        }
        status(&mut anywhere)
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
            TunnelAction::Reset { host } => self.reset_through(&stick, &agent, &host),
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

    fn reset_through(&self, stick: &Stick, agent: &Agent, host: &str) -> Result<(), Error> {
        let networkmanager = run(
            Command::new("nix")
                .args(["eval", "--raw"])
                .arg(format!("{}#nixosConfigurations.{host}.config", flake(&self.root)?))
                .args([
                    "--apply",
                    r#"c: let p = c.o11n.preserve or { enable = false; };
                       in (if p.enable then p.storage else "") + "/etc/NetworkManager""#,
                ]),
            None,
        )?;
        self.install(host, "localhost", Some((stick, agent)))?;
        status(stick.ssh(agent).arg(format!(
            "if [ -d /etc/NetworkManager/system-connections ]; then \
             mkdir -p /mnt{networkmanager} && cp -a /etc/NetworkManager/system-connections /mnt{networkmanager}/; fi"
        )))?;
        let _ = status(stick.ssh(agent).args(["systemctl", "reboot"]));
        log(format!("{host} is rebooting into its new system"));
        Ok(())
    }
}
