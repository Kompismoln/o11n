{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "o11n-logs";

  imports = [ ./timeout.nix ];
  globalTimeout = 180;

  nodes.machine = {
    imports = [ ../../nixos/services/logs.nix ];
    _module.args.org.service.logs.name = "logs";

    users.users.logs = {
      isSystemUser = true;
      group = "logs";
      home = "/var/lib/logs";
      createHome = true;
    };
    users.groups.logs = { };

    services.openssh.enable = true;
    # Duplication: the fields nixos/nginx.nix logs first, which the summary reads.
    services.nginx = {
      enable = true;
      commonHttpConfig = ''
        log_format main escape=json '{"time_iso8601": "$time_iso8601", "status": "$status", "remote_addr": "$remote_addr", "remote_user": "$remote_user", "request_method": "$request_method", "request_uri": "$request_uri", "server_protocol": "$server_protocol", "host": "$host"}';
        access_log /var/log/nginx/access.log main;
      '';
      virtualHosts.localhost.locations."/".return = "404";
    };
    environment.systemPackages = [ pkgs.curl ];
  };

  testScript = ''
    machine.wait_for_unit("sshd.service")
    machine.wait_for_unit("nginx.service")
    machine.succeed(
        "ssh-keygen -q -t ed25519 -N ''' -f /root/key",
        "install -d -m 700 -o logs -g logs /var/lib/logs/.ssh",
        "install -m 600 -o logs -g logs /root/key.pub /var/lib/logs/.ssh/authorized_keys",
    )
    ssh = "ssh -i /root/key -o BatchMode=yes -o StrictHostKeyChecking=no"

    machine.succeed("curl -s http://localhost/wp-login.php")
    machine.fail("ssh -o BatchMode=yes -o StrictHostKeyChecking=no intruder@localhost true")

    with subtest("the summary reads the journal and nginx's log as the service"):
        summary = machine.succeed(f"{ssh} logs@localhost 1d")
        for part in ["===== machine since", "--- sshd: users tried", "intruder", "--- nginx: 1 requests",
                     "localhost GET /wp-login.php"]:
            assert part in summary, f"{part!r} isn't in:\n{summary}"
        machine.fail("su -s /bin/sh -c 'cat /etc/shadow' logs")

    with subtest("the ssh-key runs the summary alone"):
        refused = machine.fail(f"{ssh} logs@localhost 'cat /etc/shadow' 2>&1")
        assert "a span is a number" in refused, refused
        machine.succeed(f"{ssh} -f -N -L 9999:localhost:80 logs@localhost")
        machine.fail("curl -sf http://localhost:9999/")
  '';
}
