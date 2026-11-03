{
  config,
  lib,
  context,
  ...
}:
{
  imports = [
    ./entity.nix
  ];

  config = {
    class = "service";
    keys = lib.optionalAttrs (config.namespace != null) { tls-cert = "tls-cert"; };
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
    data = lib.mkOption {
      description = "arbitrary data to service";
      type = with lib.types; attrsOf anything;
    };
  };
}
