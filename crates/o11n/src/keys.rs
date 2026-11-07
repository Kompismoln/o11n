use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use rand::RngCore;
use rand::rngs::OsRng;
use sha_crypt::{PasswordHasher, PasswordVerifier, ShaCrypt};
use sha1::{Digest, Sha1};
use sha2::Sha256;

use crate::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Age,
    Ssh,
    SshRsa,
    Wireguard,
    NixSign,
    TlsCert,
    Syncthing,
    Password,
    Htpasswd,
    Passphrase { bytes: usize, slots: bool },
    File,
}

impl Kind {
    // Dependency: org/entity.nix gives each key one of these types.
    pub fn named(kind: &str) -> Result<Self, Error> {
        Ok(match kind {
            "age" => Self::Age,
            "ssh" => Self::Ssh,
            "ssh-rsa" => Self::SshRsa,
            "wireguard" => Self::Wireguard,
            "nix-sign" => Self::NixSign,
            "tls-cert" => Self::TlsCert,
            "syncthing" => Self::Syncthing,
            "password" => Self::Password,
            "htpasswd" => Self::Htpasswd,
            "luks" => Self::Passphrase { bytes: 12, slots: true },
            "passphrase" => Self::Passphrase {
                bytes: 40,
                slots: false,
            },
            "file" => Self::File,
            _ => return Err(Error::new(format!("{kind} is no type of key o11n knows"))),
        })
    }

    pub fn has_slots(self) -> bool {
        matches!(self, Self::Passphrase { slots: true, .. })
    }

    pub fn has_public_key(self) -> bool {
        !matches!(self, Self::Passphrase { .. } | Self::File)
    }
}

fn random<const N: usize>() -> [u8; N] {
    let mut bytes = [0; N];
    OsRng.fill_bytes(&mut bytes);
    bytes
}

fn passphrase(bytes: usize) -> String {
    let mut random = vec![0; bytes];
    OsRng.fill_bytes(&mut random);
    STANDARD.encode(random)
}

fn invalid(key: &str, error: impl std::fmt::Display) -> Error {
    Error::new(format!("the {key} isn't one: {error}"))
}

pub fn generate(kind: Kind, id: &str, domain: Option<&str>) -> Result<String, Error> {
    Ok(match kind {
        Kind::Age => {
            use age::secrecy::ExposeSecret;
            format!("{}\n", age::x25519::Identity::generate().to_string().expose_secret())
        }
        Kind::Ssh => {
            let keypair = ssh_key::private::Ed25519Keypair::from_seed(&random());
            let mut key = ssh_key::PrivateKey::from(keypair);
            key.set_comment(id);
            key.to_openssh(ssh_key::LineEnding::LF)
                .map_err(|e| Error::new(format!("ssh-key: {e}")))?
                .to_string()
        }
        Kind::SshRsa => {
            let keypair = ssh_key::private::RsaKeypair::random(&mut OsRng, 3072)
                .map_err(|e| Error::new(format!("ssh-rsa: {e}")))?;
            let mut key = ssh_key::PrivateKey::from(keypair);
            key.set_comment(id);
            key.to_openssh(ssh_key::LineEnding::LF)
                .map_err(|e| Error::new(format!("ssh-rsa: {e}")))?
                .to_string()
        }
        Kind::Wireguard => {
            let mut secret: [u8; 32] = random();
            secret[0] &= 0b1111_1000;
            secret[31] &= 0b0111_1111;
            secret[31] |= 0b0100_0000;
            format!("{}\n", STANDARD.encode(secret))
        }
        Kind::NixSign => {
            let key = ed25519_dalek::SigningKey::from_bytes(&random());
            format!("{id}:{}", STANDARD.encode(key.to_keypair_bytes()))
        }
        Kind::TlsCert => {
            domain.ok_or_else(|| {
                Error::new(format!(
                    "{id}: a tls-cert is a namespace's, on its service domain-<namespace>"
                ))
            })?;
            rcgen::KeyPair::generate_for(&rcgen::PKCS_ED25519)
                .map_err(|e| Error::new(format!("tls-cert: {e}")))?
                .serialize_pem()
        }
        Kind::Syncthing => {
            let pair = rcgen::KeyPair::generate_for(&rcgen::PKCS_ED25519)
                .map_err(|e| Error::new(format!("syncthing: {e}")))?;
            // Policy: a certificate as Syncthing makes its own, which never expires, as a device's ID is its hash.
            let mut params = rcgen::CertificateParams::new(vec!["syncthing".to_owned()])
                .map_err(|e| Error::new(format!("syncthing: {e}")))?;
            params.distinguished_name.push(rcgen::DnType::CommonName, "syncthing");
            params.not_before = rcgen::date_time_ymd(1975, 1, 1);
            params.not_after = rcgen::date_time_ymd(4096, 1, 1);
            let cert = params
                .self_signed(&pair)
                .map_err(|e| Error::new(format!("syncthing: {e}")))?;
            format!("{}{}", cert.pem(), pair.serialize_pem())
        }
        Kind::Password => passphrase(8),
        // Policy: random enough that its unsalted {SHA} hash, the one hash rest-server reads that o11n can write,
        // is safe to publish.
        Kind::Htpasswd => passphrase(32),
        Kind::Passphrase { bytes, .. } => passphrase(bytes),
        Kind::File => {
            return Err(Error::new(format!(
                "a file isn't generated: o11n secret generate {id} <key> --from <file>"
            )));
        }
    })
}

