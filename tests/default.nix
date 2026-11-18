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
        dropbear.@dropbear[0].Interface='lan'
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

  # Policy: the router's GleSYS updater writes its WAN address to each A record and the prefix it delegates to its lan
  # with a host's suffix to each AAAA record, but for those that have it already, in whatever form.
  openwrtChecks.eval-openwrt-glesys =
    pkgs.runCommand "eval-openwrt-glesys"
      {
        nativeBuildInputs = [ pkgs.ucode ];
        script = inventories.mesh.org.host.windsor.openwrt.files."/etc/o11n/glesys";
      }
      ''
        mkdir bin
        cat > bin/ifstatus <<'EOF'
        #!/bin/sh
        case $1 in
        wan) echo '{ "ipv4-address": [ { "address": "203.0.113.7", "mask": 24 } ] }' ;;
        wan6) echo '{ "ipv6-prefix": [ { "address": "2001:db8:0:9d00::", "mask": 56, "assigned": { "lan": { "address": "2001:db8:0:9d00::", "mask": 60 } } } ] }' ;;
        *) exit 1 ;;
        esac
        EOF
        cat > bin/uclient-fetch <<'EOF'
        #!/bin/sh
        for arg; do case $arg in --post-data=*) data=''${arg#--post-data=} ;; esac; done
        echo "''${arg##*/} $data" >> "$PWD/calls"
        case $* in
        */listrecords) cat <<'JSON'
        { "response": { "records": [
          { "recordid": 1, "host": "alpha", "type": "A", "data": "198.51.100.1" },
          { "recordid": 2, "host": "alpha", "type": "AAAA", "data": "2001:db8:0:9d00::fba" },
          { "recordid": 3, "host": "beta", "type": "A", "data": "203.0.113.7" },
          { "recordid": 4, "host": "beta", "type": "AAAA", "data": "2001:0db8:0000:9d00:0000:0000:0000:000b" },
          { "recordid": 5, "host": "gamma", "type": "AAAA", "data": "2001:db8::1" }
        ] } }
        JSON
        ;;
        esac
        EOF
        printf '#!/bin/sh\nshift 2\necho "$*" >> "$PWD/log"\n' > bin/logger
        chmod +x bin/*
        export PATH=$PWD/bin:$PATH
        sh -c "$script"
        diff calls - <<'EOF'
        listrecords domainname=example.com
        updaterecord recordid=1&data=203.0.113.7
        updaterecord recordid=2&data=2001:db8:0:9d00::a
        EOF
        diff log - <<'EOF'
        alpha.example.com A is 203.0.113.7, was 198.51.100.1
        alpha.example.com AAAA is 2001:db8:0:9d00::a, was 2001:db8:0:9d00::fba
        EOF
        touch $out
      '';

  # Policy: a WordPress jail's filter is checked against what nginx logs, run with the host's own log format: a failed
  # login, one answered under load, a POST to xmlrpc.php, however many its slashes, and a login at an altpoint are
  # matched, a login, a GET and another app's requests aren't.
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
        request example.org /wp-login.php -d log=alice
        request example.net /wp-login.php -d log=alice
        kill "$(cat nginx.pid)"
        fail2ban-regex access.log "$filter" | grep -x 'Lines: 7 lines, 0 ignored, 4 matched, 3 missed'
        touch $out
      '';

  # Policy: a WordPress site's server, as the host's nginx runs it, passes WordPress's entry points to PHP, which isn't
  # there to answer (502), and denies PHP it only includes, PHP in uploads and dotfiles (403).
  # Policy: the portal lists the apps it names, in its order, described in each language, under the content's headings
  # or its own, shows a page without a title as a note, with the commit it names, and logs in with the client its
  # keycloak keeps.
  portalChecks.eval-portal-mail =
    let
      inherit (inventories.mail.nixosConfigurations.web) config;
    in
    pkgs.runCommand "eval-portal-mail"
      {
        nativeBuildInputs = [ pkgs.jq ];
        site = config.services.nginx.virtualHosts."www.example.com".root;
        clients = config.systemd.services.keycloak-realms.environment.CLIENTS;
      }
      ''
        listed() { grep -o 'card-\(title\|url\)">[^<]*' "$site/$1" | cut -d'>' -f2 | tr '\n' ' '; }
        [[ $(listed index.html) == "Moln cloud.example.com Möten meet.example.com auth auth.example.com " ]]
        [[ $(listed en/index.html) == "Cloud cloud.example.com meet meet.example.com auth auth.example.com " ]]
        grep -qF '<h2>Det vi har</h2>' "$site/index.html" && grep -qF '<h2>Vill du vara med?</h2>' "$site/index.html"
        grep -qF '<h2>Services</h2>' "$site/en/index.html" && grep -qF '<h2>Want an account?</h2>' "$site/en/index.html"
        grep -qF '"clientId":"www","issuer":"http://auth.example.com/realms/example"' "$site/index.html"
        grep -qF 'href="http://www.example.com/en/blog/first/"' "$site/en/index.html"
        [[ $(grep -c 'class="note"' "$site/en/index.html") == 2 && $(grep -c 'class="note"' "$site/notes/index.html") == 2 ]]
        grep -qF 'href="https://github.com/Kompismoln/o11n/commit/72f009123e7ea8e47d64f8c2984a5bb2e0365ae2"' "$site/notes/rescue/index.html"
        grep -qF '<code>72f0091</code>' "$site/en/notes/index.html"
        ! grep -qF 'note-commit' "$site/en/notes/hello/index.html" || exit 1
        grep -qF '<title>Test AB</title>' "$site/en/atom.xml"
        grep -qF '<a href="http://status.example.com">Driftstatus</a>' "$site/index.html"
        grep -qF '<title>A note without a commit.</title>' "$site/en/atom.xml"
        grep -qF '<a href="http://www.example.com/policy/">Villkor</a>' "$site/index.html"
        ! grep -qF 'href="http://www.example.com/en/policy/"' "$site/en/index.html"
        jq -e '.[] | select(.representation.clientId == "www") | .realm == "example" and .representation.publicClient
          and .representation.redirectUris == ["http://www.example.com/*"]' <<<"$clients"
        touch $out
      '';

  nginxChecks.eval-nginx-wordpress =
    let
      inherit (inventories.mail.nixosConfigurations.web) config;
    in
    pkgs.runCommand "eval-nginx-wordpress"
      {
        nativeBuildInputs = [
          pkgs.curl
          pkgs.nginx
        ];
        execStart = config.systemd.services.nginx.serviceConfig.ExecStart;
      }
      ''
        conf=$(grep -o "/nix/store/[^']*-nginx.conf" <<<"$execStart")
        awk '
          /^    server \{$/ { block = ""; inside = 1 }
          inside { block = block $0 "\n" }
          inside && /^    }$/ { if (block ~ /server_name www\.example\.org;/) printf "%s", block; inside = 0 }
        ' "$conf" |
          sed -E "/^ *listen /d; s#^( *)server \{#\1server {\n\1    listen 127.0.0.1:8080;#; s#^( *)root [^;]*;#\1root $PWD/root;#" > server.conf
        grep -q 'fastcgi_pass' server.conf
        cat > nginx.conf <<EOF
        pid $PWD/nginx.pid;
        error_log $PWD/error.log;
        events {}
        http {
          access_log off;
          client_body_temp_path $PWD;
          include $PWD/server.conf;
        }
        EOF
        for file in index.php wp-login.php wp-admin/admin-ajax.php wp-includes/js/tinymce/wp-tinymce.php \
          wp-content/plugins/plugin/plugin.php wp-config-sample.php wp-admin/includes/admin.php wp-includes/version.php \
          wp-includes/theme-compat/header.php wp-content/themes/theme/functions.php wp-content/uploads/shell.php \
          wp-content/uploads/2026/shell.PHP .shell.php; do
          mkdir -p "root/$(dirname "$file")"
          touch "root/$file"
        done
        nginx -p "$PWD" -e "$PWD/error.log" -c "$PWD/nginx.conf"
        status() { curl -s -o /dev/null -w '%{http_code}' -H 'Host: www.example.org' "http://127.0.0.1:8080$1"; }
        expect() {
          local want=$1 path
          shift
          for path; do
            got=$(status "$path")
            [ "$got" = "$want" ] || { echo "$path: $got, not $want"; failed=1; }
          done
        }
        failed=
        expect 502 / /index.php /wp-login.php /wp-admin/admin-ajax.php /wp-includes/js/tinymce/wp-tinymce.php \
          /wp-content/plugins/plugin/plugin.php
        expect 403 /wp-config-sample.php /wp-admin/includes/admin.php /wp-includes/version.php \
          /wp-includes/theme-compat/header.php /wp-content/themes/theme/functions.php /wp-content/uploads/shell.php \
          /wp-content/uploads/2026/shell.PHP /.shell.php /xmlrpc.php
        kill "$(cat nginx.pid)"
        [ -z "$failed" ]
        touch $out
      '';

  # Policy: a mobilizon jail's filter is checked against what nginx logs, run with the host's own log format: a profile
  # or a webfinger not found is matched, one found, a POST, another 404 and another app's requests aren't.
  fail2banChecks.eval-fail2ban-mobilizon =
    let
      inherit
        (inventories.mail.nixosConfigurations.web.extendModules {
          modules = [ { services.fail2ban.enable = true; } ];
        })
        config
        ;
    in
    pkgs.runCommand "eval-fail2ban-mobilizon"
      {
        nativeBuildInputs = [
          pkgs.curl
          pkgs.fail2ban
          pkgs.nginx
        ];
        filter = config.environment.etc."fail2ban/filter.d/mobilizon-calendar.conf".source;
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
            location = /@alice { return 200; }
            location / { return 404; }
          }
        }
        EOF
        nginx -p "$PWD" -e "$PWD/error.log" -c "$PWD/nginx.conf"
        request() { curl -s -o /dev/null -H "Host: $1" "''${@:3}" "http://127.0.0.1:8080$2"; }
        request example.net /@bob
        request example.net /@carol/events -I
        request example.net '/.well-known/webfinger?resource=acct:dave@example.net'
        request example.net /@alice
        request example.net /@bob/inbox -d '{}'
        request example.net /events/nobody
        request www.example.org /@bob
        kill "$(cat nginx.pid)"
        fail2ban-regex access.log "$filter" | grep -x 'Lines: 7 lines, 0 ignored, 3 matched, 4 missed'
        touch $out
      '';

  # Policy: every host of every inventory instantiates, a job each, so that nix-eval-jobs spreads them over its workers.
  hostChecks = lib.concatMapAttrs (
    inventory: outputs:
    lib.mapAttrs' (
      host: nixos:
      let
        name = "eval-system-${inventory}-${host}";
      in
      lib.nameValuePair name (
        pkgs.runCommand name {
          drv = builtins.unsafeDiscardOutputDependency nixos.config.system.build.toplevel.drvPath;
        } "touch $out"
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

  systemChecks = hostChecks // {
    eval-rescue-usb-leaks =
      pkgs.runCommand "eval-rescue-usb-leaks"
        {
          drv = builtins.unsafeDiscardOutputDependency rescueUsb.system.build.images.iso-installer.drvPath;
        }
        ''
          bash ${./leaks.sh} ${builtins.storeDir} "$drv" AGE-SECRET-KEY 'ENC\[AES256_GCM' > $out
        '';
  };
in
{
  eval =
    nixosChecks
    // inventoryChecks
    // homeChecks
    // o11nChecks
    // openwrtChecks
    // fail2banChecks
    // nginxChecks
    // portalChecks
    // systemChecks;
}
// lib.mapAttrs (name: check: if lib.isDerivation check then { ${name} = check; } else check) (
  import ./source.nix {
    inherit pkgs o11n o11n-dev;
    testExport = builtins.toFile "org-export.json" (
      builtins.toJSON (o11nLib.fromInventory { path = ../crates/o11n/test; }).org.export
    );
  }
)
