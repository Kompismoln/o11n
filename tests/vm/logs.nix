{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "o11n-logs";

  imports = [ ./timeout.nix ];
  globalTimeout = 180;

  nodes.machine = {
    imports = [ ../../nixos/services/logs.nix ];
    _module.args.org = {
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
      virtualHosts.localhost.locations = {
        "/".return = "404";
        "/app".proxyPass = "http://127.0.0.1:9";
      };
    };
    systemd.services.keycloak = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.Type = "oneshot";
      script = "echo 'type=LOGIN_ERROR, ipAddress=0:0:0:0:0:0:0:1, error=invalid_user_credentials'";
    };
    systemd.services.crashing = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.coreutils}/bin/false";
    };
    environment.systemPackages = [ pkgs.curl ];
  };

  testScript = ''
    import re

    machine.wait_for_unit("sshd.service")
    machine.wait_for_unit("nginx.service")
    machine.wait_until_succeeds("journalctl -u keycloak | grep -q LOGIN_ERROR")
    machine.succeed(
        "ssh-keygen -q -t ed25519 -N ''' -f /root/key",
        "install -d -m 700 -o logs -g logs /var/lib/logs/.ssh",
        "install -m 600 -o logs -g logs /root/key.pub /var/lib/logs/.ssh/authorized_keys",
    )
    ssh = "ssh -i /root/key -o BatchMode=yes -o StrictHostKeyChecking=no"

    machine.succeed("curl -s -A 'Scanner/1.0' http://localhost/wp-login.php")
    machine.succeed("curl -s http://localhost/app?secret=1")
    machine.wait_until_succeeds("systemctl is-failed crashing.service")
    machine.fail("ssh -o BatchMode=yes -o StrictHostKeyChecking=no intruder@localhost true")

    with subtest("the summary reads the journal and nginx's log as the service"):
        summary = machine.succeed(f"{ssh} logs@localhost 1d")
        for part in ["===== machine since", "\njournal from ", "\nnginx from ",
                     "\ntcp 0.0.0.0:80 nginx.service\n", "--- units failed now\ncrashing.service\n",
                     "--- sshd: ", "Invalid user U", "--- sshd: users tried", "intruder",
                     "--- nginx: 2 requests", "localhost GET /wp-login.php",
                     "localhost GET /app upstream 502\n",
                     "--- nginx: sources of 4xx, with the user agent they sent most"]:
            assert part in summary, f"{part!r} isn't in:\n{summary}"
        for pattern in [r"--- sshd: accepted, by user and source\n +1 logs \S+ \(this host\)\n",
                        r"--- keycloak: sources of failures\n +1 ::1 \(this host\)\n",
                        r"\n +1 \S+ \(this host\) Scanner/1\.0\n"]:
            assert re.search(pattern, summary), f"{pattern!r} doesn't match:\n{summary}"
        machine.fail("su -s /bin/sh -c 'cat /etc/shadow' logs")

    with subtest("the ssh-key runs the summary alone"):
        refused = machine.fail(f"{ssh} logs@localhost 'cat /etc/shadow' 2>&1")
        assert "a span is a number" in refused, refused
        machine.succeed(f"{ssh} -f -N -L 9999:localhost:80 logs@localhost")
        machine.fail("curl -sf http://localhost:9999/")
  '';
}
