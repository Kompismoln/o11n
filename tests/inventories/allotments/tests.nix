{
  lib,
  o11nLib,
  outputs,
}:
let
  inherit (outputs.nixosConfigurations) zhost laptop;

  deviceId =
    host: lib.trim (builtins.readFile ./public-keys/host-${host}-syncthing-user-alice.zhost.pub);

  # Accommodating for the inventory, which has to evaluate: what would fail is evaluated from an altered copy of its spec.
  alter =
    change:
    o11nLib.evalContext {
      path = ./.;
      flake = {
        outPath = ./.;
        inputs = { };
      };
      spec = lib.recursiveUpdate outputs.context.spec change;
    };

  failing =
    config:
    map (assertion: assertion.message) (
      lib.filter (
        assertion: !assertion.assertion && lib.hasPrefix "allotment." assertion.message
      ) config.assertions
    );
in
{
  test_records = {
    expr = lib.mapAttrs (_: allotment: {
      inherit (allotment)
        entity
        host
        size
        path
        ;
    }) outputs.org.allotment;
    expected = {
      "service-torrent-server@zhost" = {
        entity = "service-torrent-server";
        host = "zhost";
        size = "500G";
        path = "/srv/allotments/service-torrent-server";
      };
      "store-files@zhost" = {
        entity = "store-files";
        host = "zhost";
        size = "1T";
        path = "/srv/allotments/store-files";
      };
      "user-alice@zhost" = {
        entity = "user-alice";
        host = "zhost";
        size = "40G";
        path = "/srv/allotments/user-alice";
      };
    };
  };

  # Policy: under the host's storage dataset, owned by the principal's uid, though it isn't on the host.
  test_zfs_allotments = {
    expr = zhost.config.o11n.allotments;
    expected = {
      service-torrent-server = {
        dataset = "zroot/srv/storage/allotments/service-torrent-server";
        size = "500G";
        path = "/srv/allotments/service-torrent-server";
        uid = 2000;
        gid = 2000;
        mode = "0750";
      };
      store-files = {
        dataset = "zroot/srv/storage/allotments/store-files";
        size = "1T";
        path = "/srv/allotments/store-files";
        uid = 4000;
        gid = 4000;
        mode = "0700";
      };
      user-alice = {
        dataset = "zroot/srv/storage/allotments/user-alice";
        size = "40G";
        path = "/srv/allotments/user-alice";
        uid = 1000;
        gid = 1000;
        mode = "0700";
      };
    };
  };

  test_zfs_units = {
    expr = lib.filter (lib.hasPrefix "allotment@") (lib.attrNames zhost.config.systemd.services);
    expected = [
      "allotment@service-torrent-server"
      "allotment@store-files"
      "allotment@user-alice"
    ];
  };

  test_passes = {
    expr = map (host: failing host.config) [
      zhost
      laptop
    ];
    expected = [
      [ ]
      [ ]
    ];
  };

  # Policy: the principal has an account where it has an allotment but isn't, and nowhere else.
  test_accounts = {
    expr = {
      alice = zhost.config.users.users.alice.uid;
      files = zhost.config.users.users.files.uid;
      laptop = laptop.config.users.users ? files;
    };
    expected = {
      alice = 1000;
      files = 4000;
      laptop = false;
    };
  };

  # Policy: each side syncs by its own device ID and the other's, as o11n wrote them, over the vpn they share.
  test_sync = {
    expr = {
      zhost = zhost.config.o11n.allotment-sync;
      laptop = laptop.config.o11n.allotment-sync;
      firewall = lib.elem 23000 zhost.config.networking.firewall.interfaces.wg0.allowedTCPPorts;
    };
    expected = {
      zhost."user-alice.zhost" = {
        desktop = null;
        folder = "/srv/allotments/user-alice";
        state = "/srv/storage/var/lib/allotment-sync/user-alice.zhost";
        changes = "/run/allotment-changes/user-alice.zhost";
        user = "alice";
        group = "alice";
        secret = "/run/secrets/syncthing-user-alice.zhost";
        listen = [ "tcp://[fd12:3456:7890:0000::0001]:23000" ];
        self = {
          id = deviceId "zhost";
          name = "zhost";
          addresses = [ ];
        };
        peers = [
          {
            id = deviceId "laptop";
            name = "laptop";
            addresses = [ ];
          }
        ];
        after = [ "allotment@user-alice.service" ];
        wants = [ "systemd-networkd-wait-online@wg0.service" ];
      };
      laptop."user-alice.zhost" = {
        desktop = null;
        folder = "/home/alice/.o11n/allotments/zhost";
        state = "/home/alice/.o11n/syncthing/zhost";
        changes = null;
        user = "alice";
        group = "alice";
        secret = "/run/secrets/syncthing-user-alice.zhost";
        listen = [ ];
        self = {
          id = deviceId "laptop";
          name = "laptop";
          addresses = [ ];
        };
        peers = [
          {
            id = deviceId "zhost";
            name = "zhost";
            addresses = [ "tcp://[fd12:3456:7890:0000::0001]:23000" ];
          }
        ];
        after = [ ];
        wants = [ ];
      };
      firewall = true;
    };
  };

  test_no_sync_without_replicas = {
    expr =
      zhost.config.o11n.allotment-sync ? "store-files.zhost"
      || outputs.org.host.zhost.keys ? "syncthing-store-files.zhost";
    expected = false;
  };

  # Policy: an allotment lets each of its sftp in from each host it's on, over the vpn that host shares with its own.
  test_sftp_logins = {
    expr = lib.mapAttrs (
      _:
      lib.mapAttrs (
        _: login:
        login
        // {
          key = builtins.readFile login.key;
          changes = login.changes // {
            hostKey = builtins.readFile login.changes.hostKey;
          };
        }
      )
    ) outputs.org.allotment."user-alice@zhost".logins;
    expected.app-cloud.laptop = {
      address = "fd12:3456:7890:0000::0001";
      address4 = "10.0.0.1";
      from = [
        "fd12:3456:7890:0000::0002/128"
        "10.0.0.2/32"
      ];
      login = "alice";
      chroot = "/srv/allotments";
      root = "/user-alice";
      key = builtins.readFile ./public-keys/app-cloud-sftp-key.pub;
      changes = {
        login = "allotment-changes";
        id = "user-alice.zhost";
        hostKey = builtins.readFile ./public-keys/host-zhost-ssh-key.pub;
      };
    };
  };

  # Policy: the allotment's host records what its replicas change in it while a client of its sftp follows it, which
  # logs in as allotment-changes with its sftp-key, from its host alone, to follow that and nothing else.
  test_changes_followed =
    let
      inherit (zhost.config) o11n systemd users;
      relay = systemd.services."allotment-changes@user-alice.zhost";
    in
    {
      expr = {
        inherit (o11n.allotment-sync."user-alice.zhost") changes;
        inherit (relay) bindsTo;
        inherit (relay.serviceConfig) User;
        keys = map (builtins.match ''from="([^"]*)",restrict,command="[^ ]*/allotment-changes ([^"]*)" (.*)'') users.users.allotment-changes.openssh.authorizedKeys.keys;
      };
      expected = {
        changes = "/run/allotment-changes/user-alice.zhost";
        bindsTo = [ "allotment-sync@user-alice.zhost.service" ];
        User = "alice";
        keys = [
          [
            "fd12:3456:7890:0000::0002/128,10.0.0.2/32"
            "user-alice.zhost"
            (lib.trim (builtins.readFile ./public-keys/app-cloud-sftp-key.pub))
          ]
        ];
      };
    };

  # Policy: nextcloud mounts an allotment at its folder, for its user, as the allotment's login for the app has it, with
  # the app's sftp-key, and an sftp server with its key's, for a user the org needn't have.
  test_nextcloud_mounts = {
    expr = lib.mapAttrs (
      _:
      map (
        mount:
        lib.recursiveUpdate mount {
          key.publicKey = builtins.readFile mount.key.publicKey;
          key.secret.sopsFile = baseNameOf mount.key.secret.sopsFile;
        }
        // {
          server = mount.server // {
            changes = lib.mapNullable (
              changes: changes // { hostKey = builtins.readFile changes.hostKey; }
            ) mount.server.changes;
          };
        }
      )
    ) outputs.org.app.cloud.nextcloud.mounts;
    expected.laptop = [
      {
        mountPoint = "/zhost";
        user = "alice";
        sharing = true;
        server = {
          host = "10.0.0.1";
          login = "alice";
          root = "/user-alice";
          changes = {
            login = "allotment-changes";
            id = "user-alice.zhost";
            hostKey = builtins.readFile ./public-keys/host-zhost-ssh-key.pub;
          };
        };
        key = {
          handle = "app-cloud";
          secret = {
            name = "cloud/sftp-key";
            sopsFile = "app-cloud.yaml";
          };
          publicKey = builtins.readFile ./public-keys/app-cloud-sftp-key.pub;
        };
      }
      {
        mountPoint = "/files";
        user = "lisa";
        sharing = false;
        server = {
          host = "files.example.com";
          login = "lisa";
          root = "/";
          changes = null;
        };
        key = {
          handle = "store-files";
          secret = {
            name = "files/sftp-key";
            sopsFile = "store-files.yaml";
          };
          publicKey = builtins.readFile ./public-keys/store-files-sftp-key.pub;
        };
      }
    ];
  };

  # Policy: an entity has an sftp-key while a mount logs in with it, and the key names one of the org's entities.
  test_nextcloud_sftp_keys =
    let
      sftp = {
        host = "files.example.com";
        login = "lisa";
      };
      evaluates =
        external:
        (builtins.tryEval (
          builtins.deepSeq
            (alter { app.cloud.nextcloud = { inherit external; }; }).org.app.cloud.nextcloud.mounts.laptop
            true
        )).success;
    in
    {
      expr = {
        store = outputs.org.store.files.keys.sftp-key or null;
        app =
          (o11nLib.evalContext {
            path = ./.;
            flake = {
              outPath = ./.;
              inputs = { };
            };
            spec =
              let
                inherit (outputs.context) spec;
                inherit (spec.app) cloud;
              in
              lib.recursiveUpdate spec {
                allotment."user-alice@zhost".sftp = [ ];
                allotment."service-torrent-server@zhost".sftp = [ ];
              }
              // {
                app = spec.app // {
                  cloud = cloud // {
                    nextcloud = cloud.nextcloud // {
                      external = { inherit (cloud.nextcloud.external) lisa; };
                    };
                  };
                };
              };
          }).org.app.cloud.keys
            ? sftp-key;
        unknown = evaluates {
          lisa.files.sftp = sftp // {
            key = "store-nobody";
          };
        };
      };
      expected = {
        store = "ssh-rsa";
        app = false;
        unknown = false;
      };
    };

  # Policy: an external storage reaches an allotment or any other sftp server, one of them, and is at its folder for
  # its user alone, so that another user can have a folder of the same name.
  test_nextcloud_mounts_any_sftp =
    let
      mounts =
        external:
        let
          tried = builtins.tryEval (
            builtins.deepSeq
              (alter { app.cloud.nextcloud = { inherit external; }; }).org.app.cloud.nextcloud.mounts.laptop
              (alter { app.cloud.nextcloud = { inherit external; }; }).org.app.cloud.nextcloud.mounts.laptop
          );
        in
        if tried.success then
          map (mount: {
            inherit (mount) mountPoint user;
            inherit (mount.server) host;
          }) tried.value
        else
          null;
      sftp = {
        host = "files.example.com";
        login = "archive";
      };
    in
    {
      expr = {
        other = mounts {
          alice.files = { inherit sftp; };
          bob.zhost = { inherit sftp; };
        };
        both = mounts {
          alice.files = {
            allotment = "user-alice@zhost";
            inherit sftp;
          };
        };
        neither = mounts { alice.files = { }; };
      };
      expected = {
        other = [
          {
            mountPoint = "/files";
            user = "alice";
            host = "files.example.com";
          }
          {
            mountPoint = "/zhost";
            user = "alice";
            host = "10.0.0.1";
          }
          {
            mountPoint = "/zhost";
            user = "bob";
            host = "files.example.com";
          }
          {
            mountPoint = "/files";
            user = "lisa";
            host = "files.example.com";
          }
        ];
        both = null;
        neither = null;
      };
    };

  test_nextcloud_reaches_an_allotment_by_its_sftp_alone = {
    expr =
      (builtins.tryEval (
        builtins.deepSeq
          (alter { allotment."user-alice@zhost".sftp = [ ]; }).org.app.cloud.nextcloud.mounts.laptop
          true
      )).success;
    expected = false;
  };

  # Policy: the allotment's host lets the client's sftp-key in as the principal from the client's host alone, to sftp
  # jailed to the allotments.
  test_sftp_logs_in = {
    expr = {
      keys = zhost.config.users.users.alice.openssh.authorizedKeys.keys;
      match =
        lib.elem
          ''
            Match User alice Address fd12:3456:7890:0000::0002/128,10.0.0.2/32
              ChrootDirectory /srv/allotments
              ForceCommand internal-sftp -d /user-alice
          ''
          (
            map (block: "Match ${lib.concatStringsSep "\n" (lib.take 3 (lib.splitString "\n" block))}\n") (
              lib.splitString "Match " zhost.config.services.openssh.extraConfig
            )
          );
      failing = failing zhost.config;
      hostKeys = map (key: key.type) zhost.config.services.openssh.hostKeys;
      elsewhere = map (key: key.type) laptop.config.services.openssh.hostKeys;
      macs = zhost.config.services.openssh.settings.Macs;
      macsElsewhere = laptop.config.services.openssh.settings.Macs;
    };
    expected = {
      keys = [
        ''from="fd12:3456:7890:0000::0002/128,10.0.0.2/32",restrict ${lib.trim (builtins.readFile ./public-keys/app-cloud-sftp-key.pub)}''
      ];
      match = true;
      failing = [ ];
      hostKeys = [
        "ed25519"
        "rsa"
      ];
      elsewhere = [ "ed25519" ];
      macs = [
        "hmac-sha2-512-etm@openssh.com"
        "hmac-sha2-256-etm@openssh.com"
        "umac-128-etm@openssh.com"
        "hmac-sha2-256"
      ];
      macsElsewhere = [
        "hmac-sha2-512-etm@openssh.com"
        "hmac-sha2-256-etm@openssh.com"
        "umac-128-etm@openssh.com"
      ];
    };
  };

  test_an_sftp_client_has_an_sftp_key = {
    expr = outputs.org.app.cloud.keys.sftp-key;
    expected = "ssh-rsa";
  };

  # Policy: where Cinnamon runs, a replica is on its principal's Desktop as the org, by its logo, badged as it syncs; a logo
  # that isn't in the org fails evaluation.
  test_replica_on_the_desktop =
    let
      cinnamon = {
        services.xserver.desktopManager.cinnamon.enable = true;
      };
      themed =
        (o11nLib.mkNixosConfigurations (alter {
          theme = {
            wallpaper = "assets/logo.svg";
            logo = "assets/logo.svg";
            fonts = { };
          };
        })).laptop.extendModules
          { modules = [ cinnamon ]; };
      plain = laptop.extendModules { modules = [ cinnamon ]; };
      unit = themed.config.systemd.user.services."allotment-desktop@user-alice.zhost";
    in
    {
      expr = {
        themed = themed.config.o11n.allotment-sync."user-alice.zhost".desktop.name;
        icon = lib.hasSuffix "/assets/logo.svg" (
          toString themed.config.o11n.allotment-sync."user-alice.zhost".desktop.icon
        );
        plain = plain.config.o11n.allotment-sync."user-alice.zhost".desktop;
        withoutCinnamon = laptop.config.o11n.allotment-sync."user-alice.zhost".desktop;
        missing =
          (builtins.tryEval
            (alter {
              theme = {
                wallpaper = "assets/logo.svg";
                logo = "assets/missing.svg";
                fonts = { };
              };
            }).org.theme.logo
          ).success;
        inherit (unit) wantedBy;
        user = unit.unitConfig.ConditionUser;
        script = lib.all (part: lib.hasInfix part unit.script) [
          ''link="$HOME/Desktop/Test AB"''
          "ln -s /home/alice/.o11n/allotments/zhost"
          "metadata::custom-icon"
          "allotment-sync-status user-alice.zhost"
        ];
      };
      expected = {
        themed = "Test AB";
        icon = true;
        plain = {
          name = "Test AB";
          icon = null;
        };
        withoutCinnamon = null;
        missing = false;
        wantedBy = [ "default.target" ];
        user = "alice";
        script = true;
      };
    };

  # Policy: the host has one RSA host key and one MAC more however many sftp logins it has, and sops imports neither
  # host key.
  test_sftp_host_keys_once =
    let
      inherit
        ((o11nLib.mkNixosConfigurations (alter {
          allotment."store-files@zhost".sftp = [ "app-cloud" ];
        })).zhost
        )
        config
        ;
    in
    {
      expr = {
        logins = lib.length (
          lib.filter (line: lib.hasPrefix "Match User" line && lib.hasInfix " Address " line) (
            lib.splitString "\n" config.services.openssh.extraConfig
          )
        );
        hostKeys = map (key: key.type) config.services.openssh.hostKeys;
        macs = lib.count (mac: mac == "hmac-sha2-256") config.services.openssh.settings.Macs;
        sops = config.sops.gnupg.sshKeyPaths ++ config.sops.age.sshKeyPaths;
      };
      expected = {
        logins = 3;
        hostKeys = [
          "ed25519"
          "rsa"
        ];
        macs = 1;
        sops = [ ];
      };
    };

  # Policy: the torrent server downloads into its allotment, once that's there, as the org limits it, and its ssh-key
  # runs its control alone, while an sftp client of the allotment logs in as its own login has it.
  test_torrent_server =
    let
      inherit (zhost.config) services systemd users;
      inherit (services.transmission) settings;
    in
    {
      expr = {
        inherit (services.transmission) user home openPeerPorts;
        settings = {
          inherit (settings)
            download-dir
            incomplete-dir-enabled
            peer-port
            rpc-bind-address
            speed-limit-up
            speed-limit-up-enabled
            speed-limit-down-enabled
            ratio-limit
            ratio-limit-enabled
            ;
        };
        inherit (systemd.services.transmission) requires;
        keys = map (
          key:
          let
            control = builtins.match ''restrict,command="[^ ]*/bin/torrent-server" (.*)'' key;
          in
          if control == null then "sftp" else lib.head control
        ) users.users.torrent-server.openssh.authorizedKeys.keys;
        inherit (users.users.torrent-server.openssh.authorizedKeys) keyFiles;
      };
      expected = {
        user = "torrent-server";
        home = "/srv/storage/var/lib/torrent-server";
        openPeerPorts = true;
        settings = {
          download-dir = "/srv/allotments/service-torrent-server";
          incomplete-dir-enabled = false;
          peer-port = 51413;
          rpc-bind-address = "127.0.0.1";
          speed-limit-up = 200;
          speed-limit-up-enabled = true;
          speed-limit-down-enabled = false;
          ratio-limit = 2;
          ratio-limit-enabled = true;
        };
        requires = [
          "allotment@service-torrent-server.service"
          "transmission-setup.service"
        ];
        keys = [
          "sftp"
          (lib.trim (builtins.readFile ./public-keys/service-torrent-server-ssh-key.pub))
        ];
        keyFiles = [ ];
      };
    };

  # Policy: a host with the torrent server and no allotment for it fails evaluation, saying which to add.
  test_torrent_server_needs_allotment =
    let
      inherit (outputs.context) spec;
      config =
        (o11nLib.mkNixosConfigurations (
          o11nLib.evalContext {
            path = ./.;
            flake = {
              outPath = ./.;
              inputs = { };
            };
            spec = spec // {
              allotment = removeAttrs spec.allotment [ "service-torrent-server@zhost" ];
            };
          }
        )).zhost.config;
    in
    {
      expr = {
        failing = map (assertion: assertion.message) (
          lib.filter (
            assertion: !assertion.assertion && lib.hasPrefix "service.torrent-server" assertion.message
          ) config.assertions
        );
        inherit (config.services.transmission) enable;
      };
      expected = {
        failing = [
          ''service.torrent-server on zhost: the server keeps what it downloads in an allotment of its own, and zhost has none: add allotment."service-torrent-server@zhost" with its size.''
        ];
        enable = false;
      };
    };

  # Policy: the media server keeps its state where the host keeps it, reads the torrent server's allotment as a member of
  # its group, and is reached at its own address on its vpn, on whose interface alone the firewall opens its port.
  test_media_server =
    let
      inherit (zhost.config)
        networking
        services
        systemd
        users
        ;
      address = outputs.org.vpn.wg0.members.media-server-zhost.address;
    in
    {
      expr = {
        inherit (services.jellyfin) user dataDir;
        members = users.groups.torrent-server.members;
        inherit (systemd.sockets.media-server) listenStreams;
        firewall = lib.mapAttrs (
          _: interface: lib.elem 8096 interface.allowedTCPPorts
        ) networking.firewall.interfaces;
        open = lib.elem 8096 networking.firewall.allowedTCPPorts;
        hosts = laptop.config.networking.hosts.${address};
      };
      expected = {
        user = "media-server";
        dataDir = "/srv/storage/var/lib/media-server";
        members = [
          "torrent-server"
          "media-server"
        ];
        listenStreams = [ "[${address}]:8096" ];
        firewall.wg0 = true;
        open = false;
        hosts = [ "media-server-zhost.allotments" ];
      };
    };
}
