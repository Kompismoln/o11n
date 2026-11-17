use std::path::Path;
use std::process::Command;

use clap::Args;
use serde_json::{Value, json};

use crate::Error;
use crate::export::Entity;
use crate::status::{Outcome, curl, needs};
use crate::store::{Org, Secret};
use crate::util::{TempDir, log, run};

// Dependency: nixos/apps/keycloak.nix makes Keycloak bootstrap this client, an admin of every realm, and gives its
// account the app's own address, where a realm's test mail goes.
const CLIENT: &str = "o11n";

fn fail(error: &Error) -> Outcome {
    Outcome::Fail(error.to_string())
}

// Policy: curl writes the code after the body, on a line of its own, so that what Keycloak says of a refusal is kept.
fn answer(curl: &mut Command, input: Option<&str>) -> Result<(String, String), Outcome> {
    let said = run(curl.args(["-w", "\n%{http_code}"]), input).map_err(|error| fail(&error))?;
    let (body, code) = said.rsplit_once('\n').unwrap_or(("", &said));
    Ok((body.to_owned(), code.trim().to_owned()))
}

fn refused(url: &str, code: &str, body: &str) -> Outcome {
    let said: Option<Value> = serde_json::from_str(body).ok();
    let why = said
        .as_ref()
        .and_then(|said| {
            ["errorMessage", "error_description", "error"]
                .iter()
                .find_map(|key| said.get(key).and_then(Value::as_str))
        })
        .unwrap_or(body);
    Outcome::Fail(format!("{url} answers {code}: {why}"))
}

fn error(outcome: Outcome) -> Error {
    match outcome {
        Outcome::Fail(why) | Outcome::Skip(why) => Error::new(why),
        Outcome::Ok => Error::new("Keycloak answered as it should, and yet failed"),
    }
}

fn the<'a>(what: &str, flag: &str, given: Option<&'a str>, all: &[&'a str]) -> Result<&'a str, Error> {
    match (given, all) {
        (Some(given), _) if all.contains(&given) => Ok(given),
        (Some(given), _) => Err(Error::new(format!(
            "{given} is no {what} of the org's, of {}",
            all.join(", ")
        ))),
        (None, [one]) => Ok(one),
        (None, []) => Err(Error::new(format!("the org has no {what}"))),
        (None, _) => Err(Error::new(format!(
            "the org has {what}s {}: name one with {flag}",
            all.join(", ")
        ))),
    }
}

#[derive(Args)]
pub struct Invite {
    /// The address the invite goes to, which is the user's.
    address: String,
    /// The user's name, by default the address's local part.
    #[arg(long)]
    username: Option<String>,
    /// The keycloak app, by its name, of the org's.
    #[arg(long)]
    keycloak: Option<String>,
    /// The realm the user is made in, of the keycloak's.
    #[arg(long)]
    realm: Option<String>,
    /// How long the invite's link lasts.
    #[arg(long, default_value_t = 7)]
    days: u32,
}

fn authorized<'a>(curl: &'a mut Command, header: &Path) -> &'a mut Command {
    curl.arg("-H").arg(format!("@{}", header.display()))
}

impl Org {
    fn keycloak_token(url: &str, secret: &str) -> Result<String, Outcome> {
        let token = format!("{url}/realms/master/protocol/openid-connect/token");
        let (body, code) = answer(
            curl()
                .args(["-d", "grant_type=client_credentials", "-d"])
                .arg(format!("client_id={CLIENT}"))
                .args(["--data-urlencode", "client_secret@-"])
                .arg(&token),
            Some(secret.trim_end()),
        )?;
        if code != "200" {
            return Err(refused(&token, &code, &body));
        }
        serde_json::from_str::<Value>(&body)
            .ok()
            .and_then(|said| said.get("access_token")?.as_str().map(str::to_owned))
            .ok_or_else(|| Outcome::Fail(format!("{token} answers no access_token")))
    }

    pub fn keycloak_mail(&self, id: &str, entity: &Entity, realm: &str) -> Result<Outcome, Outcome> {
        let url = entity
            .url
            .as_deref()
            .ok_or_else(|| Outcome::Fail(format!("{id} has no url")))?;
        let secret = needs(self.required(Secret {
            id,
            key: "admin-client-secret",
            slot: 0,
        }))?;
        let token = Self::keycloak_token(url, &secret)?;
        let temp = TempDir::new().map_err(|error| fail(&error))?;
        let header = temp
            .file("authorization", &format!("Authorization: Bearer {token}\n"))
            .map_err(|error| fail(&error))?;

        let settings = format!("{url}/admin/realms/{realm}");
        let (body, code) = answer(authorized(&mut curl(), &header).arg(&settings), None)?;
        if code != "200" {
            return Err(refused(&settings, &code, &body));
        }
        let smtp = serde_json::from_str::<Value>(&body)
            .ok()
            .and_then(|said| said.get("smtpServer").cloned())
            .filter(|smtp| smtp.get("host").is_some())
            .ok_or_else(|| {
                Outcome::Fail(format!(
                    "realm {realm} has no mail server: systemctl status keycloak-realms on the app's host"
                ))
            })?;

        // Fact: Keycloak takes the password it shows masked as the one it holds.
        let test = format!("{settings}/testSMTPConnection");
        let (body, code) = answer(
            authorized(&mut curl(), &header)
                .args([
                    "-X",
                    "POST",
                    "-H",
                    "Content-Type: application/json",
                    "--data-binary",
                    "@-",
                ])
                .arg(&test),
            Some(&smtp.to_string()),
        )?;
        if code != "204" {
            return Err(refused(&test, &code, &body));
        }
        Ok(Outcome::Ok)
    }

