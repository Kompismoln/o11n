use std::fs::File;
use std::io::{IsTerminal, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use crate::Error;
use crate::acting::Acting;
use crate::export::State;
use crate::store::{Org, Secret};
use crate::util::{exited, log, run};

pub enum Target {
    Host(String),
    Dir(PathBuf),
}

fn quoted(word: &str) -> String {
    format!("'{}'", word.replace('\'', r"'\''"))
}

fn size(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    #[allow(clippy::cast_precision_loss)]
    let mut amount = bytes as f64;
    let mut unit = 0;
    while amount >= 1024.0 && unit < UNITS.len() - 1 {
        amount /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} B")
    } else {
        format!("{amount:.1} {}", UNITS[unit])
    }
}

fn now() -> String {
    let mut time: libc::time_t = 0;
    // SAFETY: tm is all integers but tm_zone, a pointer localtime_r sets, and both pointers are to locals.
    let tm = unsafe {
        libc::time(&raw mut time);
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&raw const time, &raw mut tm);
        tm
    };
    format!(
        "{:04}-{:02}-{:02}-{:02}-{:02}-{:02}",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
        tm.tm_sec
    )
}

fn spawned(command: &mut Command, input: Option<&str>) -> Result<Child, Error> {
    let mut child = command
        .stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| Error::new(format!("ssh: {e}")))?;
    if let (Some(input), Some(mut stdin)) = (input, child.stdin.take()) {
        stdin
            .write_all(input.as_bytes())
            .map_err(|e| Error::new(format!("ssh: {e}")))?;
    }
    Ok(child)
}

fn download(command: &mut Command, input: Option<&str>, mut file: File, path: &Path, host: &str) -> Result<u64, Error> {
    let mut child = spawned(command, input)?;
    let mut stdout = child.stdout.take().ok_or_else(|| Error::new("ssh: no stdout"))?;
    let shown = std::io::stderr().is_terminal();
    let mut buffer = vec![0u8; 1 << 16];
    let mut written = 0u64;
    let mut last = Instant::now();
    loop {
        let read = stdout.read(&mut buffer).map_err(|e| Error::new(format!("ssh: {e}")))?;
        if read == 0 {
            break;
        }
        file.write_all(&buffer[..read])
            .map_err(|e| Error::new(format!("{}: {e}", path.display())))?;
        written += read as u64;
        if shown && last.elapsed() > Duration::from_millis(500) {
            eprint!("\r\x1b[Ko11n: {host}: {}", size(written));
            last = Instant::now();
        }
    }
    if shown {
        eprint!("\r\x1b[K");
    }
    let status = child.wait().map_err(|e| Error::new(format!("ssh: {e}")))?;
    // Dependency: GNU tar exits 1 when a file changed as it read it, which it has said, and the archive is whole.
    if status.code() == Some(1) {
        log(format!("warning: {host}'s tar said some files changed as it read them"));
        return Ok(written);
    }
    exited(status)?;
    Ok(written)
}

// Policy: an archive is any of the principal's with no --from, but for what takes one, which takes its only one.
fn archives<'a>(id: &str, state: &'a State, from: Option<&'a str>) -> Result<Vec<&'a str>, Error> {
    let names: Vec<&str> = state.archives.keys().map(String::as_str).collect();
    if names.is_empty() {
        return Err(Error::new(format!("{id} archives to no host")));
    }
    match from {
        Some(host) if names.contains(&host) => Ok(vec![host]),
        Some(host) => Err(Error::new(format!("{id} archives to {}, not {host}", names.join(", ")))),
        None => Ok(names),
    }
}

fn archive<'a>(id: &str, state: &'a State, from: Option<&'a str>) -> Result<&'a str, Error> {
    match archives(id, state, from)?.as_slice() {
        [archive] => Ok(archive),
        archives => Err(Error::new(format!(
            "{id} archives to {}: name one with --from",
            archives.join(", ")
        ))),
    }
}

