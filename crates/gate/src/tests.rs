use crate::gate::{AppleProfile, Config, Gate};
use crate::http::{Request, Response};
use crate::oidc::{Endpoints, Failure, Issuer, Jwk};
use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use ring::signature::{RSA_PKCS1_SHA256, RsaKeyPair};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

const ISSUER: &str = "https://auth.example.com/realms/example";
const URL: &str = "https://calendar.example.com";
const T0: u64 = 1_800_000_000;

type Change = fn(&mut Value);

struct Fake {
    key: RsaKeyPair,
    endpoints: Endpoints,
    codes: Mutex<HashMap<String, (Value, String)>>,
    sessions: Mutex<HashMap<String, Value>>,
    issued: AtomicUsize,
    down: AtomicBool,
}

impl Fake {
    fn new() -> Self {
        Fake {
            key: RsaKeyPair::from_pkcs8(include_bytes!("testdata/issuer.pk8")).unwrap(),
            endpoints: Endpoints {
                issuer: ISSUER.to_string(),
                authorization: format!("{ISSUER}/protocol/openid-connect/auth"),
                token: format!("{ISSUER}/protocol/openid-connect/token"),
                end_session: format!("{ISSUER}/protocol/openid-connect/logout"),
                jwks: format!("{ISSUER}/protocol/openid-connect/certs"),
            },
            codes: Mutex::new(HashMap::new()),
            sessions: Mutex::new(HashMap::new()),
            issued: AtomicUsize::new(0),
            down: AtomicBool::new(false),
        }
    }

    fn sign_as(&self, kid: &str, claims: &Value) -> String {
        let header = URL_SAFE_NO_PAD.encode(json!({ "alg": "RS256", "typ": "JWT", "kid": kid }).to_string());
        let payload = URL_SAFE_NO_PAD.encode(claims.to_string());
        let message = format!("{header}.{payload}");
        let mut signature = vec![0; self.key.public().modulus_len()];
        self.key
            .sign(
                &RSA_PKCS1_SHA256,
                &ring::rand::SystemRandom::new(),
                message.as_bytes(),
                &mut signature,
            )
            .unwrap();
        format!("{message}.{}", URL_SAFE_NO_PAD.encode(signature))
    }

    fn sign(&self, claims: &Value) -> String {
        self.sign_as("k1", claims)
    }

    // Policy: as Keycloak's authorization endpoint does, a code for whoever logs in, bound to the request's PKCE
    // challenge, whose token is the ID token `claims` with the request's nonce.
    fn authorize(&self, claims: Value, challenge: &str) -> String {
        let code = format!("code-{}", self.codes.lock().unwrap().len());
        self.codes
            .lock()
            .unwrap()
            .insert(code.clone(), (claims, challenge.to_string()));
        code
    }

    // Policy: as Keycloak's token endpoint does, an access token for 300 seconds and a refresh token, a new one each
    // time, of the user's session, which lasts 3600 seconds, for its ID token's claims.
    fn tokens(&self, claims: &Value) -> Value {
        let refresh = format!("refresh-{}", self.issued.fetch_add(1, Ordering::SeqCst));
        self.sessions.lock().unwrap().insert(refresh.clone(), claims.clone());
        json!({
            "access_token": "unused", "expires_in": 300, "id_token": self.sign(claims),
            "refresh_token": refresh, "refresh_expires_in": 3600,
        })
    }

    // Policy: as Keycloak ends a user's session, which it tells no one of as it expires.
    fn end(&self, user: &str) {
        let sub = format!("sub-{user}");
        self.sessions
            .lock()
            .unwrap()
            .retain(|_, claims| claims["sub"] != sub.as_str());
    }

    fn renewals(&self) -> usize {
        self.issued.load(Ordering::SeqCst)
    }
}

struct Shared(Arc<Fake>);

impl Issuer for Shared {
    fn endpoints(&self) -> &Endpoints {
        &self.0.endpoints
    }

