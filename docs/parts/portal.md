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
services = ["drive", "meet", "photos", "mail"]
invites = "join@example.com"
principal.mail.send = true
```

## Content

`content`, `site` by default, is a directory in the org, which the site takes as Zola's content directory: a section is
a directory with an `_index.md`, a page any other `.md`, and front matter is TOML (`tests/inventories/mail/site`).

- `languages`, Swedish and English by default, are the site's, the first its default: `_index.md` is a section in the
  default language, `_index.en.md` the same in English, at `/en/`, and a page in each the same way. A page has a link to
  each language it's in.
- The start page is the content's `_index.md`: its `title` and `description` head it, then its text.
- The start page lists each app of `services`, in their order, by `extra.services.<app>` in its front matter, `title`
  and `text`, or its name without, and its `url`, which the org gives it, a mail app's its webmail
  (`docs/parts/mail.md`):

  ```toml
  [extra.services.drive]
  title = "Drive"
  text = "Files, calendar and contacts."
  ```

- The start page's front matter has the org's wording, in its language: `extra.headings`, of the start page's parts, and
  `extra.invite`, of the form (see Invites). The site has its own for what it leaves out, and for the rest, as "Log in"
  or "Feed" (`nixos/apps/portal.nix`):

  ```toml
  [extra.headings]
  services = "Services"

  [extra.invite]
  title = "Want an account?"
  text = "Accounts are by invitation."
  sent = "Thanks! We'll be in touch."
  ```

- The header has the sections of the start page alone, by their titles, in the order of their `weight`, each once it has
  text or a page: a page with `draft = true` isn't on the site, so a section of drafts alone waits to be written. One
  with `extra.on_index = <n>` has its first `n` pages on the start page too, as a blog's latest posts with
  `sort_by = "date"`.
- A status app whose `portal` is the portal has its link in the footer (`docs/parts/status.md`).
- Each language has its feed, of the pages with a `date`, at `atom.xml` there; a note's entry is titled by its text.
- `logo`, a file in the org, is in the header, `logoHeight` tall, and the site's icon, and `accent`, a CSS color, is its
  buttons and links'.
- o11n has the site's templates, style and script (`nixos/apps/portal/`), and a page that isn't there is the site's
  `404.html`.

### Notes

A page without a `title` is a note: short, its text all there is to it, shown whole wherever pages are listed, in its
section, on the start page, and at its own address, which its date links to (`nixos/apps/portal/templates/partials/`). A
section of notes is any section, as `notes/`, `sort_by = "date"`, its pages without titles. A note may name a commit,
which it's shown with, linked on GitHub, or at `url`:

```toml
+++
date = 2026-11-17T17:29:00Z

[extra.commit]
repo = "Kompismoln/o11n"
rev = "72f009123e7ea8e47d64f8c2984a5bb2e0365ae2"
subject = "rescue-usb with phone-home"
+++

The rescue stick phones home.
```

The site has a commit's repo, rev and subject only as the note gives them: it fetches nothing.

## Login

With a `keycloak`, the site has a login: a public client of the portal's name in the `realm`, with PKCE, which returns
to any of the site's pages (`org/apps/portal.nix`), and the keycloak keeps it as it keeps jitsi's
(`docs/parts/keycloak.md`).

- "Log in" sends the visitor to the realm and back to the page they were on, where the site's script exchanges the code
  for the visitor's tokens in the browser and drops it from the address; the header then has the visitor's name, a link
  to the realm's account console, and "Log out" (`nixos/apps/portal/static/auth.js`).
- The tokens are the site's, in each of its tabs, and each page renews them as it loads: it shows the visitor logged in
  as long as the realm has them so, and logged out once the realm refuses, however their session ended.
- The visitor is logged in to the realm, so another app of it logs them in without asking for their password again.
- "Log out" ends the visitor's session in the realm, and returns to the page: the next login asks for their password,
  and each app the realm tells of it logs out too (`docs/parts/keycloak.md`).
- The site's script reads nothing of the tokens but the name it shows.

## Invites

With `invites`, an address, the start page has a form where a visitor asks for an account: their address, and a message
if they like, under `extra.invite`'s `title` and `text`, and `sent` once it's sent. It mails the request to `invites`,
as the portal, which has to send mail (`principal.mail.send`), with the visitor's address as its Reply-To
(`nixos/apps/portal/invites.py`). An address on a domain with `mailbox` is to be one a principal's inbox has, as its
address or an alias, or its mail server fails to evaluate, as the server would refuse the request.

- nginx passes a POST to `/invite` alone to `<app>-invites`, a service of the portal's user on its own address, of 16
  KiB at most, and 4 at once from an address, then one a minute; more are answered 429.
- The service takes an address of one mailbox alone, and sends the visitor back to the page of the form, on the site,
  where the form tells them it's sent, or that the address doesn't look right, or to write to the org's `contact`.
- A request that fills in the form's field that people don't see, a bot's, is told it's sent, and isn't.
- The form isn't on the page for a visitor who is logged in.
- The mail ends with the command that invites the visitor, `o11n invite`, with the portal's keycloak and realm, and the
  visitor's address quoted for a shell (`docs/parts/keycloak.md`).

## Testing

`eval-portal-mail` builds `tests/inventories/mail`'s portal, `www` on `web`, and checks that it lists its services in
their order in each language, that a section is in the header once it has a page, that its notes are shown on the start
page and in their section, one with its commit and one without, that it takes the headings the content gives in one
language and its own in the other, and that the keycloak keeps its client. `vmTests.keycloak` serves it beside the
keycloak, where a browser logs alice in from a page of it and back there, and in its other tabs, finds no form for an
invite, is logged in to the drive without being asked again, and logs out, after which the portal's login asks again,
and the drive's. `vmTests.mail` has its form mail a request to elsewhere's carol, signed as the portal, and refuses an
address of more than one mailbox, a return to another site, a GET, and a fifth request at once from an address.
`eval-inventory-mail` fails the mail server's evaluation for an address on its domain that no inbox has, a send-only
principal's among them, and not for an alias, whatever its case, a postmaster, or an address elsewhere.