pub fn public(kind: Kind, key: &str, secret: &str, domain: Option<&str>) -> Result<String, Error> {
    match kind {
        Kind::Age => {
            let identity: age::x25519::Identity = secret
                .lines()
                .rfind(|line| line.starts_with("AGE-SECRET-KEY-"))
                .ok_or_else(|| invalid(key, "no AGE-SECRET-KEY- line"))?
                .parse()
                .map_err(|e| invalid(key, e))?;
            Ok(format!("{}\n", identity.to_public()))
        }
        Kind::Ssh | Kind::SshRsa => {
            let private = ssh_key::PrivateKey::from_openssh(secret).map_err(|e| invalid(key, e))?;
            if kind == Kind::SshRsa && !matches!(private.algorithm(), ssh_key::Algorithm::Rsa { .. }) {
                return Err(invalid(key, format!("a {} key, not an RSA key", private.algorithm())));
            }
            let public = private.public_key().to_openssh().map_err(|e| invalid(key, e))?;
            Ok(format!("{public}\n"))
        }
        Kind::Wireguard => {
            let bytes: [u8; 32] = STANDARD
                .decode(secret.trim())
                .map_err(|e| invalid(key, e))?
                .try_into()
                .map_err(|_| invalid(key, "not 32 bytes"))?;
            let public = x25519_dalek::PublicKey::from(&x25519_dalek::StaticSecret::from(bytes));
            Ok(format!("{}\n", STANDARD.encode(public.as_bytes())))
        }
        Kind::NixSign => {
            let (name, encoded) = secret.trim().split_once(':').ok_or_else(|| invalid(key, "no name"))?;
            let bytes = STANDARD.decode(encoded).map_err(|e| invalid(key, e))?;
            let seed: [u8; 32] = bytes
                .get(..32)
                .and_then(|seed| seed.try_into().ok())
                .ok_or_else(|| invalid(key, "too short"))?;
            let public = ed25519_dalek::SigningKey::from_bytes(&seed).verifying_key();
            Ok(format!("{name}:{}", STANDARD.encode(public.as_bytes())))
        }
        Kind::TlsCert => {
            let domain = domain.ok_or_else(|| invalid(key, "it's no domain's"))?;
            let pair = rcgen::KeyPair::from_pem(secret).map_err(|e| invalid(key, e))?;
            let mut params = rcgen::CertificateParams::new(vec![format!("*.{domain}"), domain.to_owned()])
                .map_err(|e| invalid(key, e))?;
            params.distinguished_name.push(rcgen::DnType::CommonName, domain);
            params.not_before = time::OffsetDateTime::now_utc();
            params.not_after = params.not_before + time::Duration::days(3650);
            Ok(params.self_signed(&pair).map_err(|e| invalid(key, e))?.pem())
        }
        Kind::Syncthing => syncthing_id(key, secret),
        Kind::Password => Ok(ShaCrypt::SHA512
            .hash_password_with_salt(secret.as_bytes(), &random::<12>())
            .map_err(|e| invalid(key, e))?
            .to_string()),
        Kind::Htpasswd => Ok(format!("{{SHA}}{}\n", STANDARD.encode(Sha1::digest(secret.as_bytes())))),
        Kind::Passphrase { .. } | Kind::File => Err(Error::new(format!("a {key} has no public key"))),
    }
}