    fn exchange(&self, form: &[(&str, &str)]) -> Result<Value, Failure> {
        let refused = |error: &str| Failure::Refused(error.to_string());
        if self.0.down.load(Ordering::SeqCst) {
            return Err(Failure::Unreachable("down".to_string()));
        }
        let form: HashMap<_, _> = form.iter().copied().collect();
        assert_eq!(form["client_id"], "calendar");
        if form["client_secret"] != "oidc-secret" {
            return Err(refused("401: unauthorized_client"));
        }
        if form["grant_type"] == "refresh_token" {
            let claims = self.0.sessions.lock().unwrap().remove(form["refresh_token"]);
            return claims
                .map(|claims| self.0.tokens(&claims))
                .ok_or_else(|| refused("400: invalid_grant: Session not active"));
        }
        assert_eq!(form["grant_type"], "authorization_code");
        assert_eq!(form["redirect_uri"], format!("{URL}/auth/callback"));
        let (claims, challenge) = self
            .0
            .codes
            .lock()
            .unwrap()
            .remove(form["code"])
            .ok_or_else(|| refused("400: invalid_grant"))?;
        let verified = URL_SAFE_NO_PAD.encode(ring::digest::digest(
            &ring::digest::SHA256,
            form["code_verifier"].as_bytes(),
        ));
        if verified != challenge {
            return Err(refused("400: invalid_grant: PKCE"));
        }
        Ok(self.0.tokens(&claims))
    }

    fn keys(&self) -> Result<Vec<Jwk>, String> {
        let public = ring::rsa::PublicKeyComponents::<Vec<u8>>::from(self.0.key.public());
        Ok(vec![Jwk {
            kid: "k1".to_string(),
            kty: "RSA".to_string(),
            n: URL_SAFE_NO_PAD.encode(public.n),
            e: URL_SAFE_NO_PAD.encode(public.e),
        }])
    }
}

struct Harness {
    gate: Gate,
    fake: Arc<Fake>,
    state: PathBuf,
}

fn state_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("gate-test-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn config(state: &Path) -> Config {
    serde_json::from_value(json!({
        "listen": "127.0.0.1:0",
        "url": URL,
        "issuer": ISSUER,
        "client": "calendar",
        "secret-file": "/nonexistent",
        "state": state,
        "per-user": ["/dav", "/remote.php/dav"],
        "login-flow": true,
    }))
    .unwrap()
}

impl Harness {
    fn new(name: &str) -> Self {
        Harness::with(name, |_| {})
    }

    fn with(name: &str, change: impl FnOnce(&mut Config)) -> Self {
        let state = state_dir(name);
        let mut config = config(&state);
        change(&mut config);
        let fake = Arc::new(Fake::new());
        let gate = Gate::new(config, "oidc-secret".to_string(), Box::new(Shared(fake.clone()))).unwrap();
        Harness { gate, fake, state }
    }

    fn again(self) -> Self {
        let fake = Arc::new(Fake::new());
        let gate = Gate::new(
            config(&self.state),
            "oidc-secret".to_string(),
            Box::new(Shared(fake.clone())),
        )
        .unwrap();
        Harness { gate, fake, ..self }
    }

    fn send(&self, request: &Request) -> Response {
        self.gate.handle_at(request, T0)
    }

    fn claims(user: &str, nonce: &str) -> Value {
        json!({
            "iss": ISSUER, "aud": "calendar", "sub": format!("sub-{user}"), "sid": format!("sid-{user}"),
            "exp": T0 + 300, "iat": T0, "nonce": nonce,
            "preferred_username": user, "email": format!("{user}@example.com"), "name": user.to_uppercase(),
        })
    }

