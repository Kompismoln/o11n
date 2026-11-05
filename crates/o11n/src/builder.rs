use std::fs::File;
use std::io::{BufRead, BufReader};
use std::os::unix::fs::FileTypeExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use clap::Subcommand;

use crate::Error;
use crate::util::{TempDir, exited, log, run};

// Dependency: nixos/services/nix-remote.nix serves the tunnel under this prefix.
const PREFIX: &str = "nix-daemon";

/// Builds on a host with the nix-remote service, through its endpoint on 443: here evaluates, the host builds and
/// keeps the outputs, and the build logs are shown as they come.
#[derive(Subcommand)]
pub enum RemoteCommand {
    /// What the host's store says of itself.
    Info {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        options: Vec<String>,
    },
    /// Builds the installables, with nix build's options after them.
    Build {
        #[arg(required = true, trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },
    /// Builds each check of the flake, `.` unless one is given first, with nix build's options after it.
    Check {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },
    /// Has the host evaluate and build a stage of the org at its HEAD, with o11n at the revision given: both pushed,
    /// as the host fetches them itself.
    Eval { stage: String, o11n: Option<String> },
}

pub struct Builder {
    server: String,
    token: Option<String>,
}

impl Builder {
    pub fn new(server: &str, token: Option<String>) -> Self {
        Self {
            server: server.to_owned(),
            token,
        }
    }

    // Dependency: nixos/services/nix-remote.nix answers 401 without the bearer, and its gost 404 under the prefix.
    pub fn probe(&self) -> Result<String, Error> {
        let temp = TempDir::new()?;
        let url = format!("https://{}/{PREFIX}/probe", self.name());
        let answer = run(
            self.curl(&temp)?
                .args(["-sS", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "20"])
                .arg(&url),
            None,
        )?;
        Ok(answer.trim().to_owned())
    }

    pub fn store_answers(&self) -> Result<(), Error> {
        let temp = TempDir::new()?;
        let tunnel = Tunnel::start(self, &temp)?;
        run(
            Command::new("nix").args(["store", store_info(), "--store", &tunnel.store()]),
            None,
        )
        .map(|_| ())
    }

    fn from_env() -> Result<Self, Error> {
        let url = std::env::var("O11N_REMOTE_BUILDER")
            .ok()
            .filter(|url| !url.is_empty())
            .ok_or_else(|| Error::new("set O11N_REMOTE_BUILDER to the builder's host"))?;
        let server = host(&url).to_owned();
        let token = std::env::var("O11N_REMOTE_BUILDER_TOKEN")
            .ok()
            .filter(|token| !token.is_empty());
        Ok(Self { server, token })
    }

    fn name(&self) -> &str {
        self.server.split(':').next().unwrap_or(&self.server)
    }

    fn curl(&self, temp: &TempDir) -> Result<Command, Error> {
        let mut curl = Command::new("curl");
        if let Some(token) = &self.token {
            let headers = temp.file("headers", &format!("Authorization: Bearer {token}\n"))?;
            curl.arg("-H").arg(format!("@{}", headers.display()));
        }
        Ok(curl)
    }

