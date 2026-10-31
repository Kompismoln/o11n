use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::Error;

pub fn log(message: impl std::fmt::Display) {
    eprintln!("o11n: {message}");
}

// Policy: a failure is what the command said, stderr first, as locksmith.sh says why on stdout.
pub fn run(command: &mut Command, input: Option<&str>) -> Result<String, Error> {
    let program = command.get_program().to_string_lossy().into_owned();
    let mut child = command
        .stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| Error::new(format!("{program}: {e}")))?;
    if let (Some(input), Some(mut stdin)) = (input, child.stdin.take()) {
        stdin
            .write_all(input.as_bytes())
            .map_err(|e| Error::new(format!("{program}: {e}")))?;
    }
    let output = child
        .wait_with_output()
        .map_err(|e| Error::new(format!("{program}: {e}")))?;
    if !output.status.success() {
        let said = String::from_utf8_lossy(&output.stderr).into_owned() + &String::from_utf8_lossy(&output.stdout);
        return Err(Error::new(format!("{program}: {}", said.trim_end())));
    }
    String::from_utf8(output.stdout).map_err(|e| Error::new(format!("{program}: {e}")))
}

pub fn write(path: &Path, contents: &str, private: bool) -> Result<(), Error> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| Error::new(format!("{}: {e}", parent.display())))?;
    }
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    if private {
        options.mode(0o600);
    }
    options
        .open(path)
        .and_then(|mut file| file.write_all(contents.as_bytes()))
        .map_err(|e| Error::new(format!("{}: {e}", path.display())))
}

pub fn read(path: &Path) -> Result<Option<String>, Error> {
    match std::fs::read_to_string(path) {
        Ok(contents) => Ok(Some(contents)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(Error::new(format!("{}: {e}", path.display()))),
    }
}

pub struct TempDir(PathBuf);

impl TempDir {
    pub fn new() -> Result<Self, Error> {
        let mut name = [0u8; 8];
        rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut name);
        let name = name
            .iter()
            .fold(String::from("o11n-"), |name, byte| name + &format!("{byte:02x}"));
        let path = std::env::temp_dir().join(name);
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&path)
            .map_err(|e| Error::new(format!("{}: {e}", path.display())))?;
        Ok(Self(path))
    }

    pub fn file(&self, name: &str, contents: &str) -> Result<PathBuf, Error> {
        let path = self.0.join(name);
        write(&path, contents, true)?;
        Ok(path)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