    fn start_login(&self, target: &str) -> HashMap<String, String> {
        let response = self.send(&Request::new("GET", target));
        assert_eq!(response.status, 303);
        let location = response.header("location").unwrap();
        let (authorization, query) = location.split_once('?').unwrap();
        assert_eq!(authorization, self.fake.endpoints.authorization);
        form_urlencoded::parse(query.as_bytes()).into_owned().collect()
    }

    fn finish_login(&self, params: &HashMap<String, String>, claims: Value) -> Response {
        let code = self.fake.authorize(claims, &params["code_challenge"]);
        self.send(&Request::new(
            "GET",
            &format!("/auth/callback?state={}&code={code}", params["state"]),
        ))
    }

    fn login(&self, user: &str) -> String {
        let params = self.start_login("/auth/login?next=/");
        let response = self.finish_login(&params, Harness::claims(user, &params["nonce"]));
        assert_eq!(response.status, 303, "{}", String::from_utf8_lossy(&response.body));
        let cookie = response.header("set-cookie").unwrap();
        cookie.split(';').next().unwrap().to_string()
    }

    fn check(&self, uri: &str, headers: &[(&str, &str)]) -> Response {
        let mut request = Request::new("GET", "/auth/check");
        request.headers.push(("X-Original-URI".to_string(), uri.to_string()));
        for (name, value) in headers {
            request.headers.push(((*name).to_string(), (*value).to_string()));
        }
        self.send(&request)
    }
}

fn with_cookie(mut request: Request, cookie: &str) -> Request {
    request.headers.push(("Cookie".to_string(), cookie.to_string()));
    request
}

fn browser(mut request: Request) -> Request {
    request.headers.push(("Origin".to_string(), URL.to_string()));
    request
        .headers
        .push(("Sec-Fetch-Site".to_string(), "same-origin".to_string()));
    request
}

fn basic(user: &str, password: &str) -> String {
    format!("Basic {}", STANDARD.encode(format!("{user}:{password}")))
}

fn body(response: &Response) -> String {
    String::from_utf8_lossy(&response.body).into_owned()
}

#[test]
fn asks_a_device_for_a_password_and_a_browser_to_log_in() {
    let h = Harness::new("unauthenticated");
    let device = h.check("/dav/", &[]);
    assert_eq!(device.status, 401);
    assert!(device.header("www-authenticate").unwrap().starts_with("Basic "));
    let browser = h.check("/dav/", &[("Sec-Fetch-Site", "same-origin")]);
    assert_eq!(browser.status, 401);
    assert!(browser.header("www-authenticate").is_none());
}

#[test]
fn logs_a_browser_in_with_the_issuer() {
    let h = Harness::new("login");
    let params = h.start_login("/auth/login?next=/month%3Fday%3D1");
    assert_eq!(params["client_id"], "calendar");
    assert_eq!(params["code_challenge_method"], "S256");
    assert_eq!(params["redirect_uri"], format!("{URL}/auth/callback"));
    let response = h.finish_login(&params, Harness::claims("alice", &params["nonce"]));
    assert_eq!(response.status, 303);
    assert_eq!(response.header("location"), Some("/month?day=1"));
    let cookie = response.header("set-cookie").unwrap();
    assert!(cookie.contains("HttpOnly") && cookie.contains("SameSite=Lax") && cookie.contains("Secure"));
    let checked = h.check("/dav/alice/", &[("Cookie", cookie.split(';').next().unwrap())]);
    assert_eq!(checked.status, 200);
    assert_eq!(checked.header("x-user"), Some("alice"));
    assert_eq!(checked.header("x-email"), Some("alice@example.com"));
    assert_eq!(checked.header("x-name"), Some("ALICE"));
}