    // Accommodating for gost, which logs nothing when the tunnel's requests fail: the endpoint is asked once, the
    // same way, for a path under the prefix that the host's gost doesn't serve, which answers 404.
    fn diagnose(&self) {
        let url = format!("https://{}/{PREFIX}/probe", self.name());
        match self.probe() {
            Ok(answer) if answer == "404" => log(format!("{url} answers as it should, so the tunnel itself failed")),
            Ok(answer) if answer == "401" => log(format!("{url}: the bearer token is missing or wrong")),
            Ok(answer) => log(format!("{url}: {answer}")),
            Err(error) => log(format!("{url}: {error}")),
        }
    }
}

pub fn host(url: &str) -> &str {
    let url = url.split_once("://").map_or(url, |(_, rest)| rest);
    url.split('/').next().unwrap_or(url)
}

fn gost_config(builder: &Builder, socket: &Path) -> String {
    let server = if builder.server.contains(':') {
        builder.server.clone()
    } else {
        format!("{}:443", builder.server)
    };
    let proxy = std::env::var("HTTPS_PROXY")
        .or_else(|_| std::env::var("https_proxy"))
        .ok()
        .filter(|proxy| !proxy.is_empty())
        .map(|proxy| host(&proxy).to_owned());
    let mut config = vec![
        "log:".to_owned(),
        "  level: warn".into(),
        "services:".into(),
        "  - name: nix-daemon".into(),
        format!("    addr: {}", socket.display()),
        "    listener:".into(),
        "      type: unix".into(),
        "    handler:".into(),
        "      type: unix".into(),
        "      chain: builder".into(),
        "chains:".into(),
        "  - name: builder".into(),
        "    hops:".into(),
    ];
    if let Some(proxy) = proxy {
        config.extend([
            "      - name: proxy".to_owned(),
            "        nodes:".into(),
            "          - name: proxy".into(),
            format!("            addr: {proxy}"),
            "            connector:".into(),
            "              type: http".into(),
            "            dialer:".into(),
            "              type: tcp".into(),
        ]);
    }
    config.extend([
        "      - name: builder".to_owned(),
        "        nodes:".into(),
        "          - name: builder".into(),
        format!("            addr: {server}"),
        "            connector:".into(),
        "              type: relay".into(),
        "            dialer:".into(),
        "              type: phts".into(),
        "              tls:".into(),
        "                secure: true".into(),
        format!("                serverName: {}", builder.name()),
        "              metadata:".into(),
        format!("                pushPath: /{PREFIX}/push"),
        format!("                pullPath: /{PREFIX}/pull"),
    ]);
    if let Some(token) = &builder.token {
        config.extend([
            "                header:".to_owned(),
            format!("                  Authorization: 'Bearer {token}'"),
        ]);
    }
    config.join("\n") + "\n"
}

struct Tunnel {
    gost: Child,
    socket: PathBuf,
    log: PathBuf,
}

impl Tunnel {
    // Dependency: where only HTTPS_PROXY resolves names, gost needs o11n's patch (o11n#gost).
    fn start(builder: &Builder, temp: &TempDir) -> Result<Self, Error> {
        let socket = temp.path().join("nix-daemon.sock");
        let log = temp.path().join("gost.log");
        let config = temp.file("gost.yaml", &gost_config(builder, &socket))?;
        let output = File::create(&log).map_err(|e| Error::new(format!("{}: {e}", log.display())))?;
        let errors = output.try_clone().map_err(|e| Error::new(e.to_string()))?;
        let gost = Command::new("gost")
            .arg("-C")
            .arg(&config)
            .env("HOME", temp.path())
            .stdin(Stdio::null())
            .stdout(output)
            .stderr(errors)
            .spawn()
            .map_err(|e| Error::new(format!("gost: {e}")))?;
        let mut tunnel = Self { gost, socket, log };
        let started = Instant::now();
        while !std::fs::metadata(&tunnel.socket).is_ok_and(|metadata| metadata.file_type().is_socket()) {
            if matches!(tunnel.gost.try_wait(), Ok(Some(_))) || started.elapsed() > Duration::from_secs(5) {
                tunnel.show_log();
                return Err(Error::new("gost didn't start"));
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        Ok(tunnel)
    }

    fn store(&self) -> String {
        format!("unix://{}", self.socket.display())
    }

    fn show_log(&self) {
        let said = std::fs::read_to_string(&self.log).unwrap_or_default();
        let lines: Vec<&str> = said.lines().collect();
        for line in &lines[lines.len().saturating_sub(20)..] {
            eprintln!("{line}");
        }
    }

    // Policy: after a failure, a store that still answers through the tunnel means the build failed, not the tunnel.
    fn answers(&self) -> bool {
        let Ok(mut info) = Command::new("nix")
            .args(["store", store_info()])
            .args(["--store", &self.store()])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        else {
            return false;
        };
        let started = Instant::now();
        while started.elapsed() < Duration::from_secs(60) {
            if let Ok(Some(status)) = info.try_wait() {
                return status.success();
            }
            std::thread::sleep(Duration::from_millis(200));
        }
        let _ = info.kill();
        let _ = info.wait();
        false
    }
}

impl Drop for Tunnel {
    fn drop(&mut self) {
        let _ = self.gost.kill();
        let _ = self.gost.wait();
    }
}

// Accommodating for Lix, forked before `nix store info`, which still calls it ping.
fn store_info() -> &'static str {
    match run(Command::new("nix").arg("--version"), None) {
        Ok(version) if version.contains("Lix") => "ping",
        _ => "info",
    }
}

fn status(command: &mut Command) -> Result<(), Error> {
    let program = command.get_program().to_string_lossy().into_owned();
    exited(command.status().map_err(|e| Error::new(format!("{program}: {e}")))?)
}

// Policy: what applies only to building, and nix eval refuses, is left out of the options checks are listed with.
fn eval_options(options: &[String]) -> Vec<String> {
    let mut kept = Vec::new();
    let mut options = options.iter();
    while let Some(option) = options.next() {
        match option.as_str() {
            "--dry-run" | "--rebuild" | "--print-out-paths" | "--no-link" | "--stdin" => {}
            "-o" | "--out-link" => {
                options.next();
            }
            _ => kept.push(option.clone()),
        }
    }
    kept
}

fn checks(args: &[String]) -> Result<Vec<String>, Error> {
    let (flake, options) = match args.split_first() {
        Some((flake, options)) if !flake.starts_with('-') => (flake.as_str(), options),
        _ => (".", args),
    };
    let system = run(
        Command::new("nix").args(["eval", "--raw", "--impure", "--expr", "builtins.currentSystem"]),
        None,
    )?;
    let names = run(
        Command::new("nix")
            .args(["eval", "--json"])
            .arg(format!("{flake}#checks.{system}"))
            .args(["--apply", "builtins.attrNames"])
            .args(eval_options(options)),
        None,
    )
    .map_err(|error| Error::new(format!("couldn't list the checks of {flake}: {error}")))?;
    let names: Vec<String> = serde_json::from_str(&names).map_err(|e| Error::new(format!("{flake}'s checks: {e}")))?;
    if names.is_empty() {
        return Err(Error::new(format!("{flake} has no checks for {system}")));
    }
    log(format!("checks: {}", names.join(" ")));
    Ok(names
        .iter()
        .map(|name| format!("{flake}#checks.{system}.{name}"))
        .chain(options.iter().cloned())
        .collect())
}

fn build(builder: &Builder, args: &[String]) -> Result<(), Error> {
    let temp = TempDir::new()?;
    let tunnel = Tunnel::start(builder, &temp)?;
    let built = status(
        Command::new("nix")
            .arg("build")
            .args(["--store", &tunnel.store(), "--eval-store", "auto", "--no-link", "-L"])
            .args(args),
    );
    match built {
        Ok(()) => log(format!("built on {}", builder.name())),
        Err(_) if tunnel.answers() => log(format!(
            "{} still answers, so the build failed and not the tunnel",
            builder.name()
        )),
        Err(_) => {
            tunnel.show_log();
            builder.diagnose();
        }
    }
    built
}

fn info(builder: &Builder, options: &[String]) -> Result<(), Error> {
    let temp = TempDir::new()?;
    let tunnel = Tunnel::start(builder, &temp)?;
    let answered = status(
        Command::new("nix")
            .args(["store", store_info(), "--store", &tunnel.store()])
            .args(options),
    );
    if answered.is_err() {
        tunnel.show_log();
        builder.diagnose();
    }
    answered
}

// Dependency: the host answers with nix's output, and a last line with its exit status.
fn eval(builder: &Builder, org: &Path, stage: &str, o11n: Option<&str>) -> Result<(), Error> {
    if let Some(o11n) = o11n
        && !(o11n.len() == 40 && o11n.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()))
    {
        return Err(Error::new(format!("{o11n}: give o11n's revision whole")));
    }
    let git = |args: &[&str]| run(Command::new("git").arg("-C").arg(org).args(args), None);
    let revision = git(&["rev-parse", "HEAD"])?.trim().to_owned();
    if git(&["branch", "-r", "--contains", &revision])?.trim().is_empty() {
        return Err(Error::new(format!("{revision} isn't pushed, and the host fetches it")));
    }

