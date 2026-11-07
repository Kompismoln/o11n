use std::net::{IpAddr, TcpStream, ToSocketAddrs};
use std::time::Duration;

use crate::Error;
use crate::export::Export;
use crate::util::log;

fn answers(host: &str, port: u16) -> bool {
    (host, port).to_socket_addrs().is_ok_and(|mut addresses| {
        addresses.any(|address| TcpStream::connect_timeout(&address, Duration::from_secs(2)).is_ok())
    })
}

fn pinned(name: &str) -> Option<String> {
    let routes = std::env::var("O11N_ROUTES").ok()?;
    routes
        .split_whitespace()
        .filter_map(|route| route.split_once('='))
        .rfind(|(pinned, _)| *pinned == name)
        .map(|(_, address)| address.to_owned())
}

impl Export {
    pub fn on_endpoint(&self, name: &str) -> String {
        pinned(name).unwrap_or_else(|| format!("{name}.{}", self.endpoint))
    }

    pub fn route(&self, name: &str, port: u16) -> Result<String, Error> {
        if let Some(address) = pinned(name) {
            log(format!("{name} is {address}, as O11N_ROUTES pins it"));
            return Ok(address);
        }
        if name == "localhost" || name.parse::<IpAddr>().is_ok() {
            return Ok(name.to_owned());
        }
        // Optimization: a dotted name, likely a fqdn, is tried as it is before the namespaces.
        // Policy: a router, which may be on no vpn, is tried last at its address on its lan.
        let candidates = name
            .contains('.')
            .then(|| name.to_owned())
            .into_iter()
            .chain(self.namespaces.iter().map(|namespace| format!("{name}.{namespace}")))
            .chain(
                self.entities
                    .get(&format!("host-{name}"))
                    .and_then(|entity| entity.router.as_ref())
                    .map(|router| router.address4.clone()),
            );
        for candidate in candidates {
            if answers(&candidate, port) {
                log(format!("{candidate}:{port} is up"));
                return Ok(candidate);
            }
        }
        Err(Error::new(format!("no contact with {name}:{port}")))
    }
}
