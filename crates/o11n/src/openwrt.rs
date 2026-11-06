use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::fs::File;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use clap::Subcommand;

use crate::Error;
use crate::store::{Org, Secret};
use crate::util::{exited, flake, log, run};

// Dependency: org/openwrt.nix writes a secret into a file as @o11n-secret:<key>@.
const MARKER: &str = "@o11n-secret:";

// Dependency: the script below keeps what it replaced here, which a reboot drops.
const BACKUP: &str = "/tmp/o11n-rollback";

const ROLLBACK: Duration = Duration::from_secs(90);

#[derive(Subcommand)]
pub enum OpenwrtCommand {
    /// Writes the router's files, its secrets in them, and reloads its configuration; unless o11n gets back in within
    /// 90 seconds, the router puts back what it had and reloads that.
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

/// Runs `restore` after `delay` unless `armed` is gone by then, and `reload` either way, both detached from the session.
fn arm(delay: u64, reload: &str) -> String {
    format!(
        "touch \"$backup/armed\"\n\
         nohup sh -c 'sleep {delay}; if [ -e \"$0/armed\" ]; then sh \"$0/restore\"; rm -f \"$0/armed\"; \
         touch \"$0/rolled-back\"; {reload}; fi' \"$backup\" >/dev/null 2>&1 &\n\
         nohup sh -c 'sleep 1; {reload}' >/dev/null 2>&1 &\n"
    )
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

    fn operator_id(&self) -> Result<String, Error> {
        self.acting_as()?
            .ok_or_else(|| Error::new("the operator's identity is none of the org's, whose ssh-key would log in"))
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
        let script = writes(&written, "")? + &arm(ROLLBACK.as_secs(), reload);
        let acting = self.acting(&self.operator_id()?)?;

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
        let acting = self.acting(&self.operator_id()?)?;
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