    let temp = TempDir::new()?;
    let url = format!(
        "https://{}/nix-eval/{stage}/{revision}{}",
        builder.name(),
        o11n.map(|o11n| format!("/{o11n}")).unwrap_or_default()
    );
    let mut curl = builder.curl(&temp)?;
    let mut child = curl
        .args(["-sS", "-N", "--fail-with-body"])
        .arg(&url)
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| Error::new(format!("curl: {e}")))?;
    let mut exit = None;
    if let Some(stdout) = child.stdout.take() {
        for line in BufReader::new(stdout).lines() {
            let line = line.map_err(|e| Error::new(format!("curl: {e}")))?;
            match line
                .strip_prefix("nix-remote-eval: exit ")
                .and_then(|code| code.parse::<i32>().ok())
            {
                Some(code) => exit = Some(code),
                None => println!("{line}"),
            }
        }
    }
    let _ = child.wait();
    match exit {
        None => Err(Error::new(format!(
            "the evaluation on {} didn't finish",
            builder.name()
        ))),
        Some(0) => {
            log(format!("evaluated and built on {}", builder.name()));
            Ok(())
        }
        Some(code) => Err(Error::status(code)),
    }
}

pub fn remote(org: &Path, command: RemoteCommand) -> Result<(), Error> {
    let builder = Builder::from_env()?;
    match command {
        RemoteCommand::Info { options } => info(&builder, &options),
        RemoteCommand::Build { args } => build(&builder, &args),
        RemoteCommand::Check { args } => build(&builder, &checks(&args)?),
        RemoteCommand::Eval { stage, o11n } => eval(&builder, org, &stage, o11n.as_deref()),
    }
}