impl Org {
    pub fn fetch_state(&self, id: &str, dir: &Path) -> Result<(), Error> {
        let entity = self.entity(id)?;
        let state = entity
            .state
            .as_ref()
            .ok_or_else(|| Error::new(format!("{id} has no home to fetch")))?;
        if state.hosts.is_empty() {
            return Err(Error::new(format!("{id} is on no host")));
        }
        let home = Path::new(&state.home);
        let (Some(parent), Some(name)) = (home.parent(), home.file_name()) else {
            return Err(Error::new(format!("{id}'s home is {}", state.home)));
        };
        let acting = self.acting("service-rescue")?;

        let mut sources = Vec::new();
        let mut total = 0;
        for host in &state.hosts {
            let address = self.export.route(host, 22)?;
            let said = run(
                acting
                    .command("ssh")
                    .arg(format!("root@{address}"))
                    .args(["du", "-sb", "--"])
                    .arg(quoted(&state.home)),
                None,
            )?;
            let bytes: u64 = said
                .split_whitespace()
                .next()
                .and_then(|bytes| bytes.parse().ok())
                .ok_or_else(|| Error::new(format!("du on {host} said: {}", said.trim())))?;
            total += bytes;
            sources.push((host, address, bytes));
        }
        log(format!(
            "{} to download, before compression, from {}",
            size(total),
            sources
                .iter()
                .map(|(host, _, bytes)| format!("{host} ({})", size(*bytes)))
                .collect::<Vec<_>>()
                .join(", ")
        ));

        let mut failed = Vec::new();
        for (host, address, _) in sources {
            let path = dir.join(format!("{id}@{host}-{}.tar.zst", now()));
            let file = File::create_new(&path).map_err(|e| Error::new(format!("{}: {e}", path.display())))?;
            let downloaded = download(
                acting
                    .command("ssh")
                    .arg(format!("root@{address}"))
                    .args(["tar", "--zstd", "-cf", "-", "-C"])
                    .arg(quoted(&parent.to_string_lossy()))
                    .arg("--")
                    .arg(quoted(&name.to_string_lossy())),
                None,
                file,
                &path,
                host,
            );
            match downloaded {
                Ok(bytes) => log(format!("{} ({})", path.display(), size(bytes))),
                Err(error) => {
                    let _ = std::fs::remove_file(&path);
                    log(format!("{host}: {error}"));
                    failed.push(host.as_str());
                }
            }
        }
        if failed.is_empty() {
            Ok(())
        } else {
            Err(Error::new(format!("no download from {}", failed.join(", "))))
        }
    }

    fn state(&self, id: &str) -> Result<&State, Error> {
        self.entity(id)?
            .state
            .as_ref()
            .ok_or_else(|| Error::new(format!("{id} has no state")))
    }

    fn restic_key(&self, id: &str) -> Result<String, Error> {
        Ok(self.required(Secret {
            id,
            key: "restic-key",
            slot: 0,
        })? + "\n")
    }

    // Dependency: nixos/services/archive.nix installs archive-restic on a host with the archive service.
    fn restic(&self, acting: &Acting, archive: &str, id: &str, args: &[&str], then: &str) -> Result<Command, Error> {
        let address = self.export.route(archive, 22)?;
        let mut command = acting.command("ssh");
        command
            .arg(format!("root@{address}"))
            .arg("set -o pipefail;")
            .arg("archive-restic")
            .arg(quoted(id))
            .args(args.iter().map(|arg| quoted(arg)))
            .arg(then);
        Ok(command)
    }

    pub fn snapshots(&self, id: &str, from: Option<&str>) -> Result<(), Error> {
        let state = self.state(id)?;
        let archives = archives(id, state, from)?;
        let password = self.restic_key(id)?;
        let acting = self.acting("service-rescue")?;
        for archive in archives {
            let said = run(
                &mut self.restic(&acting, archive, id, &["snapshots"], "")?,
                Some(&password),
            )?;
            println!("{archive}:\n{said}");
        }
        Ok(())
    }

