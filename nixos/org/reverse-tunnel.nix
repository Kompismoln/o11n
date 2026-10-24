# nixos/org/reverse-tunnel.nix
{
  config,
  host,
  lib,
  org,
  pkgs,
  ...
}:
let
  user = "reverse-tunnel";

  # nixos/org/rescue-usb.nix knocks on port and forwards its sshd to forwardPort.
  port = 2602;
  forwardPort = 2603;
  openForMinutes = 60;

  hostKey =
    (lib.findFirst (key: key.type == "ed25519")
      (throw "reverse-tunnel serves with the host's ed25519 key, and ${host.name} has none")
      config.services.openssh.hostKeys
    ).path;

  # Separate from the host's sshd so that it can take a password and be stopped. It is stopped
  # until opened, and the account it lets in is locked until then.
  sshdConfig = pkgs.writeText "reverse-tunnel-sshd.conf" ''
    Port ${toString port}
    HostKey ${hostKey}
    PidFile none
    AllowUsers ${user}
    UsePAM yes
    AuthenticationMethods password
    PasswordAuthentication yes
    PermitEmptyPasswords no
    KbdInteractiveAuthentication no
    PubkeyAuthentication no
    AuthorizedKeysFile none
    PermitRootLogin no
    AllowTcpForwarding remote
    GatewayPorts no
    PermitListen ${toString forwardPort}
    AllowStreamLocalForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTunnel no
    PermitTTY no
    PermitUserRC no
    ForceCommand ${pkgs.coreutils}/bin/false
    MaxAuthTries 3
    MaxStartups 4:50:10
    LoginGraceTime 30
    ClientAliveInterval 15
    ClientAliveCountMax 4
  '';

  reverseTunnel = pkgs.writeShellApplication {
    name = "reverse-tunnel";
    runtimeInputs = [
      config.systemd.package
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.iproute2
      pkgs.mkpasswd
      pkgs.openssh
      pkgs.procps
      pkgs.shadow
    ];
    text = ''
      usage() {
        echo "usage: reverse-tunnel open [code] | close | status" >&2
        exit 1
      }

      # The caller types the code on a keyboard of unknown layout: digits are where they
      # always are, and spaces and dashes are dropped on both ends.
      normalize() {
        local code=''${1//[[:space:]-]/}
        echo "''${code,,}"
      }

      lock() {
        usermod --password '!' ${user}
        systemctl stop reverse-tunnel.service
      }

      case ''${1:-status} in
      open)
        [[ $# -le 2 ]] || usage
        if [[ $# -eq 2 ]]; then
          code=$(normalize "$2")
        else
          code=$(printf '%04d' $((SRANDOM % 10000)) $((SRANDOM % 10000)) $((SRANDOM % 10000)))
        fi
        if [[ ''${#code} -lt 12 ]]; then
          echo "a code needs at least 12 characters" >&2
          exit 1
        fi
        printf '%s:%s\n' ${user} "$(mkpasswd --method=sha-512 --stdin <<<"$code")" | chpasswd --encrypted
        systemctl restart reverse-tunnel.service reverse-tunnel-expire.timer
        echo "open until $(date --date='${toString openForMinutes} minutes' +%H:%M), code: $(fold -w 4 <<<"$code" | paste -sd ' ')"
        # A caller that doesn't know this host's key shows these words of the key it met.
        echo "this host's key: $(ssh-keygen -l -B -f ${hostKey} | cut -d' ' -f2 | cut -d- -f1-4 | tr - ' ')"
        ;;
      expire)
        lock
        ;;
      close)
        lock
        systemctl stop reverse-tunnel-expire.timer
        pkill --uid ${user} || true
        ;;
      status)
        if systemctl --quiet is-active reverse-tunnel.service; then
          echo "open"
          systemctl list-timers --no-pager reverse-tunnel-expire.timer
        else
          echo "closed"
        fi
        if ss -Htln "sport = :${toString forwardPort}" | grep -q .; then
          echo "connected: the caller's sshd is at localhost:${toString forwardPort}"
        fi
        ;;
      *)
        usage
        ;;
      esac
    '';
  };
in
{
  assertions = [
    {
      assertion = lib.elem user (lib.concatMap (role: org.role.${role}.services) host.roles);
      message = "The reverse-tunnel module lets the ${user} service in, and ${host.name} has none.";
    }
  ];

  environment.systemPackages = [ reverseTunnel ];

  users.users.${user} = {
    hashedPasswordFile = lib.mkForce null;
    hashedPassword = "!";
  };

  services.openssh = {
    enable = true;
    settings.DenyUsers = [ user ];
  };

  networking.firewall.allowedTCPPorts = [ port ];

  systemd.services.reverse-tunnel = {
    description = "sshd for stranded machines to call in through";
    after = [ "network.target" ];
    serviceConfig = {
      ExecStart = "${config.services.openssh.package}/bin/sshd -D -f ${sshdConfig}";
      # Closing the door doesn't hang up on whoever came in through it.
      KillMode = "process";
    };
  };

  systemd.timers.reverse-tunnel-expire.timerConfig.OnActiveSec = "${toString openForMinutes}min";

  systemd.services.reverse-tunnel-expire.serviceConfig = {
    Type = "oneshot";
    ExecStart = "${reverseTunnel}/bin/reverse-tunnel expire";
  };
}
