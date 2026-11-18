<<<<<<< signed
=======
# Status

A status app is the org's status page: Gatus, which checks what the org runs from the app's host, keeps each check's
history, and shows it at the app's endpoint, behind nginx (`nixos/apps/status.nix`). The checks follow from the org: no
check is written by hand.

```toml
[app.status]
id = 7
endpoint = "status.example.com"
run-on-hosts = ["web"]
kind = "status"
portal = "www"
mail = "Mail"
groups.Services = ["www", "auth", "drive"]
announcements = [
  { timestamp = "2026-11-18T09:00:00+01:00", type = "information", message = "The status page is up." },
]
```

## Checks

Each runs every `interval`, two minutes by default (`org/apps/status.nix`):

- each app of `groups`, by its `endpoint`, in the group it's listed under: its `url` answers below 500, and with `ssl`,
  with a certificate that has more than a week left, three weeks after ACME would have renewed it. A redirect is the
  app's answer: the check doesn't follow it, so an app whose login is the keycloak's is up though the keycloak isn't.
- with `mail`, in the group it names, the mail server, `mail.<endpoint>` of `[mailserver]`: submission on 587 takes
  STARTTLS, and imaps on 993 TLS, each with a certificate that has more than a week left, and smtp on 25 takes a
  connection.

The page has the checks by group, the groups by their names, and `announcements`, as Gatus has them: an `outage`, a
`warning`, `information`, `operational` or `none`, each with its `timestamp` and `message`.

## Place

- The page checks from its own host, so a check of an app on that host says it answers there, and the page goes down
  with it: it belongs on a host apart from what it watches, once there is one.
- Gatus listens on the app's own address alone, port 8080, which nginx passes the endpoint on to, and keeps its history
  in `/var/lib/gatus`, which is no state of the org's: nothing archives it. A host runs one status app, as it runs one
  Gatus.
- With a `portal`, the page links back to it, with its logo, and the portal's footer links to the page
  (`docs/parts/portal.md`).

## Testing

`vmTests.keycloak` runs `tests/inventories/mail`'s status app on `web`, where every check passes: the portal, the
keycloak and the drive, and the mail server on `mx`, its submission, imaps and smtp; and the page announces what the
inventory declares.

## Work in progress

- Alerts: Gatus mails no one when a check fails.
>>>>>>> @stamp
