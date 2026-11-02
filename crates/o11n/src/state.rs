use std::fs::File;
use std::io::{IsTerminal, Read, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::Error;
use crate::store::Org;
use crate::util::{exited, log, run};

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

fn download(command: &mut Command, mut file: File, path: &Path, host: &str) -> Result<u64, Error> {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| Error::new(format!("ssh: {e}")))?;
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
}
