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
- The start page is the content's `_index.md`: its `title` and `description` head it, then its apps (see below), then
  its text, on one surface, the storefront, under a faint tint of the `accent`, and, with `extra.invite`, the form for
  an invite (see Forms) (`nixos/apps/portal/templates/index.html`).
- Any other section has its `title` and `description` above its text. With `extra.band`, the id of one of its `##`
  headings, its text from that heading to the next is a band of its own after its pages, as a CV is (see CV), and the
  rest of the text after the band; a band that names no `##` of the section fails the site's build
  (`nixos/apps/portal/templates/section.html`).
- A text may set a paragraph apart as a callout, a heads-up in an afternoon's yellow, under a `title` if it has one
  (`nixos/apps/portal/templates/components.html`):

  ```markdown
  {% <callout title="Right now"> %}

  What the text above doesn't say.

  {% </callout> %}
  ```

  With compact={true}, it's one line in a rounded box with a dot before its title, and its text is inline markdown.

- A text may have its points as numbered cards, each with an icon of Lucide's, or `screwdriver`, drawn in its style
  (`nixos/apps/portal/static/icons/`), in a tone, `accent`, `sunset`, `forest` or `bloom`, a title and a sentence. Two
  cards share a row where there's room, and an odd one out last spans it (`nixos/apps/portal/static/portal.css`):

  ```markdown
  {{ <points items={[["unplug", "accent", "Stay independent", "What is built runs without us."]]} /> }}
  ```

- A sandbox is a test environment, where AI works on test data, a review, and the systems it reaches once reviewed, each
  with a title and a note, and its text is the caption:

  ```markdown
  {% <sandbox test={["Test environment", "Mistakes stay here."]} ai="AI" data="Test data"
    review={["Review", "Alice reads the code."]} live={["Your systems", "Real data."]}> %}

  Nothing reaches your systems unreviewed.

  {% </sandbox> %}
  ```

- A foundation is `##` headings of the text as blocks on another, its text under it, each with an icon and a link to its
  heading, and a `label` that names it for a screen reader:

  ```markdown
  {% <foundation label="Services" items={[["workflow", "Automate"], ["cable", "Integrate"]]}
    base={["server", "Operations"]}> %}

  Servers and backup.

  {% </foundation> %}
  ```

- An icon a component names that the site doesn't have fails the site's build, which says which
  (`nixos/apps/portal/site.nix`).

- The start page lists each app of `services`, in their order, by `extra.services.<app>` in its front matter, `title`
  and `text`, or its name without, and its `url`, which the org gives it, a mail app's its webmail
  (`docs/parts/mail.md`):

  ```toml
  [extra.services.drive]
  title = "Drive"
  text = "Files, calendar and contacts."
  ```

- The start page's front matter has the org's wording, in its language: `extra.headings`, of the start page's parts, and
  a section's `extra.invite`, of the form (see Forms). The site has its own for what it leaves out, and for the rest, as
  "Log in" or "Feed" (`nixos/apps/portal.nix`), but for the apps, which have no heading without `headings.services`:

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
  with `extra.menu = false` isn't in the header, and keeps its address, for the links of other texts. One with
  `extra.on_index = <n>` has its first `n` pages on the start page too, as a blog's latest posts with
  `sort_by = "date"`.
- A status app whose `portal` is the portal has its link in the footer (`docs/parts/status.md`).
- Each language has its feed, of the pages with a `date`, at `atom.xml` there; a note's entry is titled by its text. The
  footer links it, and the head names it, once a section of the start page or the start page itself has such a page
  (`nixos/apps/portal/templates/base.html`).
- `logo`, a file in the org, is in the header, `logoHeight` tall, and the site's icon, and `accent`, a CSS color, is its
  links', and the box of a list item that begins with `[x]` or `[ ]`, a task, which has no bullet; a link right after
  the task's first emphasis is a chip (`nixos/apps/portal/static/portal.css`).
- The rest of the site's colors each have a part: `forest` green is what sends or makes something, its buttons; `bloom`
  pink is a detail, a label above a part and an example's edge; `sunset`, an afternoon's yellow, is a heads-up, a
  callout; and an earth brown is the footer, which anchors the page, with a tulip of the green and the pink growing from
  its edge, in the middle of its right half (`nixos/apps/portal/static/portal.css`).
- With `accentHeader`, the header is in the `accent` in light mode, with white on it, and its logo as dark mode has it,
  and in dark mode as without, but for the site's name in white. The logo has it so by an SVG's `prefers-color-scheme`,
  which follows the header's (`nixos/apps/portal/static/portal.css`).
