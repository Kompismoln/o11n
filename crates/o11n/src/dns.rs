use std::net::IpAddr;
use std::process::Command;

use serde::Deserialize;

use crate::Error;

const DOH: &str = "https://cloudflare-dns.com/dns-query";

// Fact: RFC 7208 caps the lookups an SPF evaluation makes.
const SPF_LOOKUPS: u32 = 10;

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct Response {
    status: u32,
    #[serde(default)]
    answer: Vec<Answer>,
}

#[derive(Deserialize)]
struct Answer {
    #[serde(rename = "type")]
    kind: u16,
    data: String,
}

#[derive(Clone, Copy)]
pub enum Type {
    A,
    Aaaa,
    Mx,
    Txt,
}

impl Type {
    fn name(self) -> &'static str {
        match self {
            Self::A => "A",
            Self::Aaaa => "AAAA",
            Self::Mx => "MX",
            Self::Txt => "TXT",
        }
    }

    fn code(self) -> u16 {
        match self {
            Self::A => 1,
            Self::Aaaa => 28,
            Self::Mx => 15,
            Self::Txt => 16,
        }
    }
}

// Policy: as the internet sees the name, from a public resolver over https, which reaches where plain DNS doesn't;
// O11N_DOH names another.
pub fn lookup(name: &str, kind: Type) -> Result<Vec<String>, Error> {
    let doh = std::env::var("O11N_DOH").unwrap_or_else(|_| DOH.to_owned());
    let output = Command::new("curl")
        .args(["-sS", "--max-time", "20", "--get", "-H", "accept: application/dns-json"])
        .arg("--data-urlencode")
        .arg(format!("name={name}"))
        .arg("--data-urlencode")
        .arg(format!("type={}", kind.name()))
        .arg(&doh)
        .output()
        .map_err(|e| Error::new(format!("curl: {e}")))?;
    if !output.status.success() {
        return Err(Error::new(
            String::from_utf8_lossy(&output.stderr).trim_end().to_owned(),
        ));
    }
    let response: Response = serde_json::from_slice(&output.stdout).map_err(|e| {
        Error::new(format!(
            "{doh} answers {name} {} with what isn't DNS JSON: {e}",
            kind.name()
        ))
    })?;
    // Fact: 3 is NXDOMAIN, a name without records.
    match response.status {
        0 | 3 => {}
        status => {
            return Err(Error::new(format!(
                "{doh} can't resolve {name} {}: rcode {status}",
                kind.name()
            )));
        }
    }
    Ok(response
        .answer
        .into_iter()
        .filter(|answer| answer.kind == kind.code())
        .map(|answer| match kind {
            Type::Txt => txt(&answer.data),
            _ => answer.data.trim_end_matches('.').to_owned(),
        })
        .collect())
}

// Fact: a TXT record's data is its strings, each quoted, which make one text.
fn txt(data: &str) -> String {
    let mut text = String::new();
    let mut quoted = false;
    let mut escaped = false;
    for c in data.chars() {
        match (quoted, escaped, c) {
            (true, true, c) => {
                text.push(c);
                escaped = false;
            }
            (true, false, '\\') => escaped = true,
            (_, false, '"') => quoted = !quoted,
            (true, false, c) => text.push(c),
            _ => {}
        }
    }
    if text.is_empty() && !data.contains('"') {
        return data.to_owned();
    }
    text
}

// Policy: the one TXT record at name that starts with prefix, as a receiver takes it.
pub fn record(name: &str, prefix: &str) -> Result<String, Error> {
    let records: Vec<String> = lookup(name, Type::Txt)?
        .into_iter()
        .filter(|text| text.to_ascii_lowercase().starts_with(&prefix.to_ascii_lowercase()))
        .collect();
    match records.as_slice() {
        [record] => Ok(record.clone()),
        [] => Err(Error::new(format!("{name} has no {prefix} record"))),
        _ => Err(Error::new(format!(
            "{name} has {} {prefix} records, which receivers take as none: keep one",
            records.len()
        ))),
    }
}

pub fn addresses(name: &str) -> Result<Vec<IpAddr>, Error> {
    let mut addresses = Vec::new();
    for kind in [Type::A, Type::Aaaa] {
        for data in lookup(name, kind)? {
            addresses.push(
                data.parse()
                    .map_err(|_| Error::new(format!("{name} {} is {data}, no address", kind.name())))?,
            );
        }
    }
    Ok(addresses)
}

pub fn exchangers(name: &str) -> Result<Vec<String>, Error> {
    Ok(lookup(name, Type::Mx)?
        .into_iter()
        .filter_map(|data| {
            data.split_whitespace()
                .nth(1)
                .map(|host| host.trim_end_matches('.').to_ascii_lowercase())
        })
        .collect())
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Spf {
    Pass,
    Fail,
    SoftFail,
    Neutral,
}

impl Spf {
    pub fn name(self) -> &'static str {
        match self {
            Self::Pass => "pass",
            Self::Fail => "fail",
            Self::SoftFail => "softfail",
            Self::Neutral => "neutral",
        }
    }
}

// Policy: SPF as RFC 7208 evaluates it for mail from ip, but for exists and ptr, which match nothing here.
pub fn spf(domain: &str, ip: IpAddr) -> Result<Spf, Error> {
    let mut lookups = 0;
    spf_of(domain, ip, &mut lookups)
}

