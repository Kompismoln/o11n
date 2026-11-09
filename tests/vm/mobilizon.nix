{
  pkgs,
  o11nInputs,
  outputs,
}:
let
  inherit (outputs) org;
  inherit (org.app) calendar;
  shared = import ./mail-org.nix { inherit pkgs o11nInputs outputs; };
  inherit (shared) inventorySecrets principal;

  mobilizon =
    {
      config,
      host,
      lib,
      org,
      pkgs,
      ...
    }:
    import ../../nixos/apps/mobilizon.nix {
      app = calendar;
      inputs = import ../inventories/mail/inputs.nix { inherit pkgs; };
      inherit
        config
        host
        lib
        org
        pkgs
        ;
    };
in
pkgs.testers.runNixOSTest {
  name = "o11n-mobilizon";

  imports = [ ./timeout.nix ];
  globalTimeout = 600;

  node.specialArgs = { inherit org o11nInputs; };

  nodes.web =
    { config, ... }:
    {
      imports = [
        inventorySecrets
        ../../nixos/preserve.nix
        ../../nixos/org/mail.nix
        mobilizon
        (principal org.user.alice)
        (principal org.app.blog)
        (principal calendar)
        (principal org.app.auth)
      ];
      _module.args.host = org.host.web;
      services.nginx.enable = true;
      # Accommodating for nixos/postgresql.nix, which makes no role, database or extension, as an operator made
      # Kompismoln/org's.
      services.postgresql = {
        ensureDatabases = [ calendar.database ];
        ensureUsers = [
          {
            inherit (calendar) name;
            ensureDBOwnership = true;
          }
        ];
      };
      systemd.services.mobilizon-extensions = {
        after = [ "postgresql-setup.service" ];
        requires = [ "postgresql-setup.service" ];
        before = [ "container@calendar.service" ];
        requiredBy = [ "container@calendar.service" ];
        serviceConfig = {
          Type = "oneshot";
          User = "postgres";
        };
        path = [ config.services.postgresql.package ];
        script = ''
          psql -d ${calendar.database} -c 'CREATE EXTENSION IF NOT EXISTS postgis' \
            -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm' -c 'CREATE EXTENSION IF NOT EXISTS unaccent'
        '';
      };
      # Accommodating for the test's network, which has no wg0: the principals bind to their loopback addresses as
      # nixos/org/networking.nix routes them.
      networking.localCommands = "ip -6 route replace local ${org.loCidr} dev lo";
      boot.kernel.sysctl."net.ipv6.ip_nonlocal_bind" = 1;
      virtualisation.memorySize = 3072;
      virtualisation.cores = 2;
    };

  testScript = ''
    def request(path, *args):
        return web.succeed(
            f"curl -s -o /dev/null -w '%{{http_code}}' -H 'Host: ${calendar.endpoint}' {' '.join(args)} http://127.0.0.1{path}"
        )

    web.wait_for_unit("container@calendar.service", timeout=300)
    try:
        web.wait_until_succeeds("test \"$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: ${calendar.endpoint}' http://127.0.0.1/@nobody)\" = 404", timeout=300)
    finally:
        print(web.execute("journalctl -u container@calendar.service -o cat | tail -100")[1])

    with subtest("mobilizon's errors reach the host's journal, and what went as it should doesn't"):
        answered = request("/inbox", "-H 'Content-Type: application/json'",
                           "-d '{\"type\": \"Create\", \"actor\": \"https://elsewhere.test/@bob\", \"object\": \"https://elsewhere.test/notes/1\"}'")
        print(f"an unsigned Create of an object by its URL is answered {answered}")
        web.wait_until_succeeds(
            "journalctl -u container@calendar.service -o cat"
            " | grep -q 'mobilizon\\[[0-9]*\\]: .* \\[error\\] \\*\\* (FunctionClauseError)'", timeout=60)
        web.succeed("curl -sf -H 'Host: ${calendar.endpoint}' http://127.0.0.1/ > /dev/null")
        web.fail("journalctl -u container@calendar.service -o cat | grep 'mobilizon\\[[0-9]*\\]: .* \\[info\\]'")
  '';
}
