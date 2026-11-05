{
  config,
  lib,
  context,
  name,
  ...
}:
{
  imports = [
    ./entity.nix
  ];

  config = {
    class = "service";
    keys =
      lib.optionalAttrs (config.namespace != null) { tls-cert = "tls-cert"; }
      # Dependency: o11n's modules read these keys of the services they name.
      // {
        # Dependency: crates/o11n/src/host.rs logs in to a host's locksmith with it.
        locksmith.ssh-key = "ssh";
        nix-remote = {
          secret-key = "passphrase";
          ssh-key = "ssh";
        };
        nix-serve.nix-sign = "nix-sign";
        # Dependency: nixos/org/system.nix and nixos/org/rescue-usb.nix let root in with them, and o11n logs in with the
        # ssh-key as root.
        rescue = {
          passwd = "password";
          ssh-key = "ssh";
        };
      }
      .${config.name} or { };
  };

  options = {
    endpoint = lib.mkOption {
      description = "maybe canonical name on internet";
      default = null;
      type = with lib.types; nullOr str;
    };
    vpn = lib.mkOption {
      description = "the vpn the service serves on, at its address on each host it's on, or null";
      default = null;
      type = lib.types.nullOr context.types.vpn.ref;
    };
    namespace = lib.mkOption {
      description = "the namespace whose tls-cert the service holds, for it and its subdomains, or null";
      type = lib.types.nullOr lib.types.str;
      readOnly = true;
      default =
        let
          namespace = lib.removePrefix "domain-" config.name;
        in
        if
          namespace != config.name
          && lib.elem namespace (
            context.org.namespaces ++ lib.mapAttrsToList (_: vpn: vpn.namespace) context.org.vpn
          )
        then
          namespace
        else
          null;
      defaultText = lib.literalMD "`<namespace>` for the service `domain-<namespace>`, of a namespace in the org's `namespaces` or a vpn's `namespace`, or else `null`";
    };
    hosts = lib.mkOption {
      description = "the service's settings on each host it's on, which its configuration reads, typed by o11n's org/services/<name>.nix when that exists";
      type = lib.types.attrsOf (
        if builtins.pathExists (./services + "/${name}.nix") then
          lib.types.submoduleWith {
            modules = [ (./services + "/${name}.nix") ];
            specialArgs = { inherit context; };
          }
        else
          lib.types.attrsOf lib.types.anything
      );
      default = { };
      apply =
        hosts:
        let
          stray = lib.filter (
            host: !lib.any (service: service.name == config.name) (context.org.host.${host}.services or [ ])
          ) (lib.attrNames hosts);
        in
        lib.throwIf (stray != [ ])
          "service.${config.name}.hosts has settings for ${lib.concatStringsSep ", " stray}, which the service isn't on: give each a role with the service, or drop its settings."
          hosts;
    };
    configurationFile = lib.mkOption {
      description = "the configuration a host with the service imports, or null";
      type = lib.types.nullOr lib.types.path;
      default = lib.findFirst builtins.pathExists null [
        (../nixos/services + "/${config.name}.nix")
        (context.path + "/services/${config.name}.nix")
      ];
      defaultText = lib.literalMD "o11n's `nixos/services/<name>.nix`, or else the org's `services/<name>.nix`, if either exists";
    };
    data = lib.mkOption {
      description = "arbitrary data to service";
      type = with lib.types; attrsOf anything;
    };
  };
}
