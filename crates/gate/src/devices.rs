use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Serialize, Deserialize)]
pub struct Device {
    pub id: String,
    pub user: String,
    pub email: Option<String>,
    pub name: Option<String>,
    pub label: String,
    pub created: u64,
    hash: String,
}

// Policy: a device's password is 256 random bits, so its SHA-256 is all there is to keep of it; a slow hash would
// guard a guessable one.
fn hash(password: &str) -> String {
    crate::http::hex(ring::digest::digest(&ring::digest::SHA256, password.as_bytes()).as_ref())
}

impl Device {
    pub fn new(
        id: String,
        user: String,
        email: Option<String>,
        name: Option<String>,
        label: String,
        created: u64,
        password: &str,
    ) -> Self {
        Device {
            id,
            user,
            email,
            name,
            label,
            created,
            hash: hash(password),
        }
    }
}

pub struct Devices {
    path: PathBuf,
    list: Vec<Device>,
}

impl Devices {
    pub fn load(path: PathBuf) -> Result<Self, String> {
        let list = match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(|error| format!("{}: {error}", path.display()))?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(error) => return Err(format!("{}: {error}", path.display())),
        };
        Ok(Devices { path, list })
    }

    fn save(&self) -> Result<(), String> {
        let json = serde_json::to_vec_pretty(&self.list).map_err(|error| error.to_string())?;
        let partial = self.path.with_extension("json.partial");
        std::fs::write(&partial, json)
            .and_then(|()| std::fs::rename(&partial, &self.path))
            .map_err(|error| format!("{}: {error}", self.path.display()))
    }

    pub fn add(&mut self, device: Device) -> Result<(), String> {
        self.list.push(device);
        self.save().inspect_err(|_| {
            self.list.pop();
        })
    }

    pub fn find(&self, user: &str, password: &str) -> Option<&Device> {
        let hash = hash(password);
        self.list
            .iter()
            .find(|device| device.hash == hash && device.user == user)
    }

    pub fn of<'a>(&'a self, user: &'a str) -> impl Iterator<Item = &'a Device> {
        self.list.iter().filter(move |device| device.user == user)
    }

    pub fn revoke(&mut self, user: &str, id: &str) -> Result<(), String> {
        let before = self.list.clone();
        self.list.retain(|device| !(device.user == user && device.id == id));
        self.save().inspect_err(|_| self.list = before)
    }
}