// Accommodating for a password's hash and a certificate, which differ each time they're derived: they're checked
// against the secret rather than compared.
pub fn matches(kind: Kind, key: &str, secret: &str, public: &str, domain: Option<&str>) -> Result<bool, Error> {
    match kind {
        Kind::Password => Ok(ShaCrypt::SHA512
            .verify_password(secret.as_bytes(), public.trim())
            .is_ok()),
        Kind::TlsCert => tls_matches(
            key,
            secret,
            public,
            domain.ok_or_else(|| invalid(key, "it's no domain's"))?,
        ),
        _ => Ok(self::public(kind, key, secret, domain)? == public),
    }
}

fn tls_matches(key: &str, secret: &str, certificate: &str, domain: &str) -> Result<bool, Error> {
    let pair = rcgen::KeyPair::from_pem(secret).map_err(|e| invalid(key, e))?;
    let (_, pem) = x509_parser::pem::parse_x509_pem(certificate.as_bytes()).map_err(|e| invalid(key, e))?;
    let cert = pem.parse_x509().map_err(|e| invalid(key, e))?;
    let lasts = cert.validity().not_after.timestamp()
        > (time::OffsetDateTime::now_utc() + time::Duration::days(30)).unix_timestamp();
    let names: Vec<String> = cert
        .subject_alternative_name()
        .ok()
        .flatten()
        .map(|san| {
            san.value
                .general_names
                .iter()
                .filter_map(|name| match name {
                    x509_parser::extensions::GeneralName::DNSName(name) => Some((*name).to_owned()),
                    _ => None,
                })
                .collect()
        })
        .unwrap_or_default();
    let for_domain = names
        .iter()
        .any(|name| name == domain || *name == format!("*.{domain}"));
    let own = cert.public_key().subject_public_key.data.as_ref() == pair.public_key_raw();
    Ok(lasts && for_domain && own)
}

// Fact: Syncthing reads its certificate and its key from the same file, as it skips the other's block in each.
fn syncthing_id(key: &str, secret: &str) -> Result<String, Error> {
    let (mut certificate, mut private) = (None, None);
    for pem in x509_parser::pem::Pem::iter_from_buffer(secret.as_bytes()) {
        let pem = pem.map_err(|e| invalid(key, e))?;
        match pem.label.as_str() {
            "CERTIFICATE" => certificate = Some(pem),
            "PRIVATE KEY" => private = Some(pem),
            _ => {}
        }
    }
    let certificate = certificate.ok_or_else(|| invalid(key, "no certificate"))?;
    let private = private.ok_or_else(|| invalid(key, "no private key"))?;
    let pair = rcgen::KeyPair::try_from(private.contents.as_slice()).map_err(|e| invalid(key, e))?;
    let cert = certificate.parse_x509().map_err(|e| invalid(key, e))?;
    if cert.public_key().subject_public_key.data.as_ref() != pair.public_key_raw() {
        return Err(invalid(key, "its certificate is of another key"));
    }
    Ok(format!("{}\n", device_id(&certificate.contents)))
}

