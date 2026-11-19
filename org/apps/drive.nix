{
  config,
  context,
  lib,
  ...
}:
let
  inherit (context) org;

  storage = {
    options = {
      bind = lib.mkOption {
        description = "the directory on the app's hosts the storage is of, which nextcloud's user can write in, or null";
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
                description = "the server, as Nextcloud takes it: a name, or an IPv6 address in brackets";
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
      photos = lib.mkOption {
        description = "the photos app the storage is a drop folder of, which takes what's put there into the user's library there, deleting it, or null";
        type = lib.types.nullOr context.types.app.ref;
        default = null;
      };
      library = lib.mkOption {
        description = "the photos app whose library of the user the storage is, read-only, from the root's share, or null";
        type = lib.types.nullOr context.types.app.ref;
        default = null;
      };
      sharing = lib.mkOption {
        description = "whether the user can share from the storage, Nextcloud's enable_sharing";
        type = lib.types.bool;
        default = false;
      };
    };
  };

  entityOf =
    option: handle:
    org.entities.${handle}
      or (throw "app.${config.name}.${option}: ${handle} is no entity of the org's.");

  kinds = [
    "bind"
    "allotment"
    "sftp"
    "photos"
    "library"
  ];

  # Policy: a storage is of one kind, a folder of its name in its user's root.
  checked = lib.mapAttrs (
    user:
    lib.mapAttrs (
      name: storage:
      let
        set = lib.filter (kind: storage.${kind} != null) kinds;
      in
      if lib.length set != 1 then
        throw "app.${config.name}.storages.${user}.${name}: a storage is a bind, an allotment, an sftp server, or a photos app's drop folder or library: set one of them${
          lib.optionalString (set != [ ]) ", not ${lib.concatStringsSep " and " set}"
        }."
      else
        storage // { kind = lib.head set; }
    )
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

  # Policy: a drop folder is a directory in its photos app's home, which the photos app takes from on the host they
  # both run on, for a user it has a root of, as one without could upload nothing.
  drop =
    storage:
    let
      at = "app.${config.name}.storages.${storage.user}.${storage.name}";
      photos = org.app.${storage.photos};
      elsewhere = lib.subtractLists photos.run-on-hosts config.run-on-hosts;
    in
    if photos.kind != "photos" then
      throw "${at}: ${storage.photos} is no photos app: name one of kind photos."
    else if !(photos.roots ? ${storage.user}) then
      throw "${at}: ${storage.photos} has no root of ${storage.user}, whose library could take nothing: set app.${storage.photos}.roots.${storage.user}."
    else if elsewhere != [ ] then
      throw "${at}: ${storage.photos} doesn't run on ${lib.concatStringsSep " and " elsewhere}, where ${config.name} does, which a drop folder is a directory of: run both on the same hosts."
    else
      {
        mountPoint = "/${storage.name}";
        inherit (storage) user sharing photos;
        drive = config.name;
        path = "${photos.principal.home}/drop/${storage.user}/${config.name}/${storage.name}";
        owner = photos.name;
      };

  # Policy: a library is read from its root's share alone, which Immich alone writes in.
  library =
    storage:
    let
      at = "app.${config.name}.storages.${storage.user}.${storage.name}";
      photos = org.app.${storage.library};
      root = lib.findFirst (share: share.user == storage.user) null (photos.shares or [ ]);
    in
    if photos.kind != "photos" then
      throw "${at}: ${storage.library} is no photos app: name one of kind photos."
    else if root == null then
      throw "${at}: ${storage.library} has no root of ${storage.user}, which their library is: set app.${storage.library}.roots.${storage.user}."
    else
      {
        mountPoint = "/${storage.name}";
        inherit (storage) user sharing;
        photos = storage.library;
        inherit (root)
          host
          share
          login
          key
          ;
      };

  servers =
    user: folder: mount:
    let
      fail = message: throw "app.${config.name}.storages.${user}.${folder}: ${message}";
      allotment = org.allotment.${mount.allotment};
    in
    if mount.sftp != null then
      lib.genAttrs config.run-on-hosts (_: {
        inherit (mount.sftp) host login root;
        changes = null;
      })
    else if !(allotment.logins ? ${config.handle}) then
      fail "${mount.allotment} lets ${config.handle} in by sftp only from its sftp: add it there."
    else
      # Accommodating for Nextcloud, which keeps the host keys it knows as host::key lines, split at the first ::.
      lib.mapAttrs (_: login: {
        host = login.address4;
        inherit (login) login root changes;
      }) allotment.logins.${config.handle};

  key =
    user: folder: mount:
    let
      handle = if mount.sftp.key or null == null then config.handle else mount.sftp.key;
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
  imports = [ ./roots.nix ];

  options = {
    storages = lib.mkOption {
      description = "the storages of each Nextcloud user, by user, then by name: each a folder of its name in their root, or, without one, in a folder no one can write in";
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.submodule storage));
      default = { };
      example = lib.literalExpression ''
        {
          alice.web = { allotment = "user-alice@web"; sharing = true; };
        }
      '';
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
    drops = lib.mkOption {
      description = "each drop folder, at its folder, for its user, with the photos app and the directory in its home it's of, its owner, and whether it can be shared from";
      internal = true;
      readOnly = true;
      type = lib.types.listOf lib.types.raw;
      default = map drop (ofKind "photos");
      defaultText = lib.literalMD "each photos drop folder of `storages`, at its name";
    };
    libraries = lib.mkOption {
      description = "each photos library, at its folder, for its user, with the photos app, and the share of its root and the key it logs in with";
      internal = true;
      readOnly = true;
      type = lib.types.listOf lib.types.raw;
      default = map library (ofKind "library");
      defaultText = lib.literalMD "each photos library of `storages`, at its name";
    };
    users = lib.mkOption {
      description = "the Nextcloud users with a root or storages, each with whether they have a root";
      internal = true;
      readOnly = true;
      type = lib.types.attrsOf lib.types.bool;
      default = lib.mapAttrs (_: _: false) config.storages // lib.mapAttrs (_: _: true) config.roots;
      defaultText = lib.literalMD "each user of `roots` or `storages`, with whether they're of `roots`";
    };
    mounts = lib.mkOption {
      description = "for each host the app runs on, its external storages: each at its folder, for its user, with the server it reaches there and how it follows what changes there, the key it logs in with and whether it can be shared from";
      internal = true;
      readOnly = true;
      type = lib.types.lazyAttrsOf lib.types.raw;
      default = lib.genAttrs config.run-on-hosts (
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
      description = "the keycloak app Nextcloud's users log in with, or null for Nextcloud's own logins alone";
      type = lib.types.nullOr context.types.app.ref;
      default = null;
    };
    realm = lib.mkOption {
      description = "the keycloak realm of Nextcloud's client";
      type = lib.types.str;
      default = "";
    };
    client = lib.mkOption {
      description = "Nextcloud's client, which the keycloak app keeps in the realm, as Keycloak's admin API represents it, or null";
      internal = true;
      readOnly = true;
      type = lib.types.raw;
      # Dependency: nixos/apps/drive.nix logs in with user_oidc, whose code route is /apps/user_oidc/code, which
      # proves its code with PKCE where the realm offers it, and which takes a logout from the realm at
      # /apps/user_oidc/backchannel-logout/<provider>, its provider named as the realm is.
      default = lib.mapNullable (keycloak: {
        inherit keycloak;
        inherit (config) realm;
        app = config.handle;
        secret = {
          name = "${config.name}/oidc-secret";
          inherit (config.secrets) sopsFile;
        };
        representation = {
          clientId = config.name;
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
            "${config.url}/apps/user_oidc/code"
            "${config.url}/index.php/apps/user_oidc/code"
          ];
          # Policy: logging out of the realm logs out of Nextcloud, which Keycloak tells as it ends the user's session.
          attributes = {
            "pkce.code.challenge.method" = "S256";
            "post.logout.redirect.uris" = "${config.url}/*";
            "backchannel.logout.url" =
              "${config.url}/index.php/apps/user_oidc/backchannel-logout/"
              + lib.escapeURL (org.app.${keycloak}.realms.${config.realm}.displayName or config.realm);
            "backchannel.logout.session.required" = "true";
          };
        };
      }) config.keycloak;
      defaultText = lib.literalMD "a confidential client with the app's `oidc-secret`, which logs out of nextcloud as the realm does, or null without a `keycloak`";
    };
  };
}
