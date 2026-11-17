# Portal

A portal is the org's website: a static site that Zola builds from the org's markdown, with the apps it names listed at
their `url`s, and a login with the org's Keycloak. nginx serves it at the app's endpoint, and it has no state and runs
nothing of its own (`nixos/apps/portal.nix`).

```toml
[app.www]
id = 6
endpoint = "www.example.com"
run-on-hosts = ["web"]
kind = "portal"
logo = "assets/logo.svg"
accent = "#30667c"
keycloak = "auth"
realm = "example"
services = ["drive", "meet", "auth"]
```

## Content

`content`, `site` by default, is a directory in the org, which the site takes as Zola's content directory: a section is
a directory with an `_index.md`, a page any other `.md`, and front matter is TOML (`tests/inventories/mail/site`).

- `languages`, Swedish and English by default, are the site's, the first its default: `_index.md` is a section in the
  default language, `_index.en.md` the same in English, at `/en/`, and a page in each the same way. A page has a link to
  each language it's in.
- The start page is the content's `_index.md`: its `title` and `description` head it, then its text.
- The start page lists each app of `services`, in their order, by `extra.services.<app>` in its front matter, `title`
  and `text`, or its name without, and its `url`, which the org gives it:

  ```toml
  [extra.services.drive]
  title = "Drive"
  text = "Files, calendar and contacts."
  ```

- Each section of the start page is in the header, by its title. One with `extra.on_index = <n>` has its first `n` pages
  on the start page too, as a blog's latest posts with `sort_by = "date"`.
- Each language has its feed, of the pages with a `date`, at `atom.xml` there.
- `logo`, a file in the org, is in the header, `logoHeight` tall, and the site's icon, and `accent`, a CSS color, is its
  buttons and links'.
- o11n has the site's templates, style and script (`nixos/apps/portal/`), and a page that isn't there is the site's
  `404.html`.

## Login

With a `keycloak`, the site has a login: a public client of the portal's name in the `realm`, with PKCE, which returns
to any of the site's pages (`org/apps/portal.nix`), and the keycloak keeps it as it keeps jitsi's
(`docs/parts/keycloak.md`).

- "Log in" sends the visitor to the realm and back to the page they were on, where the site's script exchanges the code
  for the visitor's ID token in the browser and drops it from the address; the header then has the visitor's name, a
  link to the realm's account console, and "Log out" (`nixos/apps/portal/static/auth.js`).
- The visitor is logged in to the realm, so another app of it logs them in without asking for their password again.
- "Log out" ends the visitor's session in the realm, and returns to the page: the next login asks for their password. An
  app with a session of its own, as a drive, keeps it until it ends.
- The token is the tab's alone, and the site's script reads nothing from it but the name it shows.

## Testing

`eval-portal-mail` builds `tests/inventories/mail`'s portal, `www` on `web`, and checks that it lists its services in
their order in each language, and that the keycloak keeps its client. `vmTests.keycloak` serves it beside the keycloak,
where a browser logs alice in from a page of it and back there, is logged in to the drive without being asked again, and
logs out of both.

## Work in progress

- An invite: a form where one asks for an account with their address, which mails the org, and an invite link from
  Keycloak.
- The org's latest commits, and a status page of its apps, linked from the portal.