- With `skyHeader` too, the header is a sky in light mode: the `accent` at its top, paler toward its foot, and thin
  clouds (`nixos/apps/portal/static/cirrus.svg`) above and below its text but not across it. It has no line at its foot,
  and fades into the page below it instead. A `skyHeader` without `accentHeader` fails evaluation.
- The header switches the site between light and dark, with a sun in light mode and a moon in dark, each a shining
  sphere of CSS's, in the middle of the room between the nav and the tools, or on a narrow screen between the site's
  name and the menu's button. The site is as the visitor's system has it until they switch, and keeps what they chose in
  their browser, until they switch back to what their system has (`nixos/apps/portal/templates/base.html`).
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

### CV

A section with a `cv.toml` beside its `_index.md`, `cv.en.toml` in English, has a CV, which the site shows after the
section, on a band of its own under "About me", and as a PDF that Typst sets in Inter, linked under it at `cv.pdf`,
`cv.en.pdf` (`nixos/apps/portal/cv.typ`):

```toml
name = "Alice"
title = "Operations"
location = "Stockholm"
availability = "Available from January"
email = "alice@example.com"
business = "Sole trader, registered for F-tax"
profile = ["A paragraph.", "Another."]

[[links]]
name = "GitHub"
url = "https://github.com/alice"

[[available]]
month = "2027-01"
percent = 50 # until the next, the last for good

[[skills]]
group = "Infrastructure"
items = ["NixOS", "WireGuard"]

[[experience]]
from = 2018
to = 2020 # without, to the present
employer = "Example AB"
role = "Developer"
summary = "What the role was."
points = ["What came of it."]

[[education]]
title = "BSc"
from = 2009
to = 2014
text = "Its direction."

[[languages]]
name = "English"
level = "fluent"
```

- `name` alone is required, and each part is in order, as it has it.
- The site has the `title` in a box, with the `availability` at its end, shows a role by its `summary`, and leaves its
  `points`, `education` and `languages` to the PDF.
- `available` is a bar a month, under the box, with its percent above it; the site leaves out a month once the next has
  begun, as the visitor's clock has it (`nixos/apps/portal/static/cv.js`), and the PDF has each.
- The `email`, the `links`, the `location` and the `business` are a card of contacts beside the CV, or after it on a
  narrow screen, with the link to the PDF, and at the right of the PDF's head, each with an icon of Lucide's
  (`nixos/apps/portal/static/icons/`): a link's is GitHub's or LinkedIn's by its address, or a link's. The PDF has the
  section's address at the foot of each page.
- The section's text may end a part with a row of its skills, each a chip that links to it in the CV, as a component:

  ```markdown
  {{ <skills items={["NixOS", "WireGuard"]} /> }}
  ```

  Or with a box of what the part rests on, its text under a `title` and its skills, if any, as chips at its foot:

  ```markdown
  {% <experience title="Experience" skills={["NixOS"]}> %}

  What was done, and where.

  {% </experience> %}
  ```

  A chip that names a skill the CV in the section's language doesn't have fails the site's build, which says which
  (`nixos/apps/portal/site.nix`).

- The PDF's headings are the site's, in the CV's language, and its accent the site's `accent` if a hex color, or else
  its text color.
- The site serves the TOML as it does the section's other files.

## Preview

`o11n site [app] [-- <zola serve's arguments>]`, from the org's clone, serves a portal's site from its content there,
the org's one portal or the one named, with `zola serve`, at `http://127.0.0.1:1111` unless `--port` says otherwise, as
the portal builds it, and again as the content changes, each CV's PDF too (`crates/o11n/src/site.rs`).

- It builds `portals.<system>.<app>.serve` of the org's flake, which has `content` as a place in the org
  (`lib/default.nix`), from the org's `o11n`: a change to o11n's templates is seen once the org's o11n has it.
- The site and the server are built alike (`nixos/apps/portal/site.nix`), but for the server's address in place of the
  portal's.
- A CV added while it runs has its PDF once it's started again.
- The keycloak refuses its login, as it returns to the portal's address alone, and the form for an invite has no service
  to post to.

## Login

With a `keycloak`, the site has a login: a public client of the portal's name in the `realm`, with PKCE, which returns
to any of the site's pages (`org/apps/portal.nix`), and the keycloak keeps it as it keeps jitsi's
(`docs/parts/keycloak.md`).

- "Log in", a user's icon in the header, sends the visitor to the realm and back to the page they were on, where the
  site's script exchanges the code for the visitor's tokens in the browser and drops it from the address; the header
  then has the visitor's name, a link to the realm's account console, and "Log out"
  (`nixos/apps/portal/static/auth.js`).