const BASE32: &[u8; 32] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

// Fact: as Syncthing's lib/protocol/deviceid.go has it: the certificate's SHA-256 in base32, a Luhn mod 32 check
// character after each 13, in groups of 7.
fn device_id(certificate: &[u8]) -> String {
    let digest = Sha256::digest(certificate);
    let mut encoded = Vec::new();
    let (mut buffer, mut bits) = (0u32, 0);
    for byte in digest {
        buffer = (buffer << 8) | u32::from(byte);
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            encoded.push(BASE32[((buffer >> bits) & 31) as usize]);
        }
    }
    if bits > 0 {
        encoded.push(BASE32[((buffer << (5 - bits)) & 31) as usize]);
    }
    let checked: Vec<u8> = encoded
        .chunks(13)
        .flat_map(|chunk| chunk.iter().copied().chain([luhn32(chunk)]))
        .collect();
    checked
        .chunks(7)
        .map(|group| String::from_utf8_lossy(group).into_owned())
        .collect::<Vec<_>>()
        .join("-")
}

fn luhn32(chunk: &[u8]) -> u8 {
    let mut factor = 1;
    let mut sum = 0;
    for &character in chunk {
        let codepoint = BASE32.iter().position(|&c| c == character).unwrap_or(0);
        let addend = factor * codepoint;
        factor = if factor == 2 { 1 } else { 2 };
        sum += addend / 32 + addend % 32;
    }
    BASE32[(32 - sum % 32) % 32]
}