    fn invited<'a>(&'a self, invite: &'a Invite) -> Result<(String, &'a Entity, &'a str, String), Error> {
        let keycloaks: Vec<&str> = self
            .export
            .entities
            .values()
            .filter(|entity| entity.keycloak.is_some())
            .map(|entity| entity.name.as_str())
            .collect();
        let name = the("keycloak", "--keycloak", invite.keycloak.as_deref(), &keycloaks)?;
        let id = format!("app-{name}");
        let entity = self.entity(&id)?;
        let realms: Vec<&str> = entity
            .keycloak
            .iter()
            .flat_map(|keycloak| keycloak.realms.iter().map(String::as_str))
            .collect();
        let realm = the("realm", "--realm", invite.realm.as_deref(), &realms)?;
        let username = invite
            .username
            .clone()
            .unwrap_or_else(|| invite.address.split('@').next().unwrap_or_default().to_lowercase());
        if username.is_empty() || !invite.address.contains('@') {
            return Err(Error::new(format!("{} is no address", invite.address)));
        }
        Ok((id, entity, realm, username))
    }

    // Policy: an invite is a user made in the realm, whose mail has them set their password; the user is removed when
    // the mail isn't sent, so that the invite can be made again.
    pub fn invite(&self, invite: &Invite) -> Result<(), Error> {
        let (id, entity, realm, username) = self.invited(invite)?;
        let url = entity
            .url
            .as_deref()
            .ok_or_else(|| Error::new(format!("{id} has no url")))?;
        let secret = self.required(Secret {
            id: &id,
            key: "admin-client-secret",
            slot: 0,
        })?;
        let token = Self::keycloak_token(url, &secret).map_err(error)?;
        let temp = TempDir::new()?;
        let header = temp.file("authorization", &format!("Authorization: Bearer {token}\n"))?;
        let users = format!("{url}/admin/realms/{realm}/users");
        let json = ["-H", "Content-Type: application/json", "--data-binary", "@-"];

        let found = |query: &str, value: &str| -> Result<Vec<Value>, Error> {
            let (body, code) = answer(
                authorized(&mut curl(), &header)
                    .args(["-G", "-d", "exact=true", "--data-urlencode"])
                    .arg(format!("{query}={value}"))
                    .arg(&users),
                None,
            )
            .map_err(error)?;
            if code != "200" {
                return Err(error(refused(&users, &code, &body)));
            }
            Ok(serde_json::from_str(&body).unwrap_or_default())
        };
        if let Some(user) = found("email", &invite.address)?.first() {
            return Err(Error::new(format!(
                "{} has an account in {realm} already: {}",
                invite.address,
                user.get("username").and_then(Value::as_str).unwrap_or_default()
            )));
        }

        let user = json!({
            "username": username,
            "email": invite.address,
            "emailVerified": true,
            "enabled": true,
        });
        let (body, code) = answer(
            authorized(&mut curl(), &header)
                .args(["-X", "POST"])
                .args(json)
                .arg(&users),
            Some(&user.to_string()),
        )
        .map_err(error)?;
        if code != "201" {
            return Err(error(refused(&users, &code, &body)));
        }
        let made = found("username", &username)?
            .first()
            .and_then(|user| user.get("id")?.as_str().map(str::to_owned))
            .ok_or_else(|| Error::new(format!("{users} made {username}, and has no such user")))?;

        let actions = format!("{users}/{made}/execute-actions-email");
        let mut send = curl();
        authorized(&mut send, &header)
            .args(["-X", "PUT"])
            .args(json)
            .arg("--url-query")
            .arg(format!("lifespan={}", u64::from(invite.days) * 24 * 60 * 60));
        let portals = entity.keycloak.iter().flat_map(|keycloak| &keycloak.portals);
        if let Some(portal) = portals.into_iter().find(|portal| portal.realm == realm) {
            send.arg("--url-query")
                .arg(format!("client_id={}", portal.client_id))
                .arg("--url-query")
                .arg(format!("redirect_uri={}/", portal.url));
        }
        let (body, code) = answer(send.arg(&actions), Some(r#"["UPDATE_PASSWORD"]"#)).map_err(error)?;
        if code != "204" {
            let removed = format!("{users}/{made}");
            let _ = answer(
                authorized(&mut curl(), &header).args(["-X", "DELETE"]).arg(&removed),
                None,
            );
            return Err(error(refused(&actions, &code, &body)));
        }
        log(format!(
            "invited {} to {realm} as {username}: the link in their mail lasts {} days",
            invite.address, invite.days
        ));
        Ok(())
    }
}
