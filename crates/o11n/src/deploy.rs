use std::io::{BufRead, BufReader, Write};
use std::os::fd::AsFd;
use std::process::{Command, ExitStatus, Stdio};

use crate::Error;
use crate::store::Org;
use crate::util::{exited, flake, log};

fn to_stderr() -> Result<Stdio, Error> {
    let stderr = std::io::stderr()
        .as_fd()
        .try_clone_to_owned()
        .map_err(|e| Error::new(format!("stderr: {e}")))?;
    Ok(Stdio::from(stderr))
}

fn program(command: &Command) -> String {
    command.get_program().to_string_lossy().into_owned()
}

// Policy: what a command prints goes to stderr, so that o11n's stdout holds only its own answer.
fn status(command: &mut Command) -> Result<(), Error> {
    let status = command
        .stdout(to_stderr()?)
        .status()
        .map_err(|e| Error::new(format!("{}: {e}", program(command))))?;
    exited(status)
}

fn output(command: &mut Command) -> Result<String, Error> {
    let output = command
        .stderr(Stdio::inherit())
        .output()
        .map_err(|e| Error::new(format!("{}: {e}", program(command))))?;
    exited(output.status)?;
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn shown(command: &mut Command) -> Result<(ExitStatus, String), Error> {
    let mut child = command
        .stdout(to_stderr()?)
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| Error::new(format!("{}: {e}", program(command))))?;
    let mut said = Vec::new();
    if let Some(stderr) = child.stderr.take() {
        let mut reader = BufReader::new(stderr);
        let mut line = Vec::new();
        while reader
            .read_until(b'\n', &mut line)
            .map_err(|e| Error::new(e.to_string()))?
            > 0
        {
            let _ = std::io::stderr().write_all(&line);
            said.append(&mut line);
        }
    }
    let status = child.wait().map_err(|e| Error::new(e.to_string()))?;
    Ok((status, String::from_utf8_lossy(&said).into_owned()))
}

impl Org {
    pub fn build_host(&self, build_host: Option<String>) -> Result<String, Error> {
        build_host
            .or_else(|| self.export.build_hosts.first().cloned())
            .ok_or_else(|| Error::new("the org has no build-hosts: set BUILD_HOST, as BUILD_HOST=localhost"))
    }

    pub fn build(&self, host: &str, build_host: &str, nix_options: &[String]) -> Result<String, Error> {
        let org = flake(&self.root)?;
        if build_host == "localhost" {
            return output(
                Command::new("nix")
                    .arg("build")
                    .arg(format!("{org}#nixosConfigurations.{host}.config.system.build.toplevel"))
                    .args(["--no-link", "--print-out-paths"])
                    .args(nix_options),
            );
        }
        if !self.export.build_hosts.iter().any(|name| name == build_host) {
            return Err(Error::new(format!("{build_host} is not in build-hosts")));
        }
        if !nix_options.is_empty() {
            return Err(Error::new(format!(
                "nix options apply only with BUILD_HOST=localhost: {}",
                nix_options.join(" ")
            )));
        }
        let address = self.export.route(build_host, 22)?;
        let metadata = output(Command::new("nix").args(["flake", "metadata", "--json"]).arg(&org))?;
        let flake = serde_json::from_str::<serde_json::Value>(&metadata)
            .ok()
            .and_then(|metadata| metadata.get("path")?.as_str().map(str::to_owned))
            .ok_or_else(|| Error::new("nix flake metadata gave no path"))?;

        // Policy: the build host evaluates the flake it is sent, inputs and all, so it needs no access of its own to
        // the private ones.
        let acting = self.acting("service-nix-build")?;
        status(
            acting
                .command("nix")
                .args(["flake", "archive", "--to"])
                .arg(format!("ssh-ng://nix-build@{address}"))
                .arg(&org),
        )?;
        let out = output(
            acting
                .command("ssh")
                .arg("-n")
                .arg(format!("nix-build@{address}"))
                .args(["build-system", &flake, host]),
        )
        .map_err(|_| Error::new(format!("{build_host} couldn't build {host}")))?;

        // Dependency: where nix-build has the daemon alone, the daemon gets no client and answers nothing.
        if !out.starts_with("/nix/store/") {
            return Err(Error::new(format!(
                "{build_host} has no build-system: on a configuration from before it, nix-build reaches the daemon \
                 alone. Deploy it once with:\n    BUILD_HOST=localhost o11n apply {build_host}"
            )));
        }
        Ok(out)
    }

    pub fn apply(&self, host: &str, build_host: &str) -> Result<(), Error> {
        let address = self.export.route(host, 22)?;
        log(format!("use {build_host} to build {host} (at {address})"));
        let build = self.build(host, build_host, &[])?;
        log(format!("build={build}"));

        // Policy: from a build host, the host substitutes the build when it switches.
        if build_host == "localhost" && address != "localhost" {
            let acting = self.acting("service-nix-push")?;
            status(
                acting
                    .command("nix")
                    .args(["copy", "--to"])
                    .arg(format!("ssh://nix-push@{address}"))
                    .arg(&build),
            )?;
        }

        log(format!("switching {host} to {build}"));
        let acting = self.acting("service-nix-switch")?;
        let (status, said) = shown(acting.command("ssh").arg(format!("nix-switch@{address}")).arg(&build))?;
        if !status.success() && build_host != "localhost" && said.contains("don't know how to build these paths") {
            return Err(Error::new(format!(
                "{host} couldn't fetch the build from {build_host}. To copy it there instead:\n    \
                 BUILD_HOST=localhost o11n apply {host}\n{host} fetches from the hosts with the nix-serve service in \
                 the configuration it runs now: check that its /etc/nix/nix.conf lists {build_host} among the \
                 substituters, and that it reaches {build_host} on port 5000."
            )));
        }
        exited(status)
    }
}
