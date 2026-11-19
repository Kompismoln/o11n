use crate::devices::{Device, Devices};
use crate::http::{Request, Response, escape, query};
use crate::oidc::{Failure, Issuer, Keys};
use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use ring::rand::{SecureRandom, SystemRandom};
use serde::Deserialize;
use serde_json::json;
use std::collections::HashMap;
use std::fmt::Write;
use std::path::PathBuf;
use std::sync::Mutex;

#[derive(Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
pub struct Config {
    pub listen: String,
    pub url: String,
    pub issuer: String,
    pub client: String,
    pub secret_file: PathBuf,
    pub state: PathBuf,
    #[serde(default = "Config::default_prefix")]
    pub prefix: String,
    #[serde(default = "Config::default_cookie")]
    pub cookie: String,
    #[serde(default)]
    pub per_user: Vec<String>,
    #[serde(default)]
    pub login_flow: bool,
    #[serde(default)]
    pub apple_profile: Option<AppleProfile>,
}

#[derive(Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
pub struct AppleProfile {
    pub caldav: Option<String>,
    pub carddav: Option<String>,
}

impl Config {
    fn default_prefix() -> String {
        "/auth".to_string()
    }
    fn default_cookie() -> String {
        "gate".to_string()
    }
}

// Fact: Nextcloud's Login Flow v2, which DAVx5 and Nextcloud's own clients speak, at the paths they take.
const FLOW: &str = "/index.php/login/v2";
const FLOW_SECONDS: u64 = 20 * 60;
const PENDING_SECONDS: u64 = 10 * 60;
// Policy: a session whose tokens couldn't be renewed, as the issuer didn't answer, is tried again this many seconds
// later, and goes on meanwhile, so that the issuer's outage logs no one out; and each request that comes as one renews
// them goes on as the session's too.
const RETRY_SECONDS: u64 = 30;

// Policy: a bound on what anyone can make the gate hold before they log in.
const MAX_UNAUTHENTICATED: usize = 1000;

#[derive(Clone)]
struct Identity {
    user: String,
    email: Option<String>,
    name: Option<String>,
}

// Policy: a session lasts as long as the issuer's: its tokens are renewed as they expire, and it ends as the issuer
// refuses to, or as the issuer's own would.
struct Session {
    identity: Identity,
    sub: String,
    sid: Option<String>,
    id_token: String,
    refresh: Option<String>,
    renew: u64,
    expires: u64,
}

impl Session {
    // Fact: the token endpoint's `expires_in` is the access token's lifetime, and Keycloak's `refresh_expires_in` its
    // refresh token's, which lasts as long as the user's session in the realm, or 0 for one that lasts on its own.
    fn renewed(&mut self, tokens: &serde_json::Value, now: u64) {
        let access = tokens["expires_in"].as_u64().unwrap_or(300).max(RETRY_SECONDS);
        let refresh = tokens["refresh_expires_in"].as_u64().filter(|&seconds| seconds > 0);
        self.renew = now + access;
        self.expires = now + refresh.unwrap_or(access).max(access);
        if let Some(token) = tokens["refresh_token"].as_str() {
            self.refresh = Some(token.to_string());
        }
        if let Some(token) = tokens["id_token"].as_str() {
            self.id_token = token.to_string();
        }
    }
}

#[derive(Clone)]
struct Pending {
    verifier: String,
    nonce: String,
    next: String,
    expires: u64,
    spent: bool,
}

struct Flow {
    poll: String,
    agent: String,
    expires: u64,
    granted: Option<(String, String)>,
}

struct State {
    sessions: HashMap<String, Session>,
    pending: HashMap<String, Pending>,
    flows: HashMap<String, Flow>,
    devices: Devices,
}

pub struct Gate {
    config: Config,
    secret: String,
    issuer: Box<dyn Issuer>,
    keys: Keys,
    rng: SystemRandom,
    state: Mutex<State>,
}

pub fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs())
}

