# nixos/org/rescue-usb.nix
#
# A live system for a machine that has to be reached from afar. `phonehome` gets it online and
# calls the reverse tunnel of a server with a code read out over the phone, after which root
# can log in through the tunnel with the rescue key. It carries no secrets: the org's are
# withheld because a stick goes where it's needed and can be lost there.
{
  config,
  lib,
  org,
  pkgs,
  ...
}:
let
  cfg = config.o11n.rescue-usb;
  server = org.host.${cfg.via};

  # As nixos/org/reverse-tunnel.nix sets them.
  port = 2602;
  forwardPort = 2603;

  askpass = pkgs.writeShellScript "phonehome-askpass" ''
    echo "$PHONEHOME_CODE"
  '';

  phonehome = pkgs.writeShellApplication {
    name = "phonehome";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.getent
      pkgs.gnugrep
      pkgs.networkmanager
      pkgs.openssh
    ];
    text = ''
      endpoint=${lib.escapeShellArg server.endpoint}
      socket=/run/phonehome.ssh
      log=$(mktemp)

      say() {
        printf '\n'
        printf '%s\n' "$@"
      }

      ask() {
        printf '\n%s ' "$1"
        read -r reply || exit 1
      }

      online() {
        getent hosts "$endpoint" >/dev/null
      }

      hang-up() {
        ssh -S "$socket" -O exit "reverse-tunnel@$endpoint" 2>/dev/null || true
        rm -f "$socket"
      }

      join-wifi() {
        local -a names security
        local -A seen
        local bars sec ssid number

        nmcli radio wifi on
        while true; do
          say "Looking for wifi networks..."
          names=() security=() seen=()
          while IFS=: read -r _ bars sec ssid; do
            ssid=''${ssid//\\:/:}
            [[ -n $ssid && -z ''${seen[$ssid]:-} ]] || continue
            seen[$ssid]=1
            names+=("$ssid")
            security+=("$sec")
            printf '  %2d)  %s  %s\n' "''${#names[@]}" "$bars" "$ssid"
          done < <(nmcli --terse --fields SIGNAL,BARS,SECURITY,SSID device wifi list --rescan yes | sort -t: -k1,1nr)

          if [[ ''${#names[@]} -eq 0 ]]; then
            ask "No wifi networks found. Press Enter to look again."
            continue
          fi

          ask "Type the number of your network and press Enter (just Enter looks again):"
          if [[ ! $reply =~ ^[0-9]+$ ]] || ((reply < 1 || reply > ''${#names[@]})); then
            continue
          fi
          number=$reply
          ssid=''${names[number - 1]}

          local -a secret=()
          if [[ -n ''${security[number - 1]} && ''${security[number - 1]} != -- ]]; then
            ask "Type the password for $ssid and press Enter:"
            secret=(password "$reply")
          fi

          say "Connecting to $ssid..."
          if nmcli --wait 45 device wifi connect "$ssid" "''${secret[@]}" >/dev/null 2>&1; then
            for _ in {1..15}; do
              online && return 0
              sleep 2
            done
            say "Connected to $ssid, but the internet can't be reached through it."
          else
            say "That didn't work. Check the password and try again."
          fi
          nmcli connection delete id "$ssid" >/dev/null 2>&1 || true
        done
      }

      call() {
        hang-up
        PHONEHOME_CODE=$code SSH_ASKPASS=${askpass} SSH_ASKPASS_REQUIRE=force \
          ssh -f -N -M -S "$socket" -p ${toString port} \
          -o StrictHostKeyChecking=yes \
          -o PubkeyAuthentication=no \
          -o PreferredAuthentications=password \
          -o NumberOfPasswordPrompts=1 \
          -o ExitOnForwardFailure=yes \
          -o ConnectTimeout=20 \
          -o ServerAliveInterval=15 \
          -o ServerAliveCountMax=4 \
          -R ${toString forwardPort}:localhost:22 \
          "reverse-tunnel@$endpoint" 2>"$log"
      }

      trap 'hang-up; exit 130' INT TERM

      if ! online; then
        say "This computer isn't online. Let's connect it to your wifi."
        join-wifi
      fi

      code=
      while true; do
        if [[ -z $code ]]; then
          ask "Type the code you were given over the phone and press Enter:"
          code=''${reply//[[:space:]-]/}
          code=''${code,,}
          [[ -n $code ]] || continue
        fi

        say "Calling..."
        if call; then
          say "Connected! This computer can now be reached." \
            "Leave it on and this screen as it is. Ctrl+C hangs up."
          while ssh -S "$socket" -O check "reverse-tunnel@$endpoint" 2>/dev/null; do
            sleep 5
          done
          say "The connection dropped."
        elif grep -q "Permission denied" "$log"; then
          say "That code didn't work."
          code=
        elif grep -q "Host key verification failed" "$log"; then
          say "Stop: the other end isn't who it should be. Tell the person on the phone."
          exit 1
        elif grep -q "Connection refused" "$log"; then
          ask "The line isn't open. Ask for it to be opened, then press Enter."
        elif grep -q "remote port forwarding failed" "$log"; then
          say "The line is busy. Trying again in a minute..."
          sleep 60
        elif ! online; then
          say "This computer has lost the internet."
          join-wifi
        else
          say "Something went wrong:" "$(tail -n 3 "$log")"
          ask "Press Enter to try again."
        fi
      done
    '';
  };
in
{
  options.o11n.rescue-usb.via = lib.mkOption {
    description = "the server whose reverse tunnel the stick calls";
    type = lib.types.enum (
      lib.attrNames (lib.filterAttrs (_: host: lib.elem "server" host.roles) org.host)
    );
  };

  config = {
    assertions = [
      {
        assertion = server.endpoint != null;
        message = "The rescue stick calls ${cfg.via} on its endpoint, and it has none.";
      }
    ];

    system.stateVersion = config.system.nixos.release;
    networking.hostName = "rescue-usb";

    hardware.enableRedistributableFirmware = true;
    networking.networkmanager.enable = true;

    # It's left lying open while someone works on it from afar.
    services.logind.settings.Login = {
      HandleLidSwitch = "ignore";
      HandleLidSwitchExternalPower = "ignore";
    };

    services.openssh = {
      enable = true;
      listenAddresses = [
        {
          addr = "127.0.0.1";
          port = 22;
        }
      ];
      openFirewall = false;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = lib.mkForce "prohibit-password";
      };
    };

    users.users.root.openssh.authorizedKeys.keyFiles = [ org.service.rescue.publicKeys.ssh-key ];

    programs.ssh.knownHosts.${cfg.via} = {
      hostNames = [ "[${server.endpoint}]:${toString port}" ];
      publicKeyFile = server.publicKeys.ssh-key;
    };

    services.getty = {
      autologinUser = lib.mkForce "root";
      helpLine = lib.mkForce "";
    };

    users.motd = ''

      To call ${org.name} for help, type  phonehome  and press Enter.
    '';

    environment.systemPackages = [ phonehome ];

    image.modules.iso-installer.isoImage.appendToMenuLabel = " ${org.name} rescue";
  };
}
