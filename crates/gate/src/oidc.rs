use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde::Deserialize;
use serde_json::Value;
use std::sync::Mutex;

#[derive(Clone, Deserialize)]
pub struct Endpoints {
    pub issuer: String,
    #[serde(rename = "authorization_endpoint")]
    pub authorization: String,
    #[serde(rename = "token_endpoint")]
    pub token: String,
    #[serde(rename = "end_session_endpoint")]
    pub end_session: String,
    #[serde(rename = "jwks_uri")]
    pub jwks: String,
}

#[derive(Clone, Deserialize)]
pub struct Jwk {
    #[serde(default)]
    pub kid: String,
    pub kty: String,
    #[serde(default)]
    pub n: String,
    #[serde(default)]
    pub e: String,
}

// Fact: an issuer refuses a request with a 4xx, as Keycloak does a refresh token of a session it has ended; any other
// failure leaves it unanswered.
pub enum Failure {
    Refused(String),
    Unreachable(String),
}

impl std::fmt::Display for Failure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            Failure::Refused(error) | Failure::Unreachable(error) => formatter.write_str(error),
        }
    }
}

pub trait Issuer: Send + Sync {
    fn endpoints(&self) -> &Endpoints;
    fn exchange(&self, form: &[(&str, &str)]) -> Result<Value, Failure>;
    fn keys(&self) -> Result<Vec<Jwk>, String>;
}

pub struct Remote {
    endpoints: Endpoints,
    agent: ureq::Agent,
}

impl Remote {
    pub fn discover(issuer: &str) -> Result<Self, String> {
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .timeout_global(Some(std::time::Duration::from_secs(10)))
            .http_status_as_error(false)
            .build()
            .into();
        let url = format!("{}/.well-known/openid-configuration", issuer.trim_end_matches('/'));
        let endpoints: Endpoints = read(agent.get(&url).call(), &url).map_err(|error| error.to_string())?;
        if endpoints.issuer != issuer {
            return Err(format!("{url} names its issuer {}, not {issuer}", endpoints.issuer));
        }
        Ok(Remote { endpoints, agent })
    }
}

fn read<T: serde::de::DeserializeOwned>(
    response: Result<ureq::http::Response<ureq::Body>, ureq::Error>,
    url: &str,
) -> Result<T, Failure> {
    let unreachable = |error: &dyn std::fmt::Display| Failure::Unreachable(format!("{url}: {error}"));
    let mut response = response.map_err(|error| unreachable(&error))?;
    let status = response.status();
    let body = response
        .body_mut()
        .read_to_string()
        .map_err(|error| unreachable(&error))?;
    if status.is_client_error() {
        return Err(Failure::Refused(format!("{url}: {status}: {body}")));
    }
    if !status.is_success() {
        return Err(unreachable(&format!("{status}: {body}")));
    }
    serde_json::from_str(&body).map_err(|error| unreachable(&format!("{error}: {body}")))
}

impl Issuer for Remote {
    fn endpoints(&self) -> &Endpoints {
        &self.endpoints
    }

    fn exchange(&self, form: &[(&str, &str)]) -> Result<Value, Failure> {
        let url = &self.endpoints.token;
        read(self.agent.post(url).send_form(form.iter().copied()), url)
    }

    fn keys(&self) -> Result<Vec<Jwk>, String> {
        #[derive(Deserialize)]
        struct Set {
            keys: Vec<Jwk>,
        }
        let url = &self.endpoints.jwks;
        read::<Set>(self.agent.get(url).call(), url)
            .map(|set| set.keys)
            .map_err(|error| error.to_string())
    }
}

// Policy: the issuer's keys are fetched again for a key they don't hold, at most once a minute, as a key rotates.
pub struct Keys {
    cached: Mutex<(Vec<Jwk>, Option<u64>)>,
}

// Fact: seconds of difference between the issuer's clock and the host's that a token's times allow for.
const LEEWAY: u64 = 60;

impl Keys {
    pub fn new() -> Self {
        Keys {
            cached: Mutex::new((Vec::new(), None)),
        }
    }

    fn find(&self, issuer: &dyn Issuer, kid: &str, now: u64) -> Result<Jwk, String> {
        let mut cached = self.cached.lock().unwrap();
        let known = |keys: &[Jwk]| keys.iter().find(|key| key.kid == kid).cloned();
        if let Some(key) = known(&cached.0) {
            return Ok(key);
        }
        if cached.1.is_some_and(|fetched| now < fetched + 60) {
            return Err(format!("no key {kid}"));
        }
        *cached = (issuer.keys()?, Some(now));
        known(&cached.0).ok_or_else(|| format!("no key {kid}"))
    }

    pub fn verify(&self, issuer: &dyn Issuer, audience: &str, token: &str, now: u64) -> Result<Value, String> {
        let mut parts = token.split('.');
        let (Some(header), Some(payload), Some(signature), None) =
            (parts.next(), parts.next(), parts.next(), parts.next())
        else {
            return Err("not a JWT".to_string());
        };
        let decode = |part: &str| {
            URL_SAFE_NO_PAD
                .decode(part)
                .map_err(|error| format!("not a JWT: {error}"))
        };
        let head: Value = serde_json::from_slice(&decode(header)?).map_err(|error| error.to_string())?;
        if head["alg"] != "RS256" {
            return Err(format!("signed with {}, not RS256", head["alg"]));
        }
        let key = self.find(issuer, head["kid"].as_str().unwrap_or_default(), now)?;
        if key.kty != "RSA" {
            return Err(format!("key {} is {}, not RSA", key.kid, key.kty));
        }
        ring::signature::RsaPublicKeyComponents {
            n: decode(&key.n)?,
            e: decode(&key.e)?,
        }
        .verify(
            &ring::signature::RSA_PKCS1_2048_8192_SHA256,
            format!("{header}.{payload}").as_bytes(),
            &decode(signature)?,
        )
        .map_err(|_| "a signature that doesn't verify".to_string())?;
        let claims: Value = serde_json::from_slice(&decode(payload)?).map_err(|error| error.to_string())?;
        if claims["iss"] != issuer.endpoints().issuer.as_str() {
            return Err(format!("issued by {}", claims["iss"]));
        }
        let audiences = match &claims["aud"] {
            Value::String(one) => vec![one.as_str()],
            Value::Array(many) => many.iter().filter_map(Value::as_str).collect(),
            _ => Vec::new(),
        };
        if !audiences.contains(&audience) {
            return Err(format!("for {}, not {audience}", claims["aud"]));
        }
        if let Some(expires) = claims["exp"].as_u64()
            && expires + LEEWAY < now
        {
            return Err("expired".to_string());
        }
        Ok(claims)
    }
}