#[test]
fn returns_from_a_login_to_the_original_request_only_on_the_site() {
    let h = Harness::new("next");
    for (next, expected) in [
        ("//evil.example/", "/"),
        ("/\\evil.example", "/"),
        ("https://evil.example/", "/"),
    ] {
        let params = h.start_login(&format!("/auth/login?{}", crate::http::query(&[("next", next)])));
        let response = h.finish_login(&params, Harness::claims("alice", &params["nonce"]));
        assert_eq!(response.header("location"), Some(expected), "{next}");
    }
    let mut request = Request::new("GET", "/auth/login");
    request
        .headers
        .push(("X-Original-URI".to_string(), "/week".to_string()));
    let response = h.send(&request);
    let query = response
        .header("location")
        .unwrap()
        .split_once('?')
        .unwrap()
        .1
        .to_string();
    let params: HashMap<String, String> = form_urlencoded::parse(query.as_bytes()).into_owned().collect();
    let response = h.finish_login(&params, Harness::claims("alice", &params["nonce"]));
    assert_eq!(response.header("location"), Some("/week"));
}

#[test]
fn refuses_a_login_whose_token_isnt_the_issuers_for_this_client_and_request() {
    let h = Harness::new("refused");
    let cases: Vec<(&str, Change)> = vec![
        ("another nonce", |claims| claims["nonce"] = json!("other")),
        ("another audience", |claims| claims["aud"] = json!("photos")),
        ("another issuer", |claims| claims["iss"] = json!("https://evil.example")),
        ("expired", |claims| claims["exp"] = json!(T0 - 600)),
    ];
    for (case, change) in cases {
        let params = h.start_login("/auth/login");
        let mut claims = Harness::claims("alice", &params["nonce"]);
        change(&mut claims);
        let response = h.finish_login(&params, claims);
        assert!(response.status >= 400, "{case}: {}", response.status);
        assert!(response.header("set-cookie").is_none(), "{case}");
    }
    let params = h.start_login("/auth/login");
    let forged = h.send(&Request::new("GET", "/auth/callback?state=forged&code=x"));
    assert!(forged.header("set-cookie").is_none(), "a forged state");
    let code = h
        .fake
        .authorize(Harness::claims("alice", &params["nonce"]), "another challenge");
    let response = h.send(&Request::new(
        "GET",
        &format!("/auth/callback?state={}&code={code}", params["state"]),
    ));
    assert_eq!(response.status, 502, "a code bound to another PKCE challenge");
    let replayed = h.send(&Request::new(
        "GET",
        &format!("/auth/callback?state={}&code={code}", params["state"]),
    ));
    assert!(replayed.header("set-cookie").is_none(), "a state used once");
    let location = replayed.header("location").unwrap();
    assert!(location.starts_with(&h.fake.endpoints.authorization), "{location}");
    assert!(!location.contains(&params["state"]), "{location}");
}

#[test]
fn goes_on_from_a_callback_asked_again_as_the_back_button_asks_it() {
    let h = Harness::new("again");
    let params = h.start_login("/auth/login?next=/week");
    let first = h.finish_login(&params, Harness::claims("alice", &params["nonce"]));
    let cookie = first
        .header("set-cookie")
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .to_string();
    let again = format!("/auth/callback?state={}&code=spent", params["state"]);
    let back = h.send(&with_cookie(Request::new("GET", &again), &cookie));
    assert_eq!(back.status, 303);
    assert_eq!(back.header("location"), Some("/week"));
    assert!(back.header("set-cookie").is_none());
    let fresh = h.send(&Request::new("GET", &again));
    assert_eq!(fresh.status, 303);
    let (authorization, query) = fresh.header("location").unwrap().split_once('?').unwrap();
    assert_eq!(authorization, h.fake.endpoints.authorization);
    let params: HashMap<String, String> = form_urlencoded::parse(query.as_bytes()).into_owned().collect();
    let response = h.finish_login(&params, Harness::claims("alice", &params["nonce"]));
    assert_eq!(
        response.header("location"),
        Some("/week"),
        "a login anew returns where the spent one was to"
    );
    let h = h.again();
    let unknown = h.send(&with_cookie(Request::new("GET", &again), &cookie));
    assert!(
        unknown
            .header("location")
            .unwrap()
            .starts_with(&h.fake.endpoints.authorization)
    );
}

