{
  pkgs,
  o11nLib,
  o11n,
  o11n-dev,
}:
let
  inherit (pkgs) lib;
  inherit (import ./lib.nix { inherit pkgs; }) callTests mkCheck evalNixosModule;

  args = {
    inherit
      pkgs
      lib
      o11nLib
      evalNixosModule
      ;
  };

  entries = dir: type: lib.attrNames (lib.filterAttrs (_: t: t == type) (builtins.readDir dir));

  nixosChecks = lib.genAttrs' (lib.filter (lib.hasSuffix ".nix") (entries ./nixos "regular")) (
    file:
    let
      name = "eval-nixos-${lib.removeSuffix ".nix" file}";
    in
    lib.nameValuePair name (mkCheck name (callTests ./nixos/${file} args))
  );

  inventories = lib.genAttrs (entries ./inventories "directory") (
    inventory:
    let
      path = ./inventories/${inventory};
    in
    o11nLib.fromInventory {
      inherit path;
      inputs = lib.optionalAttrs (builtins.pathExists (path + "/inputs.nix")) (
        let
          inputs = import (path + "/inputs.nix");
        in
        if lib.isFunction inputs then inputs { inherit pkgs; } else inputs
      );
    }
  );

  inventoryChecks = lib.mapAttrs' (
    inventory: outputs:
    let
      name = "eval-inventory-${inventory}";
    in
    lib.nameValuePair name (
      mkCheck name (callTests ./inventories/${inventory}/tests.nix (args // { inherit outputs; }))
    )
  ) inventories;

  homeChecks.eval-homes = pkgs.runCommand "eval-homes" {
    drvs = lib.concatMap (
      outputs:
      map (home: builtins.unsafeDiscardOutputDependency home.activationPackage.drvPath) (
        lib.attrValues outputs.homeConfigurations
      )
    ) (lib.attrValues inventories);
  } "touch $out";

  # Policy: o11n reads the sample as an org's clone, and its answers are checked against the keys on disk.
  o11nChecks.eval-o11n-sample =
    pkgs.runCommand "eval-o11n-sample"
      {
        nativeBuildInputs = [ o11n ];
        export = builtins.toFile "export.json" (builtins.toJSON inventories.sample.org.export);
        org = ./inventories/sample;
      }
      ''
        export O11N_EXPORT=$export O11N_ORG_ROOT=$org
        [[ $(o11n recipients service-nix-remote | tr '\n' ' ') == "host-gw root-1 service-nix-remote " ]]
        [[ $(o11n entities 'host:remote-builder+server' 'user-*' | tr '\n' ' ') == "host-gw user-admin " ]]
        [[ $(o11n search tunnel) == service-reverse-tunnel ]]
        [[ $(o11n get build-hosts) == gw ]]
        [[ $(o11n status --list host-gw | grep -E 'nix-daemon|submission' | tr '\n' ' ') == "host-gw nix-daemon host-gw submission mail.example.com " ]]
        [[ $(o11n status --list host-web | grep nix-daemon) == "host-web nix-daemon" ]]
        [[ -f $org/$(o11n path public-key host-gw ssh-key) && -f $org/$(o11n path sops-file user-admin) ]]
        [[ -f $org/$(o11n path identity user-admin) ]]
        diff <(o11n sops-yaml service-nix-remote) - <<EOF
        creation_rules:
          - path_regex: enc/service-nix-remote.yaml
            key_groups:
              - age:
                - $(cat $org/public-keys/host-gw-age-key.pub)
                - $(cat $org/public-keys/root-1-age-key.pub)
                - $(cat $org/public-keys/service-nix-remote-age-key.pub)
        EOF
        ! o11n entities user-nobody
        touch $out
      '';

  # Policy: a router is checked by what o11n has it run, and what it derives from the hosts behind it.
  o11nChecks.eval-o11n-mesh =
    pkgs.runCommand "eval-o11n-mesh"
      {
        nativeBuildInputs = [ o11n ];
        export = builtins.toFile "export.json" (builtins.toJSON inventories.mesh.org.export);
        org = ./inventories/mesh;
      }
      ''
        export O11N_EXPORT=$export O11N_ORG_ROOT=$org
        diff <(o11n status --list host-windsor | grep -Ev ' (identity|recipients|secrets|public-key .*|secret .*)$') - <<EOF
        org o11n
        host-windsor openwrt
        host-windsor lan alpha
        host-windsor lan beta
        host-windsor glesys alpha.example.com
        host-windsor glesys beta.example.com
        EOF
        touch $out
      '';

  # Policy: the router's script, run twice on a router's own UCI, changes what the org says, keeps the rest, and puts
  # o11n's sections after the router's own, in place of those it named before.
  openwrtChecks.eval-openwrt-mesh =
    pkgs.runCommand "eval-openwrt-mesh"
      {
        nativeBuildInputs = [ pkgs.uci ];
        script = inventories.mesh.org.host.windsor.openwrt.files."/etc/o11n/uci";
      }
      ''
        mkdir -p bin config delta
        printf '#!/bin/sh\nexec %s -c %s -t %s "$@"\n' "$(command -v uci)" "$PWD/config" "$PWD/delta" > bin/uci
        chmod +x bin/uci
        export PATH=$PWD/bin:$PATH
        printf "config system\n\toption hostname 'OpenWrt'\n\toption timezone 'GMT0'\n" > config/system
        printf "config dropbear\n\toption PasswordAuth 'on'\n" > config/dropbear
        printf "config dnsmasq\n\toption domain 'lan'\n\nconfig host 'o11n_gone'\n\toption ip '192.168.1.9'\n" > config/dhcp
        printf "config defaults\n\toption input 'REJECT'\n\nconfig redirect 'o11n_dmz'\n\toption dest_ip '192.168.1.9'\n\nconfig zone\n\toption name 'wan'\n" > config/firewall
        printf "config interface 'lan'\n\toption device 'br-lan'\n\tlist ipaddr '192.168.2.1/24'\n" > config/network
        printf "config wifi-device 'radio0'\n\toption disabled '1'\n\nconfig wifi-iface 'default_radio0'\n\toption ssid 'OpenWrt'\n\toption encryption 'none'\n" > config/wireless
        sed 's/@o11n-secret:wifi-key@/swordfish/' <<<"$script" > apply
        sh apply
        cp -r config once
        sh apply
        diff -r once config
        diff <(uci show dhcp; uci show dropbear; uci show network; uci show system; uci show wireless) - <<'EOF'
        dhcp.@dnsmasq[0]=dnsmasq
        dhcp.@dnsmasq[0].domain='lan'
        dhcp.o11n_alpha=host
        dhcp.o11n_alpha.ip='192.168.1.11'
        dhcp.o11n_alpha.mac='02:00:00:00:00:01'
        dhcp.o11n_alpha.name='alpha'
        dhcp.o11n_beta=host
        dhcp.o11n_beta.ip='192.168.1.12'
        dhcp.o11n_beta.name='beta'
        dropbear.@dropbear[0]=dropbear
        dropbear.@dropbear[0].PasswordAuth='0'
        dropbear.@dropbear[0].Port='22'
        dropbear.@dropbear[0].RootPasswordAuth='0'
        network.lan=interface
        network.lan.device='br-lan'
        network.lan.ipaddr='192.168.1.1/24'
        system.@system[0]=system
        system.@system[0].hostname='windsor'
        system.@system[0].timezone='GMT0'
        system.@system[0].zonename='UTC'
        wireless.radio0=wifi-device
        wireless.radio0.disabled='0'
        wireless.default_radio0=wifi-iface
        wireless.default_radio0.ssid='windsor'
        wireless.default_radio0.encryption='psk2'
        wireless.default_radio0.key='swordfish'
        EOF
        diff <(uci show firewall | grep -E '^firewall\.[^.]+=') - <<'EOF'
        firewall.@defaults[0]=defaults
        firewall.@zone[0]=zone
        firewall.o11n_alpha_wg0=redirect
        firewall.o11n_alpha_wg0_6=rule
        firewall.o11n_alpha_wg1=redirect
        firewall.o11n_alpha_wg1_6=rule
        firewall.o11n_beta_wg1=redirect
        firewall.o11n_beta_wg1_6=rule
        firewall.o11n_dmz=redirect
        EOF
        grep -qx "$(printf "\tlist ipaddr '192.168.1.1/24'")" config/network
        touch $out
      '';

  # Policy: a WordPress jail's filter is checked against what nginx logs, run with the host's own log format: a failed
  # login, one answered under load and a POST to xmlrpc.php, however many its slashes, are matched, a login, a GET and
  # another app's requests aren't.
  fail2banChecks.eval-fail2ban-wordpress =
    let
      inherit
        (inventories.mail.nixosConfigurations.web.extendModules {
          modules = [ { services.fail2ban.enable = true; } ];
        })
        config
        ;
    in
    pkgs.runCommand "eval-fail2ban-wordpress"
      {
        nativeBuildInputs = [
          pkgs.curl
          pkgs.fail2ban
          pkgs.nginx
        ];
        filter = config.environment.etc."fail2ban/filter.d/wordpress-blog.conf".source;
        http = builtins.toFile "http.conf" config.services.nginx.commonHttpConfig;
      }
      ''
        sed "s#/var/log/nginx/access.log#$PWD/access.log#" "$http" > http.conf
        cat > nginx.conf <<EOF
        pid $PWD/nginx.pid;
        error_log $PWD/error.log;
        events {}
        http {
          include $PWD/http.conf;
          client_body_temp_path $PWD;
          server {
            listen 127.0.0.1:8080;
            location = /wp-login.php {
              if (\$arg_ok) { return 302 /; }
              if (\$arg_busy) { return 503; }
              return 200;
            }
            location = /xmlrpc.php { return 405; }
          }
        }
        EOF
        nginx -p "$PWD" -e "$PWD/error.log" -c "$PWD/nginx.conf"
        request() { curl -s -o /dev/null -H "Host: $1" "''${@:3}" "http://127.0.0.1:8080$2"; }
        request www.example.org /wp-login.php -d log=alice
        request www.example.org '/wp-login.php?ok=1' -d log=alice
        request www.example.org '/wp-login.php?busy=1' -d log=alice
        request www.example.org //xmlrpc.php -d '<methodCall/>'
        request www.example.org /wp-login.php
        request example.net /wp-login.php -d log=alice
        kill "$(cat nginx.pid)"
        fail2ban-regex access.log "$filter" | grep -x 'Lines: 6 lines, 0 ignored, 3 matched, 3 missed'
        touch $out
      '';

  leakPatterns = [
    "kompismoln"
    "ahbk"
    "helsinki"
    "stationary"
    "pelle"
    "malborg"
    "\\.km[0-9]*"
  ];

  hostChecks = lib.concatMapAttrs (
    inventory: outputs:
    lib.mapAttrs' (
      host: nixos:
      let
        name = "leaks-${inventory}-${host}";
      in
      lib.nameValuePair name (
        pkgs.runCommand name
          {
            drv = builtins.unsafeDiscardOutputDependency nixos.config.system.build.toplevel.drvPath;
          }
          ''
            bash ${./leaks.sh} ${builtins.storeDir} "$drv" ${lib.escapeShellArgs leakPatterns} > $out
          ''
      )
    ) outputs.nixosConfigurations
  ) inventories;

  # Policy: a stick goes where it's needed and can be lost there, so nothing of the inventory's
  # may be on it but the public keys it reads.
  rescueUsb = evalNixosModule [
    ../nixos/org/rescue-usb.nix
    {
      _module.args.org = inventories.sample.org;
      o11n.rescue-usb.via = "gw";
    }
  ];

  rescueUsbChecks.leaks-sample-rescue-usb =
    pkgs.runCommand "leaks-sample-rescue-usb"
      {
        drv = builtins.unsafeDiscardOutputDependency rescueUsb.system.build.images.iso-installer.drvPath;
      }
      ''
        bash ${./leaks.sh} ${builtins.storeDir} "$drv" AGE-SECRET-KEY 'ENC\[AES256_GCM' > $out
      '';
in
{
  eval =
    nixosChecks // inventoryChecks // homeChecks // o11nChecks // openwrtChecks // fail2banChecks;
  leaks = hostChecks // rescueUsbChecks;
}
// lib.mapAttrs (name: check: { ${name} = check; }) (
  import ./source.nix {
    inherit pkgs o11n o11n-dev;
    testExport = builtins.toFile "org-export.json" (
      builtins.toJSON (o11nLib.fromInventory { path = ../crates/o11n/test; }).org.export
    );
  }
)
