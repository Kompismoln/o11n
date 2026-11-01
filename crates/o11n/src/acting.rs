use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use crate::Error;
use crate::store::{Org, Secret};
use crate::util::{TempDir, exited, run};

pub struct Agent {
    child: Child,
    socket: PathBuf,
}

impl Agent {
    pub fn start(dir: &Path) -> Result<Self, Error> {
        let socket = dir.join("agent");
        let child = Command::new("ssh-agent")
            .arg("-D")
            .arg("-a")
            .arg(&socket)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .spawn()
            .map_err(|e| Error::new(format!("ssh-agent: {e}")))?;
        let mut agent = Self { child, socket };
        let started = Instant::now();
        while !agent.socket.exists() {
            if let Ok(Some(status)) = agent.child.try_wait() {
                return Err(Error::new(format!("ssh-agent: {status}")));
            }
            if started.elapsed() > Duration::from_secs(5) {
                return Err(Error::new("ssh-agent: no socket after 5s"));
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        Ok(agent)
    }

    pub fn add(&self, ssh_key: &str) -> Result<(), Error> {
        run(
            Command::new("ssh-add").arg("-").env("SSH_AUTH_SOCK", &self.socket),
            Some(ssh_key),
        )?;
        Ok(())
    }

    pub fn command(&self, program: &str) -> Command {
        let mut command = Command::new(program);
        command
            .env("SSH_AUTH_SOCK", &self.socket)
            .env("SSH_AGENT_PID", self.child.id().to_string());
        command
    }
}

impl Drop for Agent {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

pub struct Acting {
    agent: Agent,
    identity: PathBuf,
    _temp: TempDir,
}

impl Acting {
    pub fn command(&self, program: &str) -> Command {
        let mut command = self.agent.command(program);
        command.env("SOPS_AGE_KEY_FILE", &self.identity);
        command
    }
}

impl Org {
    pub fn acting(&self, id: &str) -> Result<Acting, Error> {
        let temp = TempDir::new()?;
        let identity = temp.file("identity", &self.identity(id)?)?;
        let ssh_key = self.required_as(
            Secret {
                id,
                key: "ssh-key",
                slot: 0,
            },
            &identity,
        )?;
        let agent = Agent::start(temp.path())?;
        agent.add(&ssh_key)?;
        Ok(Acting {
            agent,
            identity,
            _temp: temp,
        })
    }

    pub fn ssh(&self, id: &str, host: &str, user: Option<String>, command: &[String]) -> Result<(), Error> {
        let address = self.export.route(host, 22)?;
        let user = match user {
            Some(user) => user,
            None => self.entity(id)?.name.clone(),
        };
        let acting = self.acting(id)?;
        let status = acting
            .command("ssh")
            .arg(format!("{user}@{address}"))
            .args(command)
            .status()
            .map_err(|e| Error::new(format!("ssh: {e}")))?;
        exited(status)
    }

    pub fn run_as(&self, id: &str, command: &[String]) -> Result<(), Error> {
        let (program, args) = command.split_first().ok_or_else(|| Error::new("no command to run"))?;
        let acting = self.acting(id)?;
        let status = acting
            .command(program)
            .args(args)
            .status()
            .map_err(|e| Error::new(format!("{program}: {e}")))?;
        exited(status)
    }
}
