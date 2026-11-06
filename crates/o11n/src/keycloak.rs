use std::path::Path;
use std::process::Command;

use serde_json::Value;

use crate::Error;
use crate::export::Entity;
use crate::status::{Outcome, curl, needs};
use crate::store::{Org, Secret};
use crate::util::{TempDir, run};

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
}