pub fn validate(kind: Kind, key: &str, secret: &str, domain: Option<&str>) -> Result<(), Error> {
    match kind {
        Kind::Password | Kind::Htpasswd | Kind::Passphrase { .. } => {
            if secret.ends_with('\n') {
                return Err(Error::new(format!("the {key} has a trailing newline")));
            }
            if secret.chars().count() < 6 {
                return Err(Error::new(format!("the {key} is shorter than 6 characters")));
            }
            Ok(())
        }
        Kind::File if secret.is_empty() => Err(Error::new(format!("the {key} is empty"))),
        Kind::File => Ok(()),
        _ => public(kind, key, secret, domain).map(|_| ()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_file_is_taken_as_it_is_and_never_generated() {
        let kind = Kind::named("file").unwrap();
        assert!(validate(kind, "wifi-keys", "psk_staple=abc\n", None).is_ok());
        assert!(validate(kind, "wifi-keys", "", None).is_err());
        assert!(generate(kind, "host-alice", None).is_err());
        assert!(!kind.has_public_key());
    }

    #[test]
    fn generated_secrets_have_public_keys_that_match() {
        for (key, kind) in [
            ("age-key", "age"),
            ("ssh-key", "ssh"),
            ("sftp-key", "ssh-rsa"),
            ("wg0-key", "wireguard"),
            ("nix-sign", "nix-sign"),
            ("tls-cert", "tls-cert"),
            ("syncthing-user-alice.web", "syncthing"),
            ("passwd", "password"),
        ] {
            let kind = Kind::named(kind).unwrap();
            let secret = generate(kind, "service-domain-alice", Some("alice")).unwrap();
            validate(kind, key, &secret, Some("alice")).unwrap();
            let public = public(kind, key, &secret, Some("alice")).unwrap();
            assert!(matches(kind, key, &secret, &public, Some("alice")).unwrap(), "{key}");
            let other = generate(kind, "service-domain-alice", Some("alice")).unwrap();
            assert!(!matches(kind, key, &other, &public, Some("alice")).unwrap(), "{key}");
        }
    }

    #[test]
    fn reads_what_age_keygen_and_mkpasswd_wrote() {
        let age = "AGE-SECRET-KEY-1L0EJY3FLSYHDE46Y80F0KLUKUWP6V3J340UR7G2GWNFGXJQ0P6ZQ6X37TN\n";
        assert!(public(Kind::Age, "age-key", age, None).unwrap().starts_with("age1"));
        let hash = "$6$abcdefgh12345678$rgVBh3dKBJ/VoOexgpHN02JF9FwwnEkyAQzqGLNlhexq64yEDKzsj2Z50xYaxbDIvKprcBvplv9z/srlOk.29/";
        assert!(matches(Kind::Password, "passwd", "hunter22", hash, None).unwrap());
        assert!(!matches(Kind::Password, "passwd", "hunter23", hash, None).unwrap());
        // Fact: as `printf hunter22 | openssl sha1 -binary | base64` gives it.
        let sha = "{SHA}YLOvi/43NWI8fUpe90m7asGkQTo=\n";
        assert_eq!(public(Kind::Htpasswd, "archive-passwd", "hunter22", None).unwrap(), sha);
    }

    #[test]
    fn an_ssh_rsa_key_is_rsa() {
        let ed25519 = generate(Kind::Ssh, "app-cloud", None).unwrap();
        assert!(validate(Kind::SshRsa, "sftp-key", &ed25519, None).is_err());
        let rsa = generate(Kind::SshRsa, "app-cloud", None).unwrap();
        assert!(
            public(Kind::SshRsa, "sftp-key", &rsa, None)
                .unwrap()
                .starts_with("ssh-rsa ")
        );
    }

    #[test]
    fn a_device_id_is_as_syncthing_gives_it() {
        // Fact: as `syncthing generate` wrote the certificate and gave its device ID.
        let pem = concat!(
            "-----BEGIN CERTIFICATE-----\n",
            "MIIBoDCCAVKgAwIBAgIJAOGqLpYkYACmMAUGAytlcDBKMRIwEAYDVQQKEwlTeW5j\n",
            "dGhpbmcxIDAeBgNVBAsTF0F1dG9tYXRpY2FsbHkgR2VuZXJhdGVkMRIwEAYDVQQD\n",
            "EwlzeW5jdGhpbmcwHhcNMjYxMTA1MDAwMDAwWhcNNDYxMDMxMDAwMDAwWjBKMRIw\n",
            "EAYDVQQKEwlTeW5jdGhpbmcxIDAeBgNVBAsTF0F1dG9tYXRpY2FsbHkgR2VuZXJh\n",
            "dGVkMRIwEAYDVQQDEwlzeW5jdGhpbmcwKjAFBgMrZXADIQD80RuhmFB9GjFIa0jA\n",
            "4+LSKYNyfF5ajvYtjLIpQT+LiaNVMFMwDgYDVR0PAQH/BAQDAgWgMB0GA1UdJQQW\n",
            "MBQGCCsGAQUFBwMBBggrBgEFBQcDAjAMBgNVHRMBAf8EAjAAMBQGA1UdEQQNMAuC\n",
            "CXN5bmN0aGluZzAFBgMrZXADQQCY5MggYBx6Hu1+41rwFnhuQDA+kRW+gEEn4wN2\n",
            "vXceWVRPRxmzhYyRTYf9ilWSkdYG+P2yefEUWpTWgT5QSzcG\n",
            "-----END CERTIFICATE-----\n",
        );
        let (_, pem) = x509_parser::pem::parse_x509_pem(pem.as_bytes()).unwrap();
        assert_eq!(
            device_id(&pem.contents),
            "6ZO3OSJ-JYEXK3W-YFWVHMX-HVQWACL-OJEIFKI-T2SZFSQ-HU4UUMC-6YGCIQ2"
        );
    }

    #[test]
    fn passphrases_are_checked() {
        let kind = Kind::named("luks").unwrap();
        assert!(validate(kind, "luks-key", "abcdef\n", None).is_err());
        assert!(validate(kind, "luks-key", "abc", None).is_err());
        assert!(validate(kind, "luks-key", &generate(kind, "host-alice", None).unwrap(), None).is_ok());
    }
}