fn spf_of(domain: &str, ip: IpAddr, lookups: &mut u32) -> Result<Spf, Error> {
    let record = record(domain, "v=spf1")?;
    let mut redirect = None;
    for term in record.split_whitespace().skip(1) {
        if let Some(target) = term.strip_prefix("redirect=") {
            redirect = Some(target.to_owned());
            continue;
        }
        if term.contains('=') {
            continue;
        }
        let (qualifier, mechanism) = match term.chars().next() {
            Some('+') => (Spf::Pass, &term[1..]),
            Some('-') => (Spf::Fail, &term[1..]),
            Some('~') => (Spf::SoftFail, &term[1..]),
            Some('?') => (Spf::Neutral, &term[1..]),
            _ => (Spf::Pass, term),
        };
        if matches(domain, mechanism, ip, lookups)? {
            return Ok(qualifier);
        }
    }
    match redirect {
        Some(target) => {
            count(lookups)?;
            spf_of(&target, ip, lookups)
        }
        None => Ok(Spf::Neutral),
    }
}

fn count(lookups: &mut u32) -> Result<(), Error> {
    *lookups += 1;
    if *lookups > SPF_LOOKUPS {
        return Err(Error::new(format!(
            "SPF takes more than {SPF_LOOKUPS} lookups, which receivers take as an error"
        )));
    }
    Ok(())
}

fn matches(domain: &str, mechanism: &str, ip: IpAddr, lookups: &mut u32) -> Result<bool, Error> {
    let (name, argument) = mechanism
        .split_once(':')
        .map_or((mechanism, None), |(name, argument)| (name, Some(argument)));
    let (name, cidr) = match name.split_once('/') {
        Some((name, cidr)) if argument.is_none() => (name, Some(cidr)),
        _ => (name, None),
    };
    let (target, cidr) = match argument.map(|argument| argument.split_once('/')) {
        Some(Some((target, cidr))) => (target, Some(cidr)),
        Some(None) => (argument.unwrap_or(domain), cidr),
        None => (domain, cidr),
    };
    Ok(match name.to_ascii_lowercase().as_str() {
        "all" => true,
        "ip4" | "ip6" => {
            let network: IpAddr = target
                .parse()
                .map_err(|_| Error::new(format!("SPF of {domain} has {mechanism}, no network")))?;
            let cidr = cidr.map(|cidr| {
                if network.is_ipv6() {
                    format!("/{cidr}")
                } else {
                    cidr.to_owned()
                }
            });
            within(ip, network, cidr.as_deref())?
        }
        "a" => {
            count(lookups)?;
            addresses(target)?
                .into_iter()
                .any(|address| within(ip, address, cidr).unwrap_or(false))
        }
        "mx" => {
            count(lookups)?;
            let mut found = false;
            for host in exchangers(target)? {
                found |= addresses(&host)?
                    .into_iter()
                    .any(|address| within(ip, address, cidr).unwrap_or(false));
            }
            found
        }
        "include" => {
            count(lookups)?;
            spf_of(target, ip, lookups)? == Spf::Pass
        }
        _ => false,
    })
}

// Fact: an a or mx mechanism's cidr is ip4's, then //ip6's.
fn within(ip: IpAddr, network: IpAddr, cidr: Option<&str>) -> Result<bool, Error> {
    let (four, six) = match cidr {
        Some(cidr) => match cidr.split_once('/') {
            Some((four, six)) => (four, six),
            None => (cidr, ""),
        },
        None => ("", ""),
    };
    let bits = |text: &str, max: u32| -> Result<u32, Error> {
        if text.is_empty() {
            return Ok(max);
        }
        text.parse::<u32>()
            .ok()
            .filter(|bits| *bits <= max)
            .ok_or_else(|| Error::new(format!("SPF has /{text}, no prefix length")))
    };
    Ok(match (ip, network) {
        (IpAddr::V4(ip), IpAddr::V4(network)) => {
            let bits = bits(four, 32)?;
            let mask = u32::MAX.checked_shl(32 - bits).unwrap_or(0);
            u32::from(ip) & mask == u32::from(network) & mask
        }
        (IpAddr::V6(ip), IpAddr::V6(network)) => {
            let bits = bits(six, 128)?;
            let mask = u128::MAX.checked_shl(128 - bits).unwrap_or(0);
            u128::from(ip) & mask == u128::from(network) & mask
        }
        _ => false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn txt_joins_its_strings() {
        assert_eq!(txt(r#""v=DKIM1; k=rsa; " "p=abc""#), "v=DKIM1; k=rsa; p=abc");
        assert_eq!(txt(r#""a \"b\"""#), r#"a "b""#);
    }

    #[test]
    fn within_masks_by_prefix() {
        let ip: IpAddr = "192.0.2.17".parse().unwrap();
        assert!(within(ip, "192.0.2.0".parse().unwrap(), Some("24")).unwrap());
        assert!(!within(ip, "192.0.3.0".parse().unwrap(), Some("24")).unwrap());
        assert!(within(ip, "192.0.2.17".parse().unwrap(), None).unwrap());
        assert!(within(ip, "0.0.0.0".parse().unwrap(), Some("0")).unwrap());
        let six: IpAddr = "2001:db8::1".parse().unwrap();
        assert!(within(six, "2001:db8::".parse().unwrap(), Some("/32")).unwrap());
        assert!(!within(six, ip, None).unwrap());
    }
}
