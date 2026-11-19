# Gate

The gate is a login with a Keycloak realm in front of an app that has none of its own: nginx asks it of each request,
with `auth_request`, and passes the user it names on to the app. A browser logs in with the realm, and a device, which
can't, with a password of its own that the gate hands it once its user has logged in, so that no one makes, types or
copies one (`crates/gate`). It runs as `gate <config.json>`, a process for each app, which no app has yet.

```json
{
  "listen": "[fd00::6]:8081",
  "url": "https://calendar.example.com",
  "issuer": "https://auth.example.com/realms/example",
  "client": "calendar",
  "secret-file": "/run/credentials/calendar-gate.service/oidc-secret",
  "state": "/var/lib/calendar/gate",
  "per-user": ["/dav", "/remote.php/dav"],
  "login-flow": true,
  "apple-profile": { "caldav": "/dav/{user}/" }
}
```

- `url` is the app's, and the gate's pages are under `prefix`, `/auth` by default, there.
- `client` is a confidential client of the realm's, whose secret is in `secret-file`, which returns to
  `<url><prefix>/callback`, and whose back-channel logout is `<url><prefix>/backchannel-logout`.
- `state` holds `devices.json`, the devices' passwords, and has to be there.
- The gate reads the issuer's endpoints from its discovery as it starts, and fails to start without them.

## Check

`<prefix>/check` is nginx's `auth_request`, with `X-Original-URI` the request's:

- a request with the gate's cookie of a session, or a device's password as Basic authentication, is the user's, and is
  answered 200, with `X-User`, the user's Keycloak username, and `X-Email` and `X-Name` as the realm has them
- one under a prefix of `per-user` is the user's only at or below `<prefix>/<user>`, decoded and with its `..` taken
  out, or at the prefix itself, and is answered 403 otherwise
- any other is answered 401, with a challenge for Basic authentication unless it's a browser's, which has
  `Sec-Fetch-Site`: a browser is to be sent to `<prefix>/login`, which takes the page to return to from `next` or
  `X-Original-URI`, of the site's alone.

The app's server has to overwrite the header the app takes the user from with `X-User`, and drop `Authorization`, so
that a request can't name its user to the app.

## Sessions

- A login is the realm's authorization code flow, with PKCE, a state and a nonce, for `openid profile email`, and its ID
  token's signature, issuer, audience, expiry and nonce are checked against the realm's keys.
- A session lasts as long as the user's in the realm: the gate keeps its refresh token and renews it as its access token
  expires, at a request of the session's, which keeps the realm's session in use too, and ends the session as the realm
  refuses to, or as the refresh token would expire. A renewal the realm doesn't answer is tried again 30 seconds later,
  and the session goes on meanwhile.
- Sessions are in the gate's memory alone: a restart ends each, and the next request of a browser logs in with the realm
  again, which asks nothing of a user still logged in to it.
- The cookie, `cookie`, `gate` by default, is HttpOnly and SameSite=Lax, and Secure with an `https` `url`.
- A callback asked again, as going back to the realm's page has the realm do, or of a login the gate doesn't hold, as
  after a restart, sends a browser with a session to where the login was to return to, or `/`, and logs one without in
  anew; it never makes a session of a spent state.
- Each redirect of the gate's is a 303, which leaves the page it answers out of the browser's history, and each of its
  pages is `no-store`, which a browser fetches anew as it goes back to it.
- `<prefix>/logout` ends the session and the realm's, and returns to the app's start; the realm's back-channel logout
  ends each session of the realm's that it names, by its `sid`.

## Devices

A device's password is 256 random bits, of which `devices.json` keeps the SHA-256, its user, its label and when it was
made; it lasts until it's revoked at `<prefix>/devices`, which lists the user's, and outlives the user's sessions.

- With `login-flow`, the gate speaks Nextcloud's Login Flow v2 at `/index.php/login/v2`, as DAVx5's Nextcloud login and
  Nextcloud's clients do: the device starts a flow, opens its page in the browser, where its user logs in and grants it,
  and polls for its password, which the gate hands over once. The app's server has to pass `/index.php/login/v2` to the
  gate, and DAVx5 takes its DAV at `<url>/remote.php/dav`. A flow lasts 20 minutes.
- With `apple-profile`, `<prefix>/apple.mobileconfig` is a configuration profile of a new password, with a CalDAV
  account at `caldav` and a CardDAV one at `carddav`, `{user}` the user's name, which an iPhone, iPad or Mac installs.
- A POST to the gate's pages from another site's page is refused, by its `Origin` and `Sec-Fetch-Site`.
- The gate holds 1000 logins and flows begun at most, and refuses more: that its pages are asked no more than that is
  the app's server's to see to.
- A device that starts a flow names itself, by its `User-Agent`, on the page its user grants it from: a flow someone
  else started and had the user open would hand them the password.

## Testing

`build-gate` builds the gate, whose tests run each flow against an issuer of their own, which signs with
`crates/gate/src/testdata/issuer.pk8`, a throwaway key: a login, its refusals and its callback asked again, a session
renewed and ended with the realm's, the paths of `per-user`, a device by the login flow and by a profile, a revoked
device, back-channel logout and logout, and that sessions end and devices last across a restart.
