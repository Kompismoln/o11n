{
  app,
  config,
  context,
  lib,
  ...
}:
let
  inherit (context) org;

  # Policy: nextcloud reaches an allotment over its vpn, or without one over the first vpn the host that runs nextcloud
  # shares with the allotment's host, as a replica does, and mounts it as the user it's for, at its host's name.
  mount =
    on: name:
    let
      allotment = org.allotment.${name};
      entity = org.entities.${allotment.entity};
      vpn = if allotment.vpn != null then allotment.vpn else org.host.${on}.shares.${allotment.host};
      fail = message: throw "app.${app.name}.nextcloud.allotments: ${name}: ${message}";
    in
    if entity.class != "user" then
      fail "${allotment.entity} is no user, whose nextcloud account would have it: mount only a user's allotment."
    else if on == allotment.host then
      fail "${on} runs ${app.name} and has the allotment, which nextcloud reaches over a vpn: run it on another host."
    else if vpn == null then
      fail "${on}, which runs ${app.name}, shares no vpn with ${allotment.host}: put both on one."
    else if
      !(lib.all (host: lib.elem vpn org.host.${host}.vpns) [
        on
        allotment.host
      ])
    then
      fail "${on}, which runs ${app.name}, would reach ${allotment.host} over ${vpn}, which both aren't on: put both on it, or set the allotment's vpn to one they are."
    else if !(lib.elem allotment.host org.vpn.${vpn}.reaches.${on}) then
      fail "${on}, which runs ${app.name}, would reach ${allotment.host} over ${vpn}, a mesh on which neither has an endpoint to be dialed at: give one of them an endpoint, or set the allotment's vpn to another."
    else
      {
        inherit name;
        inherit (allotment) entity host;
        user = entity.name;
        address = org.host.${allotment.host}.network.${vpn}.address;
        from = org.host.${on}.network.${vpn}.address;
        chroot = dirOf allotment.path;
        root = "/${baseNameOf allotment.path}";
        mountPoint = "/${allotment.host}";
      };
in
{
  options = {
    allotments = lib.mkOption {
      description = "the allotments, each as <handle>@<host>, nextcloud mounts as external storage, over SFTP, for the user each is for, at its host's name";
      type = lib.types.listOf (lib.types.enum (lib.attrNames (context.spec.allotment or { })));
      default = [ ];
      example = [ "user-alice@web" ];
    };
    mounts = lib.mkOption {
      description = "for each host the app runs on, the allotments it mounts: each with its user, its host's address and the host's own on the vpn it's reached on, and its root within the directory sftp is jailed to";
      internal = true;
      readOnly = true;
      type = lib.types.lazyAttrsOf lib.types.raw;
      default = lib.genAttrs app.run-on-hosts (on: map (mount on) config.allotments);
      defaultText = lib.literalMD "for each of the app's `run-on-hosts`, each of `allotments`, reached over its `vpn` or the first vpn the host shares with the allotment's";
    };
    collabora = lib.mkOption {
      description = "the collabora app whose endpoint nextcloud's office uses, or null";
      type = lib.types.nullOr context.types.app.ref;
      default = null;
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
