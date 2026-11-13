{
  app,
  config,
  context,
  lib,
  ...
}:
let
  inherit (context) org;

  storage = {
    options = {
      box = lib.mkOption {
        description = "the SMB share that is the user's data, their files, versions and trash, which the user's other storages are folders in, or null";
        type = lib.types.nullOr (lib.types.submodule home);
        default = null;
      };
      bind = lib.mkOption {
        description = "the directory on the app's hosts the storage is of, which nextcloud's user can write in, or null";
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      adapter = lib.mkOption {
        description = "the entity, by its handle, whose home is the user's data, as a box would be, which the app's hosts mount as nextcloud's user's and write in as the entity, or null";
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      allotment = lib.mkOption {
        description = "the allotment, as <handle>@<host>, the storage reaches over SFTP, whose `sftp` has to have the app, or null";
        type = lib.types.nullOr (lib.types.enum (lib.attrNames (context.spec.allotment or { })));
        default = null;
      };
      sftp = lib.mkOption {
        description = "the SFTP server the storage reaches, or null";
        type = lib.types.nullOr (
          lib.types.submodule {
            options = {
              host = lib.mkOption {
                description = "the server, as nextcloud takes it: a name, or an IPv6 address in brackets";
                type = lib.types.str;
              };
              login = lib.mkOption {
                description = "the user it logs in as";
                type = lib.types.str;
              };
              root = lib.mkOption {
                description = "the directory on the server the mount is of";
                type = lib.types.str;
                default = "/";
              };
              key = lib.mkOption {
                description = "the entity, by its handle, whose sftp-key the mount logs in with, which has to grant the app's hosts, or null for the app's";
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
            };
          }
        );
        default = null;
      };
      sharing = lib.mkOption {
        description = "whether the user can share from the storage, but a box or an adapter, nextcloud's enable_sharing";
        type = lib.types.bool;
        default = false;
      };
    };
  };

  home = {
    options = {
      host = lib.mkOption {
        description = "the SMB server";
        type = lib.types.str;
      };
      share = lib.mkOption {
        description = "the share on the server";
        type = lib.types.str;
      };
      login = lib.mkOption {
        description = "the user it logs in as";
        type = lib.types.str;
      };
      key = lib.mkOption {
        description = "the entity, by its handle, whose smb-password it logs in with, which has to grant the app's hosts";
        type = lib.types.str;
      };
    };
  };

  entityOf =
    option: handle:
    org.entities.${handle}
      or (throw "app.${app.name}.nextcloud.${option}: ${handle} is no entity of the org's.");

  kinds = [
    "box"
    "adapter"
    "bind"
    "allotment"
    "sftp"
  ];

  # Policy: a storage is of one kind, and a user has one home at most, a box or an adapter, which is their data, and
  # the rest folders in it.
  checked = lib.mapAttrs (
    user: storages:
    let
      homes = lib.attrNames (
        lib.filterAttrs (_: storage: storage.box != null || storage.adapter != null) storages
      );
    in
    if lib.length homes > 1 then
      throw "app.${app.name}.nextcloud.storages.${user}: ${lib.concatStringsSep " and " homes} are both homes, boxes or adapters, and a user's home is their data: keep one."
    else
      lib.mapAttrs (
        name: storage:
        let
          set = lib.filter (kind: storage.${kind} != null) kinds;
        in
        if lib.length set != 1 then
          throw "app.${app.name}.nextcloud.storages.${user}.${name}: a storage is a box, an adapter, a bind, an allotment or an sftp server: set one of them${
            lib.optionalString (set != [ ]) ", not ${lib.concatStringsSep " and " set}"
          }."
        else
          storage // { kind = lib.head set; }
      ) storages
  ) config.storages;

  ofKind =
    kind:
    lib.concatLists (
      lib.mapAttrsToList (
        user: storages:
        lib.mapAttrsToList (name: storage: storage // { inherit user name; }) (
          lib.filterAttrs (_: storage: storage.kind == kind) storages
        )
      ) checked
    );

  servers =
    user: folder: mount:
    let
      fail = message: throw "app.${app.name}.nextcloud.storages.${user}.${folder}: ${message}";
      allotment = org.allotment.${mount.allotment};
    in
    if mount.sftp != null then
      lib.genAttrs app.run-on-hosts (_: {
        inherit (mount.sftp) host login root;
        changes = null;
      })
    else if !(allotment.logins ? ${app.handle}) then
      fail "${mount.allotment} lets ${app.handle} in by sftp only from its sftp: add it there."
    else
      # Accommodating for nextcloud, which keeps the host keys it knows as host::key lines, split at the first ::.
      lib.mapAttrs (_: login: {
        host = login.address4;
        inherit (login) login root changes;
      }) allotment.logins.${app.handle};

  key =
    user: folder: mount:
    let
      handle = if mount.sftp.key or null == null then app.handle else mount.sftp.key;
      entity = entityOf "storages.${user}.${folder}.sftp.key" handle;
    in
    {
      inherit handle;
      secret = {
        name = "${entity.name}/sftp-key";
        inherit (entity.secrets) sopsFile;
      };
      publicKey = entity.publicKeys.sftp-key;
    };
in
{
  options = {
    storages = lib.mkOption {
      description = "the storages of each Nextcloud user, by user, then by name: a box or an adapter, which is their data, and the rest each a folder of its name in it, or, without either, in a folder no one can write in; a Keycloak user without one logs in to nothing they can write in";
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.submodule storage));
      default = { };
      example = lib.literalExpression ''
        {
          alice.box.box = { host = "box.example.com"; share = "alice"; login = "alice"; key = "store-box"; };
          alice.web = { allotment = "user-alice@web"; sharing = true; };
        }
      '';
    };
    shares = lib.mkOption {
      description = "each box, with its user and the key it logs in with";
      internal = true;
      readOnly = true;
      type = lib.types.listOf lib.types.raw;
      default = map (
        storage:
        let
          entity = entityOf "storages.${storage.user}.${storage.name}.box.key" storage.box.key;
        in
        {
          inherit (storage) user;
          inherit (storage.box) host share login;
          key = {
            handle = storage.box.key;
            secret = {
              name = "${entity.name}/smb-password";
              inherit (entity.secrets) sopsFile;
            };
          };
        }
      ) (ofKind "box");
      defaultText = lib.literalMD "each box of `storages`, with its user and its `key`'s smb-password";
    };
    adapters = lib.mkOption {
      description = "each adapter, with its user, the home that's their data and its owner";
      internal = true;
      readOnly = true;
      type = lib.types.listOf lib.types.raw;
      default = map (
        storage:
        let
          option = "storages.${storage.user}.${storage.name}.adapter";
          entity = entityOf option storage.adapter;
        in
        {
          inherit (storage) user;
          path =
            if entity.principal.home == "/var/empty" then
              throw "app.${app.name}.nextcloud.${option}: ${storage.adapter} has no home: set its principal.hasHome."
            else
              entity.principal.home;
          owner = entity.name;
        }
      ) (ofKind "adapter");
      defaultText = lib.literalMD "each adapter of `storages`, with its user and its entity's home";
    };
    binds = lib.mkOption {
      description = "each bind, at its folder, for its user, with the directory it's of and whether it can be shared from";
      internal = true;
      readOnly = true;
      type = lib.types.listOf lib.types.raw;
      default = map (storage: {
        mountPoint = "/${storage.name}";
        inherit (storage) user sharing;
        path = storage.bind;
      }) (ofKind "bind");
      defaultText = lib.literalMD "each bind of `storages`, at its name";
    };
    users = lib.mkOption {
      description = "the Nextcloud users with storages, each with whether one is their home, a box or an adapter";
      internal = true;
      readOnly = true;
      type = lib.types.attrsOf lib.types.bool;
      default = lib.mapAttrs (
        _: storages:
        lib.any (
          storage:
          lib.elem storage.kind [
            "box"
            "adapter"
          ]
        ) (lib.attrValues storages)
      ) checked;
      defaultText = lib.literalMD "each user of `storages`, with whether one is a box or an adapter";
    };
    mounts = lib.mkOption {
      description = "for each host the app runs on, its external storages: each at its folder, for its user, with the server it reaches there and how it follows what changes there, the key it logs in with and whether it can be shared from";
      internal = true;
      readOnly = true;
      type = lib.types.lazyAttrsOf lib.types.raw;
      default = lib.genAttrs app.run-on-hosts (
        on:
        lib.concatLists (
          lib.mapAttrsToList
            (
              user:
              lib.mapAttrsToList (
                folder: mount: {
                  mountPoint = "/${folder}";
                  inherit user;
                  inherit (mount) sharing;
                  server = (servers user folder mount).${on};
                  key = key user folder mount;
                }
              )
            )
            (
              lib.mapAttrs (
                _:
                lib.filterAttrs (
                  _: storage:
                  lib.elem storage.kind [
                    "allotment"
                    "sftp"
                  ]
                )
              ) checked
            )
        )
      );
      defaultText = lib.literalMD "for each of the app's `run-on-hosts`, each allotment and sftp server of `storages` with its server there and its `sftp.key`'s sftp-key, or the app's";
    };
    keycloak = lib.mkOption {
      description = "the keycloak app nextcloud's users log in with, or null for nextcloud's own logins alone";
      type = lib.types.nullOr context.types.app.ref;
      default = null;
    };
    realm = lib.mkOption {
      description = "the keycloak realm of nextcloud's client";
      type = lib.types.str;
      default = "";
    };
    client = lib.mkOption {
      description = "nextcloud's client, which the keycloak app keeps in the realm, as Keycloak's admin API represents it, or null";
      internal = true;
      readOnly = true;
      type = lib.types.raw;
      # Dependency: nixos/apps/nextcloud.nix logs in with user_oidc, whose code route is /apps/user_oidc/code, and
      # which proves its code with PKCE where the realm offers it.
      default = lib.mapNullable (keycloak: {
        inherit keycloak;
        inherit (config) realm;
        app = app.handle;
        secret = {
          name = "${app.name}/oidc-secret";
          inherit (app.secrets) sopsFile;
        };
        representation = {
          clientId = app.name;
          enabled = true;
          protocol = "openid-connect";
          publicClient = false;
          standardFlowEnabled = true;
          implicitFlowEnabled = false;
          directAccessGrantsEnabled = false;
          serviceAccountsEnabled = false;
          # Policy: its tokens carry no roles, as it reads none, rather than every role, as Keycloak's full scope,
          # which it deprecates, gives.
          fullScopeAllowed = false;
          redirectUris = [
            "${app.url}/apps/user_oidc/code"
            "${app.url}/index.php/apps/user_oidc/code"
          ];
          attributes = {
            "pkce.code.challenge.method" = "S256";
            "post.logout.redirect.uris" = "${app.url}/*";
          };
        };
      }) config.keycloak;
      defaultText = lib.literalMD "a confidential client with the app's `oidc-secret`, or null without a `keycloak`";
    };
  };
}
