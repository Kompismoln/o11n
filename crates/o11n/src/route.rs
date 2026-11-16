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

    fn candidates(&self, name: &str) -> Vec<String> {
        // Optimization: a dotted name, likely a fqdn, is tried as it is before the rest.
        // Policy: a host is tried on its vpns, the most direct first, before the org's namespaces, and a router, which
        // may be on no vpn, last at its address on its lan.
        let host = self.entities.get(&format!("host-{name}"));
        let mut candidates: Vec<String> = Vec::new();
        for candidate in name
            .contains('.')
            .then(|| name.to_owned())
            .into_iter()
            .chain(host.into_iter().flat_map(|entity| entity.fqdns.iter().cloned()))
            .chain(self.namespaces.iter().map(|namespace| format!("{name}.{namespace}")))
            .chain(
                host.and_then(|entity| entity.router.as_ref())
                    .map(|router| router.address4.clone()),
            )
        {
            if !candidates.contains(&candidate) {
                candidates.push(candidate);
            }
        }
        candidates
    }

    pub fn route(&self, name: &str, port: u16) -> Result<String, Error> {
        if let Some(address) = pinned(name) {
            log(format!("{name} is {address}, as O11N_ROUTES pins it"));
            return Ok(address);
        }
        if name == "localhost" || name.parse::<IpAddr>().is_ok() {
            return Ok(name.to_owned());
        }
        for candidate in self.candidates(name) {
            if answers(&candidate, port) {
                log(format!("{candidate}:{port} is up"));
                return Ok(candidate);
            }
        }
        Err(Error::new(format!("no contact with {name}:{port}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_host_is_tried_on_its_vpns_before_the_namespaces_and_a_router_last_on_its_lan() {
        let entity = |extra: serde_json::Value| {
            let mut entity = serde_json::json!({
                "class": "host", "name": "", "grants": [], "actors": [], "keys": {}, "publicKeys": {}, "secrets": {},
            });
            entity
                .as_object_mut()
                .unwrap()
                .extend(extra.as_object().unwrap().clone());
            entity
        };
        let org = Export::parse(
            &serde_json::json!({
                "root-identities": [],
                "endpoint": "example.com",
                "namespaces": ["hub.example.com", "example.com"],
                "classes": {},
                "entities": {
                    "host-alice": entity(serde_json::json!({
                        "fqdns": ["alice.own.example.com", "alice.hub.example.com"],
                    })),
                    "host-bob": entity(serde_json::json!({
                        "router": { "address4": "192.168.1.1", "lan": {}, "records": [] },
                    })),
                },
            })
            .to_string(),
        )
        .unwrap();
        assert_eq!(
            org.candidates("alice"),
            ["alice.own.example.com", "alice.hub.example.com", "alice.example.com"]
        );
        assert_eq!(
            org.candidates("bob"),
            ["bob.hub.example.com", "bob.example.com", "192.168.1.1"]
        );
        assert_eq!(
            org.candidates("carol.example.org"),
            [
                "carol.example.org",
                "carol.example.org.hub.example.com",
                "carol.example.org.example.com"
            ]
        );
    }
}
