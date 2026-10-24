# WIP: klimatkalendern's mail server

Status: noted, nothing changed. Facts are marked "Verified" (seen in an
evaluation) or "Unverified" (to check on the real host).

## In short
- Kompismoln/org's `apps/klimatkalendern.nix` means to point Mobilizon's mailer
  at `settings.mailServer` from `org.toml`; only `klimatkalendern-dev` sets it
  (`settings.mailServer = "helsinki.km"`).
- The setting never reaches Mobilizon: it is written to the host's
  `services.mobilizon`, while Mobilizon runs in `containers.<app>`
  (`nixos/mobilizon.nix`), and the host never enables `services.mobilizon`, so
  nothing reads it.

## What is wrong

```nix
services.mobilizon.settings."Mobilizon.Web.Email.Mailer" = lib.mkIf (app.settings ? mailServer) {
  adapter = (pkgs.formats.elixirConf { }).lib.mkAtom "Swoosh.Adapters.SMTP";
  relay = app.mailServer;
};
```

- `app.mailServer` doesn't exist; the value is `app.settings.mailServer`.
  Verified: forcing `relay` on stationary fails with "attribute 'mailServer'
  missing".
- It sits on the host's `services.mobilizon`. Verified: the host's
  `services.mobilizon.enable` is false; the container's settings are built in
  `nixos/mobilizon.nix` and have no mailer.
- It lacks the `":mobilizon"` level: Mobilizon's settings are
  `settings.":mobilizon"."Mobilizon.Web.Email.Mailer"`, as the container's
  `"Mobilizon.Storage.Repo"` and `":instance"` are.
- Unverified: what Mobilizon sends mail through without it (its own default
  mailer config).

## Where a fix goes
- `nixos/mobilizon.nix` has no way to pass settings into the container. An
  option on `o11n.mobilizon.apps.<name>` (a relay, or settings merged into the
  container's `services.mobilizon.settings`) would carry it.
- The app file then sets that option from `app.settings.mailServer`.