    pub fn prune(&self, id: &str, from: Option<&str>) -> Result<(), Error> {
        let state = self.state(id)?;
        let archives = archives(id, state, from)?;
        let password = self.restic_key(id)?;
        let acting = self.acting("service-rescue")?;
        for archive in archives {
            let forget = &state.archives[archive].forget;
            if forget.is_empty() {
                log(format!(
                    "{archive}: {id}'s archive there has no prune, so it keeps everything"
                ));
                continue;
            }
            let mut args = vec!["forget", "--prune"];
            args.extend(forget.iter().map(String::as_str));
            let said = run(&mut self.restic(&acting, archive, id, &args, "")?, Some(&password))?;
            println!("{archive}:\n{said}");
        }
        Ok(())
    }

    pub fn restore(
        &self,
        id: &str,
        from: Option<&str>,
        of: Option<&str>,
        snapshot: &str,
        into: Target,
    ) -> Result<(), Error> {
        let state = self.state(id)?;
        let archive = archive(id, state, from)?;
        let of = match (of, &into) {
            (Some(host), _) => host.to_owned(),
            (None, Target::Host(host)) => host.clone(),
            (None, Target::Dir(_)) => match state.hosts.as_slice() {
                [host] => host.clone(),
                hosts => {
                    return Err(Error::new(format!(
                        "{id} is on {}: name the host whose snapshot with --of",
                        hosts.join(", ")
                    )));
                }
            },
        };
        let password = self.restic_key(id)?;
        let acting = self.acting("service-rescue")?;
        // Dependency: restic dump writes a directory as a tar of its paths without the leading slash.
        let dump = [
            "dump",
            "--archive",
            "tar",
            "--host",
            of.as_str(),
            snapshot,
            state.home.as_str(),
        ];
        let mut source = self.restic(&acting, archive, id, &dump, "| zstd -q")?;

        match into {
            Target::Dir(dir) => {
                let path = dir.join(format!("{id}@{of}-{snapshot}.tar.zst"));
                let file = File::create_new(&path).map_err(|e| Error::new(format!("{}: {e}", path.display())))?;
                match download(&mut source, Some(&password), file, &path, archive) {
                    Ok(bytes) => {
                        log(format!("{} ({})", path.display(), size(bytes)));
                        Ok(())
                    }
                    Err(error) => {
                        let _ = std::fs::remove_file(&path);
                        Err(error)
                    }
                }
            }
            Target::Host(host) => {
                let address = self.export.route(&host, 22)?;
                let held = run(
                    acting
                        .command("ssh")
                        .arg(format!("root@{address}"))
                        .args(["find", "--"])
                        .arg(quoted(&state.home))
                        .args([
                            "-mindepth",
                            "1",
                            "-maxdepth",
                            "1",
                            "-print",
                            "-quit",
                            "2>/dev/null",
                            "||",
                            "true",
                        ]),
                    None,
                )?;
                if !held.trim().is_empty() {
                    return Err(Error::new(format!(
                        "{id}'s home on {host}, {}, isn't empty: move what's in it aside first",
                        state.home
                    )));
                }
                let mut child = spawned(&mut source, Some(&password))?;
                let stdout = child.stdout.take().ok_or_else(|| Error::new("ssh: no stdout"))?;
                let extracted = acting
                    .command("ssh")
                    .arg(format!("root@{address}"))
                    .args(["tar", "--zstd", "-x", "--numeric-owner", "-C", "/", "-f", "-"])
                    .stdin(Stdio::from(stdout))
                    .status()
                    .map_err(|e| Error::new(format!("ssh: {e}")))?;
                exited(child.wait().map_err(|e| Error::new(format!("ssh: {e}")))?)?;
                exited(extracted)?;
                log(format!(
                    "{id}'s home on {host} is its snapshot {snapshot} of {of}, from {archive}"
                ));
                Ok(())
            }
        }
    }
}
