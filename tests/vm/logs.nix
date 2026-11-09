{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "o11n-logs";

  imports = [ ./timeout.nix ];
  globalTimeout = 180;

  nodes.machine = {
    imports = [
      ../../nixos/services/logs.nix
      ../../nixos/org/log-retention.nix
    ];
    _module.args.org = {
      logRetention = 14;
      service.logs.name = "logs";
      prefix = "fd00:1:2";
      prefix4 = "10.9";
    };

    users.users.logs = {
      isSystemUser = true;
      group = "logs";
      home = "/var/lib/logs";
      createHome = true;
    };
    users.groups.logs = { };

    services.openssh.enable = true;
    # Duplication: the fields of nixos/nginx.nix's log format that the summary reads.
    services.nginx = {
      enable = true;
      commonHttpConfig = ''
        log_format main escape=json '{"time_iso8601": "$time_iso8601", "status": "$status", "remote_addr": "$remote_addr", "remote_user": "$remote_user", "request_method": "$request_method", "request_uri": "$request_uri", "server_protocol": "$server_protocol", "host": "$host", "http_user_agent": "$http_user_agent", "upstream_status": "$upstream_status"}';
        access_log /var/log/nginx/access.log main;
      '';
      virtualHosts.localhost = {
        # Fact: on a listen without TLS, HTTP/2 is spoken to a client that starts with it.
        extraConfig = "http2 on;";
        locations = {
          "/".return = "404";
          "/app".proxyPass = "http://127.0.0.1:9";
        };
      };
    };
    systemd.services.keycloak = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.Type = "oneshot";
      script = ''
        echo 'type=LOGIN_ERROR, ipAddress=0:0:0:0:0:0:0:1, error=invalid_user_credentials'
        echo 'neural.lua:1234: user=<> from unknown[fd00:1:2::7] port 50000:11: Bye'
      '';
    };
    systemd.services."container@calendar" = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.Type = "oneshot";
      script = ''
        echo 'Welcome to NixOS'
        echo 'calendar login: [   22.169908] mobilizon[450]: 17:44:59.395 request_id=GOZx [error] ** (FunctionClauseError) no function clause matching in Access.get/3'
        echo '[   22.170136] mobilizon[450]:     (elixir 1.18.5) lib/access.ex:320: Access.get("https://elsewhere.test/notes/1", "id", nil)'
        echo '[   23.000001] mobilizon_ctl[401]: 17:44:53.086 [info] == Running 20180109150000 Mobilizon.Repo.Migrations.Prerequites.up/0 forward'
        echo '[   24.456000] mobilizon[450]: 17:45:02.456 [warning] Mobilizon.Federation: actor not found'
      '';
    };
    systemd.services.crashing = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.coreutils}/bin/false";
    };
    environment.systemPackages = [
      pkgs.curl
      (pkgs.python3.withPackages (p: [ p.h2 ]))
    ];
  };

  testScript =
    let
      unparsed = pkgs.writeText "unparsed.py" ''
        import socket

        s = socket.create_connection(("127.0.0.1", 80))
        s.sendall(b"\x01\x02\r\n\r\n")
        s.recv(4096)
      '';
      pathless = pkgs.writeText "pathless.py" ''
        import socket

        import h2.config
        import h2.connection

        s = socket.create_connection(("127.0.0.1", 80))
        c = h2.connection.H2Connection(h2.config.H2Configuration(validate_outbound_headers=False))
        c.initiate_connection()
        c.send_headers(1, [(":method", "GET"), (":scheme", "http"), (":authority", "localhost")], end_stream=True)
        s.sendall(c.data_to_send())
        s.recv(65535)
      '';
    in
    ''
      import re

      machine.wait_for_unit("sshd.service")
      machine.wait_for_unit("nginx.service")
      machine.wait_until_succeeds("journalctl -u keycloak | grep -q LOGIN_ERROR")
      machine.wait_until_succeeds("journalctl -u container@calendar | grep -q 'actor not found'")
      machine.succeed(
          "ssh-keygen -q -t ed25519 -N ''' -f /root/key",
          "install -d -m 700 -o logs -g logs /var/lib/logs/.ssh",
          "install -m 600 -o logs -g logs /root/key.pub /var/lib/logs/.ssh/authorized_keys",
      )
      ssh = "ssh -i /root/key -o BatchMode=yes -o StrictHostKeyChecking=no"

      machine.succeed("curl -s -A 'Scanner/1.0' http://localhost/wp-login.php")
      machine.succeed("curl -s http://localhost/app?secret=1")
      machine.succeed("python3 ${unparsed}", "python3 ${pathless}")
      machine.wait_until_succeeds("systemctl is-failed crashing.service")
      machine.fail("ssh -o BatchMode=yes -o StrictHostKeyChecking=no intruder@localhost true")

      with subtest("the summary reads the journal and nginx's log as the service"):
          summary = machine.succeed(f"{ssh} logs@localhost 1d")
          for part in ["===== machine since", "\njournal from ", "\nnginx from ",
                       "\ntcp 0.0.0.0:80 nginx.service\n", "--- units failed now\ncrashing.service\n",
                       "--- sshd: ", "Invalid user U", "--- sshd: users tried", "intruder",
                       "--- nginx: 4 requests", "localhost GET /wp-login.php",
                       " (no request line)\n", " localhost GET (no path, HTTP/2.0)\n",
                       "localhost GET /app upstream 502\n",
                       "neural.lua:1234: user=<> from unknown[IP] port N:11: Bye\n",
                       "--- nginx: sources of 4xx, with the user agent they sent most",
                       "--- container@calendar.service: warnings and errors, by kind\n",
                       "[error] ** (FunctionClauseError) no function clause matching in Access.get/3\n",
                       "[warning] Mobilizon.Federation: actor not found\n"]:
              assert part in summary, f"{part!r} isn't in:\n{summary}"
          for routine in ["Accepted publickey", "Server listening on", "session opened", "Welcome to NixOS",
                          "lib/access.ex", "Migrations.Prerequites"]:
              assert routine not in summary, f"{routine!r} is in:\n{summary}"
          for pattern in [r"--- sshd: \d+ lines, [1-9]\d* of them routine; the rest by kind\n",
                          r"--- sshd: accepted, by user and source\n +1 logs \S+ \(this host\)\n",
                          r"--- keycloak: sources of failures\n +1 ::1 \(this host\)\n",
                          r"\n +1 \S+ \(this host\) Scanner/1\.0\n"]:
              assert re.search(pattern, summary), f"{pattern!r} doesn't match:\n{summary}"
          machine.fail("su -s /bin/sh -c 'cat /etc/shadow' logs")

      with subtest("the ssh-key runs the summary alone"):
          refused = machine.fail(f"{ssh} logs@localhost 'cat /etc/shadow' 2>&1")
          assert "a span is a number" in refused, refused
          machine.succeed(f"{ssh} -f -N -L 9999:localhost:80 logs@localhost")
          machine.fail("curl -sf http://localhost:9999/")

      with subtest("nginx's logs past the retention go, a count's leftovers too, and the live ones stay"):
          d = "/var/log/nginx"
          machine.succeed(
              f"touch -d '-30 days' {d}/access.log {d}/error.log",
              f"for n in 1 3 27; do echo x | gzip > {d}/access.log.$n.gz; done",
              f"touch -d '-2 days' {d}/access.log.1.gz",
              f"touch -d '-15 days' {d}/access.log.3.gz",
              f"touch -d '-200 days' {d}/access.log.27.gz",
              "systemd-tmpfiles --clean",
          )
          machine.succeed(f"test -e {d}/access.log", f"test -e {d}/error.log", f"test -e {d}/access.log.1.gz")
          machine.fail(f"test -e {d}/access.log.3.gz")
          machine.fail(f"test -e {d}/access.log.27.gz")
          machine.succeed("grep -qx 'MaxRetentionSec=14d' /etc/systemd/journald.conf")
    '';
}