impl Gate {
    pub fn new(config: Config, secret: String, issuer: Box<dyn Issuer>) -> Result<Self, String> {
        let devices = Devices::load(config.state.join("devices.json"))?;
        Ok(Gate {
            config,
            secret,
            issuer,
            keys: Keys::new(),
            rng: SystemRandom::new(),
            state: Mutex::new(State {
                sessions: HashMap::new(),
                pending: HashMap::new(),
                flows: HashMap::new(),
                devices,
            }),
        })
    }

    pub fn handle(&self, request: &Request) -> Response {
        self.handle_at(request, now())
    }

    pub fn handle_at(&self, request: &Request, now: u64) -> Response {
        self.prune(now);
        let path = request.path.as_str();
        let method = request.method.as_str();
        let Some(own) = path.strip_prefix(&self.config.prefix) else {
            return match (method, path) {
                ("POST", FLOW) if self.config.login_flow => self.flow_start(request, now),
                ("POST", "/index.php/login/v2/poll") if self.config.login_flow => self.flow_poll(request, now),
                (_, _) if self.config.login_flow && path.starts_with("/index.php/login/v2/flow/") => {
                    self.flow_grant(request, now)
                }
                _ => Response::text(404, "Not found."),
            };
        };
        match (method, own) {
            (_, "/check") => self.check(request, now),
            ("GET" | "HEAD", "/login") => self.login(request, now),
            ("GET", "/callback") => self.callback(request, now),
            ("GET", "/logout") => self.logout(request),
            ("POST", "/backchannel-logout") => self.backchannel_logout(request, now),
            ("GET", "/devices") => self.devices(request, now),
            ("POST", "/devices/revoke") => self.revoke(request, now),
            ("GET", "/apple.mobileconfig") if self.config.apple_profile.is_some() => self.apple_profile(request, now),
            _ => Response::text(404, "Not found."),
        }
    }

    fn prune(&self, now: u64) {
        let mut state = self.state.lock().unwrap();
        state.sessions.retain(|_, session| session.expires > now);
        state.pending.retain(|_, pending| pending.expires > now);
        state.flows.retain(|_, flow| flow.expires > now);
    }

    fn random(&self) -> String {
        let mut bytes = [0u8; 32];
        self.rng.fill(&mut bytes).expect("the system's random numbers");
        URL_SAFE_NO_PAD.encode(bytes)
    }

    fn secure(&self) -> bool {
        self.config.url.starts_with("https://")
    }

    fn origin(&self) -> &str {
        let after = self.config.url.find("://").map_or(0, |at| at + 3);
        let end = self.config.url[after..]
            .find('/')
            .map_or(self.config.url.len(), |at| after + at);
        &self.config.url[..end]
    }