#[test]
fn lets_a_user_reach_only_their_own_paths_under_the_per_user_prefixes() {
    let h = Harness::new("per-user");
    let cookie = h.login("alice");
    let status = |uri: &str| h.check(uri, &[("Cookie", &cookie)]).status;
    for uri in [
        "/",
        "/dav",
        "/dav/",
        "/dav/alice",
        "/dav/alice/calendars/x.ics",
        "/remote.php/dav",
        "/month",
    ] {
        assert_eq!(status(uri), 200, "{uri}");
    }
    for uri in [
        "/dav/bob/",
        "/dav/alice/../bob/",
        "/dav/%62ob/",
        "/dav/alice/%2e%2e/bob/",
        "/remote.php/dav/bob",
        "/dav//bob/",
        "/dav/alice%",
        "/dav/%ff/",
    ] {
        assert_eq!(status(uri), 403, "{uri}");
    }
}

#[test]
fn hands_a_device_a_password_by_nextclouds_login_flow() {
    let h = Harness::new("flow");
    let mut start = Request::new("POST", "/index.php/login/v2");
    start
        .headers
        .push(("User-Agent".to_string(), "DAVx5/4.5.4-ose".to_string()));
    let started: Value = serde_json::from_slice(&h.send(&start).body).unwrap();
    let login = started["login"]
        .as_str()
        .unwrap()
        .strip_prefix(URL)
        .unwrap()
        .to_string();
    assert_eq!(started["poll"]["endpoint"], format!("{URL}/index.php/login/v2/poll"));
    let mut poll = Request::new("POST", "/index.php/login/v2/poll");
    poll.body = format!("token={}", started["poll"]["token"].as_str().unwrap()).into_bytes();
    assert_eq!(h.send(&poll).status, 404);

    let away = h.send(&Request::new("GET", &login));
    assert_eq!(away.status, 303);
    assert!(
        away.header("location")
            .unwrap()
            .starts_with("/auth/login?next=%2Findex.php")
    );

    let cookie = h.login("alice");
    let page = h.send(&with_cookie(Request::new("GET", &login), &cookie));
    assert!(body(&page).contains("DAVx5/4.5.4-ose") && body(&page).contains("alice"));
    let mut forged = with_cookie(Request::new("POST", &login), &cookie);
    forged
        .headers
        .push(("Sec-Fetch-Site".to_string(), "cross-site".to_string()));
    assert_eq!(h.send(&forged).status, 403);
    assert_eq!(h.send(&poll).status, 404);

    let granted = h.send(&browser(with_cookie(Request::new("POST", &login), &cookie)));
    assert!(body(&granted).contains("done"));
    let answer = h.send(&poll);
    assert_eq!(answer.status, 200);
    let answer: Value = serde_json::from_slice(&answer.body).unwrap();
    assert_eq!(answer["server"], format!("{URL}/"));
    assert_eq!(answer["loginName"], "alice");
    assert_eq!(h.send(&poll).status, 404, "a password handed over once");
    assert_eq!(
        h.send(&browser(with_cookie(Request::new("POST", &login), &cookie)))
            .status,
        404
    );

    let password = answer["appPassword"].as_str().unwrap();
    let synced = h.check("/remote.php/dav/", &[("Authorization", &basic("alice", password))]);
    assert_eq!(synced.status, 200);
    assert_eq!(synced.header("x-user"), Some("alice"));
    assert_eq!(
        h.check("/dav/bob/", &[("Authorization", &basic("alice", password))])
            .status,
        403
    );
    assert_eq!(
        h.check("/dav/", &[("Authorization", &basic("bob", password))]).status,
        401
    );
    assert_eq!(
        h.check("/dav/", &[("Authorization", &basic("alice", "guessed"))])
            .status,
        401
    );
}

