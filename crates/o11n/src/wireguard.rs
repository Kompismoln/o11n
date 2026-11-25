use std::fmt::Write as _;

use serde::Deserialize;

use crate::Error;
use crate::store::{Org, Secret};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Interface {
    pub key: String,
    pub addresses: Vec<String>,
    pub dns: Vec<String>,
    pub listen_port: Option<u16>,
    pub peers: Vec<Peer>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Peer {
    pub host: String,
    pub public_key: String,
    #[serde(rename = "allowedIPs")]
    pub allowed_ips: Vec<String>,
    pub endpoint: Option<String>,
    pub keepalive: Option<u32>,
}

fn wg_quick_conf(
    interface: &Interface,
    private_key: &str,
    public_key: impl Fn(&Peer) -> Result<String, Error>,
) -> Result<String, Error> {
    let mut out = format!(
        "[Interface]\nPrivateKey = {private_key}\nAddress = {}\n",
        interface.addresses.join(", ")
    );
    if !interface.dns.is_empty() {
        let _ = writeln!(out, "DNS = {}", interface.dns.join(", "));
    }
    if let Some(port) = interface.listen_port {
        let _ = writeln!(out, "ListenPort = {port}");
    }
    for peer in &interface.peers {
        let _ = write!(
            out,
            "\n# {}\n[Peer]\nPublicKey = {}\nAllowedIPs = {}\n",
            peer.host,
            public_key(peer)?,
            peer.allowed_ips.join(", ")
        );
        if let Some(endpoint) = &peer.endpoint {
            let _ = writeln!(out, "Endpoint = {endpoint}");
        }
        if let Some(seconds) = peer.keepalive {
            let _ = writeln!(out, "PersistentKeepalive = {seconds}");
        }
    }
    Ok(out)
}

impl Org {
    pub fn wireguard(&self, host: &str, vpn: &str) -> Result<String, Error> {
        let id = format!("host-{host}");
        let entity = self.export.entity(&id)?;
        let interface = entity.wireguard.get(vpn).ok_or_else(|| {
            Error::new(format!(
                "{host} isn't on {vpn}: add {vpn} to [host.{host}] vpns, of {}",
                entity.wireguard.keys().cloned().collect::<Vec<_>>().join(", ")
            ))
        })?;
        let private_key = self.required(Secret {
            id: &id,
            key: &interface.key,
            slot: 0,
        })?;
        wg_quick_conf(interface, private_key.trim(), |peer| {
            let path = self.root.join(&peer.public_key);
            std::fs::read_to_string(&path)
                .map(|key| key.trim().to_owned())
                .map_err(|e| Error::new(format!("{}: {e}", path.display())))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_client_dials_its_gateway_and_keeps_it_alive() {
        let interface = Interface {
            key: "wg0-key".into(),
            addresses: vec!["fd00::3/64".into(), "10.0.0.3/24".into()],
            dns: vec!["fd00::1".into(), "10.0.0.1".into()],
            listen_port: None,
            peers: vec![Peer {
                host: "gw".into(),
                public_key: "public-keys/host-gw-wg0-key.pub".into(),
                allowed_ips: vec!["fd00::/64".into(), "10.0.0.0/24".into()],
                endpoint: Some("gw.example.com:51820".into()),
                keepalive: Some(25),
            }],
        };
        let out = wg_quick_conf(&interface, "private", |peer| Ok(format!("<{}>", peer.public_key))).unwrap();
        assert_eq!(
            out,
            "[Interface]\nPrivateKey = private\nAddress = fd00::3/64, 10.0.0.3/24\nDNS = fd00::1, 10.0.0.1\n\n\
             # gw\n[Peer]\nPublicKey = <public-keys/host-gw-wg0-key.pub>\nAllowedIPs = fd00::/64, 10.0.0.0/24\n\
             Endpoint = gw.example.com:51820\nPersistentKeepalive = 25\n"
        );
    }

    #[test]
    fn a_host_that_listens_says_its_port_and_dials_no_peer_without_an_endpoint() {
        let interface = Interface {
            key: "wg1-key".into(),
            addresses: vec!["fd01::1/64".into()],
            dns: vec![],
            listen_port: Some(52101),
            peers: vec![Peer {
                host: "gamma".into(),
                public_key: "k".into(),
                allowed_ips: vec!["fd01::3/128".into()],
                endpoint: None,
                keepalive: None,
            }],
        };
        let out = wg_quick_conf(&interface, "private", |_| Ok("pub".into())).unwrap();
        assert_eq!(
            out,
            "[Interface]\nPrivateKey = private\nAddress = fd01::1/64\nListenPort = 52101\n\n\
             # gamma\n[Peer]\nPublicKey = pub\nAllowedIPs = fd01::3/128\n"
        );
    }
}
