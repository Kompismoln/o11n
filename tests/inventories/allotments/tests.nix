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
      store-files = {
        dataset = "zroot/srv/storage/allotments/store-files";
        size = "1T";
        path = "/srv/allotments/store-files";
        uid = 4000;
        gid = 4000;
      };
      user-alice = {
        dataset = "zroot/srv/storage/allotments/user-alice";
        size = "40G";
        path = "/srv/allotments/user-alice";
        uid = 1000;
        gid = 1000;
      };
    };
  };

  test_zfs_units = {
    expr = lib.filter (lib.hasPrefix "allotment@") (lib.attrNames zhost.config.systemd.services);
    expected = [
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
      firewall = zhost.config.networking.firewall.interfaces.wg0.allowedTCPPorts;
    };
    expected = {
      zhost."user-alice.zhost" = {
        folder = "/srv/allotments/user-alice";
        state = "/srv/storage/var/lib/allotment-sync/user-alice.zhost";
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
        folder = "/home/alice/.o11n/allotments/zhost";
        state = "/home/alice/.o11n/syncthing/zhost";
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
      firewall = [ 23000 ];
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
      _: lib.mapAttrs (_: login: login // { key = builtins.readFile login.key; })
    ) outputs.org.allotment."user-alice@zhost".logins;
    expected.app-cloud.laptop = {
      address = "fd12:3456:7890:0000::0001";
      from = "fd12:3456:7890:0000::0002";
      login = "alice";
      chroot = "/srv/allotments";
      root = "/user-alice";
      key = builtins.readFile ./public-keys/app-cloud-sftp-key.pub;
    };
  };

  # Policy: nextcloud mounts an allotment at its folder, for its user, as the allotment's login for the app has it.
  test_nextcloud_mounts = {
    expr = outputs.org.app.cloud.nextcloud.mounts;
    expected.laptop = [
      {
        mountPoint = "/zhost";
        user = "alice";
        sharing = true;
        server = {
          host = "[fd12:3456:7890:0000::0001]";
          login = "alice";
          root = "/user-alice";
        };
      }
    ];
  };

  # Policy: an external storage reaches an allotment or any other sftp server, one of them.
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
            host = "[fd12:3456:7890:0000::0001]";
          }
          {
            mountPoint = "/zhost";
            user = "bob";
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
            Match User alice Address fd12:3456:7890:0000::0002/128
              ChrootDirectory /srv/allotments
              ForceCommand internal-sftp -d /user-alice
          ''
          (
            map (block: "Match ${lib.concatStringsSep "\n" (lib.take 3 (lib.splitString "\n" block))}\n") (
              lib.splitString "Match " zhost.config.services.openssh.extraConfig
            )
          );
      failing = failing zhost.config;
    };
    expected = {
      keys = [
        ''from="fd12:3456:7890:0000::0002/128",restrict ${lib.trim (builtins.readFile ./public-keys/app-cloud-sftp-key.pub)}''
      ];
      match = true;
      failing = [ ];
    };
  };

  test_an_sftp_client_has_an_sftp_key = {
    expr = outputs.org.app.cloud.keys.sftp-key;
    expected = "ssh-rsa";
  };
}