#[test]
fn forgets_a_login_flow_no_one_grants() {
    let h = Harness::new("flow-expiry");
    let started: Value = serde_json::from_slice(&h.send(&Request::new("POST", "/index.php/login/v2")).body).unwrap();
    let login = started["login"]
        .as_str()
        .unwrap()
        .strip_prefix(URL)
        .unwrap()
        .to_string();
    let cookie = h.login("alice");
    let later = h
        .gate
        .handle_at(&with_cookie(Request::new("GET", &login), &cookie), T0 + 21 * 60);
    assert_eq!(later.status, 404);
}

#[test]
fn keeps_device_passwords_across_restarts_until_revoked() {
    let h = Harness::new("devices");
    let cookie = h.login("alice");
    let started: Value = serde_json::from_slice(&h.send(&Request::new("POST", "/index.php/login/v2")).body).unwrap();
    let login = started["login"]
        .as_str()
        .unwrap()
        .strip_prefix(URL)
        .unwrap()
        .to_string();
    h.send(&browser(with_cookie(Request::new("POST", &login), &cookie)));
    let mut poll = Request::new("POST", "/index.php/login/v2/poll");
    poll.body = format!("token={}", started["poll"]["token"].as_str().unwrap()).into_bytes();
    let answer: Value = serde_json::from_slice(&h.send(&poll).body).unwrap();
    let password = answer["appPassword"].as_str().unwrap().to_string();
    let kept = std::fs::read_to_string(h.state.join("devices.json")).unwrap();
    assert!(!kept.contains(&password), "the password itself is kept");

    let h = h.again();
    let authorization = basic("alice", &password);
    assert_eq!(h.check("/dav/", &[("Authorization", &authorization)]).status, 200);
    assert_eq!(
        h.check("/dav/", &[("Cookie", &cookie)]).status,
        401,
        "a session ends with a restart"
    );

    let cookie = h.login("alice");
    let page = body(&h.send(&with_cookie(Request::new("GET", "/auth/devices"), &cookie)));
    let id = page
        .split("name=\"id\" value=\"")
        .nth(1)
        .unwrap()
        .split('"')
        .next()
        .unwrap();
    let mut revoke = browser(with_cookie(Request::new("POST", "/auth/devices/revoke"), &cookie));
    revoke.body = format!("id={id}").into_bytes();
    assert_eq!(h.send(&revoke).status, 303);
    assert_eq!(h.check("/dav/", &[("Authorization", &authorization)]).status, 401);
}

#[test]
fn hands_an_apple_device_a_profile_with_its_own_password() {
    let h = Harness::with("apple", |config| {
        config.apple_profile = Some(AppleProfile {
            caldav: Some("/dav/{user}/".to_string()),
            carddav: None,
        });
    });
    let cookie = h.login("alice");
    let response = h.send(&with_cookie(Request::new("GET", "/auth/apple.mobileconfig"), &cookie));
    assert_eq!(
        response.header("content-type"),
        Some("application/x-apple-aspen-config")
    );
    let profile = body(&response);
    assert!(profile.contains("<key>CalDAVPrincipalURL</key><string>https://calendar.example.com/dav/alice/</string>"));
    assert!(profile.contains("<key>CalDAVHostName</key><string>calendar.example.com</string>"));
    assert!(profile.contains("<key>CalDAVUseSSL</key><true/>"));
    assert!(!profile.contains("CardDAV"));
    let password = profile
        .split("<key>CalDAVPassword</key><string>")
        .nth(1)
        .unwrap()
        .split('<')
        .next()
        .unwrap();
    assert_eq!(
        h.check("/dav/alice/", &[("Authorization", &basic("alice", password))])
            .status,
        200
    );
    assert_eq!(
        Harness::new("no-apple")
            .send(&with_cookie(Request::new("GET", "/auth/apple.mobileconfig"), &cookie))
            .status,
        404
    );
}