- The tokens are the site's, in each of its tabs, and each page renews them as it loads: it shows the visitor logged in
  as long as the realm has them so, and logged out once the realm refuses, however their session ended.
- A visitor without tokens is asked after once a tab, in a frame they don't see that returns to the site's
  `silent.html`: a session they have with another app of the realm logs the page in without a click, and none, or a
  realm that hasn't answered in five seconds, leaves them logged out.
- The visitor is logged in to the realm, so another app of it logs them in without asking for their password again.
- "Log out" ends the visitor's session in the realm, and returns to the page: the next login asks for their password,
  and each app the realm tells of it logs out too (`docs/parts/keycloak.md`).
- The site's script reads nothing of the tokens but the name it shows.

## Forms

A section, the start page among them, has a form after its text for each of `extra.invite` and `extra.inquiry` its front
matter has, at `#invite` and `#inquiry` (`nixos/apps/portal/templates/partials/form.html`): with `invites`, an address,
where a visitor asks for an account, and with `inquiries`, an address, where a visitor writes. Both are a table of the
same keys, and the forms alike but for what they're for: a `title` and `text` above the form, for an invite by default
the site's own, the visitor's address and a message, which begins as `message` has it, for them to fill in, and `sent`
once it's sent:

```toml
[extra.inquiry]
title = "Hosting for you"
message = """
We need help with …
"""
```

A form mails what's sent to its address, `invites` or `inquiries`, as the portal, which has to send mail
(`principal.mail.send`), with the visitor's address as its Reply-To (`nixos/apps/portal/forms.py`). An address on a
domain with `mailbox` is to be one a principal's inbox has, as its address or an alias, or its mail server fails to
evaluate, as the server would refuse the mail. A section with `extra.invite` fails the site's build when the portal has
no `invites`, one with `extra.inquiry` when it has no `inquiries`, and so does one whose `extra.invite` or
`extra.inquiry` is the text its form begins with rather than a table.

- nginx passes a POST to `/invite` or `/inquiry` alone, each once the portal has its address, to `<app>-forms`, a
  service of the portal's user on its own address, of 16 KiB at most, and 4 at once from an address, then one a minute,
  of either; more are answered 429.
- The service takes an address of one mailbox alone, and sends the visitor back to the page of the form, on the site,
  where the form tells them it's sent, or that the address doesn't look right, or to write to the org's `contact`, or
  for an inquiry, to `inquiries`.
- A message is up to 4000 characters, and may be left as it begins, or empty.
- A request that fills in the form's field that people don't see, a bot's, is told it's sent, and isn't.
- The form for an invite isn't on the page for a visitor who is logged in.
- The mail of a request for an invite ends with the command that invites the visitor, `o11n invite`, with the portal's
  keycloak and realm, and the visitor's address quoted for a shell (`docs/parts/keycloak.md`).

## Testing

`eval-portal-mail` builds `tests/inventories/mail`'s portal, `www` on `web`, and checks that it lists its services in
their order in each language, and its text after them, that a section is in the header once it has a page, and one with
`extra.menu = false` isn't, but is built, that its notes are shown on the start page and in their section, one with its
commit and one without, that it takes the headings the content gives in one language and its own in the other, that a
section shows its description, its points, its sandbox, its foundation, which links its headings, its form for
inquiries, with its message and `sent`, and its form for an invite with its message in one language and none in the
other, and a section's own, and the CV of its language with summaries alone, which its chips link to, and links its PDF,
which has the points, and that the keycloak keeps its client. `eval-portal-chips` fails a site's build for a chip that
names a skill the CV doesn't have. `eval-portal-icons` fails it for an icon the site doesn't have, and
`eval-portal-invite` for a form for an invite without `invites`, `eval-portal-inquiry` for a form for inquiries without
`inquiries`, and `eval-portal-inquiry-text` for an `extra.inquiry` that is text. `vmTests.keycloak` serves it beside the
keycloak, where a browser logs alice in from a page of it and back there, and in its other tabs, finds no form for an
invite, is logged in to the drive without being asked again, and logs out, after which the portal's login asks again,
and the drive's. `vmTests.mail` has its forms mail a request for an invite and an inquiry to elsewhere's carol, signed
as the portal, and refuses an address of more than one mailbox, a return to another site, a GET, and a fifth request at
once from an address. `eval-inventory-mail` fails the mail server's evaluation for an address on its domain that no
inbox has, a send-only principal's among them, and not for an alias, whatever its case, a postmaster, or an address
elsewhere, for `invites` and `inquiries` alike.