    fn session(&self, request: &Request, now: u64) -> Option<Identity> {
        let id = request.cookie(&self.config.cookie)?;
        let refresh = {
            let mut state = self.state.lock().unwrap();
            let session = state.sessions.get_mut(id)?;
            if now < session.renew {
                return Some(session.identity.clone());
            }
            session.renew = now + RETRY_SECONDS;
            let Some(refresh) = session.refresh.clone() else {
                state.sessions.remove(id);
                return None;
            };
            refresh
        };
        let renewed = self.issuer.exchange(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", &refresh),
            ("client_id", &self.config.client),
            ("client_secret", &self.secret),
        ]);
        let mut state = self.state.lock().unwrap();
        match renewed {
            Ok(tokens) => {
                let session = state.sessions.get_mut(id)?;
                session.renewed(&tokens, now);
                Some(session.identity.clone())
            }
            Err(Failure::Refused(error)) => {
                eprintln!("gate: the issuer ended a session: {error}");
                state.sessions.remove(id);
                None
            }
            Err(Failure::Unreachable(error)) => {
                eprintln!("gate: renewing a session: {error}");
                state.sessions.get(id).map(|session| session.identity.clone())
            }
        }
    }

    fn device(&self, request: &Request) -> Option<Identity> {
        let credentials = request.header("authorization")?.strip_prefix("Basic ")?;
        let decoded = String::from_utf8(STANDARD.decode(credentials.trim()).ok()?).ok()?;
        let (user, password) = decoded.split_once(':')?;
        let state = self.state.lock().unwrap();
        state.devices.find(user, password).map(|device| Identity {
            user: device.user.clone(),
            email: device.email.clone(),
            name: device.name.clone(),
        })
    }

    // Policy: a POST from another site's page changes nothing, whatever cookie the browser sends with it.
    fn same_origin(&self, request: &Request) -> bool {
        request.header("origin").is_none_or(|origin| origin == self.origin())
            && request
                .header("sec-fetch-site")
                .is_none_or(|site| site == "same-origin")
    }

    fn owns(&self, user: &str, uri: &str) -> bool {
        let path = uri.split(['?', '#']).next().unwrap_or_default();
        let Ok(decoded) = percent_decode(path) else {
            return false;
        };
        let mut segments: Vec<&str> = Vec::new();
        for segment in decoded.split('/') {
            match segment {
                "" | "." => {}
                ".." => {
                    segments.pop();
                }
                _ => segments.push(segment),
            }
        }
        let normal = format!("/{}", segments.join("/"));
        self.config.per_user.iter().all(|prefix| {
            let prefix = prefix.trim_end_matches('/');
            match normal.strip_prefix(prefix) {
                Some("") => true,
                Some(rest) if rest.starts_with('/') => rest[1..].split('/').next() == Some(user),
                _ => true,
            }
        })
    }

    fn check(&self, request: &Request, now: u64) -> Response {
        let Some(identity) = self.session(request, now).or_else(|| self.device(request)) else {
            let response = Response::new(401);
            // Policy: a browser isn't asked for a password, which no one has: it's sent to log in instead.
            return if request.header("sec-fetch-site").is_some() {
                response
            } else {
                response.with("WWW-Authenticate", "Basic realm=\"devices\", charset=\"UTF-8\"")
            };
        };
        let uri = request.header("x-original-uri").unwrap_or("/");
        if !self.owns(&identity.user, uri) {
            return Response::new(403);
        }
        let mut response = Response::new(200).with("X-User", &identity.user);
        if let Some(email) = &identity.email {
            response = response.with("X-Email", email);
        }
        if let Some(name) = &identity.name {
            response = response.with("X-Name", name);
        }
        response
    }

    fn login_location(&self, next: &str) -> String {
        format!("{}/login?{}", self.config.prefix, query(&[("next", next)]))
    }

    fn login(&self, request: &Request, now: u64) -> Response {
        let next = request
            .param("next")
            .or_else(|| request.header("x-original-uri").map(str::to_string))
            .filter(|next| next.starts_with('/') && !next.starts_with("//") && !next.starts_with("/\\"))
            .unwrap_or_else(|| "/".to_string());
        self.begin(next, now)
    }

    fn begin(&self, next: String, now: u64) -> Response {
        let (state, verifier, nonce) = (self.random(), self.random(), self.random());
        let challenge = URL_SAFE_NO_PAD.encode(ring::digest::digest(&ring::digest::SHA256, verifier.as_bytes()));
        {
            let mut held = self.state.lock().unwrap();
            if held.pending.len() >= MAX_UNAUTHENTICATED {
                return Response::text(503, "Too many logins at once. Try again in a few minutes.");
            }
            held.pending.insert(
                state.clone(),
                Pending {
                    verifier,
                    nonce: nonce.clone(),
                    next,
                    expires: now + PENDING_SECONDS,
                    spent: false,
                },
            );
        }
        let redirect = format!("{}{}/callback", self.config.url, self.config.prefix);
        Response::redirect(&format!(
            "{}?{}",
            self.issuer.endpoints().authorization,
            query(&[
                ("response_type", "code"),
                ("client_id", &self.config.client),
                ("redirect_uri", &redirect),
                ("scope", "openid profile email"),
                ("state", &state),
                ("nonce", &nonce),
                ("code_challenge", &challenge),
                ("code_challenge_method", "S256"),
            ])
        ))
    }

    // Policy: a login's state is spent as its callback is first asked, and kept until it would have expired, so that
    // the callback asked again, as going back to the issuer's page does, or of a state the gate doesn't hold, as after
    // a restart, is no error: a browser with a session goes on to where the login was to return to, and one without
    // logs in anew, which the issuer answers without asking a user still logged in to it.
    fn callback(&self, request: &Request, now: u64) -> Response {
        let state = request.param("state").unwrap_or_default();
        let taken = match self.state.lock().unwrap().pending.get_mut(&state) {
            Some(pending) if !pending.spent => {
                pending.spent = true;
                Ok(pending.clone())
            }
            Some(pending) => Err(pending.next.clone()),
            None => Err("/".to_string()),
        };
        let pending = match taken {
            Ok(pending) => pending,
            Err(next) if self.session(request, now).is_some() => return Response::redirect(&next),
            Err(next) => return self.begin(next, now),
        };
        if let Some(error) = request.param("error") {
            let description = request.param("error_description").unwrap_or_default();
            return Response::html(
                403,
                "Log in",
                &format!(
                    "<p>The login was refused: {} {}. <a href=\"{}\">Try again</a>.</p>",
                    escape(&error),
                    escape(&description),
                    escape(&self.login_location(&pending.next))
                ),
            );
        }
        let Some(code) = request.param("code") else {
            return Response::text(400, "The issuer sent no code.");
        };
        let redirect = format!("{}{}/callback", self.config.url, self.config.prefix);
        let tokens = match self.issuer.exchange(&[
            ("grant_type", "authorization_code"),
            ("code", &code),
            ("redirect_uri", &redirect),
            ("client_id", &self.config.client),
            ("client_secret", &self.secret),
            ("code_verifier", &pending.verifier),
        ]) {
            Ok(tokens) => tokens,
            Err(error) => {
                eprintln!("gate: exchanging a code: {error}");
                return Response::text(502, "The issuer didn't take the login.");
            }
        };
        let Some(id_token) = tokens["id_token"].as_str() else {
            eprintln!("gate: the issuer's tokens have no id_token");
            return Response::text(502, "The issuer didn't take the login.");
        };
        let claims = match self.keys.verify(&*self.issuer, &self.config.client, id_token, now) {
            Ok(claims) if claims["nonce"] == pending.nonce.as_str() => claims,
            Ok(_) => {
                eprintln!("gate: an ID token of another login's nonce");
                return Response::text(400, "The login didn't match.");
            }
            Err(error) => {
                eprintln!("gate: an ID token: {error}");
                return Response::text(502, "The issuer's answer didn't verify.");
            }
        };
        let Some(sub) = claims["sub"].as_str() else {
            return Response::text(502, "The issuer's answer names no one.");
        };
        let identity = Identity {
            user: claims["preferred_username"].as_str().unwrap_or(sub).to_string(),
            email: claims["email"].as_str().map(str::to_string),
            name: claims["name"].as_str().map(str::to_string),
        };
        let id = self.random();
        let mut session = Session {
            identity,
            sub: sub.to_string(),
            sid: claims["sid"].as_str().map(str::to_string),
            id_token: id_token.to_string(),
            refresh: None,
            renew: now,
            expires: now,
        };
        session.renewed(&tokens, now);
        let seconds = session.expires - now;
        self.state.lock().unwrap().sessions.insert(id.clone(), session);
        let mut cookie = format!(
            "{}={id}; Path=/; HttpOnly; SameSite=Lax; Max-Age={seconds}",
            self.config.cookie
        );
        if self.secure() {
            cookie.push_str("; Secure");
        }
        Response::redirect(&pending.next).with("Set-Cookie", &cookie)
    }

    fn logout(&self, request: &Request) -> Response {
        let session = request
            .cookie(&self.config.cookie)
            .and_then(|id| self.state.lock().unwrap().sessions.remove(id));
        let after = format!("{}/", self.config.url);
        let mut params = vec![
            ("client_id", self.config.client.as_str()),
            ("post_logout_redirect_uri", &after),
        ];
        if let Some(session) = &session {
            params.push(("id_token_hint", &session.id_token));
        }
        Response::redirect(&format!("{}?{}", self.issuer.endpoints().end_session, query(&params))).with(
            "Set-Cookie",
            &format!("{}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0", self.config.cookie),
        )
    }

    // Fact: OpenID Connect Back-Channel Logout 1.0, which Keycloak sends as it ends a session of the realm.
    fn backchannel_logout(&self, request: &Request, now: u64) -> Response {
        let form = request.form();
        let Some(token) = form.get("logout_token") else {
            return Response::text(400, "No logout_token.");
        };
        let claims = match self.keys.verify(&*self.issuer, &self.config.client, token, now) {
            Ok(claims) => claims,
            Err(error) => {
                eprintln!("gate: a logout token: {error}");
                return Response::text(400, "The logout token didn't verify.");
            }
        };
        if claims["events"]
            .get("http://schemas.openid.net/event/backchannel-logout")
            .is_none()
            || claims.get("nonce").is_some()
        {
            return Response::text(400, "Not a logout token.");
        }
        let (sid, sub) = (claims["sid"].as_str(), claims["sub"].as_str());
        if sid.is_none() && sub.is_none() {
            return Response::text(400, "The logout token names no session.");
        }
        self.state.lock().unwrap().sessions.retain(|_, session| match sid {
            Some(sid) => session.sid.as_deref() != Some(sid),
            None => Some(session.sub.as_str()) != sub,
        });
        Response::new(200)
    }

    fn devices(&self, request: &Request, now: u64) -> Response {
        let Some(identity) = self.session(request, now) else {
            return Response::redirect(&self.login_location(&request.path));
        };
        let state = self.state.lock().unwrap();
        let rows = state.devices.of(&identity.user).fold(String::new(), |mut rows, device| {
            let _ = writeln!(
                rows,
                    "<li>{} <small>{}</small> <form method=\"post\" action=\"{}/devices/revoke\" style=\"display:inline\">\
                     <input type=\"hidden\" name=\"id\" value=\"{}\"><button>Revoke</button></form></li>",
                    escape(&device.label),
                    date(device.created),
                    escape(&self.config.prefix),
                escape(&device.id),
            );
            rows
        });
        let apple = if self.config.apple_profile.is_some() {
            format!(
                "<p><a href=\"{}/apple.mobileconfig\">Set up an iPhone, iPad or Mac</a></p>\n",
                escape(&self.config.prefix)
            )
        } else {
            String::new()
        };
        let list = if rows.is_empty() {
            "<p>No device has a password.</p>".to_string()
        } else {
            format!("<ul>\n{rows}</ul>")
        };
        Response::html(
            200,
            "Devices",
            &format!(
                "<h1>Devices of {}</h1>\n{list}\n{apple}<p><a href=\"{}/logout\">Log out</a></p>",
                escape(&identity.user),
                escape(&self.config.prefix)
            ),
        )
    }

    fn revoke(&self, request: &Request, now: u64) -> Response {
        let Some(identity) = self.session(request, now) else {
            return Response::text(403, "Not logged in.");
        };
        if !self.same_origin(request) {
            return Response::text(403, "Not from this site.");
        }
        let form = request.form();
        let id = form.get("id").map_or("", String::as_str);
        if let Err(error) = self.state.lock().unwrap().devices.revoke(&identity.user, id) {
            eprintln!("gate: revoking a device: {error}");
            return Response::text(500, "The device couldn't be revoked.");
        }
        Response::redirect(&format!("{}/devices", self.config.prefix))
    }

    fn mint(&self, identity: &Identity, label: &str, now: u64) -> Result<String, Response> {
        let password = self.random();
        let device = Device::new(
            self.random(),
            identity.user.clone(),
            identity.email.clone(),
            identity.name.clone(),
            label.to_string(),
            now,
            &password,
        );
        self.state.lock().unwrap().devices.add(device).map_err(|error| {
            eprintln!("gate: keeping a device's password: {error}");
            Response::text(500, "The device's password couldn't be kept.")
        })?;
        Ok(password)
    }

    fn apple_profile(&self, request: &Request, now: u64) -> Response {
        let Some(identity) = self.session(request, now) else {
            return Response::redirect(&self.login_location(&request.path));
        };
        let Some(profile) = &self.config.apple_profile else {
            return Response::text(404, "Not found.");
        };
        let password = match self.mint(&identity, "Apple profile", now) {
            Ok(password) => password,
            Err(response) => return response,
        };
        let host = self.origin().split("://").nth(1).unwrap_or_default();
        let (hostname, port) = match host.rsplit_once(':') {
            Some((hostname, port)) => (hostname, port.parse().unwrap_or(443)),
            None => (host, if self.secure() { 443 } else { 80 }),
        };
        let user = &identity.user;
        let mut payloads = String::new();
        for (kind, path) in [("CalDAV", &profile.caldav), ("CardDAV", &profile.carddav)] {
            let Some(path) = path else { continue };
            let principal = format!("{}{}", self.config.url, path.replace("{user}", user));
            let _ = write!(
                payloads,
                "<dict>\
                 <key>PayloadType</key><string>com.apple.{lower}.account</string>\
                 <key>PayloadVersion</key><integer>1</integer>\
                 <key>PayloadIdentifier</key><string>{id}.{lower}</string>\
                 <key>PayloadUUID</key><string>{uuid}</string>\
                 <key>PayloadDisplayName</key><string>{kind}</string>\
                 <key>{kind}AccountDescription</key><string>{host}</string>\
                 <key>{kind}HostName</key><string>{hostname}</string>\
                 <key>{kind}Port</key><integer>{port}</integer>\
                 <key>{kind}UseSSL</key><{ssl}/>\
                 <key>{kind}PrincipalURL</key><string>{principal}</string>\
                 <key>{kind}Username</key><string>{user}</string>\
                 <key>{kind}Password</key><string>{password}</string>\
                 </dict>",
                lower = kind.to_lowercase(),
                id = escape(&format!("{hostname}.{user}")),
                uuid = self.uuid(),
                host = escape(host),
                hostname = escape(hostname),
                ssl = self.secure(),
                principal = escape(&principal),
                user = escape(user),
            );
        }
        let plist = format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
             <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
             <plist version=\"1.0\"><dict>\
             <key>PayloadType</key><string>Configuration</string>\
             <key>PayloadVersion</key><integer>1</integer>\
             <key>PayloadIdentifier</key><string>{id}</string>\
             <key>PayloadUUID</key><string>{uuid}</string>\
             <key>PayloadDisplayName</key><string>{host}</string>\
             <key>PayloadContent</key><array>{payloads}</array>\
             </dict></plist>\n",
            id = escape(&format!("{hostname}.{user}")),
            uuid = self.uuid(),
            host = escape(host),
        );
        Response::new(200)
            .with("Content-Type", "application/x-apple-aspen-config")
            .with(
                "Content-Disposition",
                &format!("attachment; filename=\"{hostname}.mobileconfig\""),
            )
            .body(plist.as_bytes())
    }

    fn uuid(&self) -> String {
        let mut bytes = [0u8; 16];
        self.rng.fill(&mut bytes).expect("the system's random numbers");
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        let hex = crate::http::hex(&bytes).to_uppercase();
        format!(
            "{}-{}-{}-{}-{}",
            &hex[..8],
            &hex[8..12],
            &hex[12..16],
            &hex[16..20],
            &hex[20..]
        )
    }

    fn flow_start(&self, request: &Request, now: u64) -> Response {
        let (login, poll) = (self.random(), self.random());
        let agent: String = request
            .header("user-agent")
            .unwrap_or("A device")
            .chars()
            .take(200)
            .collect();
        {
            let mut state = self.state.lock().unwrap();
            if state.flows.len() >= MAX_UNAUTHENTICATED {
                return Response::text(503, "Too many logins at once. Try again in a few minutes.");
            }
            state.flows.insert(
                login.clone(),
                Flow {
                    poll: poll.clone(),
                    agent,
                    expires: now + FLOW_SECONDS,
                    granted: None,
                },
            );
        }
        Response::json(
            200,
            &json!({
                "poll": { "token": poll, "endpoint": format!("{}{FLOW}/poll", self.config.url) },
                "login": format!("{}{FLOW}/flow/{login}", self.config.url),
            }),
        )
    }

    fn flow_grant(&self, request: &Request, now: u64) -> Response {
        let login = request.path.rsplit('/').next().unwrap_or_default();
        let Some(identity) = self.session(request, now) else {
            return if request.method == "GET" {
                Response::redirect(&self.login_location(&request.path))
            } else {
                Response::text(403, "Not logged in.")
            };
        };
        let agent = {
            let state = self.state.lock().unwrap();
            match state.flows.get(login) {
                Some(flow) if flow.granted.is_none() => flow.agent.clone(),
                _ => {
                    return Response::html(
                        404,
                        "Connect a device",
                        "<p>This login has expired. Start again on the device.</p>",
                    );
                }
            }
        };
        match request.method.as_str() {
            "GET" => Response::html(
                200,
                "Connect a device",
                &format!(
                    "<p>Let <b>{}</b> reach the account of <b>{}</b>?</p>\n\
                     <p>Grant this only to a device you just set up yourself.</p>\n\
                     <form method=\"post\"><button id=\"grant\">Grant access</button></form>",
                    escape(&agent),
                    escape(&identity.user)
                ),
            ),
            "POST" if self.same_origin(request) => {
                let password = match self.mint(&identity, &agent, now) {
                    Ok(password) => password,
                    Err(response) => return response,
                };
                if let Some(flow) = self.state.lock().unwrap().flows.get_mut(login) {
                    flow.granted = Some((identity.user.clone(), password));
                }
                Response::html(
                    200,
                    "Connect a device",
                    "<p id=\"done\">Done. Return to the device.</p>",
                )
            }
            "POST" => Response::text(403, "Not from this site."),
            _ => Response::text(405, "Not allowed."),
        }
    }

    fn flow_poll(&self, request: &Request, now: u64) -> Response {
        let form = request.form();
        let token = form.get("token").map_or("", String::as_str);
        let mut state = self.state.lock().unwrap();
        let login = state
            .flows
            .iter()
            .find(|(_, flow)| flow.poll == token && flow.granted.is_some() && flow.expires > now)
            .map(|(login, _)| login.clone());
        let Some((user, password)) = login.and_then(|login| state.flows.remove(&login)?.granted) else {
            return Response::json(404, &json!([]));
        };
        Response::json(
            200,
            &json!({ "server": format!("{}/", self.config.url), "loginName": user, "appPassword": password }),
        )
    }
}

fn percent_decode(path: &str) -> Result<String, ()> {
    let bytes = path.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while at < bytes.len() {
        if bytes[at] == b'%' {
            let hex = path.get(at + 1..at + 3).ok_or(())?;
            out.push(u8::from_str_radix(hex, 16).map_err(|_| ())?);
            at += 3;
        } else {
            out.push(bytes[at]);
            at += 1;
        }
    }
    let decoded = String::from_utf8(out).map_err(|_| ())?;
    if decoded.contains(['\0', '\\']) {
        Err(())
    } else {
        Ok(decoded)
    }
}

// Fact: the civil date of a day since 1970, after Howard Hinnant's days_from_civil, inverted.
fn date(seconds: u64) -> String {
    let days = i64::try_from(seconds / 86400).unwrap_or_default() + 719_468;
    let era = days.div_euclid(146_097);
    let day_of_era = days.rem_euclid(146_097);
    let year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}")
}