#[test]
fn ends_a_session_as_the_issuer_logs_it_out() {
    let h = Harness::new("backchannel");
    let alice = h.login("alice");
    let bob = h.login("bob");
    let logout = |token: String| {
        let mut request = Request::new("POST", "/auth/backchannel-logout");
        request.body = crate::http::query(&[("logout_token", &token)]).into_bytes();
        h.send(&request).status
    };
    let event = json!({ "http://schemas.openid.net/event/backchannel-logout": {} });
    let claims =
        json!({ "iss": ISSUER, "aud": "calendar", "iat": T0, "jti": "1", "sid": "sid-alice", "events": event });
    let mut tampered = h.fake.sign(&claims);
    tampered.replace_range(tampered.len() - 4.., "AAAA");
    assert_eq!(logout(tampered), 400);
    assert_eq!(logout(h.fake.sign_as("unknown", &claims)), 400);
    let mut nonce = claims.clone();
    nonce["nonce"] = json!("n");
    assert_eq!(logout(h.fake.sign(&nonce)), 400);
    assert_eq!(h.check("/", &[("Cookie", &alice)]).status, 200);
    assert_eq!(logout(h.fake.sign(&claims)), 200);
    assert_eq!(h.check("/", &[("Cookie", &alice)]).status, 401);
    assert_eq!(h.check("/", &[("Cookie", &bob)]).status, 200);
}

#[test]
fn logs_out_of_the_issuer_too() {
    let h = Harness::new("logout");
    let cookie = h.login("alice");
    let response = h.send(&with_cookie(Request::new("GET", "/auth/logout"), &cookie));
    let location = response.header("location").unwrap();
    assert!(location.starts_with(&h.fake.endpoints.end_session));
    assert!(
        location.contains("id_token_hint=")
            && location.contains("post_logout_redirect_uri=https%3A%2F%2Fcalendar.example.com%2F")
    );
    assert!(response.header("set-cookie").unwrap().contains("Max-Age=0"));
    assert_eq!(h.check("/", &[("Cookie", &cookie)]).status, 401);
}

#[test]
fn lasts_as_long_as_the_issuers_session() {
    let h = Harness::new("session-expiry");
    let at = |cookie: &str, seconds: u64| {
        let request = with_cookie(Request::new("GET", "/auth/check"), cookie);
        h.gate.handle_at(&request, T0 + seconds).status
    };
    let alice = h.login("alice");
    let issued = h.fake.renewals();
    assert_eq!(at(&alice, 299), 200);
    assert_eq!(h.fake.renewals(), issued, "renewed before the access token expired");
    assert_eq!(at(&alice, 301), 200);
    assert_eq!(at(&alice, 302), 200);
    assert_eq!(
        h.fake.renewals(),
        issued + 1,
        "renewed once, with the refresh token the login had"
    );
    assert_eq!(at(&alice, 602), 200, "renewed with the refresh token the renewal had");
    h.fake.end("alice");
    assert_eq!(at(&alice, 903), 401, "the issuer's session ended");
    assert_eq!(at(&alice, 904), 401);

    let bob = h.login("bob");
    h.fake.down.store(true, Ordering::SeqCst);
    assert_eq!(at(&bob, 301), 200, "the issuer didn't answer");
    h.fake.down.store(false, Ordering::SeqCst);
    let issued = h.fake.renewals();
    assert_eq!(at(&bob, 320), 200);
    assert_eq!(h.fake.renewals(), issued, "tried again before its time");
    assert_eq!(at(&bob, 332), 200);
    assert_eq!(h.fake.renewals(), issued + 1);

    let carol = h.login("carol");
    let unused = with_cookie(Request::new("GET", "/auth/devices"), &carol);
    assert_eq!(
        h.gate.handle_at(&unused, T0 + 3601).status,
        303,
        "the issuer's session expired"
    );
}
